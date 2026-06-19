#Requires -Version 5.1
<#
.SYNOPSIS
    Install local git hooks for ph-cdr.
.DESCRIPTION
    Run once after cloning: .\scripts\install-hooks.ps1
    Copies every file in scripts\hooks\ into .git\hooks\.
    Git on Windows does not require execute permissions on hook files.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$HooksSrc   = Join-Path $ScriptDir 'hooks'
$GitDir     = git -C $ScriptDir rev-parse --git-dir
$HooksDst   = Join-Path $ScriptDir $GitDir 'hooks'

if (-not (Test-Path $HooksSrc)) {
    Write-Error "hooks directory not found at $HooksSrc"
    exit 1
}

foreach ($hook in Get-ChildItem $HooksSrc -File) {
    $dest = Join-Path $HooksDst $hook.Name
    Copy-Item $hook.FullName $dest -Force
    Write-Host "  installed: .git\hooks\$($hook.Name)" -ForegroundColor Green
}

Write-Host ""
Write-Host "Git hooks installed. Commits will now be validated against"
Write-Host "conventional commits format (feat|fix|docs|ci|chore|...)."
