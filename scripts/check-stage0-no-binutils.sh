#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 || ! -x $1 || $(uname -sm) != 'Linux x86_64' ]]; then
  printf '用法：bash %s 已有的 Linux x86-64 白泽编译器 [预期种子]\n' "$0" >&2
  exit 1
fi
host=$(realpath -- "$1")
expected_seed=
if [[ $# == 2 ]]; then
  [[ -f $2 ]]
  expected_seed=$(realpath -- "$2")
fi
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

mkdir -- "$work/bin"
for utility in bash cat chmod cmp dirname env grep mkdir mktemp readelf realpath rm sha256sum tee; do
  ln -s -- "$(type -P "$utility")" "$work/bin/$utility"
done
export PATH="$work/bin"
for compiler in as ld ld.bfd ld.gold ld.lld lld cc gcc clang rustc cargo; do
  if command -v "$compiler" >/dev/null; then
    printf '白泽汇编阶段出现外部构建工具：%s\n' "$compiler" >&2
    exit 1
  fi
done

build_tool() {
  env -i PATH= "$host" "$1" "$2" native-linux-x64
  chmod +x "$2"
}
assemble() {
  env -i PATH= "$work/assembler" "$1" "$2"
}
pack() {
  env -i PATH= "$work/packer" "$1" "$2"
  chmod +x "$2"
}
build_tool "$root/bootstrap/stage0/汇编器.bz" "$work/assembler"
build_tool "$root/bootstrap/stage0/ELF打包器.bz" "$work/packer"
assemble "$root/bootstrap/stage0/seed.s" "$work/seed.o"
assemble "$root/bootstrap/stage0/seed.s" "$work/seed-repeat.o"
cmp "$work/seed.o" "$work/seed-repeat.o"
pack "$work/seed.o" "$work/seed"
pack "$work/seed-repeat.o" "$work/seed-repeat"
cmp "$work/seed" "$work/seed-repeat"
if [[ -n $expected_seed ]]; then
  cmp "$expected_seed" "$work/seed"
  printf 'PASS: 白泽汇编和打包重建了相同的可信种子\n'
fi
readelf -rW "$work/seed.o" > "$work/relocations"
grep -q R_X86_64_PC32 "$work/relocations"
grep -q 'R_X86_64_64 ' "$work/relocations"
[[ $(readelf -lW "$work/seed") != *INTERP* ]]
[[ $(readelf -dW "$work/seed") != *NEEDED* ]]

probe() {
  printf '.intel_syntax noprefix\n.global _start\n.section .text\n_start:\n' > "$work/probe.s"
  cat >> "$work/probe.s" <<'ASM'
    lea rax, [rip + data]
    mov rdi, [rax]
    lea rcx, [rip + base]
    sub rdi, rcx
    jmp finish
    mov edi, 99
finish:
ASM
  printf '    add edi, %s\n    mov eax, 60\n    syscall\n' "$2" >> "$work/probe.s"
  cat >> "$work/probe.s" <<'ASM'
.section .rodata
.balign 8
data: .quad base + 10
.section .bss
.lcomm base, 8
.section .note.GNU-stack,"",@progbits
ASM
  assemble "$work/probe.s" "$work/$1.o"
  pack "$work/$1.o" "$work/$1"
  local actual=0
  env -i PATH= "$work/$1" || actual=$?
  [[ $actual == "$3" ]]
}
probe original 7 17
probe modified 11 21
if cmp -s "$work/original" "$work/modified"; then
  exit 1
fi

reject() {
  printf '.global _start\n.section .text\n_start:\n%s\n' "$1" > "$work/rejected.s"
  if assemble "$work/rejected.s" "$work/rejected.o" > "$work/error"; then
    printf '汇编器错误接受了 %s\n' "$1" >&2
    exit 1
  fi
  [[ ! -e $work/rejected.o ]]
  grep -q '汇编错误' "$work/error"
}
reject 'jmp missing'
reject 'jmp _start+2147483660'
reject 'vzeroupper'
reject 'mov eax, rbx'
reject 'mov eax, [rax + ]'
reject '_start: ret'

bash "$root/scripts/verify-stage0-boundary.sh" "$work/seed"
env -i PATH= "$work/seed" "$root/compiler/编译器.bz" "$work/first" native-linux-x64
chmod +x "$work/first"
if [[ -n ${BAIZE_BOOTSTRAP_ARTIFACTS:-} ]]; then
  mkdir -p -- "$BAIZE_BOOTSTRAP_ARTIFACTS"
  for artifact in assembler packer seed.o seed first relocations; do
    cat "$work/$artifact" > "$BAIZE_BOOTSTRAP_ARTIFACTS/$artifact"
  done
  (cd -- "$BAIZE_BOOTSTRAP_ARTIFACTS" && sha256sum assembler packer seed.o seed first) |
    tee "$BAIZE_BOOTSTRAP_ARTIFACTS/ASSEMBLER-SHA256SUMS"
fi
bash "$root/scripts/verify-native-bootstrap.sh" "$work/first" --native-only
printf 'PASS: 禁用 GNU as 和 ld，由白泽汇编和打包并完成三代自举\n'
