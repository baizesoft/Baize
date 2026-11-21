"""Exercise vector GC in a real multiple-file source counting process."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('compiler', type=Path)
    parser.add_argument('--without-gc', action='store_true', help='verify the pre-GC failure control')
    args = parser.parse_args()
    compiler = args.compiler.resolve(strict=True)
    target = 'native-windows-x64' if os.name == 'nt' else 'native-linux-x64'
    with tempfile.TemporaryDirectory(prefix='bz-vector-lines-') as directory:
        scratch = Path(directory)
        app = scratch / 'lines.exe'
        src = ROOT / 'examples/源码行统计向量.bz'
        subprocess.run([str(compiler), str(src), str(app), target], check=True, capture_output=True, timeout=25)
        assert app.is_file() and app.stat().st_size > 0
        if os.name != 'nt':
            app.chmod(0o700)
        compiler_source = ROOT / 'compiler/编译器.bz'
        # Windows argument lengths are kept below the native path buffer limit.
        fixtures = [(scratch / '白 泽.bz', '# 中文\r\n输出(1)'.encode()), (scratch / '空.bz', b''),
                    (scratch / '尾换行.bz', b'# x\n# y\n')]
        for path, body in fixtures:
            path.write_bytes(body)
        inputs = [compiler_source, fixtures[0][0], compiler_source, fixtures[1][0], fixtures[2][0]] * 12
        payloads = [path.read_bytes() for path in inputs]
        total = sum(map(len, payloads))
        expected = [str(body.count(b'\n') + bool(body and not body.endswith(b'\n'))).encode() for body in payloads]
        assert total > 2 * 1048576, total
        result = subprocess.run([str(app), *map(str, inputs)], capture_output=True, timeout=30)
        if args.without_gc:
            assert result.returncode == 1 and result.stderr == b'', result
            lines = result.stdout.splitlines()
            assert 1 < len(lines) < len(expected) and lines[:-1] == expected[:len(lines)-1], result
            assert lines[-1] == '错误：无法分配文件向量'.encode(), result
            print(f'PASS: allocator without GC stops after {len(lines)-1} of {len(inputs)} inputs')
            return
        assert (result.returncode, result.stdout.splitlines(), result.stderr) == (0, expected, b''), result
        print(f'PASS: one process counted {len(inputs)} files and loaded {total} source bytes')
        missing = subprocess.run([str(app), str(scratch / '缺失.bz')], capture_output=True, timeout=10)
        assert (missing.returncode, missing.stdout, missing.stderr) == (1, '错误：无法读取文件\n'.encode(), b''), missing
        print('PASS: native missing-file error')


if __name__ == '__main__':
    main()
