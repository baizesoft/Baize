"""Exercise the official log library through the native compiler and launcher."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PROBE = '''字节数组 输入路名[260]
整数 输入路长 = 参数读取(0, 输入路名, 260)
如果 输入路长 < 1:
    返回 2
整数 消息长度 = 文件读取(输入路名, 日志消息区, 1024)
整数 设置结果 = 日志设级别(1)
如果 设置结果 != 0:
    返回 3
整数 日志结果 = 日志记录(0, 1, 消息长度, 77)
如果 日志结果 != 0:
    返回 4
日志结果 = 日志记录(1, 1, 消息长度, -9223372036854775807 - 1)
如果 日志结果 != 0:
    返回 5
日志结果 = 日志记录(2, 0, 消息长度, 7)
如果 日志结果 != 0:
    返回 6
输出(42)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('compiler', type=Path)
    compiler = parser.parse_args().compiler.resolve(strict=True)
    target = 'native-windows-x64' if os.name == 'nt' else 'native-linux-x64'
    with tempfile.TemporaryDirectory(prefix='baize-log-') as name:
        directory = Path(name)
        source = directory / '日志探针.bz'
        output = directory / 'log.exe'
        control = directory / 'control.bz'
        control.write_bytes('输出(42)\n'.encode())
        direct = directory / 'control.exe'
        check = subprocess.run([str(compiler), str(control), str(direct), target],
                               capture_output=True, timeout=20)
        assert check.returncode == 0 and direct.is_file(), check
        print('PASS: baseline native compiler emits control', flush=True)
        source.write_bytes(PROBE.encode())
        build = subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/baize.py'),
                                'build', '--compiler', str(compiler), '--日志', str(source),
                                '-o', str(output)], capture_output=True, timeout=20)
        assert build.returncode == 0 and output.is_file(), build
        sample = directory / '中文 消息.bin'

        def run(data):
            sample.write_bytes(data)
            return subprocess.run([str(output), str(sample)], capture_output=True, timeout=20)

        payload = '进度"\\\n\x00终点🚀'
        result = run(payload.encode())
        assert (result.returncode, result.stdout) == (0, b'42\n'), result
        records = result.stderr.decode('utf-8').split('\n')
        assert len(records) == 3 and records[-1] == '', records
        assert json.loads(records[0]) == {'level': 'INFO', 'message': payload,
                                         'value': -9223372036854775808}, records
        assert records[1] == '[WARN] 进度"\\\\\\n\\u0000终点🚀 value=7', records
        print('PASS: level filter, JSON, text, UTF-8, escapes, integer minimum, stdout separation')
        for invalid in (b'\xff', b'\xc0\xaf', b'\xe2\x82', b'\xed\xa0\x80', b'\xf4\x90\x80\x80'):
            result = run(invalid)
            assert (result.returncode, result.stdout, result.stderr) == (5, b'', b''), result
        print('PASS: invalid UTF-8 does not emit partial log records')
        result = run(b'')
        assert result.returncode == 0 and json.loads(result.stderr.splitlines()[0])['message'] == '', result
        result = run(b'x' * 1024)
        assert result.returncode == 0 and json.loads(result.stderr.splitlines()[0])['message'] == 'x' * 1024, result
        print('PASS: empty and capacity-sized messages')

        application = directory / 'line-count.exe'
        launch = [sys.executable, '-B', str(ROOT / 'scripts/baize.py'), 'build',
                  '--compiler', str(compiler), '--日志', str(ROOT / 'examples/源码行统计.bz'),
                  '-o', str(application)]
        compiled = subprocess.run(launch, capture_output=True, timeout=25)
        assert compiled.returncode == 0 and application.is_file(), compiled
        original = application.read_bytes()
        duplicate = subprocess.run(launch, capture_output=True, timeout=25)
        assert duplicate.returncode == 2 and application.read_bytes() == original, duplicate
        sample.write_bytes(b'hello\r\nworld')

        def count(*flags):
            return subprocess.run([str(application), str(sample), *flags], capture_output=True, timeout=15)

        result = count()
        assert (result.returncode, result.stdout, result.stderr) == (0, b'2\n', b''), result
        result = count('--log-json')
        assert result.returncode == 0 and result.stdout == b'2\n', result
        assert json.loads(result.stderr) == {'level': 'INFO', 'message': str(sample), 'value': 2}, result
        result = count('--log-text')
        assert result.returncode == 0 and result.stdout == b'2\n' and result.stderr.endswith(b' value=2\n'), result
        result = count('--log-junk')
        assert result.returncode == 2 and result.stderr == b'', result
        print('PASS: real line counter, opt-in log formats, invalid flag, no clobber')


if __name__ == '__main__':
    main()
