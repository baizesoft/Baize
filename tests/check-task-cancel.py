"""Cancellation is distinct from a worker returning the same integer."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

EXPECTED = (0, 10, 0, 1, 2, -4, 0, 0, -4, 1048568, -4, 1, 1, -1, -2, 3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('compiler', type=Path)
    parser.add_argument('--before', action='store_true')
    args = parser.parse_args()
    compiler = args.compiler.resolve(strict=True)
    target = 'native-windows-x64' if os.name == 'nt' else 'native-linux-x64'
    source = Path(__file__).resolve().parent / 'cases/N08_任务取消与根退出.bz'
    with tempfile.TemporaryDirectory(prefix='bz-cancel-') as directory:
        program = Path(directory) / 'cancel.exe'
        cc = subprocess.run([str(compiler), str(source), str(program), target], capture_output=True, timeout=20)
        if args.before:
            assert (cc.returncode, cc.stdout, cc.stderr) == (
                1, '编译错误：静态模式下名称不存在或内置尚未标注\n'.encode(), b''), cc
            assert not program.exists(), program
            print('CONFIRMED RED: cancellation and terminal status are unavailable')
            return
        assert cc.returncode == 0 and program.is_file(), cc
        if os.name != 'nt':
            program.chmod(0o700)
        run = subprocess.run([str(program)], capture_output=True, timeout=10)
        assert (run.returncode, run.stdout, run.stderr) == (
            0, ''.join(f'{value}\n' for value in EXPECTED).encode(), b''), run
        print('PASS: cancel queued and blocked workers, drop roots, distinguish terminal causes')


if __name__ == '__main__':
    main()
