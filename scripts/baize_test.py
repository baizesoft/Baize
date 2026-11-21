"""Discovery, execution and reporting for `baize test`."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading


MAX_OUTPUT = 1024 * 1024  # Per stream, per process.
ASSERT = b'BAIZE_ASSERT_V1'
END = b'BAIZE_TEST_END_V1'
TAIL = '\n返回 测试结算()\n'.encode()


def run_bounded(argv, cwd, timeout):
    with subprocess.Popen(argv, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE) as process:
        limited = threading.Event()
        buffers = [bytearray(), bytearray()]

        def drain(pipe, target):
            with pipe:
                while chunk := pipe.read1(65536):
                    available = MAX_OUTPUT - len(target)
                    target.extend(chunk[:available])
                    if len(chunk) > available:
                        limited.set()
                        process.kill()
                        break

        readers = [threading.Thread(target=drain, args=(pipe, target), daemon=True)
                   for pipe, target in zip((process.stdout, process.stderr), buffers) if pipe is not None]
        for reader in readers:
            reader.start()
        timed_out = False
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            process.kill()
            process.wait()
        for reader in readers:
            reader.join()
        status = 'output_limit' if limited.is_set() else 'timeout' if timed_out else None
        return process.returncode, bytes(buffers[0]), bytes(buffers[1]), status


def decode(data):
    return data.decode('utf-8', errors='replace')


def parse_protocol(output, line_limit):
    lines = output.split(b'\n')
    if len(lines) < 4 or lines[-1] != b'' or lines[-4] != END:
        return None
    try:
        assertions, failed = map(int, lines[-3:-1])
        if not 0 <= failed <= assertions:
            return None
        body = lines[:-4]
        failures, normal = [], []
        index = 0
        while index < len(body):
            line = body[index]
            if line == END:
                return None
            if line != ASSERT:
                normal.append(line)
                index += 1
                continue
            if index + 4 > len(body):
                return None
            at, actual, expected = map(int, body[index + 1:index + 4])
            if not 1 <= at <= line_limit or actual == expected:
                return None
            failures.append({'line': at, 'actual': actual, 'expected': expected})
            index += 4
        if len(failures) != failed:
            return None
        return assertions, failures, decode(b'\n'.join([*normal, b'']))
    except ValueError:
        return None


def run_case(source, name, compiler, target, library, common, args, read_source, source_limit):
    record = {'path': name, 'status': 'compile_error', 'assertions': 0,
              'failures': [], 'stdout': '', 'stderr': ''}
    try:
        original = read_source(source)
        combined = b'\n'.join([library, *common, original, TAIL])
        if len(combined) > source_limit:
            raise ValueError(f'合成测试源码超过 {source_limit} 字节')
        with tempfile.TemporaryDirectory(prefix='baize-case-') as directory:
            root = Path(directory)
            merged = root / 'case.bz'
            output = root / 'case.exe'
            merged.write_bytes(combined)
            code, stdout, stderr, state = run_bounded(
                [str(compiler), str(merged), str(output), target], root, args.timeout)
            if state or code != 0 or not output.is_file() or not output.stat().st_size:
                record.update(status=f'compile_{state}' if state else 'compile_error',
                              stdout=decode(stdout), stderr=decode(stderr))
                return record
            if os.name != 'nt':
                output.chmod(0o700)
            record['status'] = 'execution_error'
            code, stdout, stderr, state = run_bounded([str(output)], root, args.timeout)
            record.update(stdout=decode(stdout), stderr=decode(stderr), exit_code=code)
            if state is not None:
                record['status'] = state
                return record
            protocol = parse_protocol(stdout, original.count(b'\n') + int(not original.endswith(b'\n')))
            if protocol is None:
                record['status'] = 'incomplete' if code == 0 else 'execution_error'
                return record
            assertions, failures, visible = protocol
            record.update(assertions=assertions, failures=failures, stdout=visible)
            if failures and code == 1:
                record['status'] = 'assertion_failed'
            elif not failures and code == 0:
                record['status'] = 'passed' if assertions else 'no_assertions'
            else:
                record['status'] = 'incomplete'
            return record
    except (OSError, ValueError) as error:
        record.update(stderr=str(error))
        return record


def run_tests(args, host, repository, read_source, source_limit):
    directory = args.directory.resolve(strict=True)
    if not directory.is_dir():
        raise ValueError('测试根路径必须是目录')
    compiler = args.compiler.resolve(strict=True)
    library = read_source(repository / '标准库' / '测试.bz')
    common = [read_source(path.resolve(strict=True)) for path in args.include]
    candidates = []
    for root, dirs, names in os.walk(directory, followlinks=False):
        dirs[:] = [name for name in dirs if not (Path(root) / name).is_symlink()]
        for file in names:
            source = Path(root) / file
            if not file.endswith('.test.bz') or source.is_symlink() or not source.is_file():
                continue
            name = source.relative_to(directory).as_posix()
            if not args.filter or args.filter in name:
                candidates.append((name, source))
    results = [run_case(source, name, compiler, host, library, common, args, read_source, source_limit)
               for name, source in sorted(candidates)]
    passed = sum(case['status'] == 'passed' for case in results)
    counts = {'total': len(results), 'passed': passed, 'failed': len(results) - passed}
    if args.json:
        print(json.dumps({'schema_version': 1, 'counts': counts, 'cases': results}))
    else:
        for case in results:
            print(f"{case['status']}: {case['path']} ({case['assertions']} 项断言)")
            for fail in case['failures']:
                print(f"  第 {fail['line']} 行：实际 {fail['actual']}，期望 {fail['expected']}")
            if case['status'] != 'passed':
                for stream in ('stdout', 'stderr'):
                    if case[stream]:
                        print(case[stream].rstrip())
        print(f"用例 {counts['total']}；通过 {counts['passed']}；失败 {counts['failed']}")
    if not results:
        return 2
    return int(bool(counts['failed']))
