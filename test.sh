#!/usr/bin/env bash
# cuzz smoke suite. Exercises the storage layer, the REST API, SSE, auth and
# crash-safety against a real binary on a real port. No mocks.
set -uo pipefail
cd "$(dirname "$0")"

CUZZ="$PWD/cuzz"
PORT="${PORT:-17799}"
WORK="$(mktemp -d)"
export CUZZ_DB="$WORK/cuzz.data"
export CUZZ_PASSWORD="test-pw"
export CUZZ_HUMAN="javi"
unset CUZZ_TOKEN CUZZ_URL CUZZ_LOCAL CUZZ_AGENT 2>/dev/null || true

PASS=0
FAIL=0
SPID=""

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     got:      %s\n' "$1" "$2" "$3"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }
# is_eq NAME ACTUAL EXPECTED
jq_() { python3 -c "import sys,json;d=json.load(sys.stdin);
import functools
p='$1'.split('.')
v=d
for k in p:
    if k=='': continue
    v = v[int(k)] if k.isdigit() else v[k]
print(v)" 2>/dev/null || echo "<parse-error>"; }

cleanup() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

[ -x "$CUZZ" ] || { echo "no ./cuzz — run ./build.sh first"; exit 1; }

echo "cuzz smoke  (db=$CUZZ_DB port=$PORT)"

# ---------------------------------------------------------------- storage
echo "storage (--local, no server)"
export CUZZ_LOCAL=1
INIT=$("$CUZZ" init --agents merger,rebaser)
is "init reports ok" "$(echo "$INIT" | jq_ ok)" "True"
AGENT_TOK=$(echo "$INIT" | jq_ data.agents.0.token)
case "$AGENT_TOK" in ct_*) ok "init mints an agent token" ;; *) bad "init mints an agent token" "ct_*" "$AGENT_TOK" ;; esac
is "init creates the default channels" "$(echo "$INIT" | jq_ data.channels.1)" "hitl"

CUZZ_AGENT=merger "$CUZZ" send -c am-fleet -k action -m "MERGED #817" >/dev/null
CUZZ_AGENT=agent-1 "$CUZZ" send -c am-fleet -m "starting #818" >/dev/null
CUZZ_AGENT=agent-2 "$CUZZ" send -c am-fleet -k alert -m 'PR #823 needs "CEO"' >/dev/null
is "three messages stored" "$("$CUZZ" get -c am-fleet | jq_ data.count)" "3"
is "kind filter narrows to the alert" "$("$CUZZ" get -c am-fleet -k alert | jq_ data.count)" "1"
is "quotes survive the round trip" "$("$CUZZ" get -c am-fleet -k alert | jq_ data.messages.0.content)" 'PR #823 needs "CEO"'
is "search is case-insensitive" "$("$CUZZ" search -q merged | jq_ data.count)" "1"
is "a new channel is auto-created on send" "$(CUZZ_AGENT=x "$CUZZ" send -c freshroom -m hi >/dev/null; "$CUZZ" channels | jq_ data.count)" "3"

WM=$("$CUZZ" get -c am-fleet | jq_ data.watermark)
is "the watermark is caught up" "$("$CUZZ" get -c am-fleet --since "$WM" | jq_ data.count)" "0"
CUZZ_AGENT=javi "$CUZZ" send -c am-fleet -m "CEO: approve" >/dev/null
is "the watermark resumes at exactly one new" "$("$CUZZ" get -c am-fleet --since "$WM" | jq_ data.count)" "1"
is "an RFC-3339 --since works too" "$("$CUZZ" get -c am-fleet --since 2020-01-01T00:00:00Z | jq_ data.count)" "4"

"$CUZZ" send -c "BAD NAME" -m x >/dev/null 2>&1; is "an invalid channel exits 80" "$?" "80"
"$CUZZ" send -c ok -k nope -m x >/dev/null 2>&1; is "an unknown kind exits 80" "$?" "80"
"$CUZZ" send -c ok -m "" >/dev/null 2>&1;         is "empty content exits 80" "$?" "80"
unset CUZZ_LOCAL

# ---------------------------------------------------------------- serve
echo "http relay"
"$CUZZ" serve --port "$PORT" >"$WORK/serve.log" 2>&1 &
SPID=$!
for _ in $(seq 1 40); do curl -sf "localhost:$PORT/health" >/dev/null 2>&1 && break; sleep 0.15; done

