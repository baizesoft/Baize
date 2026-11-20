.intel_syntax noprefix
.global _start

.equ SOURCE_LIMIT, 65536
.equ ELF_BASE, 0x400000
.equ DATA_BASE, 0x600000
.equ GLOBAL_LIMIT, 256
.equ CODE_CAPACITY, 1048576

.section .rodata
target_name: .asciz "native-linux-x64"
return_word: .ascii "返回"
.equ RETURN_LEN, . - return_word
integer_word: .ascii "整数"
.equ INTEGER_LEN, . - integer_word
if_word: .ascii "如果"
.equ IF_LEN, . - if_word
else_word: .ascii "否则"
.equ ELSE_LEN, . - else_word
while_word: .ascii "当"
.equ WHILE_LEN, . - while_word
usage: .ascii "用法：stage0 源文件 输出文件 native-linux-x64\n"
.equ USAGE_LEN, . - usage
syntax: .ascii "编译错误：无法解析语句、表达式或变量\n"
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
    .short 64, 56, 2, 0, 0, 0
    .long 1, 5
    .quad 0, ELF_BASE, ELF_BASE, 0, 0, 4096
    .long 1, 6                  # PT_LOAD, read/write zero-filled data
    .quad 0, DATA_BASE, DATA_BASE, 0, GLOBAL_LIMIT * 8, 4096
.equ HEADER_LEN, . - elf_header

.section .bss
.lcomm source, SOURCE_LIMIT + 1
.lcomm elf, CODE_CAPACITY
.lcomm global_count, 8
.lcomm block_depth, 8
# Each entry stores source offset as a pointer, and identifier byte length.
.lcomm globals, GLOBAL_LIMIT * 16

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
    cmp eax, -1
    je fail_syntax
    call parse_statements
    cmp eax, -1
    jne fail_syntax
    # Falling off the end exits with status zero.
    mov byte ptr [r14], 0x6a     # push imm8
    mov byte ptr [r14 + 1], 0
    add r14, 2
    call emit_exit
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

# Match a statement keyword at the current position. Advance only on a match.
# Input rdi = literal bytes, ecx = length; output eax = 0 or 1.
match_word:
    lea rax, [r12 + rcx]
    cmp rax, r13
    ja word_missing
    mov rsi, r12
    repe cmpsb
    jne word_missing
    cmp rsi, r13
    je word_found
    movzx eax, byte ptr [rsi]
    call identifier_byte
    jc word_missing
word_found:
    mov r12, rsi
    mov eax, 1
    ret
word_missing:
    xor eax, eax
    ret

# CF set for an ASCII letter, underscore, or byte of a UTF-8 name.
identifier_start:
    cmp eax, 128
    jae identifier_yes
    cmp eax, '_'
    je identifier_yes
    or eax, 32
    sub eax, 'a'
    cmp eax, 26
    ret
identifier_yes:
    stc
    ret
identifier_byte:
    mov edx, eax
    sub edx, '0'
    cmp edx, 10
    jb identifier_yes
    jmp identifier_start

# Return name start and byte length in r8/r9.
parse_name:
    call skip_horizontal
    cmp eax, -1
    je fail_syntax
    call identifier_start
    jnc fail_syntax
    mov r8, r12
name_next:
    inc r12
    call peek
    cmp eax, -1
    je name_done
    call identifier_byte
    jc name_next
name_done:
    mov r9, r12
    sub r9, r8
    ret

# Return global slot number or -1. Preserve the parsed name in r8/r9.
lookup_global:
    lea r10, [rip + globals]
    xor r11d, r11d
global_next:
    cmp r11, [rip + global_count]
    jae global_missing
    cmp r9, [r10 + 8]
    jne global_step
    mov rdi, [r10]
    mov rsi, r8
    mov rcx, r9
    repe cmpsb
    je global_found
global_step:
    add r10, 16
    inc r11
    jmp global_next
global_found:
    mov rax, r11
    ret
global_missing:
    mov rax, -1
    ret

parse_statements:
    cmp eax, -1
    je statements_done
    cmp eax, '}'
    je statements_done
    call parse_statement
    call skip_horizontal
    cmp eax, -1
    je statements_done
    cmp eax, '}'
    je statements_done
    cmp eax, 10
    je statements_next
    cmp eax, 13
    je statements_next
    cmp eax, '#'
    jne fail_syntax
statements_next:
    call skip_trivia
    jmp parse_statements
statements_done:
    ret

parse_statement:
    lea rdi, [rip + integer_word]
    mov ecx, INTEGER_LEN
    call match_word
    test eax, eax
    jnz parse_declaration
    lea rdi, [rip + return_word]
    mov ecx, RETURN_LEN
    call match_word
    test eax, eax
    jnz parse_return
    lea rdi, [rip + if_word]
    mov ecx, IF_LEN
    call match_word
    test eax, eax
    jnz parse_if
    lea rdi, [rip + while_word]
    mov ecx, WHILE_LEN
    call match_word
    test eax, eax
    jnz parse_while
    call parse_name
    call lookup_global
    test rax, rax
    js fail_syntax
    push rax
    call parse_initializer
    pop rax
    jmp emit_global_store

