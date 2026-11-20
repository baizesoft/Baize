.intel_syntax noprefix
.global _start

.equ SOURCE_LIMIT, 65536
.equ ELF_BASE, 0x400000
.equ CODE_CAPACITY, 1048576

.section .rodata
target_name: .asciz "native-linux-x64"
return_word: .ascii "返回"
.equ RETURN_LEN, . - return_word
usage: .ascii "用法：stage0 源文件 输出文件 native-linux-x64\n"
.equ USAGE_LEN, . - usage
syntax: .ascii "编译错误：需要返回语句和受支持的整数表达式\n"
.equ SYNTAX_LEN, . - syntax
input_error: .ascii "编译错误：无法读取源码或源码超过容量\n"
.equ INPUT_ERROR_LEN, . - input_error
output_error: .ascii "编译错误：无法写入 ELF\n"
.equ OUTPUT_ERROR_LEN, . - output_error

# Relocatable header template. Program size is filled before opening the output.
elf_header:
    .byte 0x7f, 'E', 'L', 'F', 2, 1, 1, 0
    .zero 8
    .short 2, 62
    .long 1
    .quad ELF_BASE + HEADER_LEN, 64, 0
    .long 0
    .short 64, 56, 1, 0, 0, 0
    .long 1, 5
    .quad 0, ELF_BASE, ELF_BASE, 0, 0, 4096
.equ HEADER_LEN, . - elf_header

.section .bss
.lcomm source, SOURCE_LIMIT + 1
.lcomm elf, CODE_CAPACITY

.section .text
_start:
    cld
    cmp qword ptr [rsp], 4
    jne fail_usage
    mov rbx, [rsp + 16]             # source path
    mov r15, [rsp + 24]             # output path
    mov rsi, [rsp + 32]
    lea rdi, [rip + target_name]
    mov ecx, 17                    # includes NUL
    repe cmpsb
    jne fail_usage

    mov rdi, rbx
    xor esi, esi
    call open_file
    test rax, rax
    js fail_input
    mov rbx, rax
    lea r12, [rip + source]
    mov r13, r12
    lea r14, [r12 + SOURCE_LIMIT + 1]
read_source:
    xor eax, eax
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    sub rdx, r13
    syscall
    cmp rax, -4                   # EINTR
    je read_source
    test rax, rax
    js fail_input
    jz source_complete
    add r13, rax
    cmp r13, r14
    jb read_source
    jmp fail_input
source_complete:
    mov eax, 3
    mov rdi, rbx
    syscall
    test rax, rax
    js fail_input

    lea rsi, [rip + elf_header]
    lea rdi, [rip + elf]
    mov ecx, HEADER_LEN
    rep movsb
    mov r14, rdi                   # next code byte
    xor ebp, ebp                   # expression nesting depth
    call skip_trivia
    lea rax, [r12 + RETURN_LEN]
    cmp rax, r13
    ja fail_syntax
    mov rsi, r12
    lea rdi, [rip + return_word]
    mov ecx, RETURN_LEN
    repe cmpsb
    jne fail_syntax
    mov r12, rsi
    call parse_expression
    call skip_trivia
    cmp r12, r13
    jne fail_syntax

    # pop rdi; mov eax, 60; syscall
    mov dword ptr [r14], 0x003cb85f
    mov dword ptr [r14 + 4], 0x050f0000
    add r14, 8
    lea r12, [rip + elf]
    mov r13, r14
    sub r13, r12
    mov [r12 + 96], r13
    mov [r12 + 104], r13

    mov rdi, r15
    mov esi, 577                   # O_WRONLY | O_CREAT | O_TRUNC
    call open_file
    test rax, rax
    js fail_output
    mov rbx, rax
write_elf:
    mov eax, 1
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    sub rdx, r12
    syscall
    cmp rax, -4
    je write_elf
    test rax, rax
    jle fail_output
    add r12, rax
    cmp r12, r14
    jb write_elf
    mov eax, 3
    mov rdi, rbx
    syscall
    test rax, rax
    js fail_output
    xor edi, edi
    jmp exit

