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

# 分离的零填充段、跨 64 KiB 的数组和单字节截断。
cat > "$work/array.bz" <<'BZ'
字节数组 源[70000]
字节数组 结果[3]
整数 游标 = 69999
如果(源[游标] != 0) { 返回 1 }
源[游标] = 300
结果[2] = 源[游标] + 3
如果(源[0] != 0) { 返回 2 }
如果(结果[0] != 0) { 返回 3 }
返回 结果[2]
BZ
compile "$work/array.bz" "$work/array"
readelf -lW "$work/array" > "$work/segments"
grep -Eq 'LOAD .* RW ' "$work/segments"
check_status "$work/array" 47
sed 's/300/315/' "$work/array.bz" > "$work/array-variant.bz"
compile "$work/array-variant.bz" "$work/array-variant"
check_status "$work/array-variant" 62

# 使用进程参数获取文件路径，逐字节变换实际输入后写回。
cat > "$work/io.bz" <<'BZ'
字节数组 输入路径[260]
字节数组 输出路径[260]
字节数组 数据[64]
整数 长度 = 0
整数 游标 = 0
整数 暂存 = 0
如果(参数数量() != 2) { 返回 2 }
暂存 = 参数读取(0, 输入路径, 260)
暂存 = 参数读取(1, 输出路径, 260)
长度 = 文件读取(输入路径, 数据, 64)
如果(长度 < 0) { 返回 3 }
当(游标 < 长度) {
数据[游标] = 数据[游标] + 1
游标 = 游标 + 1
}
如果(文件写入(输出路径, 数据, 长度) != 长度) { 返回 4 }
输出(长度)
输出("中文\t文本")
输出(-120 / 7)
BZ
compile "$work/io.bz" "$work/io"
printf '\000\012\377' > "$work/输入"
printf '\001\013\000' > "$work/expected-io"
printf '3\n中文\t文本\n-17\n' > "$work/expected-stdout"
env -i PATH= "$work/io" "$work/输入" "$work/result" > "$work/stdout"
cmp "$work/expected-io" "$work/result"
cmp "$work/expected-stdout" "$work/stdout"
status=0
env -i PATH= "$work/io" "$work/missing" "$work/unexpected" || status=$?
[[ $status == 3 && ! -e $work/unexpected ]]

# 向前引用、递归、参数顺序、局部变量及全局变量遮蔽。
cat > "$work/function.bz" <<'BZ'
整数 数 = 7
返回 聚合(4, 1) + 数
函数 聚合(数, 基数) {
整数 中间 = 数 * 基数
如果(数 <= 1) { 返回 中间 }
返回 中间 + 聚合(数 - 1, 基数 + 1)
}
BZ
compile "$work/function.bz" "$work/function"
check_status "$work/function" 27
bash "$root/scripts/verify-stage0-boundary.sh" "$work/seed"

# EOF、括号不匹配、溢出的字面量及语句尾部多余输入。
for source in '返回' '返回 (1 + 2' '返回 9223372036854775808' '返回 7 值' '返回 未声明' '未声明 = 1' '如果(1) {' '返回 1 }' '字节数组 结果[0]' '字节数组 结果[16777217]' '字节数组 结果[2' '返回 参数数量(1)' '返回 未声明()' '返回 参数读取(0)' '返回 调用(1)
函数 调用() { 返回 1 }'; do
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
printf '%*s' "$((262144 - size))" '' >> "$work/limit.bz"
compile "$work/limit.bz" "$work/limit"
check_status "$work/limit" 7
printf ' ' >> "$work/limit.bz"
if compile "$work/limit.bz" "$work/too-large" 2> "$work/error"; then
  exit 1
fi
grep -q '超过容量' "$work/error"
[[ ! -e $work/too-large ]]
printf 'PASS: 汇编种子独立生成并运行 ELF\n'
