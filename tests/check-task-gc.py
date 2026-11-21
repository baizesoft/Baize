"""Native task/collector integration: suspended roots and discarded worker stacks."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

CASES = {
    'suspended': ('N03_挂起任务精确根.bz', b'11\n22\n227\n150\n199\n0\n1048568\n'),
    'retired': ('N04_终止任务释放根.bz', b'18\n-2\n1048568\n'),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('compiler', type=Path)
    parser.add_argument('--case', choices=tuple(CASES))
    parser.add_argument('--before', action='store_true', help='verify the prior rejection without an artifact')
    args = parser.parse_args()
    compiler = args.compiler.resolve(strict=True)
    target = 'native-windows-x64' if os.name == 'nt' else 'native-linux-x64'
    cases = Path(__file__).resolve().parent / 'cases'
    with tempfile.TemporaryDirectory(prefix='bz-task-gc-') as directory:
        for label, (name, want) in CASES.items():
            if args.case and args.case != label:
                continue
            output = Path(directory) / f'{label}.exe'
            cc = subprocess.run([str(compiler), str(cases / name), str(output), target],
                                capture_output=True, timeout=20)
            if args.before:
                assert (cc.returncode, cc.stdout, cc.stderr) == (
                    1, '编译错误：实验性任务尚不能与字节向量混用\n'.encode(), b''), cc
                assert not output.exists(), output
                print('CONFIRMED RED:', label, 'prior compiler explicitly rejects the combination')
                continue
            assert cc.returncode == 0 and output.is_file() and output.stat().st_size > 0, cc
            if os.name != 'nt':
                output.chmod(0o700)
            run = subprocess.run([str(output)], capture_output=True, timeout=10)
            assert (run.returncode, run.stdout, run.stderr) == (0, want, b''), run
            print('PASS:', label)


if __name__ == '__main__':
    main()
