"""First managed-memory end-to-end acceptance: a dynamic vector crosses a typed call."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

CASES = Path(__file__).resolve().parent / 'cases'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('compiler', type=Path)
    parser.add_argument('--baseline', type=Path)
    args = parser.parse_args()
    compiler = args.compiler.resolve(strict=True)
    native = 'native-windows-x64' if os.name == 'nt' else 'native-linux-x64'
    with tempfile.TemporaryDirectory(prefix='baize-memory-') as directory:
        root = Path(directory)
        control = root / 'control.bz'
        control.write_bytes('输出(17)\n'.encode())
        for label, source, expected in (
            ('control', control, b'17\n'),
            ('vector', CASES / 'M01_动态向量长度.bz', b'17\n0\n23\n-1\n-1\n1048504\n0\n-1\n1\n'),
            ('checked-access', CASES / 'M02_动态向量受检读写.bz',
             b'0\n0\n0\n-1\n-1\n-1\n-1\n-1\n-1\n255\n9\n1\n-1\n-1\n-1\n-1\n-1\n'),
        ):
            artifact = root / f'{label}.exe'
            compiled = subprocess.run([str(compiler), str(source), str(artifact), native],
                                      capture_output=True, timeout=20)
            if compiled.returncode or not artifact.is_file():
                print('FAIL:', label, 'compiler exit', compiled.returncode, 'artifact', artifact.exists(),
                      compiled.stdout.decode('utf-8', errors='replace').strip())
                return 1
            if os.name != 'nt':
                artifact.chmod(0o700)
            execution = subprocess.run([str(artifact)], capture_output=True, timeout=15)
            assert (execution.returncode, execution.stdout, execution.stderr) == (0, expected, b''), execution
            print('PASS:', label, flush=True)
        if args.baseline:
            old = root / 'baseline.exe'
            subprocess.run([str(args.baseline.resolve(strict=True)), str(control), str(old), native],
                           capture_output=True, check=True, timeout=20)
            assert old.read_bytes() == (root / 'control.exe').read_bytes()
            print('PASS: unchanged image without vector calls', flush=True)
        for label, text in (
            ('integer-as-reference', '输出(向量长度(17))\n'),
            ('boolean-as-size', '输出(向量长度(新建字节向量(真)))\n'),
            ('read-integer-reference', '输出(向量读字节(17, 0))\n'),
            ('read-boolean-index', '输出(向量读字节(新建字节向量(1), 真))\n'),
            ('write-boolean-value', '输出(向量写字节(新建字节向量(1), 0, 真))\n'),
            ('write-arity', '输出(向量写字节(新建字节向量(1), 0))\n'),
        ):
            source = root / f'{label}.bz'
            source.write_bytes(text.encode())
            artifact = root / f'{label}.exe'
            rejected = subprocess.run([str(compiler), str(source), str(artifact), native],
                                      capture_output=True, timeout=20)
            assert (rejected.returncode, rejected.stdout) == (1, '编译错误：实参类型不匹配或数量不符\n'.encode()), rejected
            assert not artifact.exists(), artifact
            print('PASS:', label, flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
