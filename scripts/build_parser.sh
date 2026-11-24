#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$ROOT_DIR/tree-sitter-verbose/src"
OUT_DIR="$ROOT_DIR/parser"
mkdir -p "$OUT_DIR"

CC="${CC:-$(command -v clang || command -v cc || command -v gcc)}"
UNAME="$(uname -s)"
EXT="so"
FLAGS="-shared -fPIC -O2"
if [ "$UNAME" = "Darwin" ]; then
  EXT="so"
  FLAGS="-dynamiclib -fPIC -O2"
fi

"$CC" $FLAGS -I "$SRC_DIR" "$SRC_DIR/parser.c" -o "$OUT_DIR/verbose.$EXT"
echo "[OK] Built Tree-sitter parser -> $OUT_DIR/verbose.$EXT"
