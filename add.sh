#!/usr/bin/env bash
# Builds spark from this checkout and installs it to ~/.local/bin (or $PREFIX/bin).
set -euo pipefail

cd "$(dirname "$0")"

prefix="${PREFIX:-$HOME/.local}"
bin_dir="$prefix/bin"

if ! command -v zig >/dev/null 2>&1; then
  echo "add.sh: zig is not installed; get Zig 0.17 from https://ziglang.org/download/" >&2
  exit 1
fi

optimize="ReleaseSafe"
for arg in "$@"; do
  case "$arg" in
    --dev) optimize="Debug" ;;
    -h|--help) echo "usage: ./add.sh [--dev]   (--dev: fast debug build, slower at runtime)"; exit 0 ;;
    *) echo "add.sh: unknown option $arg" >&2; exit 2 ;;
  esac
done

echo "Building spark ($optimize)..."
zig build -Doptimize="$optimize"

mkdir -p "$bin_dir"
install -m 755 zig-out/bin/spark "$bin_dir/spark"
echo "Installed $("$bin_dir/spark" --version) to $bin_dir/spark"

case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo "Note: $bin_dir is not on your PATH. Add it to your shell profile:"
     echo "  export PATH=\"$bin_dir:\$PATH\"" ;;
esac
