#!/usr/bin/env bash
# Build cuzz — fleet communication relay over grange.
set -euo pipefail
cd "$(dirname "$0")"
MACHIN="${MACHIN:-machin}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
# Prefer sibling checkouts under ~/ai (dogfood layout); override with env.
FRAMEWORK="${FRAMEWORK:-$ROOT/../machin/framework}"
GRANGE_SRC="${GRANGE_SRC:-$ROOT/../grange/src}"
[[ -f "$FRAMEWORK/flags.src" ]] || FRAMEWORK="$ROOT/vendor/framework"
[[ -f "$GRANGE_SRC/engine.src" ]] || GRANGE_SRC="$ROOT/vendor/grange"

SRCS=(
  "$FRAMEWORK/flags.src"
  "$FRAMEWORK/machweb.src"
  # grange's embeddable core. This list is not free-form: grange's modules call
  # each other, so a subset either resolves or does not compile at all. It is the
  # same list poche pins, and grange compiles it in its own gate
  # (scripts/embed_test.sh), so drift shows up there rather than here.
  "$GRANGE_SRC/recfile.src"
  "$GRANGE_SRC/engine.src"
  "$GRANGE_SRC/registry.src"
  "$GRANGE_SRC/cold.src"
  "$GRANGE_SRC/coldbulk.src"
  "$GRANGE_SRC/coldindex.src"
  "$GRANGE_SRC/coldquery.src"
  "$GRANGE_SRC/coldrange.src"
  "$GRANGE_SRC/coldsort.src"
  "$GRANGE_SRC/index.src"
  "$GRANGE_SRC/range.src"
  "$GRANGE_SRC/qcost.src"
  "$GRANGE_SRC/project.src"
  "$GRANGE_SRC/query.src"
  "$GRANGE_SRC/order.src"
  src/out.src
  src/store.src
  src/relay.src
  src/guide.src
  src/chat.src
  src/serve.src
  src/cli.src
  src/main.src
)

"$MACHIN" encode "${SRCS[@]}" > cuzz.mfl
if [[ "${STATIC:-0}" == "1" ]]; then
  "$MACHIN" build cuzz.mfl --static -o cuzz
  # ~1MB of the static image is debug symbols nothing on the target reads.
  strip cuzz 2>/dev/null || true
else
  "$MACHIN" build cuzz.mfl -o cuzz
fi
echo "built ./cuzz ($(du -h cuzz | cut -f1))"
