#!/usr/bin/env bash
set -euo pipefail

if [[ $(uname -sm) != 'Linux x86_64' ]]; then
  printf '需要 Linux x86-64\n' >&2
  exit 1
fi
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
as --64 -o "$work/seed.o" "$root/bootstrap/stage0/seed.s"
ld -o "$work/seed" "$work/seed.o"

compile() {
  env -i PATH= "$work/seed" "$1" "$2" native-linux-x64
}

check_status() {
  local actual=0
  env -i PATH= "$1" || actual=$?
  [[ $actual == "$2" ]]
}

printf '# 编译器读取源码并生成程序\n返回 (5 + 2) * 3 - -4 # 25\n' > "$work/first.bz"
printf '返回 20 - 3 - 2 * 4\n' > "$work/second.bz"
compile "$work/first.bz" "$work/first"
compile "$work/first.bz" "$work/repeated"
compile "$work/second.bz" "$work/second"
LC_ALL=C readelf -hW "$work/first" > "$work/header"
grep -q 'ELF64' "$work/header"
grep -q 'X86-64' "$work/header"
cmp "$work/first" "$work/repeated"
if cmp -s "$work/first" "$work/second"; then
  printf '不同源程序产生了相同的 ELF\n' >&2
  exit 1
fi
check_status "$work/first" 25
check_status "$work/second" 9

# 全局状态、嵌套分支、比较和循环都由生成的机器码执行。
cat > "$work/control.bz" <<'BZ'
整数 序号 = 0
整数 总和 = 0
当(序号 < 6) {
如果(序号 >= 3) {
总和 = 总和 + 序号
} 否则 {
总和 = 总和 - 1
}
序号 = 序号 + 1
}
当(序号 < 6) { 返回 99 }
如果(-3 <= -2) {
如果(序号 == 6) {
如果(序号 != 7) { 返回 总和 }
}
}
返回 1
BZ
compile "$work/control.bz" "$work/control"
check_status "$work/control" 9
sed 's/序号 < 6/序号 < 5/g; s/序号 == 6/序号 == 5/' "$work/control.bz" > "$work/variant.bz"
compile "$work/variant.bz" "$work/variant"
check_status "$work/variant" 4

# EOF、括号不匹配、溢出的字面量及语句尾部多余输入。
for source in '返回' '返回 (1 + 2' '返回 9223372036854775808' '返回 7 值' '返回 未声明' '未声明 = 1' '如果(1) {' '返回 1 }'; do
  printf '%s\n' "$source" > "$work/invalid.bz"
  if compile "$work/invalid.bz" "$work/invalid" 2> "$work/error"; then
    printf '种子错误地接受了 %s\n' "$source" >&2
    exit 1
  fi
  grep -q '编译错误' "$work/error"
  [[ ! -e $work/invalid ]]
done

printf '返回 7\n' > "$work/limit.bz"
size=$(wc -c < "$work/limit.bz")
printf '%*s' "$((65536 - size))" '' >> "$work/limit.bz"
compile "$work/limit.bz" "$work/limit"
check_status "$work/limit" 7
printf ' ' >> "$work/limit.bz"
if compile "$work/limit.bz" "$work/too-large" 2> "$work/error"; then
  exit 1
fi
grep -q '超过容量' "$work/error"
[[ ! -e $work/too-large ]]
printf 'PASS: 汇编种子独立生成并运行 ELF\n'
