[CmdletBinding()]
param([string]$OutputDirectory, [string]$ReferenceCompiler)

$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'check-native-windows.ps1') @PSBoundParameters
