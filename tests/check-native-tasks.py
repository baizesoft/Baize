"""Native cooperative task acceptance, including independent frame state."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('compiler', type=Path)
    parser.add_argument('--baseline', type=Path)
    args = parser.parse_args()
    compiler = args.compiler.resolve(strict=True)
    target = 'native-windows-x64' if os.name == 'nt' else 'native-linux-x64'
    cases = Path(__file__).resolve().parent / 'cases'
    with tempfile.TemporaryDirectory(prefix='baize-task-') as directory:
        root = Path(directory)
        control = root / 'control.bz'
        control.write_bytes('输出(7)\n'.encode())
        for label, source, want in (
            ('control', control, b'7\n'),
            ('resumption', cases / 'N01_任务挂起恢复.bz', b'99\n11\n21\n12\n22\n13\n23\n'),
            ('limits', cases / 'N02_任务限额与栈保护.bz',
             b'-1\n-1\n-1\n-2\n447\n-1\n444\n445\n446\n447\n448\n-1\n448\n'),
        ):
            program = root / f'{label}.exe'
            compiled = subprocess.run([str(compiler), str(source), str(program), target],
                                      capture_output=True, timeout=20)
            if compiled.returncode or not program.is_file():
                print('FAIL:', label, compiled.returncode, 'artifact', program.exists(),
                      compiled.stdout.decode('utf-8', 'replace').strip())
                return 1
            if os.name != 'nt':
                program.chmod(0o700)
            run = subprocess.run([str(program)], capture_output=True, timeout=10)
            assert (run.returncode, run.stdout, run.stderr) == (0, want, b''), run
            print('PASS:', label, flush=True)
        if args.baseline:
            older = root / 'old.exe'
            subprocess.run([str(args.baseline.resolve(strict=True)), str(control), str(older), target],
                           capture_output=True, check=True, timeout=20)
            assert older.read_bytes() == (root / 'control.exe').read_bytes()
            print('PASS: unchanged binary without task operations')
        for label, text, diagnostic in (
            ('literal-entry', '输出(启动任务(1, 0))\n', '任务入口须为整数到整数的具名函数'),
            ('boolean-return', '函数 工作(甲: 整数) -> 布尔:\n    返回 甲 == 0\n输出(启动任务(工作, 0))\n',
             '任务入口须为整数到整数的具名函数'),
            ('boolean-handle', '输出(等待任务(真))\n', '实参类型不匹配或数量不符'),
            ('yield-arity', '输出(让出任务(1))\n', '实参类型不匹配或数量不符'),
            ('task-with-gc', '输出(让出任务())\n输出(向量长度(新建字节向量(1)))\n',
             '实验性任务尚不能与字节向量混用'),
        ):
            source = root / f'{label}.bz'
            source.write_bytes(text.encode())
            program = root / f'{label}.exe'
            rejected = subprocess.run([str(compiler), str(source), str(program), target],
                                      capture_output=True, timeout=20)
            assert (rejected.returncode, rejected.stdout) == (1, f'编译错误：{diagnostic}\n'.encode()), rejected
            assert not program.exists(), program
            print('PASS:', label, flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
