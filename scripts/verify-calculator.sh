#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 1 || ! -x $1 ]]; then
  printf '用法：bash %s 白泽编译器\n' "$0" >&2
  exit 2
fi
compiler=$(realpath -- "$1")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
source="$root/examples/计算器.bz"

env -i PATH= "$compiler" "$source" "$work/calculator" native-linux-x64
chmod +x "$work/calculator"
programs=("$work/calculator")
cat > "$work/literals.bz" <<'BZ'
输出(1000 * 60 * 60 * 24 * 365)
输出(00012 + 0008 + 000)
输出(2147483647 + 1)
整数 外值 = 9
如果(外值 == 9) {
  整数 外值 = 外值 + 输入字节()
  输出(外值)
  输出(输入字节())
}
输出(外值)
BZ
$compiler "$work/literals.bz" "$work/literals" native-linux-x64
chmod +x "$work/literals"
printf 'AB' | "$work/literals" > "$work/actual"
printf '%s\n' 31536000000 20 2147483648 74 66 9 > "$work/expected"
cmp "$work/expected" "$work/actual"

check() {
  local expected_status=$1 expected_output=$2 executable status
  shift 2
  printf '%s\n' "$expected_output" > "$work/expected"
  for executable in "${programs[@]}"; do
    status=0
    env -i PATH= "$executable" "$@" > "$work/actual" || status=$?
    if [[ $status != "$expected_status" ]]; then
      printf '退出状态错误：%s，预期 %s，实际 %s，输入 %s\n' "$executable" "$expected_status" "$status" "$*" >&2
      return 1
    fi
    cmp "$work/expected" "$work/actual" || return 1
  done
}

check 0 14 '2 + 3 * 4'
check 0 -4 '2+3*(4-6)'
check 0 5 '10-3-2'
check 0 -2 '-7/3'
check 0 7 $' \t ( +5 + - -2 )'
check 0 2147483647 '2147483647'
check 1 '计算错误：不能除以零' '1/(2-2)'
check 1 '计算错误：整数超出计算器范围' '2147483647+1'
check 1 '计算错误：整数超出计算器范围' '2147483648'
check 1 '计算错误：整数超出计算器范围' '2147483647*2147483647'
check 1 $'计算错误：表达式无效，UTF-8 字节偏移\n4' '1+(2'
check 1 $'计算错误：表达式无效，UTF-8 字节偏移\n1' '1加2'
check 1 $'计算错误：表达式无效，UTF-8 字节偏移\n0' ''
printf -v spaces '%1024s' ''
check 0 7 "${spaces:1}7"
check 1 '计算错误：表达式最多 1024 字节' "${spaces}7"
printf -v nested '%65s' ''
check 1 '计算错误：表达式嵌套过深' "${nested// /-}1"
check 2 '用法：计算器 "整数表达式"'
check 2 '用法：计算器 "整数表达式"' '1+2' '3'
check 0 3000 '0.1 + 0.2' --4
check 0 35000 '1.25 * 2.8' --4
check 0 -23333 '-7/3' --4
check 0 7500 '.5 * 1.5' --4
check 0 21474836469999 '2147483646.9999 * 1' --4
check 1 '计算错误：整数超出计算器范围' '2147483647 * 2' --4
check 1 '计算错误：整数超出计算器范围' '2147483647 / 0.0001' --4
check 1 '计算错误：不能除以零' '1/0.0' --4
check 1 '计算错误：小数最多四位' '0.00001' --4
check 1 $'计算错误：表达式无效，UTF-8 字节偏移\n1' '.' --4
check 0 1200000000 '12MCk7MCjG' --keys
check 0 700000000 '12MCk7MCkG' --keys
check 0 1200000000 '12MCk7MXCjG' --keys
check 0 800000000 'l5MC3AlG' --keys
check 0 0 'mG' --keys
check 0 2000000000 '2+3*4=' --keys
check 0 800000000 '2+3==' --keys
check 0 22000000000 '200+10%=' --keys
check 0 22000000000 '200+10%B=' --keys
check 0 1100000000 '7+16QB=' --keys
check 0 1000000000 '10+9QBE=' --keys
check 0 1200000000 '10+9QB2=' --keys
check 0 1700000000 '7MC10+GB=' --keys
check 0 18000000000 '200-10%=' --keys
check 0 2000000000 '200*10%=' --keys
check 0 10000000 '1000000000*0.00000001%=' --keys
check 0 -10000000 '1000000000*0.00000001%~=' --keys
check 0 100000000 '100*10%==' --keys
check 0 46116860141324206 '2147483647*2147483647%%%%%=' --keys
check 1 '计算错误：整数超出计算器范围' '2147483647*2147483647%=' --keys
check 0 200000000000 '200/10%=' --keys
check 0 10000000000 '0.00000001/0.00000001%=' --keys
check 0 -10000000000 '0.00000001/0.00000001%~=' --keys
check 0 400000000 '1/50%==' --keys
check 0 20000000000 '1/50%%=' --keys
check 0 10100000000 '0.00000001/0.00000001%+1=' --keys
check 1 '计算错误：整数超出计算器范围' '1/0.00000001%=' --keys
check 1 '计算错误：不能除以零' '1/0%=' --keys
check 0 2000000000 '200+10%' --keys
check 0 -600000000 '3*~2=' --keys
check 0 30000000 '0.1+0.29B=' --keys
check 0 125000000 '1.2501B=' --keys
check 0 300000000 '1/0=C1+2=' --keys
check 0 400000000 '2+=' --keys
check 0 500000000 '2+3=5' --keys
check 1 $'计算错误：表达式无效，UTF-8 字节偏移\n2' '2+Z7' --keys
check 0 33333333 '1/3' --8
check 0 100000000 '(1/3)*3' --expr
check 0 1 '(1/3)*3' --expr-text
check 0 -0.125 '-1/8' --expr-text
check 0 -0.25 'inv(-sqrt(16))' --expr-text
check 0 -2 'floor(-1.000000001)' --expr-text
check 0 -1 'ceil(-1.000000001)' --expr-text
check 0 0 'floor(ceil(0.1)-1)' --expr-text
check 0 -200000000 --graph 'floor(x)' -1.1
check 0 -100000000 --graph 'ceil(x)' -1.1
check 0 0.000000001 'inv(1000000000)' --expr-text
check 1 '计算错误：不能除以零' 'inv(2-2)' --expr-text
check 0 25000000 --graph 'inv(x)' 4
check 0 1 --graph9 'inv(1000000000)' 1
check 0 0 --graph 'inv(1000000000)' 1
check 0 9223372036854775807 --graph9 'inv(x)' 0
check 0 0.000000001 'sinh(1e-9)' --expr-text
check 0 2 'cosh(0)+tanh(12)' --expr-text
check 0 -76159416 --graph 'tanh(x)' -1
check 1 '计算错误：整数超出计算器范围' 'cosh(23)' --expr-text
check 0 0.00000001 '0.000000005' --expr-text
check 0 -0.000000004 '-0.000000004' --expr-text
check 0 0.000000001 '1/1000000000' --expr-text
check 0 0 '0/1000000000' --expr-text
check 0 0 '-0.000000004' --expr
check 0 2147483647 '2147483647' --expr-text
check 0 -214748364700000000 '-2147483647' --expr
# /dev/full reproduces both immediate write errors and errors deferred until a C stdio flush.
for executable in "${programs[@]}"; do
  for mode in --expr --expr-text; do
    status=0
    "$executable" '-1/8' "$mode" > /dev/full || status=$?
    if [[ $status != 1 ]]; then
      printf '标准输出写入失败应返回 1：%s %s，实际 %s\n' "$executable" "$mode" "$status" >&2
      exit 1
    fi
  done
  for target in 4 all; do
    status=0
    "$executable" --convert 8 "$target" 1 > /dev/full || status=$?
    if [[ $status != 1 ]]; then
      printf '换算输出写入失败应返回 1：%s，目标 %s，实际 %s\n' "$executable" "$target" "$status" >&2
      exit 1
    fi
  done
  for mode in --graph --graph9; do
    for output in point range s z; do
      args=(x 0)
      if [[ $output != point ]]; then args=(x -1 1); fi
      if [[ $output == s || $output == z ]]; then args+=("$output"); fi
      status=0
      "$executable" "$mode" "${args[@]}" > /dev/full || status=$?
      if [[ $status != 1 ]]; then
        printf '绘图输出写入失败应返回 1：%s %s %s，实际 %s\n' "$executable" "$mode" "$output" "$status" >&2
        exit 1
      fi
    done
  done
  for keys in 'H1' 'W'; do
    printf '%s' "$keys" > "$work/keys"
    status=0
    "$executable" --serve < "$work/keys" > /dev/full || status=$?
    if [[ $status != 1 ]]; then
      printf '会话输出写入失败应返回 1：%s %s，实际 %s\n' "$executable" "$keys" "$status" >&2
      exit 1
    fi
  done
