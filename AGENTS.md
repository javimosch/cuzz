# AGENTS.md — cuzz

Fleet communication relay over [grange](https://github.com/javimosch/grange). One
binary: REST for agents, a chat page for the human, SSE for both.

```sh
./build.sh                  # STATIC=1 ./build.sh for the release binary
export CUZZ_DB=./cuzz.data
./cuzz guide                # mental model (JSON) — read this, not the README
./cuzz help-json            # command catalog
./test.sh                   # 57-assertion smoke: storage, REST, SSE, auth, SIGKILL
```

## Constraints

- ≤500 LOC per `src/*.src` file
- Storage = grange only. The embed list in `build.sh` is **not free-form** —
  grange's modules call each other, so a subset either resolves or does not
  compile. It is the same list poche pins; grange compiles it in its own gate.
- **Single-actor HTTP** (`listen`/`accept`) — do **not** use machweb `serve()`.
  The grange engine is single-actor state in package globals; machweb runs each
  request in its own goroutine and would race it.
- Read `machin guide` before writing MFL. It is version-exact and cannot drift
  from the compiler; your memory of the language can.
- Adopt [cli-specs](https://cli-specs.intrane.fr/): stdout is data JSON only,
  stderr is typed JSON errors, exits 0 / 80–89 user / 90–99 resource /
  100–109 integration (retryable) / 110–119 internal.

## Layout

| file | |
|---|---|
| `src/out.src` | output contract, `$CUZZ_DB`, `mkdir_all`, timestamp parsing |
| `src/store.src` | the grange facade (`st_*`) |
| `src/relay.src` | the model: channels, messages, tokens, kinds |
| `src/guide.src` | `guide` / `llms.txt` / `help-json` |
| `src/chat.src` | the chat page, as one self-contained string |
| `src/serve.src` | the accept loop, REST handlers, SSE fan-out |
| `src/cli.src` | the commands; HTTP by default, `--local` for direct grange |
| `src/main.src` | dispatch |

## Two things that will bite you

**Timestamps.** grange's `>` `<` operators are numeric (`parse_float`), so an
RFC-3339 *string* cannot be range-queried. Every message therefore carries both
`ts` (unix ms, the range-indexed field `--since` compares) and `created_at` (the
ISO stamp humans read). Do not filter on `created_at`.

**`--local` vs the server.** They are one storage code path reached two ways, not
two implementations. But only one process may hold a grange directory at a time,
so `--local` against a live server is a bug, not a fallback. The default is HTTP
for exactly this reason.

## Adding a route

Add it to `srv_handle` in `src/serve.src`, above the `tok := bearer(req)` line if
it should be unauthenticated, below if not. Then add an assertion to `test.sh` and
a line to `guide_json()` + `llms_txt()` in `src/guide.src` — a dev-facing feature
that is not in `guide` does not exist as far as an agent is concerned.

## Deliberately absent

Threads, reactions, DMs, keypairs, federation, workflows, multi-tenancy,
per-agent read tracking (agents keep their own watermark), full-text search
(substring scan is fine below ~10k messages), retention/TTL.
