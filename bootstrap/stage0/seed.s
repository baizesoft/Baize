.intel_syntax noprefix
.global _start

.equ SOURCE_LIMIT, 262144
.equ ELF_BASE, 0x400000
.equ DATA_BASE, 0x600000
.equ GLOBAL_LIMIT, 512
.equ LOCAL_LIMIT, 64
.equ FUNCTION_LIMIT, 256
.equ CALL_LIMIT, 16384
.equ DATA_LIMIT, 16777216
.equ CODE_CAPACITY, DATA_BASE - ELF_BASE

.section .rodata
target_name: .asciz "native-linux-x64"
return_word: .ascii "返回"
.equ RETURN_LEN, . - return_word
integer_word: .ascii "整数"
.equ INTEGER_LEN, . - integer_word
array_word: .ascii "字节数组"
.equ ARRAY_LEN, . - array_word
function_word: .ascii "函数"
.equ FUNCTION_LEN, . - function_word
if_word: .ascii "如果"
.equ IF_LEN, . - if_word
else_word: .ascii "否则"
.equ ELSE_LEN, . - else_word
while_word: .ascii "当"
.equ WHILE_LEN, . - while_word
output_word: .ascii "输出"
.equ OUTPUT_LEN, . - output_word
arg_count_word: .ascii "参数数量"
arg_read_word: .ascii "参数读取"
file_read_word: .ascii "文件读取"
file_write_word: .ascii "文件写入"
.balign 8
# name, byte length, runtime offset, arity
builtins:
    .quad arg_count_word, 12, runtime_arg_count - runtime_begin, 0
    .quad arg_read_word, 12, runtime_arg_read - runtime_begin, 3
    .quad file_read_word, 12, runtime_read - runtime_begin, 3
    .quad file_write_word, 12, runtime_write - runtime_begin, 3
builtins_end:
usage: .ascii "用法：stage0 源文件 输出文件 native-linux-x64\n"
.equ USAGE_LEN, . - usage
syntax: .ascii "编译错误：无法解析语句、表达式或变量。UTF-8 字节偏移 "
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
    .quad ELF_BASE + HEADER_LEN + RUNTIME_LEN, 64, 0
    .long 0
    .short 64, 56, 2, 0, 0, 0
    .long 1, 5
    .quad 0, ELF_BASE, ELF_BASE, 0, 0, 4096
    .long 1, 6                  # PT_LOAD, read/write zero-filled data
    .quad 0, DATA_BASE, DATA_BASE, 0, 0, 4096
.equ HEADER_LEN, . - elf_header

.section .bss
.lcomm source, SOURCE_LIMIT + 1
.lcomm elf, CODE_CAPACITY
.lcomm global_count, 8
.lcomm data_size, 8
.lcomm block_depth, 8
# Global entry: source-name pointer, name length, runtime address, array length (zero for integers).
.lcomm globals, GLOBAL_LIMIT * 32
.lcomm inside_function, 8
.lcomm local_count, 8
# Same layout as globals. Local integers store their signed frame offset.
.lcomm locals, LOCAL_LIMIT * 32
.lcomm function_count, 8
# Function entry: name pointer, name length, code address (0 before declaration), arity.
.lcomm functions, FUNCTION_LIMIT * 32
.lcomm call_count, 8
# Call entry: rel32 field address, pointer to function entry.
.lcomm calls, CALL_LIMIT * 16

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
    lea rsi, [rip + runtime_begin]
    mov ecx, OFFSET FLAT:RUNTIME_LEN
    rep movsb
    mov r14, rdi                   # next code byte
    # Generated entry captures the initial process stack in r12.
    mov word ptr [r14], 0x8949
    mov byte ptr [r14 + 2], 0xe4
    add r14, 3
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
    call resolve_calls
    lea r12, [rip + elf]
    mov r13, r14
    sub r13, r12
    mov [r12 + 96], r13
    mov [r12 + 104], r13
    mov rax, [rip + data_size]
    mov [r12 + 160], rax

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

