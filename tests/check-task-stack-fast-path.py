"""Exercise stack protection and confirm generated hot paths don't call a helper."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile

SITE = re.compile(rb'\x48\x3b\x25(.{4})\x0f\x86(.{4})', re.S)


def image_addresses(img):
    def u(off, n):
        return int.from_bytes(img[off:off+n], 'little')
    if img[:4] == b'\x7fELF':
        ph = u(32, 8)
        return u(ph+16, 8) - u(ph+8, 8), u(ph+56+16, 8)
    assert img[:2] == b'MZ'
    pe = u(60, 4)
    opt = pe + 24
    section = opt + u(pe+20, 2)
    base = u(opt+24, 8)
    return base + u(section+12, 4) - u(section+20, 4), base + u(section+40+12, 4)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('compiler', type=Path)
    p.add_argument('--before', action='store_true')
    a = p.parse_args()
    compiler = a.compiler.resolve(strict=True)
    target = 'native-windows-x64' if os.name == 'nt' else 'native-linux-x64'
    cases = Path(__file__).resolve().parent / 'cases'
    with tempfile.TemporaryDirectory(prefix='bz-stack-fast-') as directory:
        root = Path(directory)
        for label, source, stdout in (
            ('recursive', cases / 'N02_任务限额与栈保护.bz', b'-1\n-1\n-1\n-2\n447\n-1\n444\n445\n446\n447\n448\n-1\n448\n'),
            ('retired-roots', cases / 'N04_终止任务释放根.bz', b'18\n-2\n1048568\n'),
            ('switch', cases / 'N01_任务挂起恢复.bz', b'99\n11\n21\n12\n22\n13\n23\n'),
        ):
            exe = root / f'{label}.exe'
            r = subprocess.run([str(compiler), str(source), str(exe), target], capture_output=True, timeout=20)
            assert r.returncode == 0 and exe.is_file(), r
            if os.name != 'nt':
                exe.chmod(0o700)
            run = subprocess.run([str(exe)], capture_output=True, timeout=10)
            assert (run.returncode, run.stdout, run.stderr) == (0, stdout, b''), run
            img = exe.read_bytes()
            sites = list(SITE.finditer(img))
            if a.before:
                assert not sites, label
                print(f'CONFIRMED RED: {label} retains behavior but has no inline stack guards')
                continue
            assert len(sites) >= 8, (label, len(sites))
            delta, data = image_addresses(img)
            limits = {delta + m.start() + 7 + int.from_bytes(m[1], 'little', signed=True) for m in sites}
            failures = {m.end() + int.from_bytes(m[2], 'little', signed=True) for m in sites}
            assert len(limits) == len(failures) == 1, (limits, failures)
            address, = limits
            slow, = failures
            assert address >= data + 16 and (address-data) % 16 == 0, (data, address)
            assert 0 <= slow < sites[0].start() and img[slow] == 0xe8, slow
            area_helper = slow + 5 + int.from_bytes(img[slow+1:slow+5], 'little', signed=True)
            assert 0 <= area_helper < slow and img[area_helper:area_helper+2] == b'\x49\xbb', area_helper
            assert address == int.from_bytes(img[area_helper+2:area_helper+10], 'little') + 16
            print(f'PASS: {label}, {len(sites)} inline guards target one limit and one slow path')


if __name__ == '__main__':
    main()
