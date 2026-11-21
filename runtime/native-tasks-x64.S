.intel_syntax noprefix
.text
.global task_spawn, task_yield, task_wait, task_stack_check, task_area_address
.global task_cancel, task_outcome, task_release, task_worker_roots_address
.global channel_new, channel_send, channel_recv, channel_value, channel_close
.equ LIMIT, 8
.equ RECORDS, 64
.equ STACKS, 4096
.equ STACK_BYTES, 131072
.equ RED_ZONE, 16384
.equ TASK_ISSUED, 8
.equ TASK_CURRENT_STACK_LIMIT, 16
.equ TASK_RECORDS, RECORDS
.equ TASK_STATE, 8
.equ TASK_DONE, 2
.equ TASK_SEND, 3
.equ TASK_RECV, 4
.equ TASK_JOIN, 5
.equ TASK_KEY, 48
.equ TASK_WAKE_ERROR, 56
.equ TASK_OUTCOME, TASK_WAKE_ERROR   # a retired task can no longer be woken
.equ TASK_HANDLES, 640              # signed generation-bearing token per slot
.equ WORKER_STRIDE, 131080          # same as vector-gc-x64.S
.equ MAILBOX, 1024
.equ CHANNEL_ISSUED, 1104
.equ CHANNELS, 1152
.equ CHANNEL_LIMIT, 8
.equ CHANNEL_CAPACITY, 8
# 0=current slot, 8=issued slots, 16=current stack limit (zero for main).
# Record: sp/state/result/low/entry/argument/key/wake-error.
task_area:
  .byte 0x49, 0xbb                 # movabs r11, <task-area>
task_area_address:
  .quad 0x1234567890abcdef
  ret

task_spawn:
  call task_area
  cmp qword ptr [r11], 0           # Only the main task starts work in v1.
  jne task_error
  mov edx, 1
spawn_find:
  cmp rdx, [r11+TASK_ISSUED]
  ja spawn_new
  mov rax, [r11+rdx*8+TASK_HANDLES]
  test rax, rax
  jns spawn_next
  neg rax
  add rax, LIMIT                  # keep slot bits, advance generation
  jns spawn_reuse                 # never wrap a handle back into use
spawn_next:
  inc edx
  jmp spawn_find
spawn_reuse:
  .byte 0x49, 0xb8                # movabs r8, <worker root base or zero>
task_worker_roots_address:
  .quad 0x1234567890abcdef
  test r8, r8
  jz spawn_init
  lea rcx, [rdx-1]
  imul rcx, rcx, WORKER_STRIDE
  mov qword ptr [r8+rcx], 0       # clear retired roots before making it live
  jmp spawn_init
spawn_new:
  cmp rdx, LIMIT
  ja task_error
  mov [r11+TASK_ISSUED], rdx
  mov rax, rdx
spawn_init:
  mov [r11+rdx*8+TASK_HANDLES], rax
  mov qword ptr [r11+rdx*8+MAILBOX], 0
  lea rcx, [rdx-1]
  shl rcx, 17
  lea rcx, [r11+rcx+STACKS]
  mov r10, rdx
  shl r10, 6
  lea r10, [r11+r10+RECORDS]
  lea rdx, [rcx+RED_ZONE]
  mov [r10+24], rdx
  mov rdx, [rsp+16]
  mov [r10+32], rdx                # fixed, checked function entry
  mov rdx, [rsp+8]
  mov [r10+40], rdx
  mov qword ptr [r10+16], 0
  mov qword ptr [r10+TASK_KEY], 0
  mov qword ptr [r10+TASK_WAKE_ERROR], 0
  add rcx, STACK_BYTES - 72
  lea rdx, [rip+task_begin]
  mov [rcx+64], rdx                # return target after restoring GPRs
  mov [rcx+16], r13
  mov [rcx+24], r12                # process argument base, inherited
  xor edx, edx
  mov [rcx], rdx                  # clear prior callee-saved context on reuse
  mov [rcx+8], rdx
  mov [rcx+32], rdx
  mov [rcx+40], rdx
  mov [rcx+48], rdx
  mov [rcx+56], rdx
  mov [r10], rcx
  mov qword ptr [r10+TASK_STATE], 1
  ret

task_wait:
  call task_area
  cmp qword ptr [r11], 0           # v1 forbids waits inside workers.
  jne task_error