# Generic name lookup. r8/r9 = name, r10 = start, r11 = entry count.
lookup_entry:
    test r11, r11
    jz entry_missing
    cmp r9, [r10 + 8]
    jne entry_step
    mov rdi, [r10]
    mov rsi, r8
    mov rcx, r9
    repe cmpsb
    je entry_found
entry_step:
    add r10, 32
    dec r11
    jmp lookup_entry
entry_found:
    mov rax, r10
    ret
entry_missing:
    xor eax, eax
    ret

lookup_local_entry:
    lea r10, [rip + locals]
    mov r11, [rip + local_count]
    jmp lookup_entry

lookup_global:
    lea r10, [rip + globals]
    mov r11, [rip + global_count]
    call lookup_entry
    jmp unpack_variable

# Check the function frame's names before looking at global storage.
lookup_variable:
    call lookup_local_entry
    test rax, rax
    jz lookup_global
unpack_variable:
    test rax, rax
    jz variable_missing
    mov rdx, [rax + 24]
    mov rax, [rax + 16]
    ret
variable_missing:
    mov rax, -1
    ret

# Insert a name at the next negative frame offset.
allocate_local:
    mov rax, [rip + local_count]
    cmp rax, LOCAL_LIMIT
    jae fail_syntax
    lea r10, [rip + locals]
    mov rdx, rax
    shl rdx, 5
    add r10, rdx
    mov [r10], r8
    mov [r10 + 8], r9
    inc rax
    mov [rip + local_count], rax
    neg rax
    shl rax, 3
    mov [r10 + 16], rax
    mov qword ptr [r10 + 24], 0
    ret

# Call or define a function by source name. A forward reference initially
# leaves code address and arity unresolved.
function_entry:
    lea r10, [rip + functions]
    mov r11, [rip + function_count]
    call lookup_entry
    test rax, rax
    jnz function_entry_done
    mov rax, [rip + function_count]
    cmp rax, FUNCTION_LIMIT
    jae fail_syntax
    inc qword ptr [rip + function_count]
    shl rax, 5
    lea r10, [rip + functions]
    add rax, r10
    mov [rax], r8
    mov [rax + 8], r9
    mov qword ptr [rax + 16], 0
    mov qword ptr [rax + 24], -1
function_entry_done:
    ret

# Validate arity both for forward calls and later definitions.
check_arity:
    cmp qword ptr [rax + 24], -1
    jne known_arity
    mov [rax + 24], rcx
known_arity:
    cmp [rax + 24], rcx
    jne fail_syntax
    ret

resolve_calls:
    lea rsi, [rip + calls]
    mov rdi, [rip + call_count]
resolve_next:
    test rdi, rdi
    jz resolve_done
    mov rax, [rsi]
    mov rdx, [rsi + 8]
    mov rdx, [rdx + 16]
    test rdx, rdx
    jz fail_syntax
    call patch_jump
    add rsi, 16
    dec rdi
    jmp resolve_next
resolve_done:
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
    call guard_code
    lea rdi, [rip + integer_word]
    mov ecx, INTEGER_LEN
    call match_word
    test eax, eax
    jnz parse_declaration
    lea rdi, [rip + array_word]
    mov ecx, ARRAY_LEN
    call match_word
    test eax, eax
    jnz parse_array_declaration
    lea rdi, [rip + function_word]
    mov ecx, FUNCTION_LEN
    call match_word
    test eax, eax
    jnz parse_function
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
    lea rdi, [rip + output_word]
    mov ecx, OUTPUT_LEN
    call match_word
    test eax, eax
    jnz parse_output
    call parse_name
    call lookup_variable
    cmp rax, -1
    je fail_syntax
    push rax
    test rdx, rdx
    jnz parse_array_assignment
    call parse_initializer
    pop rax
    jmp emit_global_store

parse_array_assignment:
    call parse_index
    call parse_initializer
    pop rax
    # movabs rdx,array; pop rax (value); pop rcx (index); mov [rdx+rcx],al
    mov word ptr [r14], 0xba48
    mov [r14 + 2], rax
    mov dword ptr [r14 + 10], 0x04885958
    mov byte ptr [r14 + 14], 0x0a
    add r14, 15
    ret

