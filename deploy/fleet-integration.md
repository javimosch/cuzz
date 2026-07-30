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
