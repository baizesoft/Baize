param([string]$Source = 'examples\你好.bz', [string]$Name = 'demo', [string]$CompilerPath)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ([IO.Path]::IsPathRooted($Source)) {
    $sourcePath = (Resolve-Path -LiteralPath $Source).Path
} else {
    $sourcePath = (Resolve-Path -LiteralPath (Join-Path $root $Source)).Path
}
$exePath = Join-Path $root "build/$Name.exe"
$destination = Split-Path -Parent $exePath
New-Item -ItemType Directory -Force -Path $destination | Out-Null
$temporaryOutput = Join-Path $destination ("baize-output-" + [guid]::NewGuid() + ".exe")
$temporarySeed = $null
$temporaryCompiler = $null
try {
    if ($CompilerPath) {
        $compiler = (Resolve-Path -LiteralPath $CompilerPath).Path
    } else {
        $trust = Join-Path $root 'bootstrap/stage0/trust-root-windows'
        $seed = Join-Path $trust 'seed.pe'
        $manifest = (Get-Content -Raw -LiteralPath (Join-Path $trust 'SEED-SHA256SUMS')).Trim()
        if ($manifest -cnotmatch '^([0-9a-f]{64})  seed\.pe$' -or
            (Get-FileHash -LiteralPath $seed).Hash -ne $Matches[1]) {
            throw 'Windows seed verification failed.'
        }
        $temporarySeed = Join-Path $destination ("baize-seed-" + [guid]::NewGuid() + ".exe")
        Copy-Item -LiteralPath $seed -Destination $temporarySeed
        $compiler = $temporarySeed
        $compilerSource = Join-Path $root 'compiler/编译器.bz'
        if ($sourcePath -ne $compilerSource) {
            $temporaryCompiler = Join-Path $destination ("baize-compiler-" + [guid]::NewGuid() + ".exe")
            & $temporarySeed $compilerSource $temporaryCompiler native-windows-x64
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporaryCompiler -PathType Leaf)) {
                throw "Windows compiler bootstrap failed with exit code $LASTEXITCODE."
            }
            $compiler = $temporaryCompiler
        }
    }
    & $compiler $sourcePath $temporaryOutput native-windows-x64
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporaryOutput -PathType Leaf)) {
        throw "Windows native compilation failed with exit code $LASTEXITCODE."
    }
    Move-Item -LiteralPath $temporaryOutput -Destination $exePath -Force
} finally {
    if ($temporarySeed -and (Test-Path -LiteralPath $temporarySeed)) {
        Remove-Item -LiteralPath $temporarySeed
    }
    if ($temporaryCompiler -and (Test-Path -LiteralPath $temporaryCompiler)) {
        Remove-Item -LiteralPath $temporaryCompiler
    }
    if (Test-Path -LiteralPath $temporaryOutput) {
        Remove-Item -LiteralPath $temporaryOutput
    }
}
