# Runs on stock Windows PowerShell 5.1 without Pester or third-party modules.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\setup.ps1')
function Assert($Condition, $Message) {
    if (!$Condition) { throw "FAIL: $Message" }
}
function Scenario($InitialQQ, $InitialPython, $Apply, $ExpectedPackages, $ExpectedState, $NoUpgrade = $false) {
    $Install = $Apply
    $sim = @{ qq = $InitialQQ; python = $InitialPython; packages = @(); framework = 0 }
    function Find-QQ { if ($sim.qq) { [pscustomobject]@{FullName='QQ.exe';VersionInfo=@{ProductVersion=$sim.qq}} } }
    function Find-Python { return $sim.python }
    function Install-PackageId($Id) {
        $sim.packages += $Id
        if ($Id -eq 'Python.Python.3.13') { $sim.python = 'python.exe' }
        if ($Id -eq 'Tencent.QQ.NT' -and !$NoUpgrade) { $sim.qq = '9.9.37.54395' }
    }
    function Install-Framework { $sim.framework++ }
    function Test-Framework { return ($sim.framework -gt 0) }
    $failure = $null
    try { $result = Invoke-Setup | ConvertFrom-Json } catch { $failure = $_ }
    Assert (($sim.packages -join ',') -eq $ExpectedPackages) 'package decisions'
    if ($ExpectedState -eq 'error') {
        Assert ($failure -and !$sim.framework) 'incompatible QQ stops setup'
    } else {
        Assert (!$failure -and $result.qqState -eq $ExpectedState) 'setup state'
        Assert ($sim.framework -eq [int]$Apply) 'framework staging'
    }
}
Scenario '' '' $false '' 'missing'
Scenario '' '' $true 'Python.Python.3.13,Tencent.QQ.NT' 'compatible'
Scenario '9.9.11.24650' 'python.exe' $true 'Tencent.QQ.NT' 'compatible'
Scenario '9.5.2.27905' 'python.exe' $true 'Tencent.QQ.NT' 'compatible'
Scenario '9.9.37.54395' '' $true 'Python.Python.3.13' 'compatible'
Scenario '9.9.37.54395' 'python.exe' $true '' 'compatible'
Scenario 'unrecognized' 'python.exe' $true '' 'error'
Scenario '9.9.11.24650' 'python.exe' $true 'Tencent.QQ.NT' 'error' $true
Assert ((Get-QQState '9.9.19-34606') -eq 'compatible') 'minimum build'
Assert ((Get-QQState '9.9.19-34605') -eq 'upgrade') 'below minimum build'

$temp = Join-Path ([IO.Path]::GetTempPath()) ('qq-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try {
    $target = Join-Path $temp 'Framework'
    $bad = Join-Path $temp 'bad.zip'
    [IO.File]::WriteAllText($bad,'invalid archive')
    $err = $null
    try { Install-Framework $target $bad } catch { $err = $_ }
    Assert ($err -like '*SHA256*') 'corrupt download rejected'
    Assert (!(Test-Path $target)) 'no partial installation'
    Assert (@(Get-ChildItem $temp -Filter '.qce-stage-*' -Force).Count -eq 0) 'temporary files cleaned'
    & {
        function Invoke-WebRequest { throw 'simulated download interruption' }
        $err = $null
        try { Install-Framework $target '' } catch { $err = $_ }
        Assert ($err -like '*interruption*') 'interrupted download surfaced'
        Assert (!(Test-Path $target)) 'retry destination remains available'
        Assert (@(Get-ChildItem $temp -Filter '.qce-stage-*' -Force).Count -eq 0) 'interrupted staging cleaned'
    }
    $err = $null
    [void][IO.Directory]::CreateDirectory($target)
    try { Install-Framework $target $bad } catch { $err = $_ }
    Assert ($err -like '*occupied*') 'occupied destination preserved'
} finally {
    $full = [IO.Path]::GetFullPath($temp)
    if ([IO.Path]::GetDirectoryName($full) -eq [IO.Path]::GetTempPath().TrimEnd('\') -and
        [IO.Path]::GetFileName($full) -match '^qq-test-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
Write-Output 'PASS: 8 setup scenarios, build boundaries, corrupt archive cleanup and occupied destination.'