is "health is unauthenticated" "$(curl -s "localhost:$PORT/health" | jq_ data.status)" "ok"
is "guide is unauthenticated" "$(curl -s "localhost:$PORT/guide" | jq_ tool)" "cuzz"
is "llms.txt is served" "$(curl -s -o /dev/null -w '%{http_code}' "localhost:$PORT/llms.txt")" "200"
is "the chat page is served at /" "$(curl -s -o /dev/null -w '%{http_code}' "localhost:$PORT/")" "200"
is "/api needs a token" "$(curl -s -o /dev/null -w '%{http_code}' "localhost:$PORT/api/messages")" "401"
is "a bogus token is refused" "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer nope' "localhost:$PORT/api/messages")" "401"
is "the agent token is accepted" "$(curl -s -H "Authorization: Bearer $AGENT_TOK" "localhost:$PORT/api/whoami" | jq_ data.agent)" "merger"
is "the password identifies the human" "$(curl -s -H "Authorization: Bearer $CUZZ_PASSWORD" "localhost:$PORT/api/whoami" | jq_ data.agent)" "javi"
is "the password is admin" "$(curl -s -H "Authorization: Bearer $CUZZ_PASSWORD" "localhost:$PORT/api/whoami" | jq_ data.role)" "admin"

export CUZZ_URL="http://127.0.0.1:$PORT" CUZZ_TOKEN="$AGENT_TOK"
is "the CLI sends over HTTP" "$("$CUZZ" send -c am-fleet -k status -m "verify PASSED on #822" | jq_ data.author)" "merger"
is "the CLI reads over HTTP" "$("$CUZZ" get -c am-fleet | jq_ data.count)" "5"
is "an editor token cannot create a channel" "$(curl -s -o /dev/null -w '%{http_code}' -X POST "localhost:$PORT/api/channels" -H "Authorization: Bearer $AGENT_TOK" -H 'Content-Type: application/json' -d '{"name":"nope"}')" "403"
is "an admin token can create a channel" "$(curl -s -o /dev/null -w '%{http_code}' -X POST "localhost:$PORT/api/channels" -H "Authorization: Bearer $CUZZ_PASSWORD" -H 'Content-Type: application/json' -d '{"name":"adminmade"}')" "201"
is "a newline survives the JSON round trip" "$(curl -s -X POST "localhost:$PORT/api/messages" -H "Authorization: Bearer $CUZZ_PASSWORD" -H 'Content-Type: application/json' -d '{"channel":"am-fleet","content":"line1\nline2"}' | jq_ data.content | wc -l)" "2"

is "an editor token cannot mint a token" "$(curl -s -o /dev/null -w '%{http_code}' -X POST "localhost:$PORT/api/tokens" -H "Authorization: Bearer $AGENT_TOK" -H 'Content-Type: application/json' -d '{"agent":"sneaky"}')" "403"
is "an editor token cannot list tokens" "$(curl -s -o /dev/null -w '%{http_code}' "localhost:$PORT/api/tokens" -H "Authorization: Bearer $AGENT_TOK")" "403"
is "an admin mints a token over HTTP" "$(curl -s -X POST "localhost:$PORT/api/tokens" -H "Authorization: Bearer $CUZZ_PASSWORD" -H 'Content-Type: application/json' -d '{"agent":"supervisor","role":"editor"}' | jq_ data.created)" "1"
is "minting is idempotent per agent" "$(curl -s -X POST "localhost:$PORT/api/tokens" -H "Authorization: Bearer $CUZZ_PASSWORD" -H 'Content-Type: application/json' -d '{"agent":"supervisor","role":"editor"}' | jq_ data.created)" "0"
is "the re-minted token is the same one" "$(curl -s -X POST "localhost:$PORT/api/tokens" -H "Authorization: Bearer $CUZZ_PASSWORD" -H 'Content-Type: application/json' -d '{"agent":"supervisor"}' | jq_ data.token)" "$(curl -s -X POST "localhost:$PORT/api/tokens" -H "Authorization: Bearer $CUZZ_PASSWORD" -H 'Content-Type: application/json' -d '{"agent":"supervisor"}' | jq_ data.token)"
is "a bad agent name is refused" "$(curl -s -o /dev/null -w '%{http_code}' -X POST "localhost:$PORT/api/tokens" -H "Authorization: Bearer $CUZZ_PASSWORD" -H 'Content-Type: application/json' -d '{"agent":"BAD NAME"}')" "400"
is "a bad role is refused" "$(curl -s -o /dev/null -w '%{http_code}' -X POST "localhost:$PORT/api/tokens" -H "Authorization: Bearer $CUZZ_PASSWORD" -H 'Content-Type: application/json' -d '{"agent":"ok","role":"root"}')" "400"
is "listing tokens never echoes a secret" "$(curl -s "localhost:$PORT/api/tokens" -H "Authorization: Bearer $CUZZ_PASSWORD" | grep -c "$AGENT_TOK")" "0"
is "the CLI mints over HTTP" "$(CUZZ_TOKEN=$CUZZ_PASSWORD "$CUZZ" token --agent glm-supervisor | jq_ data.agent)" "glm-supervisor"
is "a minted token actually works" "$(TOK=$(CUZZ_TOKEN=$CUZZ_PASSWORD "$CUZZ" token --agent glm-supervisor | jq_ data.token); curl -s "localhost:$PORT/api/whoami" -H "Authorization: Bearer $TOK" | jq_ data.agent)" "glm-supervisor"

