$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root 'build'
$boot = Join-Path $build 'bootstrap-run'
$seedExe = $null
$disabledSeedExe = $null
$seedMoved = $false
$vcvars = 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat'

function Invoke-Cl([string]$source, [string]$exe) {
    $command = 'call "' + $vcvars + '" >nul && cl /nologo /utf-8 /W4 /WX "' + $source + '" /Fe:"' + $exe + '"'
    & cmd.exe /d /c $command
    if ($LASTEXITCODE -ne 0) { throw "MSVC 编译失败：$source ($LASTEXITCODE)" }
}

function Invoke-Emit([string]$compiler, [string]$source, [string]$output) {
    Remove-Item -LiteralPath $output -ErrorAction SilentlyContinue
    $result = & $compiler $source $output emit | Out-String
    if ($LASTEXITCODE -ne 0 -or $result.Trim() -ne '1' -or !(Test-Path -LiteralPath $output)) {
        throw "编译器拒绝或未生成 C：$compiler $source => $result"
    }
}

Push-Location $root
$previousEncoding = [Console]::OutputEncoding
try {
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $metadata = & cargo metadata --no-deps --format-version 1 | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or !$metadata.target_directory) { throw '无法定位 Rust 种子构建目录' }
    $seedExe = Join-Path $metadata.target_directory 'debug\bzseed.exe'
    $disabledSeedExe = "$seedExe.disabled"
    if (Test-Path -LiteralPath $disabledSeedExe) { throw '发现上次遗留的禁用种子文件' }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\build-seed.ps1') -Source 'compiler\编译器.bz' -Name bootstrap_stage1
    if ($LASTEXITCODE -ne 0) { throw 'Rust 种子未能构建 stage1' }

    Remove-Item -LiteralPath $boot -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $boot | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'compiler\编译器.bz') -Destination (Join-Path $boot 'compiler.bz')
    Copy-Item -LiteralPath (Join-Path $build 'bootstrap_stage1.exe') -Destination (Join-Path $boot 'stage1.exe')
    Move-Item -LiteralPath $seedExe -Destination $disabledSeedExe
    $seedMoved = $true
    if (Test-Path -LiteralPath $seedExe) { throw 'Rust 种子可执行文件仍可用' }

    Push-Location $boot
    try {
        Invoke-Emit '.\stage1.exe' 'compiler.bz' 'stage2.c'
        Invoke-Cl 'stage2.c' 'stage2.exe'

        Invoke-Emit '.\stage2.exe' 'compiler.bz' 'stage3.c'
        $stage1Hash = (Get-FileHash 'stage2.c' -Algorithm SHA256).Hash
        $stage2Hash = (Get-FileHash 'stage3.c' -Algorithm SHA256).Hash
        if ($stage1Hash -ne $stage2Hash) { throw 'stage1 与 stage2 输出 C 不一致' }

        Invoke-Cl 'stage3.c' 'stage3.exe'
        Invoke-Emit '.\stage3.exe' 'compiler.bz' 'stage4.c'
        $stage3Hash = (Get-FileHash 'stage4.c' -Algorithm SHA256).Hash
        if ($stage2Hash -ne $stage3Hash) { throw 'stage2 与 stage3 输出 C 不一致' }
        $originalCompilerC = 'compiler-original.c'
        $editedCompilerC = 'compiler-edited.c'
        Invoke-Emit '.\stage1.exe' 'compiler.bz' $originalCompilerC
        $compilerSource = [IO.File]::ReadAllText((Join-Path $boot 'compiler.bz'), [Text.UTF8Encoding]::new($false))
        $functionMarker = '函数 空白('
        $functionStart = $compilerSource.IndexOf($functionMarker)
        if ($functionStart -lt 0) { throw '未找到编译器函数插入点' }
        $probeFunction = '函数 自举传播探针(值) {' + "`n" + '返回 值' + "`n" + '}' + "`n"
        $editedCompilerSource = $compilerSource.Insert($functionStart, $probeFunction)
        [IO.File]::WriteAllText((Join-Path $boot 'compiler-edited.bz'), $editedCompilerSource, [Text.UTF8Encoding]::new($false))
        Invoke-Emit '.\stage1.exe' 'compiler-edited.bz' $editedCompilerC
        $originalCompilerHash = (Get-FileHash $originalCompilerC -Algorithm SHA256).Hash
        $editedCompilerHash = (Get-FileHash $editedCompilerC -Algorithm SHA256).Hash
        if ($originalCompilerHash -eq $editedCompilerHash) { throw '编译器源修改未传播到 C 输出' }
        Invoke-Cl $editedCompilerC 'compiler-edited.exe'
        Copy-Item -LiteralPath (Join-Path $root 'examples\你好.bz') -Destination 'hello.bz' -Force
        $helloSource = [IO.File]::ReadAllText((Join-Path $root 'examples\你好.bz'), [Text.UTF8Encoding]::new($false))
        $offsetSource = '#' + ('偏移边界' * 80) + "
" + $helloSource
        [IO.File]::WriteAllText((Join-Path $boot 'offset.bz'), $offsetSource, [Text.UTF8Encoding]::new($true))
        $helloBytes = [Text.UTF8Encoding]::new($false).GetBytes($helloSource)
        $boundarySource = [byte[]]::new(262144)
        $boundaryPrefixLength = $boundarySource.Length - $helloBytes.Length - 1
        $boundarySource[0] = 35
        for ($i = 1; $i -lt $boundaryPrefixLength; $i++) { $boundarySource[$i] = 65 }
        $boundarySource[$boundaryPrefixLength] = 10
        [Buffer]::BlockCopy($helloBytes, 0, $boundarySource, $boundaryPrefixLength + 1, $helloBytes.Length)
        [IO.File]::WriteAllBytes((Join-Path $boot 'boundary.bz'), $boundarySource)
        Copy-Item -LiteralPath (Join-Path $root 'examples\额外程序.bz') -Destination 'extra.bz' -Force
        $customSource = [IO.File]::ReadAllText((Join-Path $root 'examples\额外程序.bz'), [Text.UTF8Encoding]::new($false))
        $lastDigit = $customSource.LastIndexOf('5')
        if ($lastDigit -lt 0) { throw '额外程序中未找到阶乘输入' }
        $customSource = $customSource.Substring(0, $lastDigit) + '6' + $customSource.Substring($lastDigit + 1)
        [IO.File]::WriteAllText((Join-Path $boot 'custom.bz'), $customSource, [Text.UTF8Encoding]::new($false))
        $fileIoSource = [IO.File]::ReadAllText((Join-Path $root 'examples\文件读写.bz'), [Text.UTF8Encoding]::new($false)).Replace(('build' + [char]92 + [char]92 + 'io.bin'), 'io.bin')
        [IO.File]::WriteAllText((Join-Path $boot 'fileio.bz'), $fileIoSource, [Text.UTF8Encoding]::new($false))
        Copy-Item -LiteralPath (Join-Path $root 'examples\命令行参数.bz') -Destination (Join-Path $boot 'args.bz') -Force
        [IO.File]::WriteAllText((Join-Path $boot 'negative-number.bz'), '输出（-2 * 3 + 10）', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $boot 'escaped-string.bz'), '输出("A\n\t\"B\"\\C")', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $boot 'arithmetic.bz'), '输出（-(-3) + 17 / 5 * 2）', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $boot 'negative-division.bz'), '输出（-17 / 5）', [Text.UTF8Encoding]::new($false))
        $localArray = '函数 往返（值） {' + [Environment]::NewLine + '字节数组 本地[4]' + [Environment]::NewLine + '本地[0] = 值' + [Environment]::NewLine + '返回 本地[0] + 1' + [Environment]::NewLine + '}' + [Environment]::NewLine + '输出（往返(65)）'
        [IO.File]::WriteAllText((Join-Path $boot 'local-array.bz'), $localArray, [Text.UTF8Encoding]::new($false))
        $boolTrue = '布尔 状态 = 真' + [Environment]::NewLine + '如果（状态） {' + [Environment]::NewLine + '输出（1）' + [Environment]::NewLine + '} 否则 {' + [Environment]::NewLine + '输出（0）' + [Environment]::NewLine + '}'
        $boolFalse = '布尔 状态 = 假' + [Environment]::NewLine + '如果（状态） {' + [Environment]::NewLine + '输出（1）' + [Environment]::NewLine + '} 否则 {' + [Environment]::NewLine + '输出（0）' + [Environment]::NewLine + '}'
        [IO.File]::WriteAllText((Join-Path $boot 'bool-true.bz'), $boolTrue, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $boot 'bool-false.bz'), $boolFalse, [Text.UTF8Encoding]::new($false))
        $samples = @(
            @{ Name = 'hello'; Source = 'hello.bz'; Expected = '你好，白泽！' + [Environment]::NewLine },
            @{ Name = 'offset'; Source = 'offset.bz'; Expected = '你好，白泽！' + [Environment]::NewLine },
            @{ Name = 'boundary'; Source = 'boundary.bz'; Expected = '你好，白泽！' + [Environment]::NewLine },
            @{ Name = 'factorial'; Source = 'extra.bz'; Expected = '120' + [Environment]::NewLine },
            @{ Name = 'custom'; Source = 'custom.bz'; Expected = '720' + [Environment]::NewLine },
            @{ Name = 'fileio'; Source = 'fileio.bz'; Arguments = ''; Expected = '135' + [Environment]::NewLine },
            @{ Name = 'args'; Source = 'args.bz'; Arguments = 'Alpha beta'; Expected = '72' + [Environment]::NewLine },
            @{ Name = 'negative-number'; Source = 'negative-number.bz'; Arguments = ''; Expected = '4' + [Environment]::NewLine },
            @{ Name = 'escaped-string'; Source = 'escaped-string.bz'; Arguments = ''; Expected = 'A' + [Environment]::NewLine + "	" + '"B"\C' + [Environment]::NewLine },
            @{ Name = 'arithmetic'; Source = 'arithmetic.bz'; Arguments = ''; Expected = '9' + [Environment]::NewLine },
            @{ Name = 'negative-division'; Source = 'negative-division.bz'; Arguments = ''; Expected = '-3' + [Environment]::NewLine },
            @{ Name = 'local-array'; Source = 'local-array.bz'; Arguments = ''; Expected = '66' + [Environment]::NewLine },
            @{ Name = 'bool-true'; Source = 'bool-true.bz'; Arguments = ''; Expected = '1' + [Environment]::NewLine },
            @{ Name = 'bool-false'; Source = 'bool-false.bz'; Arguments = ''; Expected = '0' + [Environment]::NewLine }
        )
        foreach ($stage in @('stage1', 'stage2')) {
            foreach ($sample in $samples) {
                $base = "$stage-$($sample.Name)"
                Invoke-Emit ".\$stage.exe" $sample.Source "$base.c"
                Invoke-Cl "$base.c" "$base.exe"
                & cmd.exe /d /c "$base.exe $($sample.Arguments) > $base.out"
                if ($LASTEXITCODE -ne 0) { throw "$stage $($sample.Name) 正例程序运行失败" }
                $actual = [IO.File]::ReadAllText((Join-Path $boot "$base.out"), [Text.UTF8Encoding]::new($false))
                if ($actual -ne $sample.Expected) { throw "$stage $($sample.Name) 输出错误：$actual" }
                if ($sample.Name -eq 'fileio') {
                    $fileBytes = [IO.File]::ReadAllBytes((Join-Path $boot 'io.bin'))
                    if ($fileBytes.Length -ne 2 -or $fileBytes[0] -ne 65 -or $fileBytes[1] -ne 66) { throw "$stage 文件 API 输出字节不符" }
                }
            }
        }
        foreach ($sample in $samples) {
            $hash1 = (Get-FileHash "stage1-$($sample.Name).c" -Algorithm SHA256).Hash
            $hash2 = (Get-FileHash "stage2-$($sample.Name).c" -Algorithm SHA256).Hash
            if ($hash1 -ne $hash2) { throw "stage1 与 stage2 对 $($sample.Name) 生成的 C 不一致" }
        }
        [IO.File]::WriteAllText((Join-Path $boot 'negative.bz'), '输出（1）' + [Environment]::NewLine + '整数 x = 1 + * 2', [Text.UTF8Encoding]::new($false))
        [IO.File]::Delete((Join-Path $boot 'missing-input.bz'))
        foreach ($stage in @('stage1', 'stage2')) {
            $missingResult = & ".\$stage.exe" (Join-Path $boot 'missing-input.bz') (Join-Path $boot "$stage-missing.c") emit | Out-String
            if ($LASTEXITCODE -ne 0 -or !$missingResult.Contains('编译错误：无法读取源文件') -or (Test-Path (Join-Path $boot "$stage-missing.c"))) {
                throw "$stage 未妥善拒绝无法读取的源文件：$missingResult"
            }
        }
        $oversizeSource = [byte[]]::new(262145)
        $oversizeSource[0] = 35
        for ($i = 1; $i -lt $oversizeSource.Length; $i++) { $oversizeSource[$i] = 65 }
        [IO.File]::WriteAllBytes((Join-Path $boot 'oversize.bz'), $oversizeSource)
        foreach ($stage in @('stage1', 'stage2')) {
            $oversizeC = Join-Path $boot "$stage-oversize.c"
            Remove-Item -LiteralPath $oversizeC -ErrorAction SilentlyContinue
            $oversizeResult = & ".\$stage.exe" (Join-Path $boot 'oversize.bz') $oversizeC emit | Out-String
            if ($LASTEXITCODE -ne 0 -or !$oversizeResult.Contains('编译错误：源文件超过最大容量') -or (Test-Path -LiteralPath $oversizeC)) {
                throw "$stage 未拒绝超容量源文件：$oversizeResult"
            }
        }        $expectedDiagnostic = $null
        $expectedOffset = [Text.Encoding]::UTF8.GetByteCount('输出（1）') + [Text.Encoding]::UTF8.GetByteCount([Environment]::NewLine) + [Text.Encoding]::UTF8.GetByteCount('整数 x = 1 + ')
        foreach ($stage in @('stage1', 'stage2')) {
            Remove-Item -LiteralPath "$stage-negative.c" -ErrorAction SilentlyContinue
            $result = & ".\$stage.exe" (Join-Path $boot 'negative.bz') (Join-Path $boot "$stage-negative.c" ) emit | Out-String
            if ($LASTEXITCODE -ne 0 -or !$result.Contains('编译错误：程序语法无效') -or !$result.Trim().EndsWith('0') -or (Test-Path "$stage-negative.c")) {
                throw "$stage 未拒绝非法语法：$result"
            }
            if ($result -notmatch ("源码行\s+2\s+UTF-8字节偏移\s+$expectedOffset")) { throw "$stage 未报告正确的语法错误行和字节偏移：$result" }
            if ($null -eq $expectedDiagnostic) { $expectedDiagnostic = $result } elseif ($expectedDiagnostic -cne $result) { throw 'stage1 与 stage2 的语法诊断不一致' }
        }

        Write-Output "自举链通过；Rust seed 可执行文件在连续自举期间已禁用；stage1/stage2/stage3 C SHA-256：$stage1Hash"
    } finally { Pop-Location }
} finally {
    if ($seedMoved) { Move-Item -LiteralPath $disabledSeedExe -Destination $seedExe }
    [Console]::OutputEncoding = $previousEncoding
    Pop-Location
}