parse_index:
    call skip_horizontal
    cmp eax, '['
    jne fail_syntax
    inc r12
    call parse_expression
    cmp eax, ']'
    jne fail_syntax
    inc r12
    ret

parse_declaration:
    cmp qword ptr [rip + inside_function], 0
    jne parse_local_declaration
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
    xor edx, edx
    mov ecx, 8
    call allocate_global
    jmp emit_global_store

parse_array_declaration:
    cmp qword ptr [rip + block_depth], 0
    jne fail_syntax
    call parse_name
    call lookup_global
    test rax, rax
    jns fail_syntax
    push r8
    push r9
    call skip_horizontal
    cmp eax, '['
    jne fail_syntax
    inc r12
    call skip_horizontal
    call parse_decimal
    push r8
    call skip_horizontal
    cmp eax, ']'
    jne fail_syntax
    inc r12
    pop rdx
    pop r9
    pop r8
    test rdx, rdx
    jz fail_syntax
    mov rcx, rdx
    jmp allocate_global

# r8/r9 = name, rdx = array length (0 for integer), rcx = bytes to reserve.
allocate_global:
    mov rax, [rip + global_count]
    cmp rax, GLOBAL_LIMIT
    jae fail_syntax
    mov r11, [rip + data_size]
    mov r10, DATA_LIMIT
    sub r10, r11
    cmp rcx, r10
    ja fail_syntax
    add [rip + data_size], rcx
    shl rax, 5
    lea r10, [rip + globals]
    add rax, r10
    mov [rax], r8
    mov [rax + 8], r9
    add r11, DATA_BASE
    mov [rax + 16], r11
    mov [rax + 24], rdx
    inc qword ptr [rip + global_count]
    mov rax, r11
    ret

parse_local_declaration:
    call parse_name
    call lookup_local_entry
    test rax, rax
    jnz fail_syntax
    push r8
    push r9
    call parse_initializer
    pop r9
    pop r8
    call allocate_local
    jmp emit_global_store

parse_function:
    cmp qword ptr [rip + block_depth], 0
    jne fail_syntax
    call parse_name
    call function_entry
    cmp qword ptr [rax + 16], 0
    jne fail_syntax
    push rax
    call skip_horizontal
    cmp eax, '('
    jne fail_syntax
    inc r12
    call skip_horizontal
    mov qword ptr [rip + local_count], 0
    xor ecx, ecx
    cmp eax, ')'
    je function_parameters_done
function_parameter:
    call parse_name
    call lookup_local_entry
    test rax, rax
    jnz fail_syntax
    call allocate_local
    call skip_horizontal
    cmp eax, ','
    jne function_parameters_done
    inc r12
    jmp function_parameter
function_parameters_done:
    cmp eax, ')'
    jne fail_syntax
    inc r12
    pop rax
    mov rcx, [rip + local_count]
    call check_arity
    # Main execution skips the inline function body.
    mov byte ptr [r14], 0xe9
    lea rdx, [r14 + 1]
    push rdx
    add r14, 5
    mov [rax + 16], r14
    # push rbp; mov rbp,rsp; sub rsp, LOCAL_LIMIT*8
    mov dword ptr [r14], 0xe5894855
    mov dword ptr [r14 + 4], 0x00ec8148
    mov dword ptr [r14 + 7], LOCAL_LIMIT * 8
    add r14, 11
    xor edx, edx
copy_parameter:
    cmp rdx, rcx
    jae parameters_copied
    mov rax, rcx
    sub rax, rdx
    lea rax, [rax * 8 + 8]
    # mov rax,[rbp+disp32]; mov [rbp+disp32],rax
    mov dword ptr [r14], 0x00858b48
    mov [r14 + 3], eax
    mov dword ptr [r14 + 7], 0x00858948
    mov rax, rdx
    not rax
    shl rax, 3
    mov [r14 + 10], eax
    add r14, 14
    inc rdx
    jmp copy_parameter