# open(path, flags, 0755). Retry interrupted opens.
open_file:
    mov eax, 2
    mov edx, 493
    syscall
    cmp rax, -4
    je open_file
    ret

# r12 points at the next unconsumed source byte, r13 at one past the end.
# Return the next byte in eax, or -1 at end of input.
peek:
    mov eax, -1
    cmp r12, r13
    jae peek_done
    movzx eax, byte ptr [r12]
peek_done:
    ret

skip_horizontal:
    call peek
    cmp eax, 32
    je horizontal_next
    cmp eax, 9
    jne peek_done
horizontal_next:
    inc r12
    jmp skip_horizontal

skip_trivia:
    call skip_horizontal
    cmp eax, 10
    je trivia_next
    cmp eax, 13
    je trivia_next
    cmp eax, '#'
    jne peek_done
comment_next:
    inc r12
    call peek
    cmp eax, -1
    je peek_done
    cmp eax, 10
    jne comment_next
trivia_next:
    inc r12
    jmp skip_trivia

# Expr = term { ("+" | "-") term }
parse_expression:
    call parse_term
expression_next:
    call skip_horizontal
    cmp eax, '+'
    je expression_operator
    cmp eax, '-'
    jne peek_done
expression_operator:
    push rax
    inc r12
    call parse_term
    pop rax
    # pop rcx (right); pop rax (left)
    mov word ptr [r14], 0x5859
    cmp eax, '+'
    jne emit_subtract
    mov word ptr [r14 + 2], 0x0148
    jmp emit_add_sub_tail
emit_subtract:
    mov word ptr [r14 + 2], 0x2948
emit_add_sub_tail:
    mov word ptr [r14 + 4], 0x50c8 # modrm rax,rcx; push rax
    add r14, 6
    jmp expression_next

# Term = factor { "*" factor }
parse_term:
    call parse_factor
term_next:
    call skip_horizontal
    cmp eax, '*'
    jne peek_done
    inc r12
    call parse_factor
    # pop rcx; pop rax; imul rax,rcx; push rax
    mov dword ptr [r14], 0x0f485859
    mov dword ptr [r14 + 4], 0x0050c1af
    add r14, 7
    jmp term_next

# Factor = decimal | "-" factor | "(" Expr ")"
parse_factor:
    inc ebp
    cmp ebp, 128
    ja fail_syntax
    call skip_horizontal
    cmp eax, '-'
    je parse_negate
    cmp eax, '('
    je parse_parenthesis
    xor r8d, r8d
    sub eax, '0'
    cmp eax, 9
    ja fail_syntax
digit_next:
    imul r8, r8, 10
    jo fail_syntax
    add r8, rax
    jo fail_syntax
    inc r12
    call peek
    sub eax, '0'
    cmp eax, 9
    jbe digit_next
    # movabs rax, imm64; push rax
    mov word ptr [r14], 0xb848
    mov [r14 + 2], r8
    mov byte ptr [r14 + 10], 0x50
    add r14, 11
    jmp factor_done
parse_negate:
    inc r12
    call parse_factor
    # pop rax; neg rax; push rax
    mov dword ptr [r14], 0xd8f74858
    mov byte ptr [r14 + 4], 0x50
    add r14, 5
    jmp factor_done
parse_parenthesis:
    inc r12
    call parse_expression
    cmp eax, ')'
    jne fail_syntax
    inc r12
factor_done:
    dec ebp
    ret

fail_usage:
    lea rsi, [rip + usage]
    mov edx, USAGE_LEN
    jmp fail
fail_input:
    lea rsi, [rip + input_error]
    mov edx, INPUT_ERROR_LEN
    jmp fail
fail_syntax:
    lea rsi, [rip + syntax]
    mov edx, SYNTAX_LEN
    jmp fail
fail_output:
    lea rsi, [rip + output_error]
    mov edx, OUTPUT_ERROR_LEN
fail:
    mov eax, 1
    mov edi, 2
    syscall
    mov edi, 1
exit:
    mov eax, 60
    syscall

.section .note.GNU-stack,"",@progbits