wait_again:
  mov rax, [rsp+8]
  call task_lookup
  test r10, r10
  jz task_error
  cmp qword ptr [r10+TASK_STATE], TASK_DONE
  je wait_done
  mov ecx, TASK_JOIN
  call block_current
  test rax, rax
  jnz wait_result
  call task_area
  jmp wait_again
wait_done:
  mov rax, [r10+16]
wait_result:
  ret
task_error:
  mov rax, -1
  ret

task_stack_check:
  call task_area
  # Only reached by the generated guard's taken branch, not a call.
  mov rax, -2
  mov ecx, 3
  jmp task_finish

task_yield:
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
  mov ecx, 1
task_finish:
  mov r10, [r11]
  shl r10, 6
  lea r10, [r11+r10+RECORDS]
  mov [r10+16], rax
  mov [r10+TASK_OUTCOME], rcx
  mov qword ptr [r10+TASK_STATE], TASK_DONE
  # Only the main task can join, and only the matching completion wakes it.
  cmp qword ptr [r11+RECORDS+TASK_STATE], TASK_JOIN
  jne schedule
  mov r10, [r11]
  cmp [r11+RECORDS+TASK_KEY], r10
  jne schedule
  mov qword ptr [r11+RECORDS+TASK_STATE], 1
schedule:
  mov rcx, [r11]
  mov rdx, rcx
find_next:
  inc rdx
  cmp rdx, [r11+TASK_ISSUED]
  jbe in_ring
  xor edx, edx
in_ring:
  mov r10, rdx
  shl r10, 6
  cmp qword ptr [r11+r10+TASK_RECORDS+TASK_STATE], 1
  jbe have_next                  # state 0 is the initial main slot only
  cmp rdx, rcx
  jne find_next
  # No runnable slot. Fail one blocked operation (prefer main) without writing
  # data or closing a channel. Main can then close a channel and join again.
  xor edx, edx
deadlock_slot:
  mov r10, rdx
  shl r10, 6
  lea r10, [r11+r10+RECORDS]
  cmp qword ptr [r10+TASK_STATE], TASK_SEND
  jae deadlock_wake
  inc rdx
  jmp deadlock_slot               # main is always runnable or blocked, never retired
deadlock_wake:
  mov qword ptr [r10+TASK_WAKE_ERROR], -3
  mov qword ptr [r10+TASK_STATE], 1
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
  mov r10, [r11+rdx+RECORDS+24]
  mov [r11+TASK_CURRENT_STACK_LIMIT], r10
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

# ecx=block reason, rdx=channel address or wanted task slot, r11=task area.
block_current:
  call current_record
  mov [r10+TASK_STATE], rcx
  mov [r10+TASK_KEY], rdx
  mov qword ptr [r10+TASK_WAKE_ERROR], 0
  call schedule
  call task_area
  call current_record
  mov rax, [r10+TASK_WAKE_ERROR]
  ret
current_record:
  mov r10, [r11]
  shl r10, 6
  lea r10, [r11+r10+RECORDS]
  ret

# Channel record (128 bytes): capacity, closed, count, head, tail, eight values.
channel_new:
  call task_area
  mov rcx, [rsp+8]
  test rcx, rcx
  jz channel_invalid
  cmp rcx, CHANNEL_CAPACITY
  ja channel_invalid
  mov rax, [r11+CHANNEL_ISSUED]
  cmp rax, CHANNEL_LIMIT
  jae channel_invalid
  mov rdx, rax
  shl rdx, 7
  mov [r11+rdx+CHANNELS], rcx
  inc rax
  mov [r11+CHANNEL_ISSUED], rax
  ret

# rax=one-based handle, r11=task area. Returns rdx=record or zero.
channel_lookup:
  xor edx, edx
  test rax, rax
  jz 1f
  cmp rax, [r11+CHANNEL_ISSUED]
  ja 1f
  dec rax
  shl rax, 7
  lea rdx, [r11+rax+CHANNELS]
1:
  ret

channel_send:
  call task_area
send_retry:
  mov rax, [rsp+16]
  call channel_lookup
  test rdx, rdx
  jz channel_invalid
  cmp qword ptr [rdx+8], 0
  jne channel_closed
  mov rax, [rdx+16]
  cmp rax, [rdx]
  jb send_ready
  mov ecx, TASK_SEND
  call block_current
  test rax, rax
  jz send_retry
  ret
