"""Verify that readable native GC assembly matches the emitted bytes and all entry offsets."""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ADDRESS = bytes.fromhex('efcdab9078563412')
ENTRIES = {
    '原生根入入口': 'root_add', '原生根基入口': 'root_base',
    '原生根复位入口': 'root_restore', '原生根弹入口': 'root_drop',
    '原生新建向量入口': 'allocate', '原生向量长度入口': 'length',
    '原生向量读取入口': 'read_byte', '原生向量写入入口': 'write_byte',
}


def main():
    with tempfile.TemporaryDirectory(prefix='baize-gc-asm-') as folder:
        obj, binary = (Path(folder) / name for name in ('runtime.o', 'runtime.bin'))
        subprocess.run(['as', '--64', '-o', obj, ROOT / 'runtime/vector-gc-x64.S'], check=True, timeout=15)
        subprocess.run(['objcopy', '-O', 'binary', '-j', '.text', obj, binary], check=True, timeout=15)
        relocations = subprocess.check_output(['objdump', '-r', obj], text=True, timeout=15)
        assert 'RELOCATION RECORDS FOR' not in relocations, relocations
        symbols = {row[2]: int(row[0], 16)
                   for line in subprocess.check_output(['nm', '-n', obj], text=True, timeout=15).splitlines()
                   if len(row := line.split()) == 3}
        raw = binary.read_bytes()

    code = (ROOT / 'compiler/编译器.bz').read_text(encoding='utf-8')
    body = code.split('函数 原生发射向量例行() {\n', 1)[1].split('\n返回 1\n}', 1)[0]
    emitted = bytearray()
    seen = set()
    for line in body.splitlines():
        if line == '暂存 = 原生追加整数(原生向量区, 8)':
            assert len(emitted) == symbols['arena_address'] and 'address' not in seen
            seen.add('address')
            emitted += ADDRESS
        elif match := re.fullmatch(r'暂存 = 原生追加整数\((\d+), (\d+)\)', line):
            value, size = map(int, match.groups())
            emitted.extend(value.to_bytes(size, 'little'))
        else:
            entry, end = line.split(' = ', 1)
            assert end == '原生输出长度' and entry not in seen, line
            assert len(emitted) == symbols[ENTRIES[entry]], line
            seen.add(entry)
    assert seen == ENTRIES.keys() | {'address'}, seen
    assert emitted == raw, 'GC assembly disagrees with compiler emitter'
    print(f'PASS: {len(raw)} runtime bytes, {len(ENTRIES)} native entries, no relocations')


if __name__ == '__main__':
    main()