done
check 0 19800000000 '200+10%-10%' --expr
check 0 1810000000 'sqrt(81)+3^2+1E-1' --expr
check 0 1500000000 '2pi-pi+11.858407346' --expr
check 1 '计算错误：算式小数最多九位' '0.0000000001' --expr
check 1 $'计算错误：表达式无效，UTF-8 字节偏移\n0' 'ans+1' --expr
check 0 -33333333 '-1/3' --8
check 0 99999999 '(1/3)*3' --8
check 0 10000001 '0.10000001*1' --8
check 0 214748364699999999 '2147483646.99999999/1' --8
check 0 214748364699999999 '2147483646.99999999*1' --8
check 0 12345678 '0.123456789' --keys
check 0 33333333 '1/3=' --keys
check 0 24691356 '0.12345678+0.12345678=' --keys
check 0 100000000 '1/3=*3=' --keys
check 0 20000000002 '200+0.00000001%=' --keys
check 1 '计算错误：整数超出计算器范围' '2147483647/0.00000001' --8
check 1 '计算错误：整数超出计算器范围' '2147483647*2147483647' --8
check 1 '计算错误：小数最多八位' '0.123456789' --8

check 0 141421356 '2Q' --keys
check 0 10000 '0.00000001Q' --keys
check 0 125000000 '1.5625Q' --keys
check 0 400000000 '16Q' --keys
check 0 0 '0Q' --keys
check 0 2025000000 '4.5S' --keys
check 0 25000000 '4R' --keys
check 0 1100000000 '7+16Q=' --keys
check 0 2600000000 '20+35E6=' --keys
check 0 1500000000 '12MC3+G=' --keys
check 0 1400000000 '12MC5AC3DG' --keys
check 0 0 '12MXG' --keys
check 1 '计算错误：负数不能开平方根' '9~Q' --keys
check 1 '计算错误：不能除以零' '0R' --keys
check 1 '计算错误：整数超出计算器范围' '2147483647S' --keys

check 0 93132258 '2000000000/2147483647=' --keys
check 0 92233720 '922337203.68/1000000000=' --keys
check 0 92233720 '922337203.69/1000000000=' --keys
check 0 214748364699999999 '2147483646.99999999/1=' --keys
check 0 1 '0.00000001/2=' --keys
check 0 -1 '0.00000001~/2=' --keys
check 0 1 '0.00000001/3=*3=' --keys
check 1 '计算错误：整数超出计算器范围' '21474836470' --keys
check 1 '计算错误：整数超出计算器范围' '2147483647*2147483647=' --keys

