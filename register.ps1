[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('claude','antigravity','cursor','codex')]
    [string]$Harness,
    [string]$Project
)
$ErrorActionPreference = 'Stop'
$folders = @{claude='.claude'; antigravity='.agents'; cursor='.cursor'; codex='.codex'}
if ($Project) {
    $workspace = Get-Item -LiteralPath $Project
    if (!$workspace.PSIsContainer) { throw 'Project must be an existing directory.' }
    $folder = if ($Harness -eq 'codex') { '.agents' } else { $folders[$Harness] }
    $base = Join-Path $workspace.FullName $folder
} elseif ($Harness -eq 'antigravity') {
    $base = Join-Path $env:USERPROFILE '.gemini\config'
} elseif ($Harness -eq 'claude' -and $env:CLAUDE_CONFIG_DIR) {
    $base = $env:CLAUDE_CONFIG_DIR
} elseif ($Harness -eq 'codex' -and $env:CODEX_HOME) {
    $base = $env:CODEX_HOME
} else {
    $base = Join-Path $env:USERPROFILE $folders[$Harness]
}
$root = [IO.Path]::GetFullPath((Join-Path $base 'skills'))
$dest = Join-Path $root 'qq-chat-history'
$files = @('SKILL.md','register.ps1','setup.ps1','scripts\sessions.py','scripts\query.py',
           'tests\test_queries.py','tests\setup.tests.ps1','tests\register.tests.ps1')
foreach ($file in $files) {
    $source = Join-Path $PSScriptRoot $file
    if (!(Test-Path -LiteralPath $source -PathType Leaf)) { throw "Incomplete package: $file" }
}
if (Test-Path -LiteralPath $dest) {
    foreach ($file in $files) {
        $target = Join-Path $dest $file
        if (!(Test-Path -LiteralPath $target -PathType Leaf) -or
            (Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $file)).Hash) {
            throw "Existing skill differs; preserve and review it before upgrading: $dest"
        }
    }
    Write-Output $dest
    return
}
[void][IO.Directory]::CreateDirectory($root)
$stage = Join-Path $root ('.qq-register-' + [guid]::NewGuid().ToString('N'))
try {
    foreach ($file in $files) {
        $target = Join-Path $stage $file
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $target -ErrorAction Stop
    }
    [IO.Directory]::Move($stage,$dest)
} finally {
    $full = [IO.Path]::GetFullPath($stage)
    if ((Test-Path -LiteralPath $full) -and [IO.Path]::GetDirectoryName($full) -eq $root -and
        [IO.Path]::GetFileName($full) -match '^\.qq-register-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
Write-Output $dest
