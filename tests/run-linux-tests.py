"""Run the shared language fixtures with a native Linux x86-64 Baize compiler."""
import argparse
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

if sys.platform == 'linux':
    import resource

    def disable_core_dumps():
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
else:
    def disable_core_dumps():
        raise SystemExit('This regression runner requires Linux.')


TESTS = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('compiler', type=Path)
    compiler = parser.parse_args().compiler.resolve(strict=True)
    cases = json.loads((TESTS / 'manifest.json').read_text(encoding='utf-8-sig'))
    disable_core_dumps()
    failures = 0
    with tempfile.TemporaryDirectory(prefix='baize-linux-regression-') as temp:
        root = Path(temp)
        (root / 'build').mkdir()
        for index, case in enumerate(cases):
            output = root / f'case-{index}'
            compile_result = subprocess.run(
                [str(compiler), str(TESTS / case['src']), str(output), 'native-linux-x64'],
                cwd=root, capture_output=True, timeout=15,
            )
            if case.get('expect_fail'):
                expected = case['expected_diagnostic'].encode('utf-8')
                passed = (compile_result.returncode == 1 and not output.exists()
                          and expected in compile_result.stdout.splitlines())
                result = compile_result
            elif compile_result.returncode or not output.is_file():
                passed, result = False, compile_result
            else:
                output.chmod(0o700)
                result = subprocess.run([str(output), *case.get('args', [])], cwd=root,
                                        capture_output=True, timeout=15)
                if case.get('expect_crash'):
                    passed = result.returncode == -signal.SIGFPE and not result.stdout
                else:
                    expected = (TESTS / case['expected']).read_bytes()
                    passed = result.returncode == 0 and result.stdout == expected
            print('PASS' if passed else 'FAIL', case['name'], f'rc={result.returncode}')
            if not passed:
                failures += 1
                print(result.stdout, result.stderr)
    print(f'TOTAL={len(cases)} PASS={len(cases) - failures} FAIL={failures}')
    return int(bool(failures))


if __name__ == '__main__':
    raise SystemExit(main())
