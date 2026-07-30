#!/usr/bin/env sh
# Install cuzz — fleet communication relay.
#   curl -fsSL https://raw.githubusercontent.com/javimosch/cuzz/main/install.sh | sh
# Env: VERSION (default latest) · PREFIX (default ~/.local/bin, or /usr/local/bin as root)
set -eu

REPO="javimosch/cuzz"
VERSION="${VERSION:-latest}"

if [ "$(id -u)" = "0" ]; then
  PREFIX="${PREFIX:-/usr/local/bin}"
else
  PREFIX="${PREFIX:-$HOME/.local/bin}"
fi

os=$(uname -s)
arch=$(uname -m)
[ "$os" = "Linux" ] || { echo "cuzz ships a linux-x86_64 binary; on $os build from source (./build.sh)" >&2; exit 1; }
case "$arch" in
  x86_64|amd64) : ;;
  *) echo "cuzz ships a linux-x86_64 binary; on $arch build from source (./build.sh)" >&2; exit 1 ;;
esac

if [ "$VERSION" = "latest" ]; then
  URL="https://github.com/$REPO/releases/latest/download/cuzz"
else
  URL="https://github.com/$REPO/releases/download/$VERSION/cuzz"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "fetching $URL"
if ! curl -fsSL "$URL" -o "$tmp/cuzz"; then
  echo "download failed — check that $VERSION has a release asset named 'cuzz'" >&2
  exit 1
fi
chmod +x "$tmp/cuzz"

# Verify the thing runs before it replaces anything on PATH.
if ! "$tmp/cuzz" version >/dev/null 2>&1; then
  echo "the downloaded binary does not run; leaving your install alone" >&2
  exit 1
fi

mkdir -p "$PREFIX"
mv "$tmp/cuzz" "$PREFIX/cuzz"
echo "installed $PREFIX/cuzz ($("$PREFIX/cuzz" version))"

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) echo "note: $PREFIX is not on your PATH" ;;
esac

cat <<'EOF'

next:
  export CUZZ_PASSWORD=your-operator-password
  cuzz init
  cuzz serve --port 7700 &
  cuzz guide            # the mental model, as JSON
EOF
