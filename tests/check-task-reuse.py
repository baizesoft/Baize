"""Validate explicit task release, stale handle rejection and real file waves."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXPECT = (1, 77, -2, 0, -4, 0, 9, -1, -1, -1, -1, 0, 1048568, 0, -1, 124, 124, 0, -2, 3, 0)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('compiler', type=Path)
    p.add_argument('--before', action='store_true')
    p.add_argument('--baseline', type=Path, help='also verify the same business workload without release')
    args = p.parse_args()
    cc = args.compiler.resolve(strict=True)
    target = 'native-windows-x64' if os.name == 'nt' else 'native-linux-x64'
    ex = ROOT/'examples'
    with tempfile.TemporaryDirectory(prefix='bz-task-reuse-') as d:
        folder = Path(d)
        fixture = ROOT/'tests/cases/N09_任务槽复用.bz'
        app = folder/'reuse.exe'
        comp = subprocess.run([str(cc),str(fixture),str(app),target],capture_output=True,timeout=20)
        if args.before:
            reason = '编译错误：静态模式下名称不存在或内置尚未标注\n'.encode()
            assert (comp.returncode,comp.stdout,comp.stderr) == (1,reason,b'') and not app.exists(), comp
            print('CONFIRMED RED: old compiler has no task release operation')
            return
        assert comp.returncode == 0 and app.is_file(), comp

        def run(exe, files):
            if os.name != 'nt': exe.chmod(0o700)
            r = subprocess.run([str(exe),*files],cwd=folder,capture_output=True,timeout=20)
            return r.returncode,r.stdout,r.stderr

        observed = run(app,[])
        assert observed == (0,b''.join(f'{v}\n'.encode() for v in EXPECT),b''), observed
        print('PASS: live/foreign release refused, stale IDs rejected, roots and mailbox reset, reused stack guarded')
        tight = folder/'churn.bz'
        tight.write_text('''函数 短任务(值: 整数) -> 整数:
    返回 值
函数 主() -> 整数:
    变量 次数 = 0
    变量 句柄 = 0
    变量 合计 = 0
    当 次数 < 1000:
        句柄 = 启动任务(短任务, 次数)
        如果 句柄 < 1:
            返回 2
        合计 = 合计 + 等待任务(句柄)
        如果 释放任务(句柄) != 0:
            返回 3
        次数 = 次数 + 1
    输出(合计)
    输出(释放任务(句柄))
    返回 0
返回 主()
''',encoding='utf-8',newline='\n')
        exe = folder/'churn.exe'
        r = subprocess.run([str(cc),str(tight),str(exe),target],capture_output=True,timeout=20)
        assert r.returncode == 0 and exe.is_file(), r
        assert run(exe,[]) == (0,f'{sum(range(1000))}\n-1\n'.encode(),b'')
        for invalid in ('释放任务(真)', '释放任务(1, 2)'):
            source, rejected = folder/'invalid.bz', folder/'invalid.exe'
            source.write_text('输出('+invalid+')\n',encoding='utf-8',newline='\n')
            r = subprocess.run([str(cc),str(source),str(rejected),target],capture_output=True,timeout=20)
            assert (r.returncode,r.stdout,r.stderr)==(1,'编译错误：实参类型不匹配或数量不符\n'.encode(),b'') and not rejected.exists(), r
        print('PASS: 1000 lifecycles without GC; invalid release arguments rejected')
        for name, source in (('waves','源码行统计任务波次.bz'),('serial','源码行统计向量.bz')):
            out = folder/(name+'.exe')
            c = subprocess.run([sys.executable,'-B',str(ROOT/'scripts/baize.py'),'build','--compiler',str(cc),'--合入',str(ex/'源码行统计向量核心.bz'),str(ex/source),'-o',str(out)],capture_output=True,timeout=30)
            assert c.returncode == 0 and out.is_file(), c
        data = (ROOT/'compiler/编译器.bz').read_bytes().replace(b'\r\n', b'\n')
        corpus = {'编译器.bz': data, '最大.bz': b'q'*262144, '空.bz':b'', '带 空格.bz': b'a\r\nb\nlast'}
        for n,b in corpus.items(): (folder/n).write_bytes(b)
        def expected(names):
            return b''.join(f'{corpus[n].count(bytes([10])) + bool(corpus[n] and not corpus[n].endswith(bytes([10])))}\n'.encode() for n in names)
        cases = list(corpus)*24 + ['带 空格.bz']
        waves, serial = folder/'waves.exe', folder/'serial.exe'
        if args.baseline:
            prefix_code = '函数 保留任务(号: 整数) -> 整数:\n    返回 0\n'
            text = (ex/'源码行统计任务波次.bz').read_text(encoding='utf-8').replace('释放任务(', '保留任务(')
            source = folder/'before.bz'
            source.write_text(prefix_code+text,encoding='utf-8',newline='\n')
            old = folder/'before.exe'
            c = subprocess.run([sys.executable,'-B',str(ROOT/'scripts/baize.py'),'build','--compiler',str(args.baseline.resolve(strict=True)),'--合入',str(ex/'源码行统计向量核心.bz'),str(source),'-o',str(old)],capture_output=True,timeout=30)
            assert c.returncode == 0 and old.is_file(), c
            observed = run(old,cases)
            assert observed == (1,expected(cases[:6])+'错误：任务未能完成文件统计\n'.encode(),b''), observed
            print('PASS: stock compiler without release runs out of task slots after six ordered results')
        assert run(waves,cases) == run(serial,cases) == (0,expected(cases),b'')
        prefix = cases[:13]
        bad = prefix+['无文件.bz']+cases[:3]
        assert run(waves,bad) == run(serial,bad) == (1,expected(prefix)+'错误：无法读取文件\n'.encode(),b'')
        print('PASS: 97 real file tasks exceed the unreleased-slot limit, with ordered output and error cleanup')


if __name__ == '__main__': main()
