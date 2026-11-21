"""Run the actual worker-pool example against a serial oracle and heap pressure."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = ROOT / 'examples'
ALLOC = '错误：无法分配文件向量\n'.encode()
MISSING = '错误：无法读取文件\n'.encode()
OVERSIZE = '错误：文件超过统计上限\n'.encode()


def build(compiler, example, program):
    r = subprocess.run([sys.executable, '-B', str(ROOT/'scripts/baize.py'), 'build',
                        '--compiler', str(compiler), '--合入', str(EXAMPLES/'源码行统计向量核心.bz'),
                        str(example), '-o', str(program)], capture_output=True, timeout=35)
    assert r.returncode == 0 and program.is_file(), r
    if os.name != 'nt':
        program.chmod(0o700)


def count(data):
    return f'{data.count(bytes([10])) + bool(data and not data.endswith(bytes([10])))}\n'.encode()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('compiler', type=Path)
    p.add_argument('--before', type=Path, help='eight-worker unbounded control source')
    args = p.parse_args()
    compiler = args.compiler.resolve(strict=True)
    data = (ROOT/'compiler/编译器.bz').read_bytes().replace(b'\r\n', b'\n')
    assert 0 < len(data) <= 262144, 'compiler-source fixture must fit in one vector'
    if args.before:
        assert 7*(len(data)+8) <= 1048576 < 8*(len(data)+8), 'wrong source revision for the red control'
    with tempfile.TemporaryDirectory(prefix='bz-window-') as directory:
        cwd = Path(directory)
        bounded = cwd/'pool.exe'
        serial = cwd/'serial.exe'
        build(compiler, EXAMPLES/'源码行统计向量.bz', serial)
        build(compiler, args.before or EXAMPLES/'源码行统计背压.bz', bounded)
        fixtures = {'编译器.bz': data, '最大.bz': b'x'*262143+b'\n', '太大.bz': b'x'*262145,
                    '跨 分块.bz': b'x'*8191+b'\r\nlast', '空.bz': b'', '不同.bz': b'a\nb\nc\n'}
        for name, body in fixtures.items():
            (cwd/name).write_bytes(body)

        def run(program, inputs):
            r = subprocess.run([str(program), *inputs], cwd=cwd, capture_output=True, timeout=20)
            return r.returncode, r.stdout, r.stderr

        dense = ['编译器.bz']*96
        expected = (0, count(data)*len(dense), b'')
        assert run(serial, dense) == expected
        if args.before:
            baseline = run(bounded, dense)
            assert baseline == (1, count(data)*7+ALLOC, b''), baseline
            print('CONFIRMED RED: unbounded eight-worker batch fails after seven correct files')
            return
        assert run(bounded, dense) == expected
        print('PASS: 96 real compiler-source jobs in one process')

        for inputs in (['最大.bz']*13, ['最大.bz','空.bz','不同.bz','跨 分块.bz','编译器.bz']*15,
                       ['不同.bz'], ['跨 分块.bz','空.bz']):
            expected = (0, b''.join(count(fixtures[n]) for n in inputs), b'')
            assert run(bounded, inputs) == run(serial, inputs) == expected, inputs
        print('PASS: maximum-sized windows, out-of-order completion, empty and partial final windows')

        for prefix, bad, diagnostic, later in (
            (['最大.bz'], '缺失.bz', MISSING, '太大.bz'),
            (['不同.bz','编译器.bz','空.bz','最大.bz'], '太大.bz', OVERSIZE, '缺失.bz'),
            ([], '缺失.bz', MISSING, '最大.bz'),
        ):
            inputs = prefix+[bad,later,'编译器.bz']
            want = (1, b''.join(count(fixtures[n]) for n in prefix)+diagnostic, b'')
            assert run(bounded, inputs) == run(serial, inputs) == want, inputs
        assert run(bounded, []) == run(serial, []) == (2, '用法：批量源码行统计 <文件.bz> ...\n'.encode(), b'')
        assert run(bounded, dense) == (0, count(data)*len(dense), b'')
        print('PASS: first input-order error, cancel other work, empty invocation, and clean rerun')


if __name__ == '__main__':
    main()
