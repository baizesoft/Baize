.intel_syntax noprefix
.text
.global allocate, length, read_byte, write_byte, root_add, root_base, root_restore, root_drop, arena_address, scheduler_address
.equ HEAP, 1048576
.equ ROOTS, 65536
.equ ROOT_COUNT, HEAP+8
.equ ROOT_LIST, ROOT_COUNT+8
.equ WORKER_ROOTS, 16384
.equ WORKER_STRIDE, 8+8*WORKER_ROOTS
.equ WORKER_COUNT, ROOT_LIST+8*ROOTS
# Native task record ABI (runtime/native-tasks-x64.S).
.equ TASK_ISSUED, 8
.equ TASK_RECORDS, 64
.equ TASK_STATE, 8
.equ TASK_DONE, 2
.equ ACTIVE, 0x80000000
.equ MARK, 0x40000000
.equ SPAN, 0x3fffffff
arena:
  .byte 0x49, 0xbb
arena_address:
  .quad 0x1234567890abcdef
  ret
scheduler:
  .byte 0x49, 0xba
scheduler_address:
  .quad 0x1234567890abcdef          # zero if tasks were not linked
  ret

# Return r9 = active root count address, r8 = that table's physical capacity.
root_context:
  call arena
  call scheduler
  lea r9, [r11+ROOT_COUNT]
  mov r8d, ROOTS
  test r10, r10
  jz 1f
  mov r10, [r10]                   # current task slot
  test r10, r10
  jz 1f
  dec r10
  imul r10, r10, WORKER_STRIDE
  lea r9, [r11+r10+WORKER_COUNT]
  mov r8d, WORKER_ROOTS
1:
  ret

# Only addresses of typed stack slots are registered. Overflow does not write
# and blocks collection until the affected task unwinds or retires.
root_add:
  call root_context
  mov r10, [r9]
  cmp r10, r8
  jae 1f
  mov [r9+r10*8+8], rdx
1:
  inc qword ptr [r9]
  ret
root_base:
  call root_context
  mov rdx, [r9]
  ret
root_restore:
  call root_context
  mov [r9], rdx
  ret
root_drop:
  call root_context
  sub [r9], rdx
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
  # Do not set any marks until every live table is known to be complete.
  cmp qword ptr [r11+ROOT_COUNT], ROOTS
  ja collect_skip
  push rdi
  push rsi
  call scheduler
  mov rdi, r10
  test rdi, rdi
  jz preflight_done
  mov esi, 1
preflight_slot:
  cmp rsi, [rdi+TASK_ISSUED]
  ja preflight_done
  call worker_context
  cmp r8, WORKER_ROOTS
  ja abandon_collection
  inc rsi
  jmp preflight_slot
preflight_done:
  lea r9, [r11+ROOT_COUNT]
  mov r8, [r9]
  call mark_context
  test rdi, rdi
  jz all_marked
  mov esi, 1
mark_slot:
  cmp rsi, [rdi+TASK_ISSUED]
  ja all_marked
  call worker_context
  call mark_context
  inc rsi
  jmp mark_slot
all_marked:
  pop rsi
  pop rdi
  jmp sweep_begin
abandon_collection:
  pop rsi
  pop rdi
collect_skip:
  ret

# Return r8=0 for retired stacks: do not inspect stale addresses even after
# a task was abandoned by its stack guard instead of returning normally.
worker_context:
  mov rax, rsi
  shl rax, 6
  xor r8d, r8d
  cmp qword ptr [rdi+rax+TASK_RECORDS+TASK_STATE], TASK_DONE
  je 1f
  lea rax, [rsi-1]
  imul rax, rax, WORKER_STRIDE
  lea r9, [r11+rax+WORKER_COUNT]
  mov r8, [r9]
1:
  ret

mark_context:
  xor ecx, ecx
mark_loop:
  cmp rcx, r8
  jae mark_done
  mov rdx, [r9+rcx*8+8]
  mov rdx, [rdx]
  test rdx, rdx
  jz mark_next
  or dword ptr [rdx+4], MARK
mark_next:
  inc rcx
  jmp mark_loop
mark_done:
  ret
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
