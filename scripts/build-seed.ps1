param([string]$Source = 'examples\你好.bz', [string]$Name = 'demo')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root $Source
$build = Join-Path $root 'build'
New-Item -ItemType Directory -Force $build | Out-Null
$cPath = Join-Path $build "$Name.c"
$exePath = Join-Path $build "$Name.exe"
Push-Location $root
try {
    cargo run --quiet --manifest-path (Join-Path $root 'Cargo.toml') -- $sourcePath $cPath
    if ($LASTEXITCODE -ne 0) { throw "Rust 种子编译失败：$LASTEXITCODE" }
    $vcvars = 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat'
    $command = "call `"$vcvars`" >nul && cl /nologo /utf-8 /W4 /WX `"build\$Name.c`" /Fo`"build\$Name.obj`" /Fe:`"build\$Name.exe`""
    & cmd.exe /d /c $command
    if ($LASTEXITCODE -ne 0) { throw "MSVC C 编译失败：$LASTEXITCODE" }
} finally { Pop-Location }
