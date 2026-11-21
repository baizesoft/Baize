"""The allocator must reclaim short-lived vectors without losing a live caller reference."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('compiler', type=Path)
    parser.add_argument('--case', choices=('live', 'argument'))
    args = parser.parse_args()
    compiler = args.compiler.resolve(strict=True)
    cases = Path(__file__).resolve().parent / 'cases'
    target = 'native-windows-x64' if os.name == 'nt' else 'native-linux-x64'
    with tempfile.TemporaryDirectory(prefix='baize-gc-') as folder:
        for label, filename, expected in (
            ('live', 'M03_GC保活与复用.bz', b'163\n163\n'),
            ('argument', 'M04_GC参数暂存保活.bz', b'219\n'),
        ):
            if args.case and args.case != label:
                continue
            program = Path(folder) / f'{label}.exe'
            compiled = subprocess.run([str(compiler), str(cases / filename), str(program), target],
                                      capture_output=True, check=True, timeout=20)
            assert program.is_file() and program.stat().st_size > 0, compiled
            if os.name != 'nt':
                program.chmod(0o700)
            result = subprocess.run([str(program)], capture_output=True, timeout=20)
            assert (result.returncode, result.stdout, result.stderr) == (0, expected, b''), result
            print('PASS: GC', label)


if __name__ == '__main__':
    main()
