"""Audit native runtime assembly against emitted bytes and entry offsets."""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ADDRESS = bytes.fromhex('efcdab9078563412')
GC_ENTRIES = {
    '原生根入入口': 'root_add', '原生根基入口': 'root_base',
    '原生根复位入口': 'root_restore', '原生根弹入口': 'root_drop',
    '原生新建向量入口': 'allocate', '原生向量长度入口': 'length',
    '原生向量读取入口': 'read_byte', '原生向量写入入口': 'write_byte',
}


TASK_ENTRIES = {
    '原生启动任务入口': 'task_spawn', '原生等待任务入口': 'task_wait',
    '原生任务栈检查入口': 'task_stack_check', '原生让出任务入口': 'task_yield',
    '原生新建通道入口': 'channel_new', '原生通道发送入口': 'channel_send',
    '原生通道接收入口': 'channel_recv', '原生通道取值入口': 'channel_value',
    '原生关闭通道入口': 'channel_close',
    '原生取消任务入口': 'task_cancel', '原生任务结局入口': 'task_outcome',
}


def check(assembly, emitter, addresses, entries):
    with tempfile.TemporaryDirectory(prefix='baize-native-asm-') as folder:
        obj, binary = (Path(folder) / name for name in ('runtime.o', 'runtime.bin'))
        subprocess.run(['as', '--64', '-o', obj, ROOT / 'runtime' / assembly], check=True, timeout=15)
        subprocess.run(['objcopy', '-O', 'binary', '-j', '.text', obj, binary], check=True, timeout=15)
        relocations = subprocess.check_output(['objdump', '-r', obj], text=True, timeout=15)
        assert 'RELOCATION RECORDS FOR' not in relocations, relocations
        symbols = {row[2]: int(row[0], 16)
                   for line in subprocess.check_output(['nm', '-n', obj], text=True, timeout=15).splitlines()
                   if len(row := line.split()) == 3}
        raw = binary.read_bytes()

    code = (ROOT / 'compiler/编译器.bz').read_text(encoding='utf-8')
    body = code.split(f'函数 {emitter}() {{\n', 1)[1].split('\n返回 1\n}', 1)[0]
    patches = {f'暂存 = 原生追加整数({area}, 8)': symbol for area, symbol in addresses.items()}
    emitted = bytearray()
    seen = set()
    for line in body.splitlines():
        if line in patches:
            symbol = patches[line]
            assert len(emitted) == symbols[symbol] and symbol not in seen, line
            seen.add(symbol)
            emitted += ADDRESS
        elif match := re.fullmatch(r'暂存 = 原生追加整数\((\d+), (\d+)\)', line):
            value, size = map(int, match.groups())
            emitted.extend(value.to_bytes(size, 'little'))
        else:
            entry, end = line.split(' = ', 1)
            assert end == '原生输出长度' and entry not in seen, line
            assert len(emitted) == symbols[entries[entry]], line
            seen.add(entry)
    assert seen == entries.keys() | set(addresses.values()), seen
    assert emitted == raw, f'{assembly} disagrees with compiler emitter'
    print(f'PASS: {assembly}: {len(raw)} runtime bytes, {len(entries)} native entries, no relocations')
    return symbols


def main():
    gc = check('vector-gc-x64.S', '原生发射向量例行',
               {'原生向量区': 'arena_address', '原生任务区': 'scheduler_address'}, GC_ENTRIES)
    tasks = check('native-tasks-x64.S', '原生发射任务例行', {'原生任务区': 'task_area_address'}, TASK_ENTRIES)
    for name in ('TASK_ISSUED', 'TASK_RECORDS', 'TASK_STATE', 'TASK_DONE'):
        assert gc[name] == tasks[name], (name, gc[name], tasks[name])
    code = (ROOT / 'compiler/编译器.bz').read_text(encoding='utf-8')
    assert f'整数 原生向量区大小 = {gc["WORKER_COUNT"]}\n' in code
    assert f'整数 原生工作根区大小 = {gc["WORKER_STRIDE"] * tasks["LIMIT"]}\n' in code
    slots = tasks['LIMIT'] + 1
    assert tasks['TASK_RECORDS'] + 64 * slots <= tasks['MAILBOX']
    assert tasks['MAILBOX'] + 8 * slots <= tasks['CHANNEL_ISSUED']
    assert tasks['CHANNEL_ISSUED'] + 8 <= tasks['CHANNELS']
    assert tasks['CHANNELS'] + 128 * tasks['CHANNEL_LIMIT'] <= tasks['STACKS']
    assert 40 + 8 * tasks['CHANNEL_CAPACITY'] <= 128
    print('PASS: collector/scheduler layout and emitted root storage agree')


if __name__ == '__main__':
    main()
