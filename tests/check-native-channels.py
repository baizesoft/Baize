"""Integer channel acceptance: exact handoff trace, closure, and no-progress recovery."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

CASES = {
    'handoff': ('N05_整数通道阻塞与关闭.bz', (10, 20, 0, 21, 0, 0, 0, 0, 0, -1, -2, 71, 72, -2, -2, -2)),
    'no-progress': ('N06_整数通道无进展.bz', (-3, -3, 0, -2, 0, -1, -1, -1)),
    'close-wakes-sender': ('N07_关闭唤醒阻塞发送者.bz', (0, 30, 40, -2, 0, 0, 41, -2, 0)),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('compiler', type=Path)
    parser.add_argument('--before', action='store_true')
    args = parser.parse_args()
    compiler = args.compiler.resolve(strict=True)
    target = 'native-windows-x64' if os.name == 'nt' else 'native-linux-x64'
    cases = Path(__file__).resolve().parent / 'cases'
    with tempfile.TemporaryDirectory(prefix='bz-channel-') as directory:
        for label, (name, values) in CASES.items():
            output = Path(directory) / f'{label}.exe'
            built = subprocess.run([str(compiler), str(cases / name), str(output), target],
                                   capture_output=True, timeout=20)
            if args.before:
                assert (built.returncode, built.stdout, built.stderr) == (
                    1, '编译错误：静态模式下名称不存在或内置尚未标注\n'.encode(), b''), built
                assert not output.exists(), output
                print('CONFIRMED RED:', label)
                continue
            assert built.returncode == 0 and output.is_file() and output.stat().st_size > 0, built
            if os.name != 'nt':
                output.chmod(0o700)
            run = subprocess.run([str(output)], capture_output=True, timeout=10)
            expected = ''.join(f'{value}\n' for value in values).encode()
            assert (run.returncode, run.stdout, run.stderr) == (0, expected, b''), run
            print('PASS:', label)
        if not args.before:
            for label, text in (
                ('bool-payload', '输出(通道发送(1, 真))\n'),
                ('wrong-arity', '输出(通道取值(1))\n'),
            ):
                source = Path(directory) / f'{label}.bz'
                output = Path(directory) / f'{label}.exe'
                source.write_bytes(text.encode())
                built = subprocess.run([str(compiler), str(source), str(output), target],
                                       capture_output=True, timeout=20)
                assert (built.returncode, built.stdout, built.stderr) == (
                    1, '编译错误：实参类型不匹配或数量不符\n'.encode(), b''), built
                assert not output.exists(), output
                print('PASS:', label)


if __name__ == '__main__':
    main()
