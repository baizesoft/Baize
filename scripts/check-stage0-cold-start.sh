#!/usr/bin/env bash
set -euo pipefail
if [[ $(uname -sm) != 'Linux x86_64' ]]; then
  printf '需要 Linux x86-64\n' >&2
  exit 1
fi

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
as --version
ld --version
as --64 -o "$work/seed.o" "$root/bootstrap/stage0/seed.s"
ld -o "$work/seed" "$work/seed.o"
[[ $(readelf -lW "$work/seed") != *INTERP* ]]
[[ $(readelf -dW "$work/seed") != *NEEDED* ]]

# After building the seed, expose only shell and acceptance utilities.
mkdir -- "$work/bin"
for utility in bash cat chmod cmp dirname env grep mkdir mktemp readelf realpath rm sha256sum tee; do
  ln -s -- "$(type -P "$utility")" "$work/bin/$utility"
done
export PATH="$work/bin"
for compiler in c++ cc clang gcc rustc cargo as ld; do
  if command -v "$compiler" >/dev/null; then
    printf '冷启动阶段出现外部编译工具：%s\n' "$compiler" >&2
    exit 1
  fi
done

env -i PATH= "$work/seed" "$root/compiler/编译器.bz" "$work/first" native-linux-x64
[[ $(readelf -lW "$work/first") != *INTERP* ]]
[[ $(readelf -dW "$work/first") != *NEEDED* ]]
if [[ -n ${BAIZE_BOOTSTRAP_ARTIFACTS:-} ]]; then
  mkdir -p -- "$BAIZE_BOOTSTRAP_ARTIFACTS"
  cat "$work/seed" > "$BAIZE_BOOTSTRAP_ARTIFACTS/assembly-seed"
  cat "$work/first" > "$BAIZE_BOOTSTRAP_ARTIFACTS/first-native-compiler"
  (cd -- "$BAIZE_BOOTSTRAP_ARTIFACTS" && sha256sum assembly-seed first-native-compiler) |
    tee "$BAIZE_BOOTSTRAP_ARTIFACTS/SEED-SHA256SUMS"
else
  (cd -- "$work" && sha256sum seed first)
fi
bash "$root/scripts/verify-native-bootstrap.sh" "$work/first" --native-only
printf 'PASS: 汇编种子冷启动并完成三代白泽原生自举\n'