parameters_copied:
    mov qword ptr [rip + inside_function], 1
    call parse_block
    mov qword ptr [rip + inside_function], 0
    mov qword ptr [rip + local_count], 0
    # A function that falls through returns zero.
    mov dword ptr [r14], 0xc3c9c031
    add r14, 4
    pop rax
    mov rdx, r14
    jmp patch_jump

parse_block:
    inc qword ptr [rip + block_depth]
    cmp qword ptr [rip + block_depth], 128
    ja fail_syntax
    call skip_horizontal
    cmp eax, '{'
    jne fail_syntax
    inc r12
    push qword ptr [rip + local_count]
    call skip_trivia
    call parse_statements
    pop qword ptr [rip + local_count]
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

parse_output:
    call skip_horizontal
    cmp eax, '('
    jne fail_syntax
    inc r12
    call skip_horizontal
    cmp eax, '"'
    je parse_output_text
    call parse_expression
    cmp eax, ')'
    jne fail_syntax
    inc r12
    mov eax, runtime_output - runtime_begin
    call emit_runtime_call
    # The printed integer occupied one stack slot.
    mov dword ptr [r14], 0x08c48348
    add r14, 4
    ret

parse_output_text:
    inc r12
    mov byte ptr [r14], 0xe9
    lea r10, [r14 + 1]
    add r14, 5
    mov r11, r14
text_next:
    call guard_code
    call peek
    cmp eax, -1
    je fail_syntax
    cmp eax, 10
    je fail_syntax
    inc r12
    cmp eax, '"'
    je text_done
    cmp eax, 92
    jne append_text
    call peek
    cmp eax, -1
    je fail_syntax
    cmp eax, 10
    je fail_syntax
    inc r12
    cmp eax, 'n'
    jne text_tab
    mov eax, 10
    jmp append_text
text_tab:
    cmp eax, 't'
    jne append_text
    mov eax, 9
append_text:
    mov [r14], al
    inc r14
    jmp text_next
text_done:
    mov byte ptr [r14], 10
    inc r14
    call skip_horizontal
    cmp eax, ')'
    jne fail_syntax
    inc r12
    mov rax, r10
    mov rdx, r14
    call patch_jump
    # write(1, ELF_BASE + text offset, text length).
    mov rax, r11
    lea rdx, [rip + elf]
    sub rax, rdx
    add rax, ELF_BASE
    mov rdx, r14
    sub rdx, r11
    mov word ptr [r14], 0xbe48   # movabs rsi,imm64
    mov [r14 + 2], rax
    mov byte ptr [r14 + 10], 0xba # mov edx,imm32
    mov [r14 + 11], edx
    mov byte ptr [r14 + 15], 0xbf # mov edi,1
    mov dword ptr [r14 + 16], 1
    mov byte ptr [r14 + 20], 0xb8 # mov eax,1
    mov dword ptr [r14 + 21], 1
    mov word ptr [r14 + 25], 0x050f
    add r14, 27
    ret

# rax is an offset into the runtime prefix of the generated ELF.
emit_runtime_call:
    lea rdx, [rip + elf + HEADER_LEN]
    add rdx, rax
    mov byte ptr [r14], 0xe8
    lea rax, [r14 + 1]
    add r14, 5
    jmp patch_jump

parse_initializer:
    call skip_horizontal
    cmp eax, '='
    jne fail_syntax
    inc r12
    jmp parse_expression

parse_return:
    call parse_expression
    cmp qword ptr [rip + inside_function], 0
    je emit_exit
    # pop rax; leave; ret
    mov word ptr [r14], 0xc958
    mov byte ptr [r14 + 2], 0xc3
    add r14, 3
    ret
emit_exit:
    # pop rdi; mov eax, 60; syscall
    mov dword ptr [r14], 0x003cb85f
    mov dword ptr [r14 + 4], 0x050f0000
    add r14, 8
    ret

emit_global_store:
    test rax, rax
    js emit_local_store
    # pop rax; mov moffs64,rax
    mov word ptr [r14], 0x4858
    mov byte ptr [r14 + 2], 0xa3
    mov [r14 + 3], rax
    add r14, 11
    ret

emit_local_store:
    # pop rax; mov [rbp+disp32],rax
    mov dword ptr [r14], 0x85894858
    mov [r14 + 4], eax
    add r14, 8
    ret