# --tail: the newest n, in chronological order. A plain --limit cannot express
# this — ascending order means limit takes the OLDEST n.
for i in 1 2 3 4 5 6 7 8; do CUZZ_LOCAL=1 CUZZ_AGENT=bot "$CUZZ" send -c ordering -m "m$i" >/dev/null; done
is "limit takes the oldest n"        "$(CUZZ_LOCAL=1 "$CUZZ" get -c ordering --limit 3 | jq_ data.messages.0.content)" "m1"
is "limit's last is not the newest"  "$(CUZZ_LOCAL=1 "$CUZZ" get -c ordering --limit 3 | jq_ data.messages.2.content)" "m3"
is "tail takes the newest n"         "$(CUZZ_LOCAL=1 "$CUZZ" get -c ordering --tail 3 | jq_ data.messages.2.content)" "m8"
is "tail is still chronological"     "$(CUZZ_LOCAL=1 "$CUZZ" get -c ordering --tail 3 | jq_ data.messages.0.content)" "m6"
is "tail's watermark is the newest"  "$(CUZZ_LOCAL=1 "$CUZZ" get -c ordering --tail 3 | jq_ data.watermark)" "$(CUZZ_LOCAL=1 "$CUZZ" get -c ordering --limit 0 | jq_ data.watermark)"
is "tail resumes with no gap"        "$(CUZZ_LOCAL=1 "$CUZZ" get -c ordering --since "$(CUZZ_LOCAL=1 "$CUZZ" get -c ordering --tail 3 | jq_ data.watermark)" | jq_ data.count)" "0"

# channel delete: takes the messages with it, admin only, and asks first.
# NB: seeded over HTTP, not --local. The server is running and owns the file;
# a --local write here would be the concurrent writer cuzz exists to avoid.
"$CUZZ" send -c doomed -m "one" >/dev/null
"$CUZZ" send -c doomed -m "two" >/dev/null
"$CUZZ" send -c keeper -m "survivor" >/dev/null
is "delete without --yes refuses"     "$(CUZZ_TOKEN=$CUZZ_PASSWORD "$CUZZ" channels --delete doomed >/dev/null 2>&1; echo $?)" "80"
is "the channel is still there"       "$("$CUZZ" get -c doomed --limit 0 | jq_ data.count)" "2"
is "an editor token cannot delete"    "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "localhost:$PORT/api/channels/doomed" -H "Authorization: Bearer $AGENT_TOK")" "403"
is "an unknown channel is refused"    "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "localhost:$PORT/api/channels/ghost" -H "Authorization: Bearer $CUZZ_PASSWORD")" "400"
is "admin deletes, messages counted"  "$(CUZZ_TOKEN=$CUZZ_PASSWORD "$CUZZ" channels --delete doomed --yes | jq_ data.messages_deleted)" "2"
is "the channel is gone from the list" "$(CUZZ_TOKEN=$CUZZ_PASSWORD "$CUZZ" channels | grep -c '\"doomed\"')" "0"
is "its messages are gone too"        "$(CUZZ_TOKEN=$CUZZ_PASSWORD "$CUZZ" get -c doomed --limit 0 | jq_ data.count)" "0"
is "a neighbouring channel survives"  "$(CUZZ_TOKEN=$CUZZ_PASSWORD "$CUZZ" get -c keeper --limit 0 | jq_ data.count)" "1"
is "deleting it twice is refused"     "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "localhost:$PORT/api/channels/doomed" -H "Authorization: Bearer $CUZZ_PASSWORD")" "400"