check 0 -300000000 --science g -27 3
check 0 141421356 --science g 2 2
check 0 1414213562 --science g9 2 2
check 0 -1 --science g9 -1e-9 1
check 1 '科学计算错误：负数不能开偶次方' --science g9 -27 2
check 0 200000000 --science g 16 4
check 0 100000 --science g 0.000000001 3
check 0 100000000 --science g 1 64
check 0 -125000000 --science g -1.25 1
check 0 0 --science g 0 8
check 1 '科学计算错误：负数不能开偶次方' --science g -27 2
check 1 '科学计算错误：根指数需要 1 到 64 的整数' --science g 1 0
check 1 '科学计算错误：根指数需要 1 到 64 的整数' --science g 1 65
check 1 '科学计算错误：根指数需要 1 到 64 的整数' --science g 1 2.5
check 0 12500000 --science p 2 -3
check 0 300000000 --science p 9 .5
check 0 12500000 --science p 16 -0.75
check 0 141421356 --science p 2 0.5
check 0 300000000 --science p 9 0.500000000
check 0 -800000000 --science p -2 3.0
check 0 0 --science p 0 0.5
check 0 0 --science p 0.000000001 63.5
check 1 '科学计算错误：结果超出定点范围' --science p 0.000000001 -63.5
check 1 '科学计算错误：负底数需要整数指数' --science p -9 0.5
check 1 '科学计算错误：零不能取负次幂' --science p 0 -0.5
check 0 -800000000 --science p -2 3
check 0 506250000 --science p 1.5 4
check 0 100000000 --science p 2 0
check 0 0 --science p 10 -64
check 0 1 --science f 0
check 0 2432902008176640000 --science f 20
check 1 '科学计算错误：阶乘需要 0 到 20 的整数' --science f 21
check 1 '科学计算错误：结果超出定点范围' --science p 2 32
check 1 '科学计算错误：指数需要 -64 到 64 的定点数值' --science p 1 -65
check 1 '科学计算错误：请输入有效定点底数' --science p 1+2 2
check 1 '科学计算错误：零的零次幂未定义' --science p 0 0
check 1 '科学计算错误：零不能取负整数次幂' --science p 0 -1
check 0 0 --science s 0 d
check 0 50000000 --science s 1000000110 d
check 0 -50000000 --science s -30 d
check 0 -70710678 --science c 135 d
check 0 100000000 --science t 225 d
check 0 -100000000 --science t 135 d
check 0 84147098 --science s 1 r
check 0 54030231 --science c 1 r
check 0 155740772 --science t 1 r
check 0 57295721335 --science t 89.9 d
check 1 '科学计算错误：该角度的正切未定义' --science t -270 d
check 1 '科学计算错误：结果超出定点范围' --science t 89.999999999 d
check 1 '科学计算错误：弧度输入范围为 -100 到 100' --science c 101 r
for executable in "${programs[@]}"; do
  "$executable" --convert --help > "$work/actual"

  "$executable" --convert-text --help > "$work/expected"

  cmp "$work/actual" "$work/expected"

  grep -F -- '--convert-text 输出十进制文本' "$work/actual" > /dev/null

  status=0

  "$executable" --convert --help-extra > "$work/expected" || status=$?

  [[ $status == 2 ]]

  "$executable" --science --help > "$work/actual"
  mapfile -t help_lines < "$work/actual"
  [[ ${#help_lines[@]} == 2 ]]
  grep -Fx '九位缩放整数运算码：p9、s9/c9/t9、S9/C9/T9、n9/l9、e9/b9、g9、k9、%9、a9/r9、H9/I9/J9' "$work/actual" > /dev/null
  status=0
  "$executable" --science F9 1 > "$work/expected" || status=$?
  [[ $status == 2 ]]
  cmp "$work/actual" "$work/expected"
done
check 0 100000000 --science e 0
check 0 271828183 --science e 1
check 0 36787944 --science e -1
check 0 0 --science e -20
check 0 316227766 --science b 0.5
check 0 31622777 --science b -0.5
check 0 100000000000000000 --science b 9
check 0 1 --science b -8
check 0 0 --science b -9
check 0 1 --science s9 1e-9 r

check 0 0 --science c9 90 d

check 0 785398163 --science T9 1 r

check 0 1 --science S9 1e-9 r

check 1 '科学计算错误：该角度的正切未定义' --science t9 90 d

check 1 '科学计算错误：结果超出定点范围' --science t9 89.999999999 d

check 0 1 --science b9 -9
check 0 0 --science b9 -10
check 0 2 --science e9 -20
check 0 1 --science e9 -21
check 0 0 --science e9 -22
check 1 '科学计算错误：结果超出定点范围' --science e9 21.5
check 1 '科学计算错误：结果超出定点范围' --science e 21.5
check 1 '科学计算错误：结果超出定点范围' --science b 10
check 1 '科学计算错误：请输入有效定点指数' --science e 1.0000000001
check 0 300000000 --science k 8 2
check 0 -300000000 --science k 8 0.5
check 0 100000000 --science k 1.000000001 1.000000001
check 0 1584962501 --science k9 3 2
check 0 1000000000 --science k9 1.000000001 1.000000001
check 0 -1000000000 --science k9 0.999999999 1.000000001
check 1 '科学计算错误：结果超出定点范围' --science k9 100 1.000000001
check 0 -100000000 --science k 0.999999999 1.000000001
check 0 0 --science k 1 0.5
check 0 150000000 --science k 8 4
check 1 '科学计算错误：对数底数须为大于零且不等于 1 的数' --science k 8 1
check 1 '科学计算错误：对数底数须为大于零且不等于 1 的数' --science k 8 -2
check 1 '科学计算错误：对数需要正数' --science k 0 2
check 1 '科学计算错误：结果超出定点范围' --science k 100 1.000000001
check 0 -150000000 --science % -7.5 2
check 0 150000000 --science % 7.5 -2
check 0 -150000000 --science % -7.5 -2
check 0 0 --science % 0.3 0.1
check 0 0 --science % 2147483647 0.000000001
check 0 214748364700000000 --science a -2147483647
check 0 1 --science a -0.000000005
check 1 '科学计算错误：不能除以零' --science % 7 0
check 1 '科学计算错误：请输入有效定点除数' --science % 7 1+2
check 0 0 --science a -1e-9
check 0 1 --science a9 -1e-9
check 0 -33333333 --science r -3
check 0 -333333333 --science r9 -3
check 0 1 --science r9 1000000000
check 1 '科学计算错误：不能除以零' --science r9 0
check 0 0 --science p 10 -9
check 0 1 --science p9 10 -9
check 0 1 --science p9 0.000001 1.5
check 0 -1 --science %9 -1.000000001 1
check 0 -200000000 --science F -1.000000001
check 0 -100000000 --science U -1.000000001
check 0 100000000 --science F 1.999999999
check 0 200000000 --science U 1.000000001
check 0 0 --science U -0.000000001
check 0 -100000000 --science F -0.000000001
check 0 214748364700000000 --science U 2147483647
check 0 -214748364700000000 --science F -2147483647
check 0 250 --science a -2.5e-6
check 0 100000000 --science a 100000000000000000000e-20
check 0 2500 --science p 2.5e-5 1e0
check 0 -900000000 --science l 1E-9
check 0 0 --science a 0e+1024
check 0 1 --science a 0.0000000005e1
check 0 214748364700000000 --science a 2.147483647e9
check 1 '科学计算错误：请输入有效定点数值' --science a 1e-10
check 1 '科学计算错误：请输入有效定点数值' --science a 2.147483648e9
check 1 '科学计算错误：请输入有效定点数值' --science a 1e+
check 1 '科学计算错误：请输入有效定点数值' --science a 1.2.3e1
check 1 '科学计算错误：请输入有效定点数值' --science a 1e1025
check 0 100000000 --science s 100 g
check 0 -100000000 --science s -1000000100 g
check 0 -100000000 --science c 200 g
check 0 100000000 --science t 50 g
check 0 5000000000 --science T 1 g
check 0 -10000000000 --science S -1 g
check 0 20000000000 --science C -1 g
check 1 '科学计算错误：该角度的正切未定义' --science t 300 g
check 0 0 --science H 0
check 0 100000000 --science I 0
check 0 0 --science J 0
check 0 -117520119 --science H -1
check 0 154308063 --science I -1
check 0 76159416 --science J 1
check 0 -99999900 --science J -7.254329
check 0 100000000 --science J 100
check 0 -100000000 --science J -2147483647
check 0 10 --science H 1e-7
check 0 1 --science H9 1e-9
check 0 1543080635 --science I9 -1
check 0 999999996 --science J9 10
check 0 -999999996 --science J9 -10
check 0 1000000000 --science J9 12
check 1 '科学计算错误：结果超出定点范围' --science I 23
check 1 '科学计算错误：结果超出定点范围' --science H -22.5
check 0 0 --science n 1
check 0 3000000000 --science S 0.5 d
check 0 -9000000000 --science S -1 d
check 0 157079633 --science S 1 r
check 0 18000000000 --science C -1 d
check 0 0 --science C 1 r
check 0 12000000000 --science C -0.5 d
check 0 6343494882 --science T 2 d
check 0 -78539816 --science T -1 r
check 0 0 --science T 0 r
check 1 '科学计算错误：反正弦和反余弦需要 -1 到 1 的数值' --science S 1.000000001 d
check 1 '科学计算错误：反正弦和反余弦需要 -1 到 1 的数值' --science C -1.1 r
check 0 69314718 --science n 2
check 0 693147181 --science n9 2
check 0 1 --science n9 1.000000001
check 0 -1 --science l9 0.999999998
check 0 0 --science l9 1
check 1 '科学计算错误：对数需要正数' --science l9 0
check 0 -69314718 --science n 0.5
check 0 1 --science n 1.00000001
check 0 -1 --science n 0.99999999
check 0 -900000000 --science l 0.000000001
check 0 900000000 --science l 1000000000
check 0 47712125 --science l 3
check 1 '科学计算错误：对数需要正数' --science l 0
check 1 '科学计算错误：对数需要正数' --science n -1
check 0 $'2020\n53\n5' --date w 20210101
check 0 20210101 --date W 2020 53 5
check 0 20191230 --date W 2020 1 1
check 0 10101 --date W 1 1 1
check 1 '日期错误：请输入有效的 ISO 周年、周数及星期（1–7）' --date W 2021 53 1
check 1 '日期错误：请输入有效的 ISO 周年、周数及星期（1–7）' --date W 2020 53 8
check 1 '日期错误：结果超出 0001–9999 年' --date W 9999 52 7
check 0 $'2019\n1\n1' --date w 20181231
check 0 $'2024\n9\n4' --date w 20240229
check 0 $'1\n1\n1' --date w 00010101
check 0 $'9999\n52\n5' --date w 99991231
check 1 '日期错误：请输入有效公历日期，格式为 YYYYMMDD' --date w 19000229
check 0 20240304 --date a 20240301 1 b
check 0 20240304 --date a 20240302 1 b
check 0 20240301 --date s 20240303 1 b
check 0 20240301 --date s 20240304 1 b
check 0 20240229 --date s 20240304 2 b
check 0 20240303 --date a 20240303 0 b
check 1 '日期错误：结果超出 0001–9999 年' --date a 99991231 1 b
check 1 '日期错误：结果超出 0001–9999 年' --date s 00010101 1 b
check 1 '日期错误：数量须为非负整数' --date a 20240301 -1 b
check 0 1 --date b 20240301 20240304
check 0 1 --date b 20240304 20240301
check 0 0 --date b 20240302 20240303
check 0 0 --date b 20240304 20240304
check 0 5 --date b 20240304 20240311
check 0 3 --date b 20240228 20240304
check 0 2608614 --date b 00010101 99991231
check 0 2 --date d 20240301 20240228
check 0 1 --date d 19000228 19000301
check 0 2 --date d 20000228 20000301
check 0 3652058 --date d 00010101 99991231
check 0 20240229 --date a 20240228 1
check 0 20231231 --date s 20240101 1
check 0 10101 --date s 00010102 1
check 0 99991231 --date a 99991230 1
check 1 '日期错误：请输入有效公历日期，格式为 YYYYMMDD' --date a 19000229 1
check 1 '日期错误：请输入有效公历日期，格式为 YYYYMMDD' --date d 20240430 20240431
check 1 '日期错误：天数须为非负整数' --date a 20240101 -1
check 1 '日期错误：结果超出 0001–9999 年' --date a 99991231 1
check 1 '日期错误：结果超出 0001–9999 年' --date s 00010101 1
check 0 20240229 --date a 20240131 1 m
check 0 20240331 --date a 20240131 2 m
check 0 20240331 --date a 20240229 1 e
check 0 20240229 --date a 20230228 1 E
check 0 20250113 --date a 20241230 2 w
check 0 0 --date b 20240301 20240304 -20240304
closed_days='-20240101,-20240102,-20240103,-20240104,-20240105,-20240106,-20240107,-20240108,-20240109,-20240110,-20240111,-20240112,-20240113,-20240114,-20240115,-20240116,-20240117,-20240118,-20240119,-20240120,-20240121,-20240122,-20240123,-20240124,-20240125,-20240126,-20240127,-20240128,-20240129,-20240130,-20240131,-20240201'
check 0 20240202 --date a 20231231 1 b "$closed_days"
check 1 '日期错误：例外日期须写为 -YYYYMMDD 或 +YYYYMMDD，以逗号分隔，最多 32 个且不可重复' --date a 20231231 1 b "$closed_days,-20240202"
check 0 1 --date b 20240302 20240301 +20240302
check 0 20240302 --date a 20240301 1 b +20240302,-20240304
check 0 20240305 --date a 20240301 2 b +20240302,-20240304
check 0 20240302 --date s 20240305 1 b +20240302,-20240304
check 1 '日期错误：例外日期须写为 -YYYYMMDD 或 +YYYYMMDD，以逗号分隔，最多 32 个且不可重复' --date b 20240301 20240304 +20240302,-20240302
check 1 '日期错误：例外日期须写为 -YYYYMMDD 或 +YYYYMMDD，以逗号分隔，最多 32 个且不可重复' --date a 20240301 1 b -20230229
check 0 20241230 --date s 20250113 2 w
check 0 20240229 --date a 20240222 1 w
check 0 20240229 --date s 20240229 0 w
check 1 '日期错误：结果超出 0001–9999 年' --date s 00010101 1 w
check 1 '日期错误：结果超出 0001–9999 年' --date a 99991231 4294967295 w
check 0 20240228 --date a 20230228 1 y
check 0 20240229 --date s 20250228 1 E
check 0 20230228 --date s 20240229 1 E
check 0 20240227 --date a 20230227 1 E
check 1 '日期错误：结果超出 0001–9999 年' --date a 99990228 1 E
check 0 20240131 --date s 20240229 1 e
check 0 20240328 --date a 20240228 1 e
check 0 20230331 --date a 20230228 1 e
check 0 20231231 --date s 20240131 1 e
check 0 20230228 --date s 20230331 1 m
check 0 20230228 --date s 20240229 1 y
check 0 20000229 --date a 19960229 4 y
check 0 20240229 --date a 20240229 0 y
check 1 '日期错误：结果超出 0001–9999 年' --date s 00010131 1 m
check 1 '日期错误：结果超出 0001–9999 年' --date a 99990101 4294967295 y
check 2 '用法：计算器 --date d/c/b YYYYMMDD YYYYMMDD 或 --date a/s YYYYMMDD 数量 [w/m/e/y/E/b] 或 年数 月数 天数，或 --date w YYYYMMDD / --date W 周年 周数 星期；工作日运算末尾可附例外列表' --date a 20240101 1 x
check 0 $'1\n0\n3\n368' --date c 20240302 20230228
check 0 $'0\n1\n0\n29' --date c 20240131 20240229
check 0 $'0\n0\n28\n28' --date c 20240131 20240228
check 0 $'0\n0\n0\n0' --date c 20240229 20240229
check 0 $'9998\n11\n30\n3652058' --date c 00010101 99991231
check 0 20250301 --date a 20240131 1 1 1
check 0 20240228 --date s 20250331 1 1 1
check 0 20250329 --date a 20240229 1 1 0
check 0 20240229 --date a 20240229 0 0 0
check 1 '日期错误：数量须为非负整数' --date a 20240131 1 -1 0
check 1 '日期错误：结果超出 0001–9999 年' --date a 99991130 0 1 32
check 1 '日期错误：结果超出 0001–9999 年' --date s 00010101 0 0 1
check 0 $'0\n3200000000\n0\n27315000000\n0\n0' --convert 11 all 0
check 1 '换算错误：油耗需要正数' --convert 86 all 0
for executable in "${programs[@]}"; do
  env -i PATH= "$executable" --convert 8 all 1000000000 > "$work/all-units"
  mapfile -t units < "$work/all-units"
  [[ ${#units[@]} == 16 && ${units[0]} == 3 && ${units[14]} == 0 && ${units[15]} == 100000000000000000 ]]
done
check 0 254000000 --convert 5 3 1e2
check 0 1250000000 --convert 92 96 1E+2
check 0 1 --convert 3 3 1e-8
check 0 100000000000000000 --convert 3 3 1e9
check 1 '换算错误：请输入绝对值不超过十亿、最多九位小数的数值' --convert 3 3 1e-10
check 0 100000 --convert 4 1 1e-9
check 0 0.000000001 --convert-text 1 3 0.000001
check 0 0 --convert 1 3 0.000001
check 0 -0.000000001 --convert-text 1 3 -0.000001
check 0 $'0\n32\n0\n273.15\n0\n0.000000001' --convert-text 11 all 1e-9
check 0 1 --convert 3 3 0.000000005
check 0 -1 --convert 3 3 -0.000000005
check 0 -180000045967000000 --convert 10 9 -1000000000
check 0 180000003200000000 --convert 11 9 1000000000
check 0 74569987158 --convert 73 72 1000000.000000001
check 0 909090909090909091 --convert 86 87 1.1e-8
check 1 '换算错误：结果超出定点范围' --convert 86 87 1e-9
check 1 '换算错误：请输入绝对值不超过十亿、最多九位小数的数值' --convert 3 3 1e10
check 0 2540000 --convert 5 3 1
check 0 160934400000 --convert 8 3 1
check 0 6213711922 --convert 3 8 100000
check 0 1 --convert 1 3 .000005
check 0 -1 --convert 1 3 -.000005
check 0 -4000000000 --convert 9 11 -40
check 0 27315000000 --convert 11 10 0
check 0 3200000000 --convert 10 9 273.15
check 0 -5555556 --convert 9 11 31.9
check 1 '换算错误：请选择同类别的有效单位' --convert 3 11 1
check 1 '换算错误：结果超出定点范围' --convert 8 1 1000000000
check 1 '换算错误：请输入绝对值不超过十亿、最多九位小数的数值' --convert 3 4 1.0000000001
check 1 '换算错误：请输入绝对值不超过十亿、最多九位小数的数值' --convert 3 4 1+2

check 0 45359237 --convert 15 14 1
check 0 2834952313 --convert 16 13 1
check 0 -2834952313 --convert 16 13 -1
check 0 1600000000 --convert 15 16 1
check 0 50000000000 --convert 17 13 1
check 0 1000000000 --convert 19 18 36
check 0 16093440000 --convert 20 19 100
check 0 185200000 --convert 21 19 1
check 0 220462262 --convert 14 15 1
check 1 '换算错误：结果超出定点范围' --convert 14 12 1000000000
check 1 '换算错误：请选择同类别的有效单位' --convert 15 20 1
check 1 '换算错误：请选择同类别的有效单位' --convert 22 18 1
check 0 3600000000 --convert 26 25 1.5
check 0 36500000000 --convert 28 26 1
check 0 150000000 --convert 22 23 1500
check 0 12500000 --convert 29 30 1
check 0 102400000000 --convert 35 30 1
check 0 100000000000 --convert 31 30 1
check 0 109951162778 --convert 38 33 1
check 0 90949470 --convert 34 38 1
check 1 '换算错误：结果超出定点范围' --convert 38 29 1000000000
check 1 '换算错误：请选择同类别的有效单位' --convert 111 38 1
check 0 66666666667 --convert 43 40 1
check 0 1500000000 --convert 41 43 1
check 0 404685642240 --convert 47 40 1
check 0 9290304 --convert 45 40 1
check 0 378541178 --convert 51 49 1
check 0 454609000 --convert 52 49 1
check 0 2957352956 --convert 54 48 1
check 0 2841306250 --convert 55 48 1
check 0 1600000000 --convert 51 53 1
check 1 '换算错误：请选择同类别的有效单位' --convert 40 49 1
check 1 '换算错误：结果超出定点范围' --convert 50 48 1000000000
check 0 10132500000 --convert 60 57 1
check 0 76000000000 --convert 60 62 1
check 0 100000000 --convert 62 60 760
check 0 689475729317 --convert 61 56 1
check 0 689475729317 --convert 61 57 1000
check 0 100000000 --convert 58 59 0.1
check 0 360000000 --convert 67 65 1
check 0 418400000 --convert 69 64 1
check 0 360000000000000 --convert 67 63 1
check 1 '换算错误：请选择同类别的有效单位' --convert 60 63 1
check 1 '换算错误：结果超出定点范围' --convert 58 56 1000000000
check 0 74569987158 --convert 73 70 1
check 0 73549875000 --convert 74 70 1
check 0 74569987 --convert 73 71 1
check 0 10000000000 --convert 72 71 0.1
check 0 100000000 --convert 70 72 1000000
check 0 2500000000 --convert 79 75 1500
check 0 1666667 --convert 79 75 1
check 0 6000000000 --convert 75 79 1
check 0 3000000000 --convert 78 77 0.03
check 1 '换算错误：请选择同类别的有效单位' --convert 72 75 1
check 1 '换算错误：结果超出定点范围' --convert 72 70 1000000000
check 0 314159265 --convert 80 81 180
check 0 -157079633 --convert 80 81 -90
check 0 5729577951 --convert 81 80 1
check 0 20000000000 --convert 80 82 180
check 0 36000000000 --convert 83 80 1
check 0 129600000000000 --convert 83 85 1
check 0 6000000000 --convert 84 85 1
check 0 111111111111111111 --convert 80 82 1000000000
check 0 100000000000000000 --convert 81 81 1000000000
check 1 '换算错误：请选择同类别的有效单位' --convert 81 75 1
check 1 '换算错误：结果超出定点范围' --convert 83 85 1000000000
check 0 0 --programmer 16 + FF 1 8
check 0 255 --programmer 16 - 0 1 8
check 0 4294967296 --programmer 16 + FFFFFFFF 1 64
check 0 4294967295 --programmer 16 - 100000000 1 64
check 0 0 --programmer 16 + FFFFFFFFFFFFFFFF 1 64
check 0 -1 --programmer 16 - 0 1 64
check 0 9223372036854775807 --programmer 16 - 8000000000000000 1 64
check 0 3 --programmer 16 L 81 1 8
check 0 192 --programmer 16 R 81 1 8
check 0 1 --programmer 16 L 8000000000000000 1 64
check 0 -9223372036854775808 --programmer 16 R 1 1 64
check 0 -1 --programmer 16 R FFFFFFFFFFFFFFFF 0 64
check 1 '程序员错误：移位数须为非负十进制，且小于所选字长' --programmer 16 R FF 8 8
check 0 254 --programmer 16 m FF 2 8
check 0 -2 --programmer 16 m FFFFFFFFFFFFFFFF 2 64
check 0 1 --programmer 16 m FFFFFFFFFFFFFFFF FFFFFFFFFFFFFFFF 64
check 0 0 --programmer 16 m 100000000 100000000 64
check 0 25 --programmer 10 d 255 10 8
check 0 5 --programmer 10 % 255 10 8
check 0 -1 --programmer 16 d FFFFFFFFFFFFFFFF 1 64
check 0 9223372036854775807 --programmer 16 d FFFFFFFFFFFFFFFF 2 64
check 0 1 --programmer 16 d FFFFFFFFFFFFFFFF 8000000000000000 64
check 0 9223372036854775807 --programmer 16 % FFFFFFFFFFFFFFFF 8000000000000000 64
check 0 -9223372036854775808 --programmer 16 % 8000000000000000 FFFFFFFFFFFFFFFF 64
check 1 '程序员错误：除数不能为零' --programmer 16 d 5 0 64
check 1 '程序员错误：除数不能为零' --programmer 16 % 5 0 64
check 0 255 --programmer 10 v -1 '' 8
check 0 128 --programmer 10 v -128 '' 8
check 0 -9223372036854775808 --programmer 10 v -9223372036854775808 '' 64
check 0 0 --programmer 10 + -1 1 64
check 0 192 --programmer 10 h -128 1 8
check 0 64 --programmer 16 r 80 1 8
check 0 63 --programmer 16 h 7F 1 8
check 0 -1 --programmer 16 h 8000000000000000 63 64
check 0 -9223372036854775808 --programmer 16 h 8000000000000000 0 64
check 1 '程序员错误：输入超出所选字长或包含无效数字' --programmer 10 v -129 '' 8
check 1 '程序员错误：输入超出所选字长或包含无效数字' --programmer 10 v -9223372036854775809 '' 64
check 1 '程序员错误：输入超出所选字长或包含无效数字' --programmer 16 v -1 '' 8
check 1 '程序员错误：移位数须为非负十进制，且小于所选字长' --programmer 10 h -1 -1 8
check 0 254 --programmer 10 D -7 3 8
check 0 255 --programmer 10 M -7 3 8
check 0 2 --programmer 10 D -7 -3 8
check 0 1 --programmer 10 M 7 -3 8
check 0 254 --programmer 16 D F9 03 8
check 0 -4611686018427387904 --programmer 16 D 8000000000000000 2 64
check 0 1 --programmer 16 D 8000000000000000 8000000000000000 64
check 0 0 --programmer 16 M 8000000000000000 FFFFFFFFFFFFFFFF 64
check 1 '程序员错误：有符号商超出所选字长' --programmer 10 D -128 -1 8
check 1 '程序员错误：有符号商超出所选字长' --programmer 16 D 8000000000000000 FFFFFFFFFFFFFFFF 64
check 1 '程序员错误：除数不能为零' --programmer 10 M -7 0 8
check 0 1250000000 --convert 86 87 8
check 0 800000000 --convert 87 86 12.5
check 0 2940182292 --convert 86 88 8
check 0 3531011704 --convert 86 89 8
check 0 784048611 --convert 88 86 30
check 0 120094993 --convert 88 89 1
check 0 100000000 --convert 89 89 1
check 1 '换算错误：油耗需要正数' --convert 86 88 0
check 1 '换算错误：油耗需要正数' --convert 88 89 -1
check 0 1250000000 --convert 92 96 100
check 0 1192092896 --convert 92 99 100
check 0 100000000000000 --convert 93 91 1
check 0 102400000000 --convert 99 98 1
check 0 838860800000000 --convert 99 90 1
check 1 '换算错误：请选择同类别的有效单位' --convert 92 33 1
check 1 '换算错误：结果超出定点范围' --convert 100 90 1000000000
check 0 980665000 --convert 105 101 1
check 0 100000000 --convert 101 105 9.80665
check 0 -60960000 --convert 104 101 -2
check 0 10000000000 --convert 101 102 1
check 0 444822162 --convert 110 106 1
check 0 980665000 --convert 109 106 1
check 0 100000000000 --convert 107 106 1
check 0 10000000000000 --convert 106 108 1
check 0 135581795 --convert 114 111 1
check 0 11298483 --convert 115 111 1
check 0 1200000000 --convert 114 115 1
check 0 -980665000 --convert 113 111 -1
check 0 10000000000 --convert 111 112 1
check 1 '换算错误：请选择同类别的有效单位' --convert 114 69 1
check 1 '换算错误：请选择同类别的有效单位' --convert 116 111 1
check 1 '换算错误：请选择同类别的有效单位' --convert 105 109 1
check 1 '换算错误：结果超出定点范围' --convert 107 108 1000000000
check 0 240 --programmer 16 x FF 0F
check 0 240 --programmer 16 x 0xF_F 0X0_F
check 0 255 --programmer 16 b FF '' 8
check 0 13330 --programmer 16 b 0x1234 '' 16
check 0 2018915346 --programmer 16 b 0x12345678 '' 32
check 0 -9223372036854775808 --programmer 16 b 80 '' 64
check 0 128 --programmer 16 b 8000000000000000 '' 64
check 0 72 --programmer 16 B 12 '' 8
check 0 18432 --programmer 16 B 12 '' 16
check 0 -9223372036854775808 --programmer 16 B 1 '' 64
check 0 1 --programmer 16 B 8000000000000000 '' 64
check 0 4 --programmer 16 q F0 55 8
check 0 188 --programmer 16 f 0xABCD 4:8 16
check 0 42029 --programmer 16 i 0xABCD 4:8=0x42 16
check 0 -9223372036854775808 --programmer 16 i 0 63:1=1 64
check 0 0 --programmer 16 i FFFFFFFFFFFFFFFF 0:64=0 64
check 1 '程序员错误：请用十进制起点:长度=十六进制值，且值须适合字段宽度' --programmer 16 i FF 4:4=10 8
check 0 65468 --programmer 16 F 0xABCD 4:8 16
check 0 60 --programmer 16 F 0xA3CD 4:8 16
check 0 -68 --programmer 16 F 0xABCD 4:8 64
check 0 -1 --programmer 16 F 8000000000000000 63:1 64
check 0 -9223372036854775808 --programmer 16 F 8000000000000000 0:64 64
check 1 '程序员错误：位字段须写为十进制起点:长度，且位于所选字长内' --programmer 16 F FF 7:2 8
check 0 1 --programmer 16 f 8000000000000000 63:1 64
check 0 -1 --programmer 16 f FFFFFFFFFFFFFFFF 0:64 64
check 1 '程序员错误：位字段须写为十进制起点:长度，且位于所选字长内' --programmer 16 f FF 7:2 8
check 1 '程序员错误：位字段须写为十进制起点:长度，且位于所选字长内' --programmer 16 f FF 0:0 8
check 1 '程序员错误：位字段须写为十进制起点:长度，且位于所选字长内' --programmer 16 f FF 4:1:1 8
check 0 64 --programmer 16 q FFFFFFFFFFFFFFFF 0 64
check 0 0 --programmer 10 q -1 255 8
check 0 64 --programmer 16 p FFFFFFFFFFFFFFFF '' 64
check 0 0 --programmer 16 p 0 '' 8
check 0 8 --programmer 16 c F00000 '' 32
check 0 0 --programmer 16 c 8000000000000000 '' 64
check 0 32 --programmer 16 c 0 '' 32
check 0 63 --programmer 16 t 8000000000000000 '' 64
check 0 20 --programmer 16 t F00000 '' 32
check 0 16 --programmer 16 t 0 '' 16
check 0 493 --programmer 8 v 0o7_55 ''
check 0 -1 --programmer 2 v 0b1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1_1 '' 64
check 0 65408 --programmer 10 v -1_28 '' 16
check 1 '程序员错误：输入超出所选字长或包含无效数字' --programmer 16 v 0x_FF ''
check 1 '程序员错误：输入超出所选字长或包含无效数字' --programmer 16 v FF__00 ''
check 1 '程序员错误：输入超出所选字长或包含无效数字' --programmer 16 v 0x1_00 '' 8
check 0 15 --programmer 16 a FF 0f
check 0 3855 --programmer 16 o F00 0F
check 0 4294967295 --programmer 10 n 0 ''
check 0 2147483648 --programmer 16 l 1 31
check 0 0 --programmer 16 l 80000000 1
check 0 1073741824 --programmer 16 r 80000000 1
check 0 32767 --programmer 8 v 77777 ''
check 0 10 --programmer 2 v 1010 ''
check 1 '程序员错误：进制须为 2、8、10 或 16' --programmer 12 v 9 ''
check 1 '程序员错误：输入超出所选字长或包含无效数字' --programmer 10 v 4294967296 ''
check 1 '程序员错误：输入超出所选字长或包含无效数字' --programmer 2 v 102 ''
check 1 '程序员错误：移位数须为非负十进制，且小于所选字长' --programmer 16 l 1 32
check 1 '程序员错误：无效运算' --programmer 16 '?' 1 1

check 0 255 --programmer 16 n 0 '' 8
check 0 0 --programmer 16 l 80 1 8
check 0 65535 --programmer 8 v 177777 '' 16
check 0 0 --programmer 16 l 8000 1 16
check 0 -1 --programmer 10 v 18446744073709551615 '' 64
check 0 -1 --programmer 8 v 1777777777777777777777 '' 64
check 0 -9223372036854775808 --programmer 16 l 1 63 64
check 0 -9223372036854775807 --programmer 16 o 8000000000000000 1 64
check 0 1 --programmer 16 r FFFFFFFFFFFFFFFF 63 64
check 0 9223372036854775807 --programmer 16 r FFFFFFFFFFFFFFFF 1 64
check 1 '程序员错误：字长须为 8、16、32 或 64' --programmer 16 v 1 '' 24
check 1 '程序员错误：输入超出所选字长或包含无效数字' --programmer 16 v 100 '' 8
check 1 '程序员错误：输入超出所选字长或包含无效数字' --programmer 10 v 18446744073709551616 '' 64
check 1 '程序员错误：输入超出所选字长或包含无效数字' --programmer 16 v 10000000000000000 '' 64
check 1 '程序员错误：移位数须为非负十进制，且小于所选字长' --programmer 16 r FFFFFFFFFFFFFFFF 64 64
printf -v bit_input '%064d' 0
check 0 -9223372036854775808 --programmer 2 v "1${bit_input:1}" '' 64
check 1 '程序员错误：输入超出所选字长或包含无效数字' --programmer 2 v "1${bit_input}" '' 64

# Use one byte stream and one process. Each key produces status and display.
printf '0\n100000000\n0\n0\n0\n1000000000\n0\n100000000\n0\n0\n0\n1000000000\n0\n0\n0\n0\n0\n0\n2\n0\n0\n0\n0\n0\n0\n0\n0\n0\n0\n0\n0\n200000000\n0\n0\n0\n2000000000\n0\n200000000\n0\n0\n0\n2000000000\n0\n300000000\n0\n0\n0\n3000000000\n0\n500000000\n43\n200000000\n300000000\n5000000000\n0\n800000000\n43\n500000000\n300000000\n8000000000\n' > "$work/expected-session"
for executable in "${programs[@]}"; do
  printf '1/0=C2+3==' | env -i PATH= "$executable" --serve > "$work/session"
  cmp "$work/expected-session" "$work/session"
  printf 'F~.0BB=' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 54 ]]
  [[ ${replies[6]} == -11 && ${replies[15]} == -2 && ${replies[24]} == -3 ]]
  [[ ${replies[33]} == -2 && ${replies[42]} == -11 && ${replies[51]} == -1 ]]
  printf 'F2+*3==' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 54 ]]
  [[ "${replies[*]:16:2}" == '43 200000000' && "${replies[*]:25:2}" == '42 200000000' ]]
  [[ "${replies[*]:52:2}" == '0 1800000000' ]]
  printf '12MCk7M+W2=' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 64 ]]
  [[ "${replies[*]:48:4}" == '1200000000 700000000 0 0' && ${replies[59]} == 900000000 ]]
  printf 'I333333333\n*3=' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 24 ]]
  [[ "${replies[*]:18:6}" == '0 100000000 42 33333333 300000000 999999999' ]]
  printf '2+P-.125\n=' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 24 ]]
  [[ "${replies[*]:12:6}" == '0 -12500000 0 0 0 -125000000' ]]
  [[ "${replies[*]:18:6}" == '0 187500000 43 200000000 -12500000 1875000000' ]]
  printf 'P3+4\nP2147483648\nP2.5\n' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 18 ]]
  [[ ${replies[0]} == 1 && ${replies[6]} == 3 ]]
  [[ "${replies[*]:12:6}" == '0 250000000 0 0 0 2500000000' ]]
  printf '1/0=*5+2=' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 54 && ${replies[18]} == 2 && ${replies[24]} == 2 ]]
  [[ "${replies[*]:48:2}" == '0 700000000' ]]
  printf '2+3P2147483648\n=' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 30 && ${replies[18]} == 3 ]]
  [[ "${replies[*]:24:2}" == '0 500000000' ]]
  printf '2/0+P5\n+2=' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 48 && ${replies[18]} == 2 ]]
  [[ "${replies[*]:42:2}" == '0 700000000' ]]
  printf '2+P-1,234.50\nP12,34.50\n=' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 30 && ${replies[13]} == -123450000000 && ${replies[18]} == 1 ]]
  [[ "${replies[*]:24:2}" == '0 -123250000000' ]]
  printf 'P-1E-8\nP1e-9\nP1e-10\nP1e+3\n' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 24 && "${replies[*]:0:2}" == '0 -1' ]]
  [[ "${replies[*]:6:2}" == '0 0' && ${replies[11]} == 1 && ${replies[12]} == 1 && ${replies[17]} == 1 && "${replies[*]:18:2}" == '0 100000000000' ]]
  printf 'Tsqrt(81)+(3)^2+1E-1\nTsqrt(-1)\nTx+1\n' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 18 && "${replies[*]:0:2}" == '0 1810000000' ]]
  [[ "${replies[*]:6:2}" == '6 1810000000' && "${replies[*]:12:2}" == '1 1810000000' ]]
  printf 'T2pi+2(3+4)\nT2sqrt(9)\nT(2+1)(4-1)\n' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 18 && "${replies[*]:0:2}" == '0 2028318531' ]]
  [[ "${replies[*]:6:2}" == '0 600000000' && "${replies[*]:12:2}" == '0 900000000' ]]
  printf 'FT2+*3\n' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 10 && ${replies[0]} == 1 && ${replies[9]} == 2 ]]
  printf '7+U2(3+4)\n3=' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 30 && "${replies[*]:12:2}" == '0 1400000000' ]]
  [[ "${replies[*]:24:2}" == '0 1000000000' ]]
  printf 'T1/3\nUans*3\nTans*3\n' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 18 && ${replies[11]} == 999999999 && ${replies[17]} == 999999999 ]]
  printf '1/0=Uans\n2' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 36 && ${replies[24]} == 7 && "${replies[*]:30:2}" == '0 200000000' ]]
  printf 'j12MCk3MCj7+Um1+m2\nG=' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 90 && ${replies[73]} == 1500000000 && ${replies[85]} == 1900000000 ]]
  printf 'jT1/3\nMU3m1\n' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 24 && ${replies[23]} == 999999999 ]]
  printf '%b' 'T0.00000001/0.00000001%\nU1/50%%\nT1/0%\n' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 18 && "${replies[*]:0:2}" == '0 10000000000' ]]
  [[ "${replies[*]:6:2}" == '0 20000000000' && "${replies[*]:12:2}" == '2 10000000000' ]]
  printf '%b' 'T1000000000*0.00000001%\nT2147483647*2147483647%%%%%\n' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 12 && "${replies[*]:0:2}" == '0 10000000' ]]
  [[ "${replies[*]:6:2}" == '0 46116860141324206' ]]
  printf '%b' 'T200+10%\nT200-10%\nT200+10%-10%\nT200+(5+5)%\nT15%\n' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 30 && "${replies[*]:0:2}" == '0 22000000000' && "${replies[*]:6:2}" == '0 18000000000' ]]
  [[ "${replies[*]:12:2}" == '0 19800000000' && "${replies[*]:18:2}" == '0 22000000000' ]]
  [[ "${replies[*]:24:2}" == '0 15000000' ]]
  printf '%b' 'T10%+3\nT2*(10%)\nT10%*3\nT200+(10%)\n' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 24 && ${replies[1]} == 310000000 && ${replies[7]} == 20000000 ]]
  [[ ${replies[13]} == 30000000 && ${replies[19]} == 20010000000 ]]
  printf 'H1/3=*3=' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 67 && "${replies[*]:65:2}" == '333333333 3000000000' ]]
  printf 'T1/3\n*3=' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 24 && "${replies[*]:0:2}" == '0 33333333' && ${replies[5]} == 333333333 ]]
  [[ "${replies[*]:18:2}" == '0 100000000' && ${replies[23]} == 999999999 ]]
  printf '5+T2*(3+4)\nT1/0\n=' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 30 && ${replies[18]} == 2 && ${replies[19]} == 1400000000 ]]
  [[ "${replies[*]:24:2}" == '0 1900000000' ]]
  printf 'JP1e-9\n*' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 18 && ${replies[16]} == 42 && ${replies[17]} == 1 ]]
  printf 'HP1e-9\n*' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 18 && ${replies[16]} == 42 && ${replies[17]} == 0 ]]
  printf 'H0.123456789B5' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 117 ]]
  [[ ${replies[81]} == 0 && ${replies[90]} == 9 && ${replies[91]} == 12345678 ]]
  [[ ${replies[99]} == 0 && ${replies[105]} == 7 ]]
  [[ ${replies[108]} == 0 && ${replies[109]} == 12345675 ]]
  printf 'P12.340\nB5' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 18 && ${replies[13]} == 1234500000 ]]
  printf 'P0.123456789\nP-0\n5' | env -i PATH= "$executable" --serve > "$work/session"
  mapfile -t replies < "$work/session"
  [[ ${#replies[@]} == 18 && ${replies[0]} == 0 && ${replies[1]} == 12345679 && ${replies[5]} == 123456789 && ${replies[13]} == -500000000 ]]
done
check_graph_syntax() {
  local offset=$1
  shift
  check 1 $'绘图错误：请输入由数字、x、括号、四则运算、幂及受支持函数组成的表达式\n'"$offset" --graph "$@"
}
check_graph_syntax 3 'x+(' -1 1
check_graph_syntax 1 '1e+*x' -1 1
check_graph_syntax 1 '1e-10*x' -1 1
check 0 70710678 --graph 'x^0.5' 0.5
check 0 141421356 --graph '2^x' 0.5
check 0 70710678 --graph '2^x' -0.5
check 0 9223372036854775807 --graph 'x^0.5' -1
check 0 0 --graph 'x^0.5' 0
check 0 9223372036854775807 --graph 'x^-0.5' 0
check 0 9223372036854775807 --graph '2^x' 64.5
check 0 600000000 --graph '2x' 3
check 0 800000000 --graph '(x+1)(x-1)' 3
check 0 200000000 --graph '2sin(pi/2)' 0
check 0 100000000 --graph 'sin(2pi*x)' 0.25
check 0 1200000000 --graph '8/2x' 3
check 0 600000 --graph '2e-3x' 3
check_graph_syntax 2 '2 3' 0
check_graph_syntax 1 '2e' 0
check 1 '绘图错误：采样点数须为 201 到 801 的整数' --graph 'x' -1 1 802
check 1 '绘图错误：采样点数须为 201 到 801 的整数' --graph 'x' -1 1 200
check 1 '绘图错误：横轴区间太窄，请减少采样点' --graph 'x' 0 0.0000002 801
check 0 1512900 --graph 'x^2' 0.123
check 0 100000 --graph 'x' 1e-3
check 0 -100000000000 --graph 'x' -1000
check 0 9223372036854775807 --graph '1/x' 0
check 0 9223372036854775807 --graph 'ln(x)' -1
check 0 200000000 --graph 'log(x)' 100
check 0 200000000 --graph 'log10(x)' 100
check 0 -300000000 --graph 'cbrt(x)' -27
check 0 0 --graph 'cbrt(x)' 0
check 0 200000000 --graph 'cbrt(x)' 8
check 0 0 --graph 'cbrt(x)^3-x' -8
check 0 -300000000 --graph 'log2(x)' .125
check 0 50000000 --graph 'log2(sqrt(x))' 2
check 0 9223372036854775807 --graph 'log2(x)' 0
check_graph_syntax 0 'log20(x)' 1
check 0 9223372036854775807 --graph 'log(x)' 0
check 0 157079633 --graph 'asin(x)' 1
check 0 314159265 --graph 'acos(x)' -1
check 0 78539816 --graph 'atan(x)' 1
check 0 9223372036854775807 --graph 'asin(x)' 1.01
check 0 9223372036854775807 --graph 'acos(x)' -1.01
check_graph_syntax 4 '1/0+bad(x)' -1 1
check_graph_syntax 10 'sqrt(-1)+(' 0
check_graph_syntax 11 '2147483648+bad(x)' 0
check 0 9223372036854775807 --graph '1/0+x' 0
check 0 9223372036854775807 --graph '2147483648+x' 0
check 1 '绘图错误：求值横坐标须位于 -1000 到 1000' --graph 'x' 1000.000000001
check 1 '绘图错误：横轴须递增、位于 -1000 到 1000，且至少相差 0.0000002' --graph 'x' 1 -1
check_graph_syntax 0 'sqr(x)' -1 1
check_graph_syntax 4 'abs x' -1 1
for executable in "${programs[@]}"; do
  env -i PATH= "$executable" --graph 'sqrt(abs(x))' -4 4 > "$work/graph"
  mapfile -t points < "$work/graph"
  [[ ${#points[@]} == 201 && ${points[0]} == 200000000 && ${points[100]} == 0 && ${points[200]} == 200000000 ]]
  env -i PATH= "$executable" --graph 'floor(x-.005)+.5' -1 1 z 201 > "$work/graph"
  [[ ! -s "$work/graph" ]]
  env -i PATH= "$executable" --graph 'ceil(x-.005)-.5' -1 1 z 201 > "$work/graph"
  [[ ! -s "$work/graph" ]]
  env -i PATH= "$executable" --graph 'floor(x)' -1 1 s 201 > "$work/graph"
  mapfile -t link_rows < "$work/graph"
  [[ ${link_rows[199]} == 1 && ${link_rows[201]} == 0 && ${link_rows[203]} == 1 ]]
  env -i PATH= "$executable" --graph 'x+floor(x)-floor(x)' -1 1 s 201 > "$work/graph"
  mapfile -t link_rows < "$work/graph"
  [[ ${link_rows[199]} == 1 && ${link_rows[201]} == 1 && ${link_rows[203]} == 1 ]]
  env -i PATH= "$executable" --graph 'x+floor(x)' -1 1 s 201 > "$work/graph"
  mapfile -t link_rows < "$work/graph"
  [[ ${link_rows[199]} == 1 && ${link_rows[201]} == 0 && ${link_rows[203]} == 1 ]]
  env -i PATH= "$executable" --graph 'ceil(x)' -1 1 s 201 > "$work/graph"
  mapfile -t link_rows < "$work/graph"
  [[ ${link_rows[199]} == 1 && ${link_rows[201]} == 1 && ${link_rows[203]} == 0 && ${link_rows[205]} == 1 ]]
  env -i PATH= "$executable" --graph '1/(x-.05)' -10 10 s 201 > "$work/graph"
  mapfile -t segments < "$work/graph"
  [[ ${#segments[@]} == 402 && "${segments[*]:200:4}" == '-2000000000 1 2000000000 0' ]]
  env -i PATH= "$executable" --graph '1/(x-.05)^2' -10 10 s 201 > "$work/graph"
  mapfile -t segments < "$work/graph"
  [[ "${segments[*]:200:4}" == '40000000000 1 40000000000 0' ]]
  env -i PATH= "$executable" --graph '1/(x-.025)^2' -10 10 s 201 > "$work/graph"
  mapfile -t segments < "$work/graph"
  [[ ${segments[202]} != 9223372036854775807 && ${segments[203]} == 0 ]]
  env -i PATH= "$executable" --graph '1/(.001+(x-.025)^2)' -10 10 s 201 > "$work/graph"
  mapfile -t segments < "$work/graph"
  [[ ${segments[203]} == 1 ]]
  env -i PATH= "$executable" --graph '(x-.05)^2' -10 10 s 201 > "$work/graph"
  mapfile -t segments < "$work/graph"
  [[ "${segments[*]:200:4}" == '250000 1 250000 1' ]]
  env -i PATH= "$executable" --graph '1000*(x-.05)' -10 10 s 201 > "$work/graph"
  mapfile -t segments < "$work/graph"
  [[ "${segments[*]:200:4}" == '-5000000000 1 5000000000 1' ]]
  env -i PATH= "$executable" --graph 'ln(x)' -1 3 > "$work/graph"
  mapfile -t points < "$work/graph"
  [[ ${points[0]} == 9223372036854775807 && ${points[50]} == 9223372036854775807 && ${points[100]} == 0 && ${points[150]} == 69314718 ]]
  env -i PATH= "$executable" --graph 'sin(x)^2+cos(x)^2' -10 10 > "$work/graph"
  mapfile -t points < "$work/graph"
  [[ ${#points[@]} == 201 && ${points[0]} == 100000000 && ${points[100]} == 100000000 && ${points[200]} == 100000000 ]]
  env -i PATH= "$executable" --graph 'tan(x)' 0 2 > "$work/graph"
  mapfile -t points < "$work/graph"
  [[ ${points[157]} -gt 1000000000 && ${points[158]} -lt -1000000000 ]]
  env -i PATH= "$executable" --graph 'sin(x)' 100 101 > "$work/graph"
  mapfile -t points < "$work/graph"
  [[ ${points[0]} != 9223372036854775807 && ${points[1]} == 9223372036854775807 ]]
  env -i PATH= "$executable" --graph 'sin(pi*x)' 0 2 > "$work/graph"
  mapfile -t points < "$work/graph"
  [[ ${#points[@]} == 201 && ${points[50]} == 100000000 && ${points[100]} == 0 && ${points[150]} == -100000000 ]]
  env -i PATH= "$executable" --graph '(1E-3*x + e)*2e+0' 0 2 > "$work/graph"
  mapfile -t points < "$work/graph"
  [[ ${points[0]} == 543656366 && ${points[200]} == 544056366 ]]
  env -i PATH= "$executable" --graph 'exp(x)' 0 2 > "$work/graph"
  mapfile -t points < "$work/graph"
  [[ ${points[0]} == 100000000 && ${points[100]} == 271828183 ]]
done
for executable in "${programs[@]}"; do
  env -i PATH= "$executable" --graph 'x' 0 2 801 > "$work/graph"
  mapfile -t points < "$work/graph"
  [[ ${#points[@]} == 801 && ${points[0]} == 0 && ${points[1]} == 250000 && ${points[800]} == 200000000 ]]
  env -i PATH= "$executable" --graph 'x*x' -10 10 > "$work/graph"
  mapfile -t points < "$work/graph"
  [[ ${#points[@]} == 201 && ${points[0]} == 10000000000 && ${points[100]} == 0 && ${points[200]} == 10000000000 ]]
  env -i PATH= "$executable" --graph '2^3^2-x^2' -10 10 > "$work/graph"
  mapfile -t points < "$work/graph"
  [[ ${#points[@]} == 201 && ${points[0]} == 41200000000 && ${points[100]} == 51200000000 ]]
  env -i PATH= "$executable" --graph 'x^-2' -10 10 > "$work/graph"
  mapfile -t points < "$work/graph"
  [[ ${points[0]} == 1000000 && ${points[100]} == 9223372036854775807 && ${points[200]} == 1000000 ]]
  env -i PATH= "$executable" --graph '1/x' -10 10 > "$work/graph"
  mapfile -t points < "$work/graph"
  [[ ${#points[@]} == 201 && ${points[99]} == -1000000000 && ${points[100]} == 9223372036854775807 && ${points[101]} == 1000000000 ]]
done
check 0 $'0\n2000000000' --graph '(x^2)-(2*x)' -2 2 z
check 0 1000000000 --graph '(x)-(1)' -2 2 z

check 0 333333333 --graph '3*x-1' 0 1 z

check 0 666666667 --graph '3*x-2' 0 1 z

for executable in "${programs[@]}"; do

  env -i PATH= "$executable" --graph 'inv(2*x-0.000000001)' -1 1 z 201 > "$work/graph"

  [[ ! -s "$work/graph" ]]

done
check 1 '绘图错误：采样点数须为 201 到 801 的整数' --graph 'x' -1 1 z 802
check 1 '绘图错误：横轴区间太窄，请减少采样点' --graph 'x' 0 0.0000002 z 801
check 0 0 --graph 'x*x' -1 1 z
check 0 5000000 --graph 'x-.005+floor(x-.005)-floor(x-.005)' -1 1 z 201
check 0 -1000000000 --graph '0' -1 1 z
for executable in "${programs[@]}"; do
  env -i PATH= "$executable" --graph '(x-0.001)*(x-0.004)' -1 1 z > "$work/graph"
  mapfile -t roots < "$work/graph"
  [[ ${#roots[@]} -lt 2 ]]
  env -i PATH= "$executable" --graph '(x-0.001)*(x-0.004)' -1 1 z 801 > "$work/graph"
  mapfile -t roots < "$work/graph"
  [[ ${#roots[@]} == 2 && ${roots[0]} -ge 999000 && ${roots[0]} -le 1001000 &&
     ${roots[1]} -ge 3999000 && ${roots[1]} -le 4001000 ]]
  env -i PATH= "$executable" --graph 'x^2-2' -2 2 z > "$work/graph"
  mapfile -t roots < "$work/graph"
  [[ ${#roots[@]} == 2 && ${roots[0]} -ge -1414213563 && ${roots[0]} -le -1414213561 &&
     ${roots[1]} -ge 1414213561 && ${roots[1]} -le 1414213563 ]]
  env -i PATH= "$executable" --graph '(x-0.12345)^2' -1 1 z > "$work/graph"
  mapfile -t roots < "$work/graph"
  [[ ${#roots[@]} == 1 && ${roots[0]} -ge 123410000 && ${roots[0]} -le 123490000 ]]
  env -i PATH= "$executable" --graph '(x-0.12345)^2+0.000000001' -1 1 z > "$work/graph"
  [[ ! -s "$work/graph" ]]
  env -i PATH= "$executable" --graph '1/(x-0.12345)' -1 1 z > "$work/graph"
  [[ ! -s "$work/graph" ]]
done
printf 'PASS: 白泽计算器的正负样例\n'
