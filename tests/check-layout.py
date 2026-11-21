"""Verify white-space layout against a supplied native Baize compiler."""
import argparse
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile


INDENTED = '''函数 合计(上限): # 统计从 0 到上限的次数和
    整数 序号 = 0
    整数 总计 = 0
    # 注释和空行不改变层级

    当 序号 < 上限:
        如果 序号 < 2:
            总计 = 总计 + (
                序号 + 1
            )
        否则:
            总计 = 总计 + 2
        序号 = 序号 + 1
    返回 总计
输出(合计(4))'''
BRACED = '''函数 合计(上限) {
整数 序号 = 0
整数 总计 = 0
当(序号 < 上限) {
如果(序号 < 2) {
总计 = 总计 + (序号 + 1)
} 否则 {
总计 = 总计 + 2
}
序号 = 序号 + 1
}
返回 总计
}
输出(合计(4))
'''
REJECTED = (
    ('如果 1:\n输出(1)\n', 2),
    ('如果 1:\n  输出(1)\n', 2),
    ('如果 1:\n\t输出(1)\n', 2),
    ('如果 1:\n    输出(1)\n  输出(2)\n', 3),
    ('如果 1:\n    输出(1)\n        输出(2)\n', 3),
    ('如果 1:\n    # 空块', 2),
    ('如果 1:\n    ;\n', 2),
    ('如果 1: 输出(1)\n', 1),
    ('如果 1:\n    如果(1) { 输出(1) }\n', 2),
)


def run(argv):
    return subprocess.run(argv, check=False, capture_output=True, timeout=15)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('compiler', type=Path)
    args = parser.parse_args()
    compiler = args.compiler.resolve(strict=True)
    windows = os.name == 'nt'
    target = 'native-windows-x64' if windows else 'native-linux-x64'
    newline = '\n'
    with tempfile.TemporaryDirectory(prefix='baize-layout-') as temp:
        root = Path(temp)

        def compile_source(label, text):
            source = root / f'{label}.bz'
            artifact = root / f'{label}.exe'
            source.write_bytes(text.encode('utf-8'))
            return run([str(compiler), str(source), str(artifact), target]), artifact

        for label, text, expect in (
            ('brace', BRACED, '7'), ('layout', INDENTED, '7'),
            ('layout-crlf', INDENTED.replace('\n', '\r\n'), '7'),
            ('layout-eof', '如果 1:\n    输出(3)', '3'),
            ('mixed-top-level', BRACED + '如果 1:\n    输出(3)', '7' + newline + '3'),
        ):
            result, artifact = compile_source(label, text)
            assert result.returncode == 0 and artifact.is_file(), (label, result)
            if not windows:
                artifact.chmod(artifact.stat().st_mode | stat.S_IXUSR)
            actual = run([str(artifact)])
            assert actual.returncode == 0 and actual.stdout == (expect + newline).encode(), (label, actual)
            print('PASS:', label)

        for index, (text, line) in enumerate(REJECTED):
            label = f'reject-{index}'
            result, artifact = compile_source(label, text)
            expected = f'编译错误：缩进块语法错误，行{newline}{line}{newline}'.encode('utf-8')
            assert result.returncode == 1 and not artifact.exists() and result.stdout == expected, (label, result)
            print('PASS:', label)

        project = Path(__file__).resolve().parents[1]
        example = project / 'examples/源码行统计.bz'
        artifact = root / 'count-lines.exe'
        result = run([sys.executable, '-B', str(project / 'scripts/baize.py'), 'build',
                      '--compiler', str(compiler), '--日志', str(example), '-o', str(artifact)])
        assert result.returncode == 0 and artifact.is_file(), result
        for name in ('编译器.bz', '带 空格.bz', '空文件.bz', '缺失.bz'):
            sample = root / name
            if name == '编译器.bz':
                data = (example.parents[1] / 'compiler/编译器.bz').read_bytes()
                expected = len(data.splitlines())
            elif name == '带 空格.bz':
                data = '输出(1)\r\n输出(2)'.encode('utf-8')
                expected = 2
            else:
                data = b''
                expected = 0
            if name != '缺失.bz':
                sample.write_bytes(data)
                actual = run([str(artifact), str(sample)])
                assert actual.returncode == 0 and actual.stdout == f'{expected}\n'.encode(), (name, actual)
            else:
                actual = run([str(artifact), str(sample)])
                assert actual.returncode == 1 and actual.stdout == '错误：无法读取文件\n'.encode(), actual
            print('PASS: source line count', name)


if __name__ == '__main__':
    main()
