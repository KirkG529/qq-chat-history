$ErrorActionPreference = 'Stop'
$register = Join-Path $PSScriptRoot '..\register.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('qq-host-' + [guid]::NewGuid().ToString('N'))
$old = @($env:USERPROFILE,$env:CLAUDE_CONFIG_DIR,$env:CODEX_HOME)
try {
    $env:USERPROFILE = Join-Path $temp 'user profile'
    $env:CLAUDE_CONFIG_DIR = $null
    $env:CODEX_HOME = $null
    $project = [IO.Directory]::CreateDirectory((Join-Path $temp 'sample project')).FullName
    $projectDirs = @{claude='.claude'; antigravity='.agents'; cursor='.cursor'; codex='.codex'}
    foreach ($hostName in $projectDirs.Keys) {
        foreach ($scope in 'user','project') {
            $arguments = @{Harness=$hostName}
            $base = $env:USERPROFILE
            $folder = $projectDirs[$hostName]
            if ($scope -eq 'project') { $base=$project; $arguments.Project=$project; if ($hostName -eq 'codex') { $folder='.agents' } }
            elseif ($hostName -eq 'antigravity') { $folder='.gemini\config' }
            $expected = Join-Path (Join-Path $base $folder) 'skills\qq-chat-history'
            $dest = & $register @arguments
            if ($dest -ne $expected -or (& $register @arguments) -ne $expected) { throw "Unexpected registration: $hostName $scope" }
            if ((Get-FileHash (Join-Path $dest 'LICENSE')).Hash -ne (Get-FileHash (Join-Path $PSScriptRoot '..\LICENSE')).Hash) { throw 'License mismatch' }
            if (!(Test-Path -LiteralPath (Join-Path $dest 'scripts\sessions.py'))) { throw 'Missing script' }
        }
    }
    $env:CLAUDE_CONFIG_DIR = Join-Path $temp 'custom claude'
    $dest = & $register -Harness claude
    if ($dest -ne (Join-Path $env:CLAUDE_CONFIG_DIR 'skills\qq-chat-history')) {throw 'Custom profile ignored'}
    Set-Content -LiteralPath (Join-Path $dest 'SKILL.md') -Value 'local changes'
    $rejected = $false
    try { & $register -Harness claude } catch { $rejected = $_ -like '*Existing skill differs*' }
    if (!$rejected -or (Get-Content -LiteralPath (Join-Path $dest 'SKILL.md')) -ne 'local changes') {throw 'Conflict handling failed'}
    'PASS: 8 harness/scope combinations, repeat registration, custom profile and conflict protection.'
} finally {
    $env:USERPROFILE,$env:CLAUDE_CONFIG_DIR,$env:CODEX_HOME = $old
    $full=[IO.Path]::GetFullPath($temp)
    if ([IO.Path]::GetDirectoryName($full) -eq [IO.Path]::GetTempPath().TrimEnd('\') -and
        [IO.Path]::GetFileName($full) -match '^qq-host-[0-9a-f]{32}$') { Remove-Item -LiteralPath $full -Recurse -Force }
}
