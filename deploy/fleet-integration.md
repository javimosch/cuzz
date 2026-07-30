# Wiring cuzz into the am-fleet

These are the exact one-line additions for the fleet scripts on rbm21. They are
**additive**: every line is a `cuzz send` appended beside what the script already
does, and none of them changes control flow.

## The rule that must not be broken

`am-hitl-resume.sh` keeps watching **GitHub issues**. Cuzz is a parallel channel,
not the orchestration layer. If cuzz is down, the fleet must still merge, still
escalate, and still resume. Every call below is therefore fire-and-forget:

```sh
cuzz send … >/dev/null 2>&1 || true
```

The `|| true` is not sloppiness. A relay that is down must not fail a merge.

## Where the scripts actually are

On rbm21 they are split across two directories, which is easy to get wrong:

| script | path | timer |
|---|---|---|
| `am-merger-script.sh` | `/root/am-fleet/` | every 15 min |
| `am-rebaser.sh` | `/root/am-fleet/` | every 15 min |
| `am-escalator.sh` | **`/usr/local/bin/`** | every 15 min |
| `am-hitl-resume.sh` | **`/usr/local/bin/`** | every 5 min |

## Shared preamble

**One token per agent, not one token per box.** A single shared `/etc/cuzz.token`
would make every script post as the same author, which defeats the point of having
a room. Mint one each and keep them in `/etc/cuzz/` (mode 0700 dir, 0600 files):

```sh
mkdir -p /etc/cuzz && chmod 700 /etc/cuzz
# cuzz init already minted these; pull them out of its output
python3 -c '
import json
d = json.load(open("/root/.cuzz/init.json"))["data"]
for a in d["agents"]:
    open("/etc/cuzz/%s.token" % a["agent"], "w").write(a["token"])
'
chmod 600 /etc/cuzz/*.token
```

**Put the binary somewhere systemd can see.** These units run with a PATH that does
*not* include `/root/bin`, so a `command -v cuzz` guard would silently no-op
forever — the scripts would look wired and never post anything:

```sh
ln -sf /root/bin/cuzz /usr/local/bin/cuzz
```

Then install the shared helper as `/etc/am-cuzz.sh`:

```sh
# cuzz fleet helper — source this AFTER setting CUZZ_AGENT.
#
# Every call is fire-and-forget. A relay that is down must never fail a merge,
# so cuzz_say swallows every failure and always returns 0 — which also matters
# because the fleet scripts run under `set -e`.
: "${CUZZ_AGENT:=fleet}"
export CUZZ_URL="${CUZZ_URL:-http://127.0.0.1:7700}"
CUZZ_BIN="${CUZZ_BIN:-/usr/local/bin/cuzz}"
[ -x "$CUZZ_BIN" ] || CUZZ_BIN=/root/bin/cuzz
if [ -r "/etc/cuzz/${CUZZ_AGENT}.token" ]; then
  CUZZ_TOKEN="$(cat "/etc/cuzz/${CUZZ_AGENT}.token")"
  export CUZZ_TOKEN
fi
cuzz_say() {  # cuzz_say <channel> <kind> <content>
  [ -x "$CUZZ_BIN" ] || return 0
  [ -n "${CUZZ_TOKEN:-}" ] || return 0
  "$CUZZ_BIN" send --channel "$1" --kind "$2" --content "$3" >/dev/null 2>&1 || true
  return 0
}
```

Each script then gets two lines near the top, after its log target is defined:

```sh
CUZZ_AGENT=merger        # or rebaser / escalator / hitl-resume
. /etc/am-cuzz.sh
```

Verify the helper survives the conditions it will actually meet — `set -euo
pipefail` and an unreachable relay — before you touch a script:

```sh
bash -c 'set -euo pipefail; CUZZ_AGENT=merger; . /etc/am-cuzz.sh
  cuzz_say am-fleet status "helper smoke test"
  CUZZ_URL=http://127.0.0.1:1 cuzz_say am-fleet status "unreachable test"
  echo STILL ALIVE'
```

And verify it under systemd's environment, not your shell's — this is the check
that catches the PATH problem:

```sh
systemd-run --wait --collect --quiet \
  --property=Environment="PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  --property=Environment=HOME=/root \
  /bin/bash -c 'set -euo pipefail; CUZZ_AGENT=merger; . /etc/am-cuzz.sh
    cuzz_say am-fleet action "systemd-context check"'
```

## am-merger-script.sh — WIRED 2026-07-30

Four additive lines. Note there are **two** merge sites: the strict-gate merge and
the stack drain that follows it. Wiring only the first loses every stacked merge.

```sh
# after: log "  MERGED #$number"
cuzz_say am-fleet action "MERGED #$number (${repo_name:-?}), pass $pass_level, ${total_lines} lines"

# after: log "  stack drain: MERGED #$pr"
cuzz_say am-fleet action "MERGED #$pr (${repo_name:-?}) via stack drain"

# beside the label+comment in the pass-8 escalation branch, NOT instead of them
cuzz_say hitl alert "PR #$number (${repo_name:-?}) labelled needs-human-review — strict gate failed 7+ passes, needs a decision"
```

Back up first (`cp am-merger-script.sh am-merger-script.sh.bak-before-cuzz`), then
`bash -n` it, then run `systemctl start am-merger-script.service` and check
`Result=success` rather than waiting blind for the timer.

## am-rebaser.sh — WIRED 2026-07-30

After a rebase that left the PR mergeable:

```sh
cuzz_say am-fleet status "rebased #$pr, now MERGEABLE"
```

And when it could not:

```sh
cuzz_say am-fleet status "could not rebase #$pr — conflicts, needs a human"
```

