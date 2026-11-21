.intel_syntax noprefix
.text
.global task_spawn, task_yield, task_wait, task_stack_check, task_area_address
.equ LIMIT, 8
.equ RECORDS, 64
.equ STACKS, 4096
.equ STACK_BYTES, 131072
.equ RED_ZONE, 16384
# 0=current slot, 8=issued slots. Record: sp/state/result/low/entry/argument.
task_area:
  .byte 0x49, 0xbb                 # movabs r11, <task-area>
task_area_address:
  .quad 0x1234567890abcdef
  ret

task_spawn:
  call task_area
  cmp qword ptr [r11], 0           # Only the main task starts work in v1.
  jne task_error
  mov rax, [r11+8]
  cmp rax, LIMIT
  jae task_error
  lea rcx, [r11+STACKS]
  mov rdx, rax
  shl rdx, 17
  add rcx, rdx                    # stack's first byte
  inc rax                         # new task ID
  mov [r11+8], rax
  mov r10, rax
  shl r10, 6
  lea r10, [r11+r10+RECORDS]
  lea rdx, [rcx+RED_ZONE]
  mov [r10+24], rdx
  mov rdx, [rsp+16]
  mov [r10+32], rdx                # fixed, checked function entry
  mov rdx, [rsp+8]
  mov [r10+40], rdx
  add rcx, STACK_BYTES - 72
  lea rdx, [rip+task_begin]
  mov [rcx+64], rdx                # return target after restoring GPRs
  mov [rcx+16], r13
  mov [rcx+24], r12                # process argument base, inherited
  mov [r10], rcx
  mov qword ptr [r10+8], 1
  ret

task_wait:
  call task_area
  cmp qword ptr [r11], 0           # v1 forbids waits inside workers.
  jne task_error
  mov rax, [rsp+8]
  test rax, rax
  jz task_error
  cmp rax, [r11+8]
  ja task_error
wait_again:
  mov r10, [rsp+8]
  shl r10, 6
  lea r10, [r11+r10+RECORDS]
  cmp qword ptr [r10+8], 2
  je wait_done
  call .Lyield
  call task_area
  jmp wait_again
wait_done:
  mov rax, [r10+16]
  ret
task_error:
  mov rax, -1
  ret

task_stack_check:
  call task_area
  mov r10, [r11]
  test r10, r10
  jz stack_ok
  shl r10, 6
  cmp rsp, [r11+r10+RECORDS+24]
  jb stack_exhausted
stack_ok:
  ret
stack_exhausted:
  mov rax, -2
  jmp task_finish

task_yield:
.Lyield:
  call task_area
  jmp schedule

task_begin:
  call task_area
  mov r10, [r11]
  shl r10, 6
  lea r10, [r11+r10+RECORDS]
  push qword ptr [r10+40]
  call [r10+32]
  add rsp, 8
  call task_area
task_finish:
  mov r10, [r11]
  shl r10, 6
  lea r10, [r11+r10+RECORDS]
  mov [r10+16], rax
  mov qword ptr [r10+8], 2
  # The finished stack is never re-entered; the main slot remains runnable.
schedule:
  mov rcx, [r11]
  mov rdx, rcx
find_next:
  inc rdx
  cmp rdx, [r11+8]
  ja choose_main
  mov r10, rdx
  shl r10, 6
  cmp qword ptr [r11+r10+RECORDS+8], 1
  jne find_next
  jmp have_next
choose_main:
  xor edx, edx
have_next:
  cmp rdx, rcx
  je yield_ret
  push rbx
  push rbp
  push rsi
  push rdi
  push r12
  push r13
  push r14
  push r15
  shl rcx, 6
  mov [r11+rcx+RECORDS], rsp
  mov [r11], rdx
  shl rdx, 6
  mov rsp, [r11+rdx+RECORDS]
  pop r15
  pop r14
  pop r13
  pop r12
  pop rdi
  pop rsi
  pop rbp
  pop rbx
yield_ret:
  xor eax, eax
  ret