# Leave room for prologues and for pending control-flow/operand emissions
# while the enclosing parse calls unwind.
guard_code:
    lea rdx, [rip + elf + CODE_CAPACITY - 4096]
    cmp r14, rdx
    jae fail_syntax
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
    je term_operator
    cmp eax, '/'
    jne peek_done
term_operator:
    push rax
    inc r12
    call parse_factor
    pop rax
    cmp eax, '/'
    je emit_divide
    # pop rcx; pop rax; imul rax,rcx; push rax
    mov dword ptr [r14], 0x0f485859
    mov dword ptr [r14 + 4], 0x0050c1af
    add r14, 7
    jmp term_next
emit_divide:
    # pop rcx; pop rax; cqo; idiv rcx; push rax
    mov dword ptr [r14], 0x99485859
    mov dword ptr [r14 + 4], 0x50f9f748
    add r14, 8
    jmp term_next

# Factor = decimal | "-" factor | "(" Expr ")"
parse_factor:
    call guard_code
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
    call parse_decimal
    mov rax, r8
    call emit_immediate
    jmp factor_done

# Parse an unsigned spelling that fits in a signed 64-bit word. Return it in r8.
parse_decimal:
    sub eax, '0'
    cmp eax, 9
    ja fail_syntax
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
    ret

emit_immediate:
    # movabs rax, imm64; push rax
    mov word ptr [r14], 0xb848
    mov [r14 + 2], rax
    mov byte ptr [r14 + 10], 0x50
    add r14, 11
    ret

parse_variable:
    call parse_name
    call skip_horizontal
    cmp eax, '('
    je parse_builtin_call
    call lookup_variable
    cmp rax, -1
    je fail_syntax
    test rax, rax
    js parse_local_value
    test rdx, rdx
    jnz parse_array_value
    # mov rax,moffs64; push rax
    mov word ptr [r14], 0xa148
    mov [r14 + 2], rax
    mov byte ptr [r14 + 10], 0x50
    add r14, 11
    jmp factor_done

parse_local_value:
    # mov rax,[rbp+disp32]; push rax
    mov dword ptr [r14], 0x00858b48
    mov [r14 + 3], eax
    mov byte ptr [r14 + 7], 0x50
    add r14, 8
    jmp factor_done

parse_builtin_call:
    lea r10, [rip + builtins]
    lea r11, [rip + builtins_end]
builtin_next:
    cmp r10, r11
    jae user_call
    cmp r9, [r10 + 8]
    jne builtin_step
    mov rsi, r8
    mov rdi, [r10]
    mov rcx, r9
    repe cmpsb
    je builtin_found
builtin_step:
    add r10, 32
    jmp builtin_next
user_call:
    call function_entry
    push rax
    push 1
    jmp parse_call_arguments
builtin_found:
    push r10
    push 0
parse_call_arguments:
    inc r12
    call skip_horizontal
    xor ecx, ecx
    cmp eax, ')'
    je builtin_arguments_done
builtin_argument:
    push rcx
    call parse_expression
    pop rcx
    inc ecx
    cmp ecx, LOCAL_LIMIT
    ja fail_syntax
    cmp eax, ','
    jne builtin_arguments_done
    inc r12
    jmp builtin_argument
builtin_arguments_done:
    cmp eax, ')'
    jne fail_syntax
    inc r12
    pop rax
    pop r10
    test rax, rax
    jnz emit_user_call
    cmp rcx, [r10 + 24]
    jne fail_syntax
    mov rax, [r10 + 16]
    call emit_runtime_call
    jmp emit_call_cleanup
emit_user_call:
    mov rax, r10
    call check_arity
    mov rdx, [rip + call_count]
    cmp rdx, CALL_LIMIT
    jae fail_syntax
    inc qword ptr [rip + call_count]
    shl rdx, 4
    lea r10, [rip + calls]
    add r10, rdx
    mov byte ptr [r14], 0xe8
    lea rdx, [r14 + 1]
    mov [r10], rdx
    mov [r10 + 8], rax
    add r14, 5
