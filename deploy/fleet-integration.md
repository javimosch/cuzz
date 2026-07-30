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

## Shared preamble

Add to each script (or to a common `am-env.sh` they all source):

```sh
export CUZZ_URL="${CUZZ_URL:-http://127.0.0.1:7700}"
export CUZZ_TOKEN="${CUZZ_TOKEN:-$(cat /etc/cuzz.token 2>/dev/null)}"
cuzz_say() {  # cuzz_say <channel> <kind> <content>
  command -v cuzz >/dev/null 2>&1 || return 0
  [ -n "${CUZZ_TOKEN:-}" ] || return 0
  cuzz send --channel "$1" --kind "$2" --content "$3" >/dev/null 2>&1 || true
}
```

Mint one token per agent so the room shows who spoke:

```sh
cuzz token --agent merger    # -> /etc/cuzz.token on the merger's box/unit
cuzz token --agent rebaser
cuzz token --agent escalator
```

## am-merger-script.sh

After a successful merge:

```sh
cuzz_say am-fleet action "MERGED #$pr, draining stack"
```

## am-rebaser.sh

After a rebase that left the PR mergeable:

```sh
cuzz_say am-fleet status "rebased #$pr, now MERGEABLE"
```

And when it could not:

```sh
cuzz_say am-fleet status "could not rebase #$pr — conflicts, needs a human"
```

## am-escalator.sh

Beside the GitHub issue it already opens — not instead of it:

```sh
cuzz_say hitl alert "PR #$pr needs a CEO decision — issue #$issue"
```

Including the issue number matters: the alert is the notification, the issue is
the thing the operator acts on.

## am-hitl-resume.sh

After it observes a resolution **on the issue**:

```sh
cuzz_say hitl action "RESOLVED #$pr, merging now"
```

## Agent spawn briefs

Inject the fleet's recent state into each agent's brief. Keep a watermark file per
agent:

```sh
WM_FILE="/var/lib/am-fleet/$AGENT.watermark"
SINCE=$(cat "$WM_FILE" 2>/dev/null || echo 0)

FLEET_CONTEXT=$(cuzz get --channel am-fleet --since "$SINCE" 2>/dev/null || echo '')
if [ -n "$FLEET_CONTEXT" ]; then
  echo "$FLEET_CONTEXT" | python3 -c 'import sys,json
d=json.load(sys.stdin)["data"]
for m in d["messages"]:
    print(f"[{m[\"created_at\"]}] {m[\"author\"]} ({m[\"kind_name\"]}): {m[\"content\"]}")
' >> "$BRIEF"
  echo "$FLEET_CONTEXT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["watermark"])' > "$WM_FILE"
fi
```

Only advance the watermark once the brief has actually been written — otherwise a
crash between the two loses messages the agent never saw.

Then append the rulebook (this is the part that makes agents use it well):

```
You are on a fleet relay called cuzz. The other agents and the operator read it.
  At the start of your run you have already been given what changed since your
  last run (above).
  When you start work:   cuzz send --channel am-fleet --kind message --content "starting #N"
  When you finish:       cuzz send --channel am-fleet --kind status  --content "PR #N opened, MERGEABLE"
  When you are blocked:  cuzz send --channel hitl     --kind alert   --content "PR #N needs a decision: X or Y"
                         …and also open the GitHub issue. cuzz does not replace it.
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
