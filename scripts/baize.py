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


def build(args):
    host = HOSTS.get(sys.platform)
    if not host or platform.machine().lower() not in {'amd64', 'x86_64'}:
        raise ValueError('目前工具链只支持 Windows / Linux x86-64')
    target = args.target or host
    compiler = args.compiler.resolve(strict=True)
    source = args.source.resolve(strict=True)
    if source.suffix != '.bz':
        raise ValueError('请输入 .bz 源码')
    parent = args.output.parent.resolve(strict=True)
    output = parent / args.output.name
    if output.exists() or output.is_symlink():
        raise FileExistsError(f'目标已存在，不覆盖：{output}')
    body = read_source(source)
    if args.log:
        library = ROOT / '标准库' / '日志.bz'
        if not library.is_file():
            raise ValueError('缺少官方日志标准库')
        body = read_source(library) + b'\n' + body
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
    b.add_argument('source', type=Path)
    b.add_argument('-o', '--output', type=Path, required=True)
    try:
        return build(parser.parse_args(argv))
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f'白泽工具：{error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
