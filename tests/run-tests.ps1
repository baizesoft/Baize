# 白泽语言语义回归 runner（数据驱动）
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1
# 每个用例：从可信种子经 build-seed.ps1 编译 .bz -> exe，运行并按字节比对期望输出。
# 负向用例（expect_fail）：断言编译非零退出且不产生 exe。
# 所有临时产物写入 build/_bztest_<stamp>/（已被 gitignore），不逐文件删除。
$ErrorActionPreference = 'Stop'
$testDir = $PSScriptRoot
$root = $testDir
while ($root -and -not (Test-Path -LiteralPath (Join-Path $root 'scripts\build-seed.ps1'))) {
    $root = Split-Path -Parent $root
}
if (-not $root) { throw '找不到仓库根（scripts\build-seed.ps1）' }
$previousEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Push-Location $root
try {
    $manifestPath = Join-Path $testDir 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "manifest 不存在: $manifestPath" }
    $cases = Get-Content -Raw -LiteralPath $manifestPath -Encoding UTF8 | ConvertFrom-Json

    $buildScript = Join-Path $root 'scripts\build-seed.ps1'
    $stamp = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $workDir = Join-Path $root "build\_bztest_$stamp"
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
    $pass = 0; $fail = 0; $results = [System.Collections.Generic.List[string]]::new()

    foreach ($case in $cases) {
        $srcAbs = Join-Path $testDir $case.src
        $name = $case.name
        $outName = "case-$($case.name -replace '[^0-9A-Za-z]', '_')"
        $exePath = Join-Path $workDir "$outName.exe"

        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell'
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Source "{1}" -Name "{2}"' -f $buildScript, $srcAbs, "_bztest_$stamp/$outName"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $proc = New-Object Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        $co = $proc.StandardOutput.ReadToEnd()
        $ce = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $compileRc = $proc.ExitCode

        # build-seed.ps1 把产物放到 <root>/build/<Name>.exe，Name 含子目录 stamp
        $exeExists = Test-Path -LiteralPath $exePath

        if ($case.expect_fail) {
            if (-not $exeExists -and $compileRc -ne 0) {
                $pass++; $results.Add("PASS  $name  [按预期拒绝 rc=$compileRc]")
            } elseif (-not $exeExists) {
                $pass++; $results.Add("PASS  $name  [按预期拒绝: 未生成 exe]")
            } else {
                $fail++; $results.Add("FAIL  $name  [非法源码却生成了 exe]")
            }
            continue
        }

        if (-not $exeExists) {
            $detail = ($ce -split "`n" | Select-Object -Last 1).Trim()
            $fail++; $results.Add("FAIL  $name  [编译未生成 exe rc=$compileRc] $detail")
            continue
        }

        # 用 .NET 进程运行产物并传参，输出字节直接读流（避免 cmd 引号与编码干扰）
        $runPsi = New-Object Diagnostics.ProcessStartInfo
        $runPsi.FileName = $exePath
        $runPsi.WorkingDirectory = $root
        $runPsi.UseShellExecute = $false
        $runPsi.RedirectStandardOutput = $true
        $runPsi.CreateNoWindow = $true
        if ($case.args) { $runPsi.Arguments = (($case.args | ForEach-Object { '"' + [string]$_ + '"' }) -join ' ') }
        $runProc = New-Object Diagnostics.Process
        $runProc.StartInfo = $runPsi
        [void]$runProc.Start()
        $stdoutBytes = $runProc.StandardOutput.BaseStream
        $mem = New-Object IO.MemoryStream
        $stdoutBytes.CopyTo($mem)
        $runProc.WaitForExit()
        $runRc = $runProc.ExitCode
        $actualBytes = $mem.ToArray()

        # 崩溃类用例：编译成功但运行须非零退出且无 stdout（如零除、INT_MIN/-1）
        if ($case.expect_crash) {
            if ($runRc -ne 0 -and $actualBytes.Length -eq 0) {
                $pass++; $results.Add("PASS  $name  [按预期崩溃 rc=$runRc]")
            } else {
                $fail++; $results.Add("FAIL  $name  [应崩溃却 rc=$runRc 或产生输出]")
            }
            continue
        }

        $expectedPath = Join-Path $testDir $case.expected
        $expectedBytes = [IO.File]::ReadAllBytes($expectedPath)
        $byteMatch = ($expectedBytes.Length -eq $actualBytes.Length)
        if ($byteMatch) {
            for ($i = 0; $i -lt $expectedBytes.Length; $i++) {
                if ($expectedBytes[$i] -ne $actualBytes[$i]) { $byteMatch = $false; break }
            }
        }
        if ($runRc -eq 0 -and $byteMatch) {
            $pass++; $results.Add("PASS  $name")
        } else {
            $expText = [Text.Encoding]::UTF8.GetString($expectedBytes).Replace("`n", '\n')
            $actText = [Text.Encoding]::UTF8.GetString($actualBytes).Replace("`n", '\n')
            $fail++; $results.Add("FAIL  $name  [rc=$runRc] expected=[$expText] actual=[$actText]")
        }
    }

    $results | ForEach-Object { Write-Output $_ }
    Write-Output "----------------------------------------"
    Write-Output "TOTAL=$($cases.Count) PASS=$pass FAIL=$fail"
    Write-Output "WORKDIR=$workDir"
    if ($fail -gt 0) { exit 1 } else { exit 0 }
} finally {
    Pop-Location
    [Console]::OutputEncoding = $previousEncoding
}
