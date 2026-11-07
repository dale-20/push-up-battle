# Runs the two-process Wi-Fi match test (host + guest over loopback).
# Usage: powershell -File tests/run_online_test.ps1 [-Godot <path to Godot console exe>]
param(
    [string]$Godot = "$env:USERPROFILE\Godot_v4.7-stable_win64.exe\Godot_v4.7-stable_win64_console.exe"
)
$project = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path ([IO.Path]::GetTempPath()) "pushup-online-test"
New-Item -ItemType Directory -Force $logDir | Out-Null

$common = @("--headless", "--path", "`"$project`"", "--script", "res://tests/test_online_match.gd", "--")
$hostProc = Start-Process -FilePath $Godot -ArgumentList ($common + "host") -NoNewWindow -PassThru `
    -RedirectStandardOutput "$logDir\host.log" -RedirectStandardError "$logDir\host.err"
$guestProc = Start-Process -FilePath $Godot -ArgumentList ($common + "guest") -NoNewWindow -PassThru `
    -RedirectStandardOutput "$logDir\guest.log" -RedirectStandardError "$logDir\guest.err"
$null = $hostProc.Handle; $null = $guestProc.Handle  # keep handles so ExitCode is readable

foreach ($p in @($hostProc, $guestProc)) {
    if (-not $p.WaitForExit(120000)) { $p.Kill(); Write-Output "TIMEOUT: killed pid $($p.Id)" }
}

Get-Content "$logDir\host.log", "$logDir\guest.log" | Where-Object { $_ -match "^\[(HOST|GUEST)\]" }
Get-Content "$logDir\host.err", "$logDir\guest.err" | Where-Object { $_ -match "ERROR" }
$failed = ($hostProc.ExitCode -ne 0) -or ($guestProc.ExitCode -ne 0)
Write-Output ("host exit={0} guest exit={1}" -f $hostProc.ExitCode, $guestProc.ExitCode)
if ($failed) { exit 1 } else { exit 0 }
