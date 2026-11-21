"""Exercise vector GC in a real multiple-file source counting process."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('compiler', type=Path)
    parser.add_argument('--without-gc', action='store_true', help='verify the pre-GC failure control')
    parser.add_argument('--concurrent', action='store_true', help='also compare native task output with serial')
    args = parser.parse_args()
    if args.without_gc and args.concurrent:
        parser.error('choose a pre-GC control or concurrent comparison')
    compiler = args.compiler.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='bz-vector-lines-') as directory:
        scratch = Path(directory)
        app = scratch / 'lines.exe'
        def build(name, output):
            proc = subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/baize.py'), 'build',
                                   '--compiler', str(compiler), '--合入', str(ROOT / 'examples/源码行统计向量核心.bz'),
                                   str(ROOT / 'examples' / name), '-o', str(output)], capture_output=True, timeout=35)
            assert proc.returncode == 0 and output.is_file() and output.stat().st_size > 0, proc
            if os.name != 'nt':
                output.chmod(0o700)
        build('源码行统计向量.bz', app)
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
        if args.concurrent:
            cooperative = scratch / 'cooperative.exe'
            build('源码行统计协作.bz', cooperative)
            def invoke(program, files):
                p = subprocess.run([str(program), *map(str, files)], capture_output=True, timeout=30)
                return p.returncode, p.stdout, p.stderr
            out = invoke(cooperative, inputs)
            assert out == (result.returncode, result.stdout, result.stderr), out
            boundary = scratch / '跨块.bz'
            boundary.write_bytes(b'x' * 8191 + b'\r\nlast')
            assert invoke(cooperative, [boundary]) == invoke(app, [boundary]) == (0, b'2\n', b'')
            oversized = scratch / '超限.bz'
            oversized.write_bytes(b'x' * 262145)
            for failure, expect in ((scratch / '缺失.bz', '错误：无法读取文件'), (oversized, '错误：文件超过统计上限')):
                batch = [boundary, failure, compiler_source, fixtures[0][0]]
                want = (1, b'2\n' + (expect + '\n').encode(), b'')
                assert invoke(cooperative, batch) == invoke(app, batch) == want
            print('PASS: cooperative/serial results identical for 60 inputs, split CRLF, missing and oversized files')


if __name__ == '__main__':
    main()
