"""Windows runner regression: a missing seed must not pass syntax tests."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SYSTEM = Path(os.environ['SystemRoot']) / 'System32'
PS = SYSTEM / 'WindowsPowerShell' / 'v1.0'


def main():
    with tempfile.TemporaryDirectory(prefix='baize-no-seed-') as temp:
        temp = Path(temp)
        # Copy runner and fixtures, deliberately without the trusted seed.
        for directory in ('tests', 'scripts', 'compiler'):
            shutil.copytree(ROOT / directory, temp / directory)
        env = {k: v for k, v in os.environ.items()
               if k.lower() not in {'path', 'psmodulepath'}}
        env.update(Path=f'{SYSTEM};{PS}', PSModulePath=str(PS / 'Modules'))
        result = subprocess.run(
            [str(PS / 'powershell.exe'), '-NoProfile', '-ExecutionPolicy',
             'Bypass', '-File', 'tests/run-tests.ps1'], cwd=temp, env=env,
            capture_output=True, timeout=90,
        )
        print(result.stdout.decode('utf-8', errors='replace'), end='')
        print(result.stderr.decode('utf-8', errors='replace'), end='')
        if result.returncode == 0 or b'PASS  E0' in result.stdout:
            raise SystemExit('FAIL: a broken bootstrap passed the syntax tests')
        if b'BOOTSTRAP_FAILED' not in result.stderr:
            raise SystemExit('FAIL: bootstrap failure not identified')
        print('PASS: missing seed aborts before evaluating syntax tests')


if __name__ == '__main__':
    main()
