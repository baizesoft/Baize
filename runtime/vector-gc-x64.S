.intel_syntax noprefix
.text
.global allocate, length, read_byte, write_byte, root_add, root_base, root_restore, root_drop, arena_address
.equ HEAP, 1048576
.equ ROOTS, 65536
.equ ROOT_COUNT, HEAP+8
.equ ROOT_LIST, ROOT_COUNT+8
.equ ACTIVE, 0x80000000
.equ MARK, 0x40000000
.equ SPAN, 0x3fffffff
arena:
  .byte 0x49, 0xbb
arena_address:
  .quad 0x1234567890abcdef
  ret

# r11 = base, r10 = logical root count. Only addresses of typed stack slots
# are registered. Overflow does not write and blocks collection until unwound.
root_add:
  call arena
  mov r10, [r11+ROOT_COUNT]
  cmp r10, ROOTS
  jae 1f
  mov [r11+r10*8+ROOT_LIST], rdx
1:
  inc qword ptr [r11+ROOT_COUNT]
  ret
root_base:
  call arena
  mov rdx, [r11+ROOT_COUNT]
  ret
root_restore:
  call arena
  mov [r11+ROOT_COUNT], rdx
  ret
root_drop:
  call arena
  sub [r11+ROOT_COUNT], rdx
  ret

# Block: requested length u32, span including header u30, mark + active.
# Internal try: r11 base, rdx length, rcx span. Result rax or zero.
allocate:
  mov rdx, [rsp+8]
  cmp rdx, HEAP-8
  ja no_space
  call arena
  call try_alloc
  test rax, rax
  jnz alloc_ret
  cmp qword ptr [r11+ROOT_COUNT], ROOTS
  ja no_space
  push rdx
  call collect
  pop rdx
  call try_alloc
alloc_ret:
  ret
no_space:
  xor eax, eax
  ret
try_alloc:
  lea rcx, [rdx+8]
  mov r8, [r11]
  lea r9, [r8+rcx]
  cmp r9, HEAP
  ja use_free
  lea rax, [r11+r8+8]
  mov [r11], r9
  mov r10d, ecx
  jmp init_block
use_free:
  lea rax, [r11+8]
  lea r9, [rax+r8]
try_next:
  cmp rax, r9
  jae no_space
  mov r10d, [rax+4]
  test r10d, r10d
  js skip_block
  cmp r10, rcx
  jb skip_block
  mov r8, r10
  sub r8, rcx
  cmp r8, 8
  jb init_block
  mov dword ptr [rax+rcx], 0
  mov [rax+rcx+4], r8d
  mov r10d, ecx
  jmp init_block
skip_block:
  and r10d, SPAN
  add rax, r10
  jmp try_next
init_block:
  mov [rax], edx
  or r10d, ACTIVE
  mov [rax+4], r10d
  # Zero only the requested payload, including bytes in a reused block.
  push rdi
  push rax
  lea rdi, [rax+8]
  mov rcx, rdx
  xor eax, eax
  rep stosb
  pop rax
  pop rdi
  ret

collect:
  xor ecx, ecx
  mov r8, [r11+ROOT_COUNT]
mark_loop:
  cmp rcx, r8
  jae sweep_begin
  mov rdx, [r11+rcx*8+ROOT_LIST]
  mov rdx, [rdx]
  test rdx, rdx
  jz mark_next
  or dword ptr [rdx+4], MARK
mark_next:
  inc rcx
  jmp mark_loop
sweep_begin:
  lea rax, [r11+8]
  mov r9, [r11]
  add r9, rax
  xor r8d, r8d
sweep_loop:
  cmp rax, r9
  jae sweep_end
  mov ecx, [rax+4]
  mov edx, ecx
  and edx, SPAN
  test ecx, MARK
  jnz keep_block
  test r8, r8
  jnz merge_block
  mov [rax+4], edx
  mov r8, rax
  jmp sweep_next
merge_block:
  add [r8+4], edx
  jmp sweep_next
keep_block:
  and dword ptr [rax+4], ~MARK
  xor r8d, r8d
sweep_next:
  add rax, rdx
  jmp sweep_loop
sweep_end:
  test r8, r8
  jz done
  sub r8, r11
  sub r8, 8
  mov [r11], r8
 done:
  ret

length:
  mov rax, [rsp+8]
  test rax, rax
  jz access_fail
  mov eax, [rax]
  ret
read_byte:
  mov rdx, [rsp+16]
  test rdx, rdx
  jz access_fail
  mov rcx, [rsp+8]
  mov eax, [rdx]
  cmp rcx, rax
  jae access_fail
  movzx eax, byte ptr [rdx+rcx+8]
  ret
write_byte:
  mov rax, [rsp+8]
  cmp rax, 255
  ja access_fail
  mov rdx, [rsp+24]
  test rdx, rdx
  jz access_fail
  mov rcx, [rsp+16]
  mov r8d, [rdx]
  cmp rcx, r8
  jae access_fail
  mov [rdx+rcx+8], al
  xor eax, eax
  ret
access_fail:
  mov rax, -1
  ret