# cuzz rm + the impersonation guard
MID=$("$CUZZ" send -c keeper -m "delete me" | jq_ data.id)
is "rm without --yes refuses"        "$("$CUZZ" rm "$MID" >/dev/null 2>&1; echo $?)" "80"
is "the message is still there"      "$("$CUZZ" get -c keeper --limit 0 | jq_ data.count)" "2"
is "an editor token cannot rm"       "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "localhost:$PORT/api/messages/$MID" -H "Authorization: Bearer $AGENT_TOK")" "403"
is "admin rm deletes it"             "$(CUZZ_TOKEN=$CUZZ_PASSWORD "$CUZZ" rm "$MID" --yes | jq_ data.count)" "1"
is "and it is really gone"           "$("$CUZZ" get -c keeper --limit 0 | jq_ data.count)" "1"
is "rm of an unknown id is 404"      "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "localhost:$PORT/api/messages/msg_deadbeef" -H "Authorization: Bearer $CUZZ_PASSWORD")" "404"
is "rm rejects a non-message id"     "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "localhost:$PORT/api/messages/nope" -H "Authorization: Bearer $CUZZ_PASSWORD")" "404"

# posting with the operator password authors as the human — that must be LOUD
is "password posts as the human"     "$(CUZZ_TOKEN=$CUZZ_PASSWORD "$CUZZ" send -c keeper -m "who am i" 2>/dev/null | jq_ data.author)" "javi"
is "and warns on stderr"             "$(CUZZ_TOKEN=$CUZZ_PASSWORD "$CUZZ" send -c keeper -m "warn me" 2>&1 >/dev/null | grep -c 'CUZZ_PASSWORD')" "1"
is "the warning names the author"    "$(CUZZ_TOKEN=$CUZZ_PASSWORD "$CUZZ" send -c keeper -m "name me" 2>&1 >/dev/null | grep -c 'authored as')" "1"
is "the warning names javi"           "$(CUZZ_TOKEN=$CUZZ_PASSWORD "$CUZZ" send -c keeper -m "name me 2" 2>&1 >/dev/null | grep -c javi)" "1"
is "an agent token does NOT warn"    "$("$CUZZ" send -c keeper -m "quiet" 2>&1 >/dev/null | grep -c 'CUZZ_PASSWORD')" "0"
is "the warning never hits stdout"   "$(CUZZ_TOKEN=$CUZZ_PASSWORD "$CUZZ" send -c keeper -m "clean stdout" 2>/dev/null | grep -c warning)" "0"
is "whoami reports the identity"     "$("$CUZZ" whoami | jq_ data.agent)" "merger"

# @mentions — a query dimension, not a substring hunt
"$CUZZ" send -c mentions-t -m "plain message, nobody tagged" >/dev/null
"$CUZZ" send -c mentions-t -m "@merger please look at this" >/dev/null
"$CUZZ" send -c mentions-t -m "@rebaser and @merger both" >/dev/null
"$CUZZ" send -c mentions-t -m "@nosuchagent should not register" >/dev/null
"$CUZZ" send -c mentions-t -m "@javi the human is mentionable" >/dev/null
is "an @mention is extracted"        "$("$CUZZ" get -c mentions-t -q "please look" | jq_ data.messages.0.mentions)" "|merger|"
is "two mentions both register"      "$("$CUZZ" get -c mentions-t -q "both" | jq_ data.messages.0.mentions)" "|rebaser|merger|"
is "an unknown @name does NOT"       "$("$CUZZ" get -c mentions-t -q "should not register" | jq_ data.messages.0.mentions)" ""
is "the human is mentionable"        "$("$CUZZ" get -c mentions-t -q "the human is" | jq_ data.messages.0.mentions)" "|javi|"
is "--mentions filters to 2"         "$("$CUZZ" get -c mentions-t --mentions merger --limit 0 | jq_ data.count)" "2"
is "--mentions is exact, not prefix" "$("$CUZZ" get -c mentions-t --mentions merg --limit 0 | jq_ data.count)" "0"
is "--mentions me resolves to token" "$("$CUZZ" get -c mentions-t --mentions me --limit 0 | jq_ data.count)" "2"
is "untagged messages are excluded"  "$("$CUZZ" get -c mentions-t --mentions rebaser --limit 0 | jq_ data.count)" "1"
is "mentions_list is there for UI"   "$("$CUZZ" get -c mentions-t -q "both" | jq_ data.messages.0.mentions_list.1)" "merger"
is "mentions compose with --since"   "$("$CUZZ" get -c mentions-t --mentions merger --since "$("$CUZZ" get -c mentions-t --limit 0 | jq_ data.watermark)" --limit 0 | jq_ data.count)" "0"

