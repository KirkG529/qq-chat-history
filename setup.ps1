[CmdletBinding()]
param(
    [switch]$Install,
    [string]$QQExe,
    [string]$FrameworkDir = (Join-Path $env:LOCALAPPDATA 'QQChatHistory\Framework-6.4.3'),
    [string]$Archive
)
$ErrorActionPreference = 'Stop'

function Get-QQState([string]$Version) {
    if (!$Version) { return 'missing' }
    if ($Version -match '^([1-8]\.\d+|9\.[0-8]\.)') { return 'upgrade' }
    if ($Version -notmatch '^9\.9\.\d+[.-](\d+)(?:\D|$)') { return 'unknown' }
    if ([int]$Matches[1] -lt 34606) { return 'upgrade' }
    return 'compatible'
}

function Find-QQ([string]$ExplicitPath) {
    if ($ExplicitPath) {
        $file = Get-Item -LiteralPath $ExplicitPath
        if ($file.Name -ne 'QQ.exe') { throw 'QQExe must point to QQ.exe.' }
        return $file
    }
    $paths = @((Get-Process -Name QQ -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Path -Unique))
    $keys = @('HKCU:\SOFTWARE','HKLM:\SOFTWARE','HKLM:\SOFTWARE\WOW6432Node')
    foreach ($key in $keys) {
        foreach ($app in (Get-ItemProperty "$key\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -match '^(?:Tencent |腾讯)?QQ(?: NT)?$' })) {
            if ($app.DisplayIcon) { $paths += ($app.DisplayIcon -replace ',\s*-?\d+$','').Trim('"') }
            if ($app.InstallLocation) { $paths += Join-Path $app.InstallLocation 'QQ.exe' }
        }
    }
    foreach ($base in @($env:ProgramFiles,${env:ProgramFiles(x86)},$env:LOCALAPPDATA)) {
        if ($base) {
            $paths += Join-Path $base 'Tencent\QQNT\QQ.exe'
            $paths += Join-Path $base 'Tencent\QQ\Bin\QQ.exe'
        }
    }
    $first = $null
    foreach ($path in $paths) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf) -and [IO.Path]::GetFileName($path) -eq 'QQ.exe') {
            $candidate = Get-Item -LiteralPath $path
            if ((Get-QQState $candidate.VersionInfo.ProductVersion) -eq 'compatible') { return $candidate }
            if (!$first) { $first = $candidate }
        }
    }
    return $first
}

function Find-Python {
    $candidates = @((Get-Command python.exe,py.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source))
    foreach ($key in @('HKCU:\Software','HKLM:\Software')) {
        foreach ($entry in (Get-Item "$key\Python\PythonCore\*\InstallPath" -ErrorAction SilentlyContinue)) {
            $candidates += $entry.GetValue('ExecutablePath')
        }
    }
    foreach ($exe in $candidates) {
        if (!$exe -or $exe -like '*\Microsoft\WindowsApps\python.exe' -or !(Test-Path -LiteralPath $exe)) { continue }
        $argsPrefix = @()
        if ([IO.Path]::GetFileName($exe) -eq 'py.exe') { $argsPrefix = @('-3') }
        $found = & $exe @argsPrefix -c 'import sys; print(sys.executable); sys.exit(sys.version_info < (3,9))' 2>$null
        if ($LASTEXITCODE -eq 0 -and $found) { return [string]$found }
    }
}

function Install-PackageId([string]$Id) {
    if (!(Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw "winget unavailable. Install App Installer, or install $Id from its publisher, then rerun setup."
    }
    & winget.exe install --id $Id --exact --source winget --architecture x64 --accept-source-agreements --accept-package-agreements | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "winget returned ${LASTEXITCODE} for $Id. Check the installer result and rerun setup." }
}

function Test-Framework([string]$Path) {
    foreach ($name in 'napiLoader.bat','qce-server.exe','plugins\napcat-plugin-qce\index.mjs') {
        if (!(Test-Path -LiteralPath (Join-Path $Path $name) -PathType Leaf)) { return $false }
    }
    return $true
}

function Install-Framework([string]$Path, [string]$Zip) {
    $Path = [IO.Path]::GetFullPath($Path)
    if (Test-Framework $Path) { return }
    if (Test-Path -LiteralPath $Path) { throw "Incomplete or occupied directory: $Path. Select a new -FrameworkDir." }
    $parent = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)).FullName
    $stage = Join-Path $parent ('.qce-stage-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stage)
    try {
        if (!$Zip) {
            $Zip = Join-Path $stage 'framework.zip'
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/shuakami/qq-chat-exporter/releases/download/v6.4.3/NapCat-Framework-QCE-v6.4.3.zip' -OutFile $Zip
        }
        $hash = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash
        if ($hash -ne 'a455f6420f78b3fc141625d6d82b84aeabc0377c4b528b34f848cdb44cecca78') { throw 'Framework SHA256 mismatch.' }
        $unpacked = Join-Path $stage 'unpacked'
        Expand-Archive -LiteralPath $Zip -DestinationPath $unpacked
        if (!(Test-Framework $unpacked)) { throw 'Framework package layout mismatch.' }
        [IO.Directory]::Move($unpacked,$Path)
    } finally {
        $absolute = [IO.Path]::GetFullPath($stage)
        if ([IO.Path]::GetDirectoryName($absolute) -eq $parent -and [IO.Path]::GetFileName($absolute) -match '^\.qce-stage-[0-9a-f]{32}$') {
            Remove-Item -LiteralPath $absolute -Recurse -Force
        }
    }
}

function Invoke-Setup {
    if (![Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') {
        throw 'This Framework package requires Windows x64.'
    }
    $python = Find-Python
    $qq = Find-QQ $QQExe
    $version = if ($qq) { $qq.VersionInfo.ProductVersion }
    $state = Get-QQState $version
    if ($Install) {
        if ($state -eq 'unknown') { throw "Unrecognized QQ version '$version'. Check -QQExe or install a compatible x64 QQNT build." }
        if (!$python) {
            Install-PackageId 'Python.Python.3.13'
            $python = Find-Python
            if (!$python) { throw 'Python installation not detected. Open a new shell and rerun.' }
        }
        if ($state -ne 'compatible') {
            Install-PackageId 'Tencent.QQ.NT'
            $qq = Find-QQ $QQExe
            $version = if ($qq) { $qq.VersionInfo.ProductVersion }
            $state = Get-QQState $version
            if ($state -ne 'compatible') { throw "Compatible QQNT not detected after installation. Check -QQExe; detected: $version" }
        }
        Install-Framework $FrameworkDir $Archive
    }
    [pscustomobject]@{
        python = $python; qq = $qq.FullName; qqVersion = $version; qqState = $state
        frameworkDir = [IO.Path]::GetFullPath($FrameworkDir); frameworkPresent = (Test-Framework $FrameworkDir)
        tokenFilePresent = (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.qq-chat-exporter\security.json'))
    } | ConvertTo-Json
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-Setup }
