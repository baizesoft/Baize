"""Acceptance for the official Baize test command (not the compiler's fixture runner)."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('compiler', type=Path)
    compiler = parser.parse_args().compiler.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='baize-test-cli-') as temp:
        project = Path(temp)
        (project / 'nested').mkdir()
        for name, source in {
            'nested/01-通过.test.bz': '测试断言整数(2 + 1, 3, 1)\n测试断言真(3 > 2, 2)\n',
            '02-断言失败.test.bz': '# 文件源位置保留\n测试断言整数(2, 3, 2)\n',
            '03-编译失败.test.bz': '测试断言真(1 +, 1)\n',
            '04-提前退出.test.bz': '返回 0\n',
            '05-无断言.test.bz': '输出(3)\n',
            '06-超时.test.bz': '当 真:\n    测试断言真(真, 2)\n',
            '07-输出上限.test.bz': '当 真:\n    输出("' + 'x' * 160 + '")\n',
            '普通.bz': 'this is not a test\n',
        }.items():
            (project / name).write_bytes(source.encode())

        cli = [sys.executable, '-B', str(ROOT / 'scripts/baize.py'), 'test',
               '--compiler', str(compiler), '--json', str(project)]

        def report(*args):
            result = subprocess.run([*cli, *args], capture_output=True, timeout=40)
            assert result.stdout, result
            return result, json.loads(result.stdout)

        result, data = report('--filter', '01-通过')
        assert result.returncode == 0, (result, data)
        assert data['counts'] == {'total': 1, 'passed': 1, 'failed': 0}, data
        case = data['cases'][0]
        assert case['path'] == 'nested/01-通过.test.bz' and case['assertions'] == 2, case
        print('PASS: recursive discovery, filename filter and real assertions', flush=True)

        result, data = report('--filter', '02-断言失败')
        assert result.returncode == 1 and data['counts']['failed'] == 1, data
        case = data['cases'][0]
        assert case['status'] == 'assertion_failed', case
        assert case['failures'] == [{'line': 2, 'actual': 2, 'expected': 3}], case
        print('PASS: failure line and values', flush=True)

        for label, status, flags in (
            ('03-', 'compile_error', []), ('04-', 'incomplete', []), ('05-', 'no_assertions', []),
            ('06-', 'timeout', ['--timeout', '1']), ('07-', 'output_limit', ['--timeout', '5']),
        ):
            result, data = report('--filter', label, *flags)
            assert result.returncode == 1 and data['cases'][0]['status'] == status, (result, data)
        result, data = report('--filter', 'nonexistent filter')
        assert result.returncode == 2 and data['counts']['total'] == 0, (result, data)
        print('PASS: compile failure, early exit, zero tests, timeout and bounded output')

        real = subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/baize.py'), 'test',
                               '--compiler', str(compiler), '--json',
                               '--合入', str(ROOT / 'examples/源码行统计核心.bz'),
                               str(ROOT / 'examples/源码行统计测试')], capture_output=True, timeout=30)
        assert real.returncode == 0, real
        data = json.loads(real.stdout)
        assert data['counts'] == {'total': 1, 'passed': 1, 'failed': 0}, data
        assert data['cases'][0]['assertions'] == 3, data
        core = ROOT / 'examples/源码行统计核心.bz'
        mutated = project / '变异核心.bz'
        original = core.read_bytes()
        assert original.count('行数 = 行数 + 1'.encode()) == 2
        mutated.write_bytes(original.replace('行数 = 行数 + 1'.encode(), '行数 = 行数 + 2'.encode(), 1))
        real_red = subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/baize.py'), 'test',
                                   '--compiler', str(compiler), '--json', '--合入', str(mutated),
                                   str(ROOT / 'examples/源码行统计测试')], capture_output=True, timeout=30)
        assert real_red.returncode == 1, real_red
        wrong = json.loads(real_red.stdout)['cases'][0]
        assert wrong['status'] == 'assertion_failed' and [x['line'] for x in wrong['failures']] == [6, 8], wrong
        assert core.read_bytes() == original
        print('PASS: official runner tests the production line-counter core and detects an injected defect')


if __name__ == '__main__':
    main()
