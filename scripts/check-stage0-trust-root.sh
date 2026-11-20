#!/usr/bin/env bash
set -euo pipefail
if [[ $(uname -sm) != 'Linux x86_64' ]]; then
  printf '需要 Linux x86-64\n' >&2
  exit 1
fi

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
trust="$root/bootstrap/stage0/trust-root"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

# Permit only shell and verification utilities before decoding the trusted input.
mkdir -- "$work/bin"
for utility in bash cat chmod cmp dirname env grep ln mkdir mktemp readelf realpath rm sha256sum tee uname; do
  ln -s -- "$(type -P "$utility")" "$work/bin/$utility"
done
export PATH="$work/bin"
export LC_ALL=C
for tool in as ld ld.bfd ld.gold ld.lld lld cc c++ gcc clang rustc cargo; do
  if command -v "$tool" >/dev/null; then
    printf '独立冷启动环境出现了外部构建工具：%s\n' "$tool" >&2
    exit 1
  fi
done

write_seed() {
  local line escapes i count=0
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ ! $line =~ ^([0-9a-f]{2}){1,32}$ ]] || (( count + ${#line} / 2 > 1048576 )); then
      printf '可信种子包含无效或超限的十六进制字节\n' >&2
      return 1
    fi
    escapes=
    for ((i=0; i<${#line}; i+=2)); do
      escapes+="\x${line:i:2}"
    done
    printf '%b' "$escapes"
    count=$((count + ${#line} / 2))
  done
  (( count > 0 ))
}

write_seed < "$trust/seed.hex" > "$work/trusted-seed"
(cd -- "$work" && sha256sum --check --strict "$trust/SEED-SHA256SUMS")
chmod +x "$work/trusted-seed"
env -i PATH= "$work/trusted-seed" "$root/compiler/编译器.bz" "$work/host" native-linux-x64
chmod +x "$work/host"

if [[ -n ${BAIZE_BOOTSTRAP_ARTIFACTS:-} ]]; then
  mkdir -p -- "$BAIZE_BOOTSTRAP_ARTIFACTS"
  evidence=$(mktemp -d "$(realpath -- "$BAIZE_BOOTSTRAP_ARTIFACTS")/trust-root.XXXXXX")
else
  evidence="$work/evidence"
  mkdir -- "$evidence"
fi
cat "$work/trusted-seed" > "$evidence/trusted-seed"
cat "$work/host" > "$evidence/trusted-seed-host"
cat "$trust/GNU-SHA256SUMS" > "$evidence/GNU-SHA256SUMS"
(cd -- "$evidence" && sha256sum trusted-seed trusted-seed-host) |
  tee "$evidence/TRUST-CHAIN-SHA256SUMS"

BAIZE_BOOTSTRAP_ARTIFACTS="$evidence"   bash "$root/scripts/check-stage0-no-binutils.sh" "$work/host" "$work/trusted-seed"
generations=("$evidence"/native.*/)
[[ ${#generations[@]} == 1 && -f ${generations[0]}stage3 ]]
(cd -- "${generations[0]}" && sha256sum --check --strict "$trust/GNU-SHA256SUMS")
printf 'PASS: 独立可信种子冷启动，重建种子一致，三代固定点与 GNU 基线一致\n'
