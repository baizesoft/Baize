#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 1 || ! -x $1 || $(uname -sm) != 'Linux x86_64' ]]; then
  printf '用法：bash %s 已有的 Linux x86-64 白泽编译器\n' "$0" >&2
  exit 1
fi
host=$(realpath -- "$1")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

as --version | sed -n '1p'
as --64 -o "$work/seed.o" "$root/bootstrap/stage0/seed.s"
cat > "$work/probe.s" <<'ASM'
.global _start
.text
.byte 0xcc
_start:
    mov buffer(%rip), %edi
    add pointer(%rip), %rdi
    lea buffer(%rip), %rax
    sub %rax, %rdi
    mov $60, %eax
    syscall
.section .rodata
pointer: .quad buffer + 17
.bss
.lcomm buffer, 8
.section .note.GNU-stack,"",@progbits
ASM
as --64 -o "$work/probe.o" "$work/probe.s"
printf '.global _start\n_start: call missing\n' |
  as --64 -o "$work/unsupported.o" -
printf '.global _start\n_start: .long missing - .\n' |
  as --64 -o "$work/undefined.o" -
printf '.global _start\n_start: .long data + 2147483647 - .\n.section .rodata\ndata: .byte 0\n' |
  as --64 -o "$work/overflow.o" -
head -c 63 "$work/seed.o" > "$work/truncated.o"

# GNU as is the last external build tool. The host came from the reference
# bootstrap, and compiles the packer without starting any external tool.
mkdir -- "$work/bin"
for utility in bash cat chmod cmp dirname env grep mkdir mktemp readelf realpath rm sha256sum tee; do
  ln -s -- "$(type -P "$utility")" "$work/bin/$utility"
done
export PATH="$work/bin"
for compiler in as ld ld.bfd ld.gold ld.lld lld cc gcc clang rustc cargo; do
  if command -v "$compiler" >/dev/null; then
    printf '打包阶段出现外部构建工具：%s\n' "$compiler" >&2
    exit 1
  fi
done

env -i PATH= "$host" "$root/bootstrap/stage0/ELF打包器.bz" "$work/packer" native-linux-x64
chmod +x "$work/packer"
pack() {
  env -i PATH= "$work/packer" "$1" "$2"
}
reject() {
  if pack "$work/$1.o" "$work/rejected" > "$work/error"; then
    printf '错误接受了 %s\n' "$1" >&2
    exit 1
  fi
  [[ ! -e $work/rejected ]]
  grep -q -- "$2" "$work/error"
}

pack "$work/seed.o" "$work/seed"
pack "$work/seed.o" "$work/seed-repeat"
cmp "$work/seed" "$work/seed-repeat"
pack "$work/probe.o" "$work/probe"
chmod +x "$work/seed" "$work/probe"
status=0
env -i PATH= "$work/probe" || status=$?
[[ $status == 17 ]]

reject unsupported '不支持的重定位'
reject undefined '符号未定义'
reject overflow '无法应用重定位'
reject truncated '无效或不支持的节表'
readelf -lW "$work/seed" > "$work/segments"
grep -Eq 'LOAD .* R E ' "$work/segments"
grep -Eq 'LOAD .* R +0x1000' "$work/segments"
grep -Eq 'LOAD .* RW ' "$work/segments"
grep -Eq 'GNU_STACK .* RW ' "$work/segments"
if grep -Eq 'INTERP|LOAD .* RWE ' "$work/segments"; then
  exit 1
fi
[[ $(readelf -dW "$work/seed") != *NEEDED* ]]
bash "$root/scripts/verify-stage0-boundary.sh" "$work/seed"
env -i PATH= "$work/seed" "$root/compiler/编译器.bz" "$work/first" native-linux-x64
chmod +x "$work/first"
if [[ -n ${BAIZE_BOOTSTRAP_ARTIFACTS:-} ]]; then
  mkdir -p -- "$BAIZE_BOOTSTRAP_ARTIFACTS"
  for artifact in seed.o packer seed first segments; do
    cat "$work/$artifact" > "$BAIZE_BOOTSTRAP_ARTIFACTS/$artifact"
  done
  (cd -- "$BAIZE_BOOTSTRAP_ARTIFACTS" && sha256sum seed.o packer seed first) |
    tee "$BAIZE_BOOTSTRAP_ARTIFACTS/PACKER-SHA256SUMS"
fi
bash "$root/scripts/verify-native-bootstrap.sh" "$work/first" --native-only
printf 'PASS: 禁用 ld，白泽打包后完成原生自举\n'
