"""Compile and verify independent stdout/stderr on the native target."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

CASES = Path(__file__).resolve().parent / 'cases'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('compiler', type=Path)
    parser.add_argument('--baseline', type=Path, help='compare no-stderr output with the previous compiler')
    args = parser.parse_args()
    compiler = args.compiler.resolve(strict=True)
    target = 'native-windows-x64' if os.name == 'nt' else 'native-linux-x64'
    with tempfile.TemporaryDirectory(prefix='baize-stderr-') as temp:
        root = Path(temp)

        def compile_source(source, name):
            artifact = root / f'{name}.exe'
            result = subprocess.run([str(compiler), str(source), str(artifact), target],
                                    capture_output=True, timeout=15)
            assert result.returncode == 0 and artifact.is_file(), (name, result)
            if os.name != 'nt':
                artifact.chmod(0o700)
            return artifact

        control = root / 'control.bz'
        control.write_bytes('输出(3)\n'.encode('utf-8'))
        executable = compile_source(control, 'control')
        result = subprocess.run([str(executable)], capture_output=True, timeout=15)
        assert (result.returncode, result.stdout, result.stderr) == (0, b'3\n', b''), result
        print('PASS: native control', flush=True)

        if args.baseline is not None:
            baseline = args.baseline.resolve(strict=True)
            output = root / 'baseline.exe'
            result = subprocess.run([str(baseline), str(control), str(output), target],
                                    capture_output=True, timeout=15)
            assert result.returncode == 0 and output.is_file(), result
            assert executable.read_bytes() == output.read_bytes(), 'unused stderr changed the artifact'
            print('PASS: no-stderr program stays byte-identical', flush=True)

        executable = compile_source(CASES / 'L01_标准错误隔离.bz', 'stderr')
        result = subprocess.run([str(executable)], capture_output=True, timeout=15)
        assert (result.returncode, result.stdout, result.stderr) == (0, b'3\n', b'L'), result
        print('PASS: stderr byte separate from stdout')

        with control.open('rb') as unreadable_for_write:
            result = subprocess.run([str(executable)], stdout=subprocess.PIPE,
                                    stderr=unreadable_for_write, timeout=15)
        assert (result.returncode, result.stdout) == (2, b''), result
        assert control.read_bytes() == '输出(3)\n'.encode('utf-8')
        print('PASS: nonwritable stderr returns failure')

        typed = root / 'typed.bz'
        typed.write_bytes(('函数 写(值: 整数) -> 整数:\n    返回 错误输出字节(值)\n'
                           '输出(写(-1))\n输出(写(256))\n'
                           '输出(写(0))\n输出(写(255))\n').encode('utf-8'))
        executable = compile_source(typed, 'typed')
        result = subprocess.run([str(executable)], capture_output=True, timeout=15)
        assert (result.returncode, result.stdout, result.stderr) == (0, b'-2\n-2\n0\n0\n', b'\x00\xff'), result
        print('PASS: typed stderr and byte range 0..255')


if __name__ == '__main__':
    main()