is "/api/agents lists mentionables"  "$("$CUZZ" get -c mentions-t --limit 0 >/dev/null; curl -s "localhost:$PORT/api/agents" -H "Authorization: Bearer $AGENT_TOK" | jq_ data.agents.0)" "javi"
is "/api/agents needs auth"          "$(curl -s -o /dev/null -w '%{http_code}' "localhost:$PORT/api/agents")" "401"
is "/api/agents leaks no token"      "$(curl -s "localhost:$PORT/api/agents" -H "Authorization: Bearer $AGENT_TOK" | grep -c "$AGENT_TOK")" "0"
is "an editor may read agents"       "$(curl -s -o /dev/null -w '%{http_code}' "localhost:$PORT/api/agents" -H "Authorization: Bearer $AGENT_TOK")" "200"

# a relay that is not running must say so, with a retryable code
( unset CUZZ_TOKEN; CUZZ_URL=http://127.0.0.1:1 "$CUZZ" get -c am-fleet >/dev/null 2>&1 )
is "an unreachable relay exits 100" "$?" "100"

# ---------------------------------------------------------------- sse
echo "sse"
curl -sN --max-time 5 "localhost:$PORT/events?channel=am-fleet&token=$CUZZ_PASSWORD" >"$WORK/sse.out" 2>&1 &
SSE=$!
sleep 1.2
"$CUZZ" send -c am-fleet -m "live one" >/dev/null
sleep 0.7
"$CUZZ" send -c hitl -k alert -m "other room" >/dev/null
sleep 1.5
kill "$SSE" 2>/dev/null; wait "$SSE" 2>/dev/null
is "the stream opens with a comment frame" "$(head -1 "$WORK/sse.out" | tr -d '\r')" ": connected"
is "the live message is pushed" "$(grep -c 'live one' "$WORK/sse.out")" "1"
is "another channel is not leaked into the stream" "$(grep -c 'other room' "$WORK/sse.out")" "0"
is "an unauthenticated stream is refused" "$(curl -s -o /dev/null -w '%{http_code}' "localhost:$PORT/events?channel=am-fleet")" "401"

# ---------------------------------------------------------------- crash
echo "crash safety (SIGKILL mid-write)"
ACK=0
for i in $(seq 1 120); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "localhost:$PORT/api/messages" \
    -H "Authorization: Bearer $AGENT_TOK" -H 'Content-Type: application/json' \
    -d "{\"channel\":\"smoke\",\"content\":\"m$i\"}")
  [ "$code" = "201" ] && ACK=$((ACK+1))
done
kill -9 "$SPID" 2>/dev/null
sleep 0.8
if kill -0 "$SPID" 2>/dev/null; then bad "the server is dead before we read" "dead" "alive"; else ok "the server is dead before we read"; fi
SPID=""
is "every acked write survives SIGKILL" "$(CUZZ_LOCAL=1 "$CUZZ" get -c smoke --limit 0 | jq_ data.count)" "$ACK"
is "the database still reads after SIGKILL" "$(CUZZ_LOCAL=1 "$CUZZ" status | jq_ data.status)" "ok"

# ---------------------------------------------------------------- contract
echo "agent-first contract"
is "guide is valid json" "$("$CUZZ" guide | jq_ tool)" "cuzz"
is "help-json lists commands" "$("$CUZZ" help-json | jq_ commands.0.name)" "init"
is "version is machine-readable" "$("$CUZZ" version | jq_ data.tool)" "cuzz"
is "no args exits 80" "$("$CUZZ" >/dev/null 2>&1; echo $?)" "80"
is "stdout stays clean on error" "$("$CUZZ" send -c 'BAD NAME' -m x 2>/dev/null | wc -c)" "0"

echo
echo "passed $PASS · failed $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