send_ready:
  mov rcx, [rdx+32]
  mov rax, [rsp+8]
  mov [rdx+rcx*8+40], rax
  inc ecx
  and ecx, CHANNEL_CAPACITY-1
  mov [rdx+32], rcx
  inc qword ptr [rdx+16]
  mov ecx, TASK_RECV
  jmp channel_wake

channel_recv:
  call task_area
  mov rax, [r11]
  mov qword ptr [r11+rax*8+MAILBOX], 0
recv_retry:
  mov rax, [rsp+8]
  call channel_lookup
  test rdx, rdx
  jz channel_invalid
  cmp qword ptr [rdx+16], 0
  jne recv_ready
  cmp qword ptr [rdx+8], 0
  jne channel_closed
  mov ecx, TASK_RECV
  call block_current
  test rax, rax
  jz recv_retry
  ret
recv_ready:
  mov rcx, [rdx+24]
  mov rax, [rdx+rcx*8+40]
  mov r8, [r11]
  mov [r11+r8*8+MAILBOX], rax
  inc ecx
  and ecx, CHANNEL_CAPACITY-1
  mov [rdx+24], rcx
  dec qword ptr [rdx+16]
  mov ecx, TASK_SEND
  jmp channel_wake

channel_value:
  call task_area
  mov rax, [r11]
  mov rax, [r11+rax*8+MAILBOX]
  ret

channel_close:
  call task_area
  mov rax, [rsp+8]
  call channel_lookup
  test rdx, rdx
  jz channel_invalid
  cmp qword ptr [rdx+8], 0
  jne channel_closed
  mov qword ptr [rdx+8], 1
  mov ecx, TASK_SEND
  call channel_wake
  mov ecx, TASK_RECV

# Wake matching waiters; they re-check readiness after being scheduled.
channel_wake:
  xor r8d, r8d
wake_slot:
  mov r10, r8
  shl r10, 6
  lea r10, [r11+r10+RECORDS]
  cmp [r10+TASK_STATE], rcx
  jne wake_next
  cmp [r10+TASK_KEY], rdx
  jne wake_next
  mov qword ptr [r10+TASK_STATE], 1
wake_next:
  inc r8
  cmp r8, [r11+TASK_ISSUED]
  jbe wake_slot
  xor eax, eax
  ret
channel_invalid:
  mov rax, -1
  ret
channel_closed:
  mov rax, -2
  ret

# Only the main task can cancel. It owns the thread at this point, so the
# target cannot be executing. Retire it before the next scheduling/GC point.
task_cancel:
  call task_area
  cmp qword ptr [r11], 0
  jne task_error
  mov rax, [rsp+8]
  call task_lookup
  test r10, r10
  jz task_error
  cmp qword ptr [r10+TASK_STATE], TASK_DONE
  je already_retired
  mov qword ptr [r10+TASK_KEY], 0
  mov qword ptr [r10+16], -4
  mov qword ptr [r10+TASK_OUTCOME], 2
  mov qword ptr [r10+TASK_STATE], TASK_DONE
  xor eax, eax
  ret
already_retired:
  mov eax, 1
  ret
task_outcome:
  call task_area
  mov rax, [rsp+8]
  call task_lookup
  test r10, r10
  jz task_error
  xor eax, eax
  cmp qword ptr [r10+TASK_STATE], TASK_DONE
  jne 1f
  mov rax, [r10+TASK_OUTCOME]
1:
  ret

# Only the main task can release a finished task; keep DONE for GC/scheduling.
task_release:
  call task_area
  cmp qword ptr [r11], 0
  jne task_error
  mov rax, [rsp+8]
  call task_lookup
  test r10, r10
  jz task_error
  cmp qword ptr [r10+TASK_STATE], TASK_DONE
  jne channel_closed             # -2: live, unchanged
  neg qword ptr [r11+rdx*8+TASK_HANDLES]
  xor eax, eax
  ret

# Decode slot, then compare the entire positive handle before touching a record.
# Returns r10=record (zero if stale), rdx=physical slot.
task_lookup:
  xor r10d, r10d
  test rax, rax
  jle 1f
  lea edx, [rax-1]
  and edx, LIMIT-1
  inc edx
  cmp rax, [r11+rdx*8+TASK_HANDLES]
  jne 1f
  mov r10, rdx
  shl r10, 6
  lea r10, [r11+r10+RECORDS]
1:
  ret
