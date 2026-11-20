[CmdletBinding()]
param(
    [string] $OutputDirectory = (Join-Path ([IO.Path]::GetTempPath()) ("baize-native-" + [guid]::NewGuid())),
    [string] $ReferenceCompiler
)

$ErrorActionPreference = 'Stop'
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -or -not [Environment]::Is64BitProcess) {
    throw 'Windows x86-64 and a 64-bit PowerShell process are required.'
}

$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root 'compiler/编译器.bz'
$trust = Join-Path $root 'bootstrap/stage0/trust-root-windows'
$seed = Join-Path $trust 'seed.pe'
$manifest = (Get-Content -Raw -LiteralPath (Join-Path $trust 'SEED-SHA256SUMS')).Trim()
if ($manifest -cnotmatch '^([0-9a-f]{64})  seed\.pe$') {
    throw 'Invalid Windows seed manifest.'
}
if ((Get-FileHash -LiteralPath $seed).Hash -ne $Matches[1]) {
    throw 'Windows seed SHA-256 does not match the manifest.'
}

$work = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $work | Out-Null
$previous = Join-Path $work 'seed.exe'
Copy-Item -LiteralPath $seed -Destination $previous

function Assert-IdenticalFile($First, $Second) {
    $firstBytes = [IO.File]::ReadAllBytes($First)
    $secondBytes = [IO.File]::ReadAllBytes($Second)
    if (-not [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals($firstBytes, $secondBytes)) {
        throw "Different compiler images: $First and $Second"
    }
}

$originalPath = $env:PATH
try {
    $env:PATH = Join-Path $env:SystemRoot 'System32'
    foreach ($tool in 'cargo.exe', 'rustc.exe', 'cl.exe', 'link.exe', 'gcc.exe', 'clang.exe',
        'as.exe', 'ld.exe', 'ml64.exe', 'lld-link.exe') {
        if (Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue) {
            throw "External build tool found: $tool"
        }
    }

    foreach ($stage in 1..3) {
        $next = Join-Path $work "stage$stage.exe"
        & $previous $source $next native-windows-x64
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $next -PathType Leaf)) {
            throw "Windows bootstrap stage $stage failed with exit code $LASTEXITCODE."
        }
        $previous = $next
    }

    $first = Join-Path $work 'stage1.exe'
    Assert-IdenticalFile $first (Join-Path $work 'stage2.exe')
    Assert-IdenticalFile $first $previous
    if ($ReferenceCompiler) {
        Assert-IdenticalFile (Resolve-Path -LiteralPath $ReferenceCompiler).Path $previous
    }

    $sample = Join-Path $work '原生 验收.bz'
    $program = Join-Path $work '原生 验收.exe'
    $inputPath = Join-Path $work '二进制 输入.bin'
    $copyPath = Join-Path $work '二进制 副本.bin'
    [IO.File]::WriteAllBytes($inputPath, [byte[]](0..255))
    $probe = @'
字节数组 缓冲[300]
如果(文件读取("二进制 输入.bin", 缓冲, 300) != 256) { 返回 1 }
如果(文件写入("二进制 副本.bin", 缓冲, 256) != 256) { 返回 2 }
如果(输入字节() != 0) { 返回 3 }
如果(输入字节() != 255) { 返回 4 }
如果(输入字节() != 0 - 1) { 返回 5 }
如果(文件读取("不存在.bin", 缓冲, 300) != 0 - 1) { 返回 6 }
返回 42
'@
    [IO.File]::WriteAllText($sample, $probe, [Text.UTF8Encoding]::new($false))
    & $previous $sample $program native-windows-x64
    if ($LASTEXITCODE -ne 0) { throw 'Windows sample compilation failed.' }
    $stdin = Join-Path $work 'stdin.bin'
    [IO.File]::WriteAllBytes($stdin, [byte[]]@(0, 255))
    $process = Start-Process -FilePath $program -WorkingDirectory $work -RedirectStandardInput $stdin -WindowStyle Hidden -PassThru -Wait
    try {
        if ($process.ExitCode -ne 42) { throw "Windows sample returned $($process.ExitCode) instead of 42." }
    } finally {
        $process.Dispose()
    }
    Assert-IdenticalFile $inputPath $copyPath
    $start = [Diagnostics.ProcessStartInfo]::new($program)
    $start.WorkingDirectory = $work
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $priorInputEncoding = [Console]::InputEncoding
    try {
        [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
        $process = [Diagnostics.Process]::Start($start)
    } finally {
        [Console]::InputEncoding = $priorInputEncoding
    }
    try {
        $pipe = $process.StandardInput.BaseStream
        $bytes = [byte[]]@(0, 255)
        $pipe.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(10000)) {
            $process.Kill()
            throw 'Windows pipe EOF sample timed out.'
        }
        if ($process.ExitCode -ne 42) {
            throw "Windows pipe EOF sample returned $($process.ExitCode) instead of 42."
        }
    } finally {
        $process.Dispose()
    }

    $invalid = Join-Path $work 'invalid.bz'
    $rejected = Join-Path $work 'invalid.exe'
    [IO.File]::WriteAllText($invalid, '整数 x = 1 + * 2', [Text.UTF8Encoding]::new($false))
    & $previous $invalid $rejected native-windows-x64
    if ($LASTEXITCODE -ne 1 -or (Test-Path -LiteralPath $rejected)) {
        throw 'Windows compiler did not reject invalid source.'
    }
    $global:LASTEXITCODE = 0
} finally {
    $env:PATH = $originalPath
}

Get-FileHash -LiteralPath $previous
Write-Output "PASS: Windows seed verified and three native compiler images match in $work"
