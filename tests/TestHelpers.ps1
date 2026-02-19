Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Failures = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) {
        $script:Failures++
        Write-Host "[FAIL] $Message (expected=$Expected actual=$Actual)" -ForegroundColor Red
    }
    else {
        Write-Host "[PASS] $Message" -ForegroundColor Green
    }
}

function Assert-Contains {
    param([string]$Text, [string]$Substring, [string]$Message)
    if ($Text -notlike "*$Substring*") {
        $script:Failures++
        Write-Host "[FAIL] $Message (missing '$Substring')" -ForegroundColor Red
    }
    else {
        Write-Host "[PASS] $Message" -ForegroundColor Green
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $script:Failures++
        Write-Host "[FAIL] $Message" -ForegroundColor Red
    }
    else {
        Write-Host "[PASS] $Message" -ForegroundColor Green
    }
}

function New-TestDir {
    $path = Join-Path ([IO.Path]::GetTempPath()) ("repogen-test-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

function Invoke-Repogen {
    param([string[]]$Arguments)
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'repogen.ps1'
    $pwshCmd = (Get-Command pwsh).Source

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwshCmd
    $psi.WorkingDirectory = $repoRoot
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.ArgumentList.Add('-NoProfile')
    $psi.ArgumentList.Add('-File')
    $psi.ArgumentList.Add($scriptPath)
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut = $stdout
        StdErr = $stderr
    }
}

function Complete-Tests {
    if ($script:Failures -gt 0) {
        Write-Host "Tests failed: $script:Failures" -ForegroundColor Red
        exit 1
    }
    Write-Host 'All tests passed.' -ForegroundColor Green
    exit 0
}