parse_declaration:
    cmp qword ptr [rip + block_depth], 0
    jne fail_syntax
    call parse_name
    call lookup_global
    test rax, rax
    jns fail_syntax
    cmp qword ptr [rip + global_count], GLOBAL_LIMIT
    jae fail_syntax
    push r8
    push r9
    call parse_initializer
    pop r9
    pop r8
    mov rax, [rip + global_count]
    mov rdx, rax
    shl rdx, 4
    lea r10, [rip + globals]
    mov [r10 + rdx], r8
    mov [r10 + rdx + 8], r9
    inc qword ptr [rip + global_count]
    jmp emit_global_store

parse_block:
    inc qword ptr [rip + block_depth]
    cmp qword ptr [rip + block_depth], 128
    ja fail_syntax
    call skip_horizontal
    cmp eax, '{'
    jne fail_syntax
    inc r12
    call skip_trivia
    call parse_statements
    cmp eax, '}'
    jne fail_syntax
    inc r12
    dec qword ptr [rip + block_depth]
    ret

# Emit an unresolved jump when a condition is zero.
# Return the rel32 field address in rax.
parse_condition:
    call skip_horizontal
    cmp eax, '('
    jne fail_syntax
    inc r12
    call parse_expression
    cmp eax, ')'
    jne fail_syntax
    inc r12
    # pop rax; test rax,rax; jz rel32
    mov dword ptr [r14], 0xc0854858
    mov word ptr [r14 + 4], 0x840f
    lea rax, [r14 + 6]
    add r14, 10
    ret

# Patch the relative displacement at rax to jump to rdx.
patch_jump:
    sub rdx, rax
    sub rdx, 4
    mov [rax], edx
    ret

parse_if:
    call parse_condition
    push rax
    call parse_block
    call skip_horizontal
    lea rdi, [rip + else_word]
    mov ecx, ELSE_LEN
    call match_word
    test eax, eax
    pop rax
    jz finish_if
    mov byte ptr [r14], 0xe9
    lea rcx, [r14 + 1]
    add r14, 5
    mov rdx, r14
    call patch_jump
    push rcx
    call parse_block
    pop rax
finish_if:
    mov rdx, r14
    jmp patch_jump

parse_while:
    push r14
    call parse_condition
    push rax
    call parse_block
    mov byte ptr [r14], 0xe9
    lea rax, [r14 + 1]
    add r14, 5
    pop rcx
    pop rdx
    call patch_jump
    mov rax, rcx
    mov rdx, r14
    jmp patch_jump

parse_initializer:
    call skip_horizontal
    cmp eax, '='
    jne fail_syntax
    inc r12
    jmp parse_expression

parse_return:
    call parse_expression
emit_exit:
    # pop rdi; mov eax, 60; syscall
    mov dword ptr [r14], 0x003cb85f
    mov dword ptr [r14 + 4], 0x050f0000
    add r14, 8
    ret

emit_global_store:
    lea rax, [rax * 8 + DATA_BASE]
    # pop rax; mov moffs64,rax
    mov word ptr [r14], 0x4858
    mov byte ptr [r14 + 2], 0xa3
    mov [r14 + 3], rax
    add r14, 11
    ret

# Expr = arithmetic [comparison arithmetic]
parse_expression:
    call parse_arithmetic
    cmp eax, '<'
    je compare_less
    cmp eax, '>'
    je compare_greater
    cmp eax, '='
    je compare_equal
    cmp eax, '!'
    je compare_not_equal
    ret
compare_less:
    mov ecx, 0x9c               # setl
    jmp compare_order
compare_greater:
    mov ecx, 0x9f               # setg
compare_order:
    inc r12
    call peek
    cmp eax, '='
    jne compare_right
    xor ecx, 2                  # setle (9e) or setge (9d)
    jmp compare_second_byte
compare_equal:
    mov ecx, 0x94
    jmp compare_check_equal
compare_not_equal:
    mov ecx, 0x95
compare_check_equal:
    inc r12
    call peek
    cmp eax, '='
    jne fail_syntax
compare_second_byte:
    inc r12
compare_right:
    push rcx
    call parse_arithmetic
    pop rcx
    # pop rcx; pop rax; cmp rax,rcx; setcc al; movzx eax,al; push rax
    mov dword ptr [r14], 0x39485859
    mov word ptr [r14 + 4], 0x0fc8
    mov byte ptr [r14 + 6], cl
    mov dword ptr [r14 + 7], 0xc0b60fc0
    mov byte ptr [r14 + 11], 0x50
    add r14, 12
    ret

# Arithmetic = term { ("+" | "-") term }
parse_arithmetic:
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
    mov edx, eax
    sub edx, '0'
    cmp edx, 9
    ja parse_variable
    mov eax, edx
    xor r8d, r8d
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
parse_variable:
    call parse_name
    call lookup_global
    test rax, rax
    js fail_syntax
    lea rax, [rax * 8 + DATA_BASE]
    # mov rax,moffs64; push rax
    mov word ptr [r14], 0xa148
    mov [r14 + 2], rax
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
