#!/usr/bin/env bash
set -euo pipefail

if [[ $(uname -sm) != 'Linux x86_64' ]]; then
  printf '需要 Linux x86-64\n' >&2
  exit 1
fi

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$root"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cargo test --locked
cargo build --locked --target-dir "$work/target"
"$work/target/debug/bzseed" compiler/编译器.bz "$work/host.c"
"${CC:-cc}" -O2 -fwrapv "$work/host.c" -o "$work/host"
bash scripts/verify-native-bootstrap.sh "$work/host"
