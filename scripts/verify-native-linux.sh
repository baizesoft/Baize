#!/usr/bin/env bash
# TASK-BAIZE-NATIVE-0001/0002/0003 / RED 验收脚本（只断言，不实现功能）
# 用法: bash scripts/verify-native-linux.sh /absolute/path/to/compiler [recursion]
# 在 Linux x86-64 上运行；编译器可执行文件由外部经现有链临时构建。
# 可选第二参数 recursion：仅运行“运行时递归”一节，便于单独确认该缺口。

set -u

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# ---------- 前置检查：失败必须给出清晰错误 ----------
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || die "用法: bash $0 /绝对路径/to/编译器 [recursion]"
COMPILER=$1
ONLY=${2:-}
[ -z "$ONLY" ] || [ "$ONLY" = "recursion" ] || die "未知的可选参数: $ONLY（仅支持 recursion）"
case "$COMPILER" in
  /*) ;;
  *) die "编译器路径必须为绝对路径: $COMPILER" ;;
esac
[ -f "$COMPILER" ] || die "编译器文件不存在: $COMPILER"
[ -r "$COMPILER" ] || die "编译器不可读: $COMPILER"
[ -x "$COMPILER" ] || die "编译器不可执行: $COMPILER"
for tool in readelf cmp mktemp grep; do
  command -v "$tool" >/dev/null 2>&1 || die "缺少依赖工具: $tool"
done

# ---------- 隔离临时目录并清理 ----------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bz-native.XXXXXX") || die "无法创建临时目录"
trap 'rm -rf "$WORK"' EXIT

# 在临时目录内、以清空 PATH 的环境运行；命令一律用绝对路径。
clean_run() {
  local dir=$1; shift
  ( cd "$dir" && env -i PATH= "$@" )
}

# 调用 native 目标：成功退出码须为 0；产物是否为有效 ELF 仍由 is_static_x64_elf 显式诊断。
compile_native() {
  local src=$1 out=$2 rc
  rm -f "$out"
  clean_run "$WORK" "$COMPILER" "$src" "$out" native-linux-x64
  rc=$?
  [ "$rc" -eq 0 ] || die "编译器返回非零退出码（成功编译应为 0）: rc=$rc, src=$src"
}

# 断言为静态 x86-64 ELF64：ELF64、x86-64、无 INTERP、无 NEEDED。
is_static_x64_elf() {
  local f=$1 h
  [ -f "$f" ] || return 1
  h=$(readelf -hW "$f" 2>/dev/null) || return 1
  printf '%s\n' "$h" | grep -q 'ELF64' || return 1
  printf '%s\n' "$h" | grep -qi 'x86-64' || return 1
  readelf -lW "$f" 2>/dev/null | grep -q 'INTERP' && return 1
  readelf -dW "$f" 2>/dev/null | grep -q 'NEEDED' && return 1
  return 0
}

# 测试 chmod +x 后直接运行，输出重定向到文件再用 cmp 比较（不靠命令替换）。
run_to_file() {
  local prog=$1 out=$2 rc
  chmod +x "$prog" || die "无法 chmod 产物为可执行文件: $prog"
  rm -f "$out"
  clean_run "$WORK" "$prog" > "$out"
  rc=$?
  [ "$rc" -eq 0 ] || die "产物运行退出码非零（应为 0）: rc=$rc, prog=$prog"
}

# 6) 运行时递归：单参数阶乘函数（比较 + 条件/返回 + 递归乘法与减法），输出须精确为 120 加一个换行。
#    夹具与 examples/额外程序.bz 同构，旧 C 后端可编译通过；当前 native 后端缺失递归时应失败。
run_recursion() {
  local REC=$WORK/rec.bz EXP=$WORK/expected-rec
  local AR=$WORK/a-rec OR=$WORK/o-rec
  {
    printf '%s\n' '函数 阶乘(数) {'
    printf '%s\n' '如果(数 <= 1) {'
    printf '%s\n' '返回 1'
    printf '%s\n' '} 否则 {'
    printf '%s\n' '返回 数 * 阶乘(数 - 1)'
    printf '%s\n' '}'
    printf '%s\n' '}'
    printf '%s\n' '输出(阶乘(5))'
  } > "$REC"
  printf '%s\n' '120' > "$EXP"

  compile_native "$REC" "$AR"
  is_static_x64_elf "$AR" || die "递归夹具（阶乘）未生成有效 ELF；请检查 native 后端对函数/递归调用的支持: $AR"
  run_to_file "$AR" "$OR"
  cmp -s "$EXP" "$OR" || die "递归夹具（阶乘）输出字节不符：期望恰好 120 加一个换行（native 后端递归未正确实现）"
}

# 9) native 端到端切片：单参数整数函数以 当 循环求迭代和——局部整数初始化、重新赋值、
#    条件比较、循环体内更新和与序号、返回和；顶层恰好一个整数 输出。
#    零迭代（求和(0) => 0）与多迭代（求和(5) => 15）两例；夹具与旧 C 后端兼容，
#    当前 native 后端缺失 当 循环时应在编译阶段失败（本切片专属失败点）。
run_loops() {
  local SRC0=$WORK/loop-zero.bz SRC5=$WORK/loop-five.bz
  local A0=$WORK/a-loop-zero A5=$WORK/a-loop-five
  local O0=$WORK/o-loop-zero O5=$WORK/o-loop-five
  local E0=$WORK/expected-loop-zero E5=$WORK/expected-loop-five

  {
    printf '%s\n' '函数 求和(数) {'
    printf '%s\n' '整数 和 = 0'
    printf '%s\n' '整数 序号 = 1'
    printf '%s\n' '当(序号 <= 数) {'
    printf '%s\n' '和 = 和 + 序号'
    printf '%s\n' '序号 = 序号 + 1'
    printf '%s\n' '}'
    printf '%s\n' '返回 和'
    printf '%s\n' '}'
    printf '%s\n' '输出(求和(0))'
  } > "$SRC0"
  {
    printf '%s\n' '函数 求和(数) {'
    printf '%s\n' '整数 和 = 0'
    printf '%s\n' '整数 序号 = 1'
    printf '%s\n' '当(序号 <= 数) {'
    printf '%s\n' '和 = 和 + 序号'
    printf '%s\n' '序号 = 序号 + 1'
    printf '%s\n' '}'
    printf '%s\n' '返回 和'
    printf '%s\n' '}'
    printf '%s\n' '输出(求和(5))'
  } > "$SRC5"

  printf '%s\n' '0' > "$E0"
  printf '%s\n' '15' > "$E5"

  # 零迭代：当(序号 <= 数) 一次都不进入，返回初始和 0，输出恰好 0 加一个换行。
  compile_native "$SRC0" "$A0"
  is_static_x64_elf "$A0" || die "当循环零迭代夹具（求和(0)）未生成有效 ELF（native 后端缺失 当 循环支持）: $A0"
  run_to_file "$A0" "$O0"
  cmp -s "$E0" "$O0" || die "当循环零迭代夹具（求和(0)）输出字节不符：期望恰好 0 加一个换行"

  # 多迭代：序号 1..5 累加得 15，输出恰好 15 加一个换行。
  compile_native "$SRC5" "$A5"
  is_static_x64_elf "$A5" || die "当循环多迭代夹具（求和(5)）未生成有效 ELF（native 后端缺失 当 循环支持）: $A5"
  run_to_file "$A5" "$O5"
  cmp -s "$E5" "$O5" || die "当循环多迭代夹具（求和(5)）输出字节不符：期望恰好 15 加一个换行"
}

# ---------- 夹具：UTF-8 字节精确，输出恰好一个换行 ----------
S1=$WORK/s1.bz
S2=$WORK/s2.bz
BAD=$WORK/bad.bz
E1=$WORK/expected1
E2=$WORK/expected2
printf '%s\n' '输出("你好，白泽")' > "$S1"
printf '%s\n' '输出("白泽，你好")' > "$S2"
printf '%s\n' '计数 = 1' > "$BAD"
printf '%s\n' '你好，白泽' > "$E1"
printf '%s\n' '白泽，你好' > "$E2"

printf '前置检查通过；工作目录: %s\n' "$WORK"

# 可选：仅运行递归一节（不执行 1-5），便于单独定位 native 后端递归缺口。
if [ "$ONLY" = "recursion" ]; then
  run_recursion
  printf 'PASS: native-linux-x64 运行时递归断言通过\n'
  exit 0
fi

# 1) 首样例：原版在此处失败——无法生成有效 ELF（预期首个 RED 失败点）。
A1=$WORK/a1
compile_native "$S1" "$A1"
is_static_x64_elf "$A1" || die "首样例无法生成有效 ELF（静态 x86-64 ELF64，无 INTERP/NEEDED）: $A1"
O1=$WORK/o1
run_to_file "$A1" "$O1"
cmp -s "$E1" "$O1" || die "首样例输出字节不符（须 UTF-8 精确且末尾恰好一个换行）"

# 2) 同一输入两次产物一致。
A1B=$WORK/a1-again
compile_native "$S1" "$A1B"
is_static_x64_elf "$A1B" || die "重复编译未生成有效 ELF: $A1B"
cmp -s "$A1" "$A1B" || die "同一输入的两次产物不一致"

# 3) 不同字符串输入：产物与运行输出都不同且正确。
A2=$WORK/a2
compile_native "$S2" "$A2"
is_static_x64_elf "$A2" || die "第二个样例未生成有效 ELF: $A2"
cmp -s "$A1" "$A2" && die "不同字符串输入却生成了相同产物"
O2=$WORK/o2
run_to_file "$A2" "$O2"
cmp -s "$E2" "$O2" || die "第二个样例输出字节不符（须为另一串且 UTF-8 精确）"
cmp -s "$O1" "$O2" && die "不同字符串输入的运行输出相同"

# 4) 受支持语法之外的有效 .bz：非零退出且不生成输出（不依赖错误文案）。
BADOUT=$WORK/bad.out
rm -f "$BADOUT"
clean_run "$WORK" "$COMPILER" "$BAD" "$BADOUT" native-linux-x64
rc=$?
[ "$rc" -ne 0 ] || die "不受支持的语法应返回非零退出码"
[ ! -e "$BADOUT" ] || die "不受支持的语法不应生成输出文件"

# 5) 回归：字符串词长跨 256 字节边界。253 字节不回绕，300 字节回绕；两者输出须逐字节精确。
LONG_A=$WORK/long-a.bz
LONG_B=$WORK/long-b.bz
EXP_A=$WORK/expected-long-a
EXP_B=$WORK/expected-long-b
BODY_A=$(printf 'x%.0s' {1..253})
BODY_B=$(printf 'x%.0s' {1..300})
printf '输出("%s")\n' "$BODY_A" > "$LONG_A"
printf '输出("%s")\n' "$BODY_B" > "$LONG_B"
printf '%s\n' "$BODY_A" > "$EXP_A"
printf '%s\n' "$BODY_B" > "$EXP_B"
AL=$WORK/a-long
BL=$WORK/b-long
compile_native "$LONG_A" "$AL"
is_static_x64_elf "$AL" || die "253 字节字符串样例未生成有效 ELF: $AL"
OL=$WORK/o-long-a
run_to_file "$AL" "$OL"
cmp -s "$EXP_A" "$OL" || die "253 字节字符串输出不符（须逐字节精确，末尾恰好一个换行）"
compile_native "$LONG_B" "$BL"
is_static_x64_elf "$BL" || die "300 字节字符串样例未生成有效 ELF: $BL"
OB=$WORK/o-long-b
run_to_file "$BL" "$OB"
cmp -s "$EXP_B" "$OB" || die "300 字节字符串输出不符（词长跨 256 边界回绕）"

# 6) 运行时递归（见 run_recursion）：保留上述全部断言，并新增此节。
run_recursion

# 7) 回归：函数参数为负数——恒等函数返回 -123，打印例行负路径不得产生杂散字节。
#    run_to_file 同时断言产物运行时退出码为 0。
NEG=$WORK/neg.bz
{
  printf '%s\n' '函数 计算(数) {'
  printf '%s\n' '返回 数'
  printf '%s\n' '}'
  printf '%s\n' '输出(计算(-123))'
} > "$NEG"
printf '%s\n' '-123' > "$WORK/expected-neg"
AN=$WORK/a-neg
compile_native "$NEG" "$AN"
is_static_x64_elf "$AN" || die "负数恒等函数未生成有效 ELF: $AN"
ON=$WORK/o-neg
run_to_file "$AN" "$ON"
cmp -s "$WORK/expected-neg" "$ON" || die "负数恒等函数输出不符：期望恰好 -123 加一个换行（打印例行负路径存在杂散字节）"

# 8) 函数、整数和多个跨 256 字节边界的 UTF-8 文本共享输出流程。
MIX=$WORK/mix.bz
{
  printf '函数 计算(数) {\n'
  printf '输出("%s中")\n' "$BODY_B"
  printf '返回 数\n}\n'
  printf '函数 零参() {\n返回 5\n}\n'
  printf '输出("%s文")\n' "$BODY_A"
  printf '输出(计算(零参()))\n'
  printf '输出(计算(-7) / 3)\n'
} > "$MIX"
printf '%s文\n%s中\n5\n%s中\n-2\n' "$BODY_A" "$BODY_B" "$BODY_B" > "$WORK/expected-mix"
MIXOUT=$WORK/mix.out
compile_native "$MIX" "$MIXOUT"
is_static_x64_elf "$MIXOUT" || die "混合输出未生成有效 ELF"
run_to_file "$MIXOUT" "$WORK/mix.stdout"
cmp -s "$WORK/expected-mix" "$WORK/mix.stdout" || die "混合输出的字节或顺序有误"

# 9) native 端到端切片：当循环迭代和（见 run_loops）；保留上述全部断言，并新增此节。
run_loops

# 10) 100 个函数和跨 64 KiB 的调用及返回重定位。
WIDE=$WORK/wide.bz
PAD=$(printf 'x%.0s' {1..700})
{
  for ((i=0; i<100; i++)); do
    printf '函数 项%s() {\n如果(0) {\n输出("%s")\n}\n返回 %s\n}\n' "$i" "$PAD" "$i"
  done
  printf '函数 末项() {\n返回 项99()\n}\n输出(末项())\n'
} > "$WIDE"
compile_native "$WIDE" "$WORK/wide.elf"
is_static_x64_elf "$WORK/wide.elf" || die "跨 64 KiB 的函数重定位未生成有效 ELF"
run_to_file "$WORK/wide.elf" "$WORK/wide.stdout"
printf '99\n' > "$WORK/expected-wide"
cmp -s "$WORK/expected-wide" "$WORK/wide.stdout" || die "跨 64 KiB 的调用或返回偏移错误"

# 11) 全局数据从零初始化，函数和顶层共享同一地址，字节写入截断。
STATE=$WORK/state.bz
cat > "$STATE" <<'BZ'
整数 计数 = 2
字节数组 数据[70000]
函数 更新(位置) {
计数 = 计数 + 1
数据[位置] = 300
返回 数据[位置]
}
输出(数据[69999])
当(计数 < 4) {
输出(更新(69999))
}
输出(计数)
返回 7
BZ
compile_native "$STATE" "$WORK/state.elf"
is_static_x64_elf "$WORK/state.elf" || die "全局存储样例未生成有效 ELF"
chmod +x "$WORK/state.elf" || die "无法设置 ELF 执行权限"
clean_run "$WORK" "$WORK/state.elf" > "$WORK/state.stdout"
[ "$?" -eq 7 ] || die "顶层返回未传递退出状态"
printf '0\n44\n44\n4\n' > "$WORK/expected-state"
cmp -s "$WORK/expected-state" "$WORK/state.stdout" || die "全局变量或字节数组行为错误"

# 12) 命令行参数按 UTF-8 字节读取，检查截断、NUL 和非法参数。
ARGS=$WORK/args.bz
cat > "$ARGS" <<'BZ'
字节数组 缓冲[8]
输出(参数数量())
输出(参数读取(0, 缓冲, 3))
输出(缓冲[0])
输出(缓冲[1])
输出(缓冲[2])
输出(参数读取(2, 缓冲, 8))
输出(参数读取(0, 缓冲, 0))
BZ
compile_native "$ARGS" "$WORK/args.elf"
is_static_x64_elf "$WORK/args.elf" || die "参数样例未生成有效 ELF"
chmod +x "$WORK/args.elf" || die "无法设置 ELF 执行权限"
clean_run "$WORK" "$WORK/args.elf" '中' '' > "$WORK/args.stdout" || die "参数样例运行失败"
printf '2\n2\n228\n184\n0\n-1\n-1\n' > "$WORK/expected-args"
cmp -s "$WORK/expected-args" "$WORK/args.stdout" || die "参数读取的 UTF-8 字节、截断或错误返回有误"

# 13) 二进制文件读写、部分读取、EOF、零长度读取和错误返回。
IO=$WORK/io.bz
cat > "$IO" <<'BZ'
字节数组 输入路径[260]
字节数组 输出路径[260]
字节数组 缺失路径[260]
字节数组 缓冲[32]
整数 暂存 = 参数读取(0, 输入路径, 260)
暂存 = 参数读取(1, 输出路径, 260)
暂存 = 参数读取(2, 缺失路径, 260)
整数 长度 = 文件读取(输入路径, 缓冲, 3)
输出(长度)
输出(文件写入(输出路径, 缓冲, 长度))
输出(文件读取(输入路径, 缓冲, 32))
输出(文件读取(输入路径, 缓冲, 0))
输出(文件读取(缺失路径, 缓冲, 32))
输出(文件写入(输出路径, 缓冲, -1))
BZ
printf '\000\377\012\200\021' > "$WORK/io.in"
printf '\000\377\012' > "$WORK/expected-io.bin"
printf '3\n3\n5\n0\n-1\n-1\n' > "$WORK/expected-io.stdout"
compile_native "$IO" "$WORK/io.elf"
is_static_x64_elf "$WORK/io.elf" || die "文件读写样例未生成有效 ELF"
chmod +x "$WORK/io.elf" || die "无法设置 ELF 执行权限"
clean_run "$WORK" "$WORK/io.elf" io.in io.out io.missing > "$WORK/io.stdout" || die "文件读写样例运行失败"
cmp -s "$WORK/expected-io.stdout" "$WORK/io.stdout" || die "文件读写长度或错误返回有误"
cmp -s "$WORK/expected-io.bin" "$WORK/io.out" || die "二进制文件内容有误"

printf 'PASS: native-linux-x64 全部断言通过\n'
