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
    [IO.File]::WriteAllText($sample, '返回 42', [Text.UTF8Encoding]::new($false))
    & $previous $sample $program native-windows-x64
    if ($LASTEXITCODE -ne 0) { throw 'Windows sample compilation failed.' }
    & $program
    if ($LASTEXITCODE -ne 42) { throw "Windows sample returned $LASTEXITCODE instead of 42." }
} finally {
    $env:PATH = $originalPath
}

Get-FileHash -LiteralPath $previous
Write-Output "PASS: Windows seed verified and three native compiler images match in $work"
