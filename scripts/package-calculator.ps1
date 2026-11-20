param([string]$OutputPath)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (!$OutputPath) {
    $OutputPath = Join-Path $root 'dist/BaizeCalculator-win-x64.zip'
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if ([IO.Path]::GetExtension($OutputPath) -ne '.zip') { throw '输出文件必须以 .zip 结尾' }
$outputDir = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

$buildScript = Join-Path $PSScriptRoot 'build-seed.ps1'
$build = (New-Item -ItemType Directory -Force (Join-Path $root 'build')).FullName
$stageName = 'calculator-package-' + [guid]::NewGuid().ToString('N')
$stage = Join-Path $build $stageName
$archive = Join-Path $outputDir ('baize-calculator-' + [guid]::NewGuid().ToString('N') + '.zip')
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    $compilerWork = Join-Path $stage 'compiler'
    & (Join-Path $PSScriptRoot 'check-native-windows.ps1') -OutputDirectory $compilerWork
    $compilerPath = Join-Path $compilerWork 'stage3.exe'
    & $buildScript -Source 'examples\计算器.bz' -Name "$stageName/compiler/baize-calculator" -CompilerPath $compilerPath
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'start-calculator.ps1') -Destination (Join-Path $stage 'Start-Calculator.ps1')
    Copy-Item -LiteralPath (Join-Path $stage 'compiler/baize-calculator.exe') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination $stage
    $launcher = @"
@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -File "%~dp0Start-Calculator.ps1" -WorkerPath "%~dp0baize-calculator.exe"
if errorlevel 1 pause
"@
    [IO.File]::WriteAllText((Join-Path $stage 'Start-Calculator.cmd'), $launcher, [Text.Encoding]::ASCII)
    $readme = @"
白泽计算器 · Windows x64

解压全部文件后，双击 Start-Calculator.cmd。
运行使用系统的 Windows PowerShell 5.1 和 WinForms。

按键：数字、小数点、四则运算、等号、百分号、CE 和退格。
Enter 计算，Backspace 退格，Delete 清除当前输入，Esc 清除，F9 切换正负号。
Ctrl+E 打开算式编辑器，Ctrl+Shift+V 粘贴算式。可用 Ctrl+C 复制当前数值，也可展开计算历史并复用结果。窗口底部的程序员模式支持 BYTE、WORD、DWORD 和 QWORD。
"@
    [IO.File]::WriteAllText((Join-Path $stage 'README.txt'), $readme, [Text.UTF8Encoding]::new($true))

    Add-Type -AssemblyName System.IO.Compression
    $timestamp = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
    $names = [string[]]@(Get-ChildItem -LiteralPath $stage -File | Select-Object -ExpandProperty Name)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $zipFile = [IO.File]::Open($archive, [IO.FileMode]::CreateNew)
    try {
        $zip = [IO.Compression.ZipArchive]::new($zipFile, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($name in $names) {
                $entry = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $timestamp
                $sourceStream = [IO.File]::OpenRead((Join-Path $stage $name))
                try {
                    $output = $entry.Open()
                    try { $sourceStream.CopyTo($output) }
                    finally { $output.Dispose() }
                } finally { $sourceStream.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $zipFile.Dispose() }
    # Exercise the package layout from a directory with spaces and non-ASCII characters.
    $extracted = Join-Path $stage '独立运行 验收'
    Expand-Archive -LiteralPath $archive -DestinationPath $extracted
    $powershell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $oldPath = $env:PATH
    try {
        $env:PATH = Join-Path $env:SystemRoot 'System32'
        & $powershell -NoProfile -STA -File (Join-Path $extracted 'Start-Calculator.ps1') `
            -WorkerPath (Join-Path $extracted 'baize-calculator.exe') -Verify
        if ($LASTEXITCODE -ne 0) { throw "解压包验收失败：$LASTEXITCODE" }
    } finally {
        $env:PATH = $oldPath
    }
    Move-Item -LiteralPath $archive -Destination $OutputPath -Force
    Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256
} finally {
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    $resolved = (Resolve-Path -LiteralPath $stage).Path
    if ((Split-Path -Parent $resolved) -ne $build -or (Split-Path -Leaf $resolved) -notlike 'calculator-package-*') {
        throw "打包暂存目录不在预期范围：$resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}