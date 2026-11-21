#!/usr/bin/env python3
"""Official host launcher for the native Baize compiler."""
import argparse
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
HOSTS = {'win32': 'native-windows-x64', 'linux': 'native-linux-x64'}
MAX_SOURCE = 262144


def read_source(path):
    with path.open('rb') as stream:
        raw = stream.read(MAX_SOURCE + 1)
    if len(raw) > MAX_SOURCE:
        raise ValueError(f'源码超过 {MAX_SOURCE} 字节：{path.name}')
    raw.decode('utf-8-sig')  # Reject malformed UTF-8 before the compiler reads it.
    return raw.removeprefix(b'\xef\xbb\xbf')


def native_host():
    host = HOSTS.get(sys.platform)
    if not host or platform.machine().lower() not in {'amd64', 'x86_64'}:
        raise ValueError('目前工具链只支持 Windows / Linux x86-64')
    return host


def build(args):
    host = native_host()
    target = args.target or host
    compiler = args.compiler.resolve(strict=True)
    source = args.source.resolve(strict=True)
    if source.suffix != '.bz':
        raise ValueError('请输入 .bz 源码')
    parent = args.output.parent.resolve(strict=True)
    output = parent / args.output.name
    if output.exists() or output.is_symlink():
        raise FileExistsError(f'目标已存在，不覆盖：{output}')
    pieces = [read_source(path.resolve(strict=True)) for path in args.include]
    if args.log:
        library = ROOT / '标准库' / '日志.bz'
        if not library.is_file():
            raise ValueError('缺少官方日志标准库')
        pieces.insert(0, read_source(library))
    pieces.append(read_source(source))
    body = b'\n'.join(pieces)
    if len(body) > MAX_SOURCE:
        raise ValueError(f'合成源码超过 {MAX_SOURCE} 字节')
    with tempfile.TemporaryDirectory(prefix='.baize-', dir=parent) as directory:
        temporary = Path(directory)
        source = temporary / 'source.bz'
        source.write_bytes(body)
        artifact = temporary / 'native.exe'
        result = subprocess.run([str(compiler), str(source), str(artifact), target], timeout=60)
        if result.returncode != 0:
            return 1
        if not artifact.is_file() or not artifact.stat().st_size:
            raise ValueError('编译器没有生成可用产物')
        if target == 'native-linux-x64' and os.name != 'nt':
            artifact.chmod(0o700)
        os.link(artifact, output)  # Same filesystem; never overwrite an existing output.
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    b = commands.add_parser('build', help='编译 .bz 源码')
    b.add_argument('--compiler', type=Path, required=True, help='当前宿主的白泽编译器')
    b.add_argument('--target', choices=tuple(HOSTS.values()), help='默认当前宿主')
    b.add_argument('--日志', dest='log', action='store_true', help='加入官方日志标准库')
    b.add_argument('--合入', dest='include', type=Path, action='append', default=[],
                   help='在主源码前合入指定的白泽源码，可重复')
    b.add_argument('source', type=Path)
    b.add_argument('-o', '--output', type=Path, required=True)
    t = commands.add_parser('test', help='发现并执行 .test.bz 文件')
    t.add_argument('--compiler', type=Path, required=True, help='当前宿主的白泽编译器')
    t.add_argument('--合入', dest='include', type=Path, action='append', default=[],
                   help='为每份测试合入指定的白泽源码，可重复')
    t.add_argument('--filter', help='按相对路径字面筛选')
    t.add_argument('--json', action='store_true', help='只输出机器可读报告')
    t.add_argument('--timeout', type=int, default=10, metavar='SECONDS',
                   help='每次编译或运行的期限，默认 10 秒')
    t.add_argument('directory', type=Path, nargs='?', default=Path('.'))
    try:
        args = parser.parse_args(argv)
        if args.command == 'build':
            return build(args)
        from baize_test import run_tests
        if not 1 <= args.timeout <= 60:
            raise ValueError('测试期限必须在 1 到 60 秒之间')
        return run_tests(args, native_host(), ROOT, read_source, MAX_SOURCE)
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f'白泽工具：{error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
