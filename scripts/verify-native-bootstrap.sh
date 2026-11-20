#!/usr/bin/env bash
# Linux x86-64 原生自举。第一个参数是已构建的 Linux 宿主白泽编译器。
set -euo pipefail

if [[ $# != 1 || ! -x $1 ]]; then
  printf '用法：bash %s 可执行的宿主白泽编译器\n' "$0" >&2
  exit 1
fi
host=$(realpath -- "$1")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
src="$root/compiler/编译器.bz"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

env -i PATH= "$host" "$src" "$work/stage1" native-linux-x64
chmod +x "$work/stage1"
env -i PATH= "$work/stage1" "$src" "$work/stage2" native-linux-x64
chmod +x "$work/stage2"
env -i PATH= "$work/stage2" "$src" "$work/stage3" native-linux-x64
chmod +x "$work/stage3"
cmp "$work/stage1" "$work/stage2"
cmp "$work/stage2" "$work/stage3"
sha256sum "$work"/stage{1,2,3}

# 对实际由原生 ELF 生成的编译器运行完整正负样例。
bash "$root/scripts/verify-native-linux.sh" "$work/stage3"
printf 'PASS: 三代原生白泽编译器逐字节一致\n'
# 在原生链完成后，用同一源程序对照两个后端的可观察行为。
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
返回 7
BZ
"$work/stage3" "$work/parity.bz" "$work/parity.c" emit
"${CC:-cc}" "$work/parity.c" -o "$work/parity-c"
env -i PATH= "$work/stage3" "$work/parity.bz" "$work/parity-elf" native-linux-x64
chmod +x "$work/parity-elf"
c_status=0
elf_status=0
env -i PATH= "$work/parity-c" > "$work/c.stdout" || c_status=$?
env -i PATH= "$work/parity-elf" > "$work/elf.stdout" || elf_status=$?
[[ $c_status == 7 && $elf_status == 7 ]]
printf '中文\n24\n中文\n120\n-2\n' > "$work/expected.stdout"
cmp "$work/expected.stdout" "$work/c.stdout"
cmp "$work/c.stdout" "$work/elf.stdout"
printf 'PASS: C 与 ELF 后端输出和退出状态一致\n'
