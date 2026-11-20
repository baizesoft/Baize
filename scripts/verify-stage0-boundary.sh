#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 1 || ! -x $1 ]]; then
  printf '用法：bash %s 可执行的编译器\n' "$0" >&2
  exit 1
fi
compiler=$(realpath -- "$1")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

env -i PATH= "$compiler" "$root/bootstrap/stage0/扫描样例.bz" "$work/scanner" native-linux-x64
chmod +x "$work/scanner"
printf '42x7' > "$work/source"
printf '42' > "$work/expected"
env -i PATH= "$work/scanner" "$work/source" "$work/result" > "$work/stdout"
cmp "$work/expected" "$work/result"
printf '2\n' > "$work/expected"
cmp "$work/expected" "$work/stdout"
printf '900x' > "$work/source"
printf '900' > "$work/expected"
env -i PATH= "$work/scanner" "$work/source" "$work/result" > "$work/stdout"
cmp "$work/expected" "$work/result"
printf '3\n' > "$work/expected"
cmp "$work/expected" "$work/stdout"
status=0
env -i PATH= "$work/scanner" "$work/missing" "$work/unexpected" || status=$?
[[ $status == 3 && ! -e $work/unexpected ]]
printf '整数 值 =\n' > "$work/invalid.bz"
if env -i PATH= "$compiler" "$work/invalid.bz" "$work/invalid-elf" native-linux-x64; then
  printf '应拒绝缺少初始化表达式的源码\n' >&2
  exit 1
fi
[[ ! -e $work/invalid-elf ]]
printf 'PASS: Stage 0 扫描样例及失败行为\n'