emit_call_cleanup:
    # add rsp, nargs * 8; push rax
    mov dword ptr [r14], 0x00c48148
    shl ecx, 3
    mov [r14 + 3], ecx
    mov byte ptr [r14 + 7], 0x50
    add r14, 8
    jmp factor_done

parse_array_value:
    push rax
    call skip_horizontal
    cmp eax, '['
    pop rax
    jne emit_array_address
    push rax
    call parse_index
    pop rax
    # movabs rax,array; pop rcx; movzx eax,byte [rax+rcx]; push rax
    mov word ptr [r14], 0xb848
    mov [r14 + 2], rax
    mov dword ptr [r14 + 10], 0x04b60f59
    mov word ptr [r14 + 14], 0x5008
    add r14, 16
    jmp factor_done
emit_array_address:
    call emit_immediate
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
    mov eax, 1
    mov edi, 2
    syscall
    lea rax, [rip + source]
    mov rdx, r12
    sub rdx, rax
    push rdx
    mov r9d, 2
    call print_integer
    mov edi, 1
    jmp exit
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

# Copied with its relative branches intact. No host pointers are embedded.
runtime_begin:
runtime_arg_count:
    mov rax, [r12]
    dec rax
    ret

runtime_arg_read:
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 16]
    mov rdx, [rsp + 8]
    test rdi, rdi
    js runtime_error
    test rdx, rdx
    jle runtime_error
    mov rcx, [r12]
    dec rcx
    cmp rdi, rcx
    jae runtime_error
    mov r8, [r12 + rdi * 8 + 16]
    xor eax, eax
    dec rdx
runtime_arg_next:
    cmp rax, rdx
    jae runtime_arg_done
    mov cl, [r8 + rax]
    test cl, cl
    jz runtime_arg_done
    mov [rsi + rax], cl
    inc rax
    jmp runtime_arg_next
runtime_arg_done:
    mov byte ptr [rsi + rax], 0
    ret

runtime_read:
    xor r8d, r8d
    jmp runtime_open
runtime_write:
    mov r8d, 1
runtime_open:
    cmp qword ptr [rsp + 8], 0
    jl runtime_error
    mov rdi, [rsp + 24]
    xor esi, esi
    test r8d, r8d
    jz runtime_open_retry
    mov esi, 577
runtime_open_retry:
    mov eax, 2
    mov edx, 438
    syscall
    cmp rax, -4
    je runtime_open_retry
    test rax, rax
    js runtime_error
    mov r9, rax
    xor r10d, r10d
runtime_transfer:
    mov rdx, [rsp + 8]
    sub rdx, r10
    jz runtime_close
    mov rdi, r9
    mov rsi, [rsp + 16]
    add rsi, r10
    mov eax, r8d
    syscall
    cmp rax, -4
    je runtime_transfer
    test rax, rax
    js runtime_transfer_error
    jnz runtime_advance
    test r8d, r8d
    jz runtime_close
runtime_transfer_error:
    mov r10, -1
    jmp runtime_close
runtime_advance:
    add r10, rax
    jmp runtime_transfer
runtime_close:
    mov eax, 3
    mov rdi, r9
    syscall
    test rax, rax
    js runtime_error
    mov rax, r10
    ret
runtime_error:
    mov rax, -1
    ret

runtime_output:
    mov r9d, 1
print_integer:
    mov rax, [rsp + 8]
    sub rsp, 32
    lea rsi, [rsp + 31]
    mov byte ptr [rsi], 10
    xor r8d, r8d
    test rax, rax
    jns runtime_print_magnitude
    mov r8d, 1
    neg rax
runtime_print_magnitude:
    mov ecx, 10
runtime_print_next:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rax, rax
    jnz runtime_print_next
    test r8d, r8d
    jz runtime_print
    dec rsi
    mov byte ptr [rsi], '-'
runtime_print:
    lea rdx, [rsp + 32]
    sub rdx, rsi
    mov edi, r9d
    mov eax, 1
    syscall
    add rsp, 32
    ret
.equ RUNTIME_LEN, . - runtime_begin

.section .note.GNU-stack,"",@progbits