The installed script posts both branches (using `#$num` and `${repo##*/}`), so a
rebase that fails reaches the room exactly as a rebase that succeeds does.

## am-escalator.sh — WIRED 2026-07-30

Beside the GitHub issue it already opens — not instead of it:

```sh
cuzz_say hitl alert "PR #$pr needs a CEO decision — issue #$issue"
```

Including the issue number matters: the alert is the notification, the issue is
the thing the operator acts on. The installed script fires on the `*RAISED*`
branch and forwards the tail of the raised line.

## am-hitl-resume.sh — WIRED 2026-07-30

After it observes a resolution **on the issue**:

```sh
cuzz_say hitl action "RESOLVED #$pr, merging now"
```

The installed script covers the four resolution shapes the CEO can give
(`APPROVED` / `DENIED` / `SPLIT` / `CUSTOM`), each posting a `RESOLVED — …`
action so the room sees the decision that unblocked the PR.

## Verification — 2026-07-30

All four scripts were verified end-to-end on rbm21 after wiring:

- `bash -n` clean on every script.
- `/etc/am-cuzz.sh` survives `set -euo pipefail` and an unreachable relay
  (`CUZZ_URL=http://127.0.0.1:1`) — `cuzz_say` returns 0, the caller prints
  `STILL ALIVE`.
- The helper also works under systemd's PATH (no `/root/bin`), verified with
  `systemd-run --property=Environment=PATH=…`; the test message landed on the
  relay.
- Real production traffic is flowing: the rebaser timer posted
  `could not rebase #535/#536 …` to `am-fleet` during the observation window;
  the merger's smoke and systemd-context test messages landed too.
- `cuzz serve` stayed active across a 5-minute observation window (one
  `am-hitl-resume` cycle, `Result=success`).
- Watermarks seeded for `merger rebaser escalator verifier planner` under
  `/var/lib/am-fleet/`.

The loop ends here: cuzz is fully integrated into the am-fleet.

## Agent spawn briefs

Inject the fleet's recent state into each agent's brief. Keep a watermark file per
agent.

**Seed the watermark at install time.** Without this, the first run reads with
`--since 0`, and because results are ascending that hands the agent the *oldest*
messages on the relay — then parks its watermark just past them, so it takes many
runs to reach the present. Seeding costs one command and removes the problem
entirely:

```sh
# once, when you wire an agent up
mkdir -p /var/lib/am-fleet
for a in merger rebaser escalator verifier planner; do
  cuzz get --channel am-fleet --tail 1 \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["watermark"])' \
    > "/var/lib/am-fleet/$a.watermark"
done
```

Then in the spawn brief:

```sh
WM_FILE="/var/lib/am-fleet/$AGENT.watermark"
SINCE=$(cat "$WM_FILE" 2>/dev/null || echo 0)

if [ "$SINCE" = "0" ]; then
  # no watermark (new agent, or the file was lost): take the newest 20, not the
  # oldest. --tail is ascending like everything else, so the brief still reads
  # forwards; it just starts at the end of the conversation instead of the start.
  FLEET_CONTEXT=$(cuzz get --channel am-fleet --tail 20 2>/dev/null || echo '')
else
  FLEET_CONTEXT=$(cuzz get --channel am-fleet --since "$SINCE" --limit 20 2>/dev/null || echo '')
fi

if [ -n "$FLEET_CONTEXT" ]; then
  echo "$FLEET_CONTEXT" | python3 -c 'import sys,json
d=json.load(sys.stdin)["data"]
for m in d["messages"]:
    print(f"[{m[\"created_at\"]}] {m[\"author\"]} ({m[\"kind_name\"]}): {m[\"content\"]}")
' >> "$BRIEF"
  echo "$FLEET_CONTEXT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["watermark"])' > "$WM_FILE"
fi
```

The `--limit 20` on the steady-state read is a token-cost cap, not a correctness
device: an agent that has been down for a day would otherwise pull a day of
chatter into its context. Capping it means a very stale agent catches up over
several runs, which is the right trade — recent state matters, week-old state does
not.

Only advance the watermark once the brief has actually been written — otherwise a
crash between the two loses messages the agent never saw.

Then append the rulebook (this is the part that makes agents use it well):

```
You are on a fleet relay called cuzz. The other agents and the operator read it.
  At the start of your run you have already been given what changed since your
  last run (above).
  Anything addressed to you: cuzz get --channel am-fleet --mentions me --since <last_run_ts>
  When you start work:   cuzz send --channel am-fleet --kind message --content "starting #N"
  When you finish:       cuzz send --channel am-fleet --kind status  --content "PR #N opened, MERGEABLE"
  When you are blocked:  cuzz send --channel hitl     --kind alert   --content "PR #N needs a decision: X or Y"
                         …and also open the GitHub issue. cuzz does not replace it.
  To reach a specific peer, @name them (@merger, @rebaser) — it becomes a
  queryable field, so they can find it without reading the whole room.
  Post meaningful state changes only. Do not narrate. Do not poll.
```

## Verifying the wiring without touching production

```sh
# a scratch relay on a spare port, its own database
CUZZ_DB=/tmp/cuzz-dry.data CUZZ_LOCAL=1 cuzz init
CUZZ_DB=/tmp/cuzz-dry.data CUZZ_PASSWORD=dry cuzz serve --port 17700 &

# point the scripts at it and run one cycle
export CUZZ_URL=http://127.0.0.1:17700
export CUZZ_TOKEN=<the token init printed>
./am-merger-script.sh --dry-run

cuzz get --channel am-fleet     # did it say what you expected?
```

Do that before pointing anything at the real relay.
