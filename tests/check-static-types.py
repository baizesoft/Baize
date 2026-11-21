"""Check the first typed-signature slice with a supplied Baize compiler."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile


CASES = Path(__file__).resolve().parent / 'cases'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('compiler', type=Path)
    compiler = parser.parse_args().compiler.resolve(strict=True)
    target = 'native-windows-x64' if os.name == 'nt' else 'native-linux-x64'
    cases = (
        ('T01_整数签名.bz', None, None),
        ('T02_布尔实参拒绝.bz', '实参类型不匹配', None),
        ('T03_布尔返回拒绝.bz', '返回类型不匹配', None),
        ('inferred', None, '函数 算(数: 整数) -> 整数:\n    变量 中间 = 数 + 1\n    返回 中间\n输出(算(2))\n'),
        ('inferred-reassign', '赋值类型不匹配', '函数 算(数: 整数) -> 整数:\n    变量 中间 = 数\n    中间 = 真\n    返回 中间\n输出(算(2))\n'),
        ('boolean-policy', '条件必须是布尔值', '函数 算(数: 整数) -> 整数:\n    如果 数:\n        返回 3\n    返回 2\n输出(算(2))\n'),
        ('signature-complete', '完整的函数签名', '函数 算(数) -> 整数:\n    返回 数\n输出(算(2))\n'),
        ('return-path', '缺少返回值', '函数 算(数: 整数) -> 整数:\n    如果 数 > 0:\n        返回 3\n输出(算(2))\n'),
        ('both-branches-return', None, '函数 算(数: 整数) -> 整数:\n    如果 数 > 0:\n        返回 3\n    否则:\n        返回 2\n输出(算(2))\n'),
        ('byte-narrowing', '赋值类型不匹配', '字节数组 缓存[2]\n函数 算(数: 整数) -> 整数:\n    缓存[0] = 256\n    返回 缓存[0]\n输出(算(2))\n'),
        ('byte-literal', None, '字节数组 缓存[2]\n函数 算(数: 整数) -> 整数:\n    缓存[0] = 3\n    返回 缓存[0]\n输出(算(2))\n'),
        ('bool-forward', None, '函数 算(数: 整数) -> 整数:\n    如果 比较(数):\n        返回 3\n    返回 0\n函数 比较(值: 整数) -> 布尔:\n    返回 值 == 2\n输出(算(2))\n'),
    )
    bad = []
    with tempfile.TemporaryDirectory(prefix='baize-typed-') as temp:
        for i, (name, diagnostic, text) in enumerate(cases):
            artifact = Path(temp) / f'type-{i}.exe'
            source = CASES / name
            if text is not None:
                source = Path(temp) / f'{name}.bz'
                source.write_bytes(text.encode('utf-8'))
            result = subprocess.run([str(compiler), str(source), str(artifact), target],
                                    capture_output=True, timeout=15)
            if diagnostic:
                passed = (result.returncode == 1 and not artifact.exists()
                          and diagnostic.encode('utf-8') in result.stdout)
            else:
                passed = result.returncode == 0 and artifact.is_file()
                if passed:
                    if os.name != 'nt':
                        artifact.chmod(0o700)
                    output = subprocess.run([str(artifact)], capture_output=True, timeout=15)
                    passed = output.returncode == 0 and output.stdout == b'3\n'
            print('PASS' if passed else 'FAIL', name, result.returncode,
                  result.stdout.decode('utf-8', errors='replace').strip())
            if not passed:
                bad.append(name)
    return int(bool(bad))


if __name__ == '__main__':
    raise SystemExit(main())
