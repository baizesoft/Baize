#!/usr/bin/env bash
# Linux x86-64 原生自举。第一个参数是已构建的 Linux 宿主白泽编译器。
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ! -x $1 || ( $# == 2 && $2 != --native-only ) ]]; then
  printf '用法：bash %s 可执行的宿主白泽编译器 [--native-only]\n' "$0" >&2
  exit 1
fi
host=$(realpath -- "$1")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
src="$root/compiler/编译器.bz"
if [[ -n ${BAIZE_BOOTSTRAP_ARTIFACTS:-} ]]; then
  mkdir -p -- "$BAIZE_BOOTSTRAP_ARTIFACTS"
  work=$(mktemp -d "$(realpath -- "$BAIZE_BOOTSTRAP_ARTIFACTS")/native.XXXXXX")
else
  work=$(mktemp -d)
  trap 'rm -rf -- "$work"' EXIT
fi

env -i PATH= "$host" "$src" "$work/stage1" native-linux-x64
chmod +x "$work/stage1"
env -i PATH= "$work/stage1" "$src" "$work/stage2" native-linux-x64
chmod +x "$work/stage2"
env -i PATH= "$work/stage2" "$src" "$work/stage3" native-linux-x64
chmod +x "$work/stage3"
cmp "$work/stage1" "$work/stage2"
cmp "$work/stage2" "$work/stage3"
(cd -- "$work" && sha256sum stage{1,2,3}) | tee "$work/SHA256SUMS"

# 对实际由原生 ELF 生成的编译器运行完整正负样例。
bash "$root/scripts/verify-native-linux.sh" "$work/stage3"
bash "$root/scripts/verify-stage0-boundary.sh" "$work/stage3"
bash "$root/scripts/verify-calculator.sh" "$work/stage3"
printf 'PASS: 三代原生白泽编译器逐字节一致\n'
cat > "$work/parity.bz" <<'BZ'
函数 阶乘(数) {
如果(数 <= 1) {
返回 1
}
返回 数 * 阶乘(数 - 1)
}
整数 次数 = 0
当(次数 < 2) {
输出("中文")
输出(阶乘(次数 + 4))
次数 = 次数 + 1
}
输出(-7 / 3)
输出(整数位与(整数位反(0), 255))
输出(逻辑左移(1, 63))
输出(逻辑右移(-1, 1))
输出(逻辑右移(-1, 64))
返回 7
BZ
env -i PATH= "$work/stage3" "$work/parity.bz" "$work/parity-elf" native-linux-x64
chmod +x "$work/parity-elf"
elf_status=0
env -i PATH= "$work/parity-elf" > "$work/elf.stdout" || elf_status=$?
[[ $elf_status == 7 ]]
printf '中文\n24\n中文\n120\n-2\n255\n-9223372036854775808\n9223372036854775807\n0\n' > "$work/expected.stdout"
