# Runs tests/net_test.gd twice (host, then client) over ENet on localhost and
# merges their PASS/FAIL output. Exit code is non-zero if either half failed.
param(
    [string]$Godot = "$env:USERPROFILE\Downloads\Godot_v4.7.2-stable_win64\Godot_v4.7.2-stable_win64_console.exe",
    [int]$Port = 7777
)
$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$hostLog = Join-Path $env:TEMP "net_test_host.log"
$clientLog = Join-Path $env:TEMP "net_test_client.log"

$common = @("--headless", "--path", $projectRoot, "--script", "res://tests/net_test.gd", "--")
$hostProc = Start-Process -FilePath $Godot -ArgumentList ($common + @("role=host", "port=$Port")) `
    -PassThru -NoNewWindow -RedirectStandardOutput $hostLog
$null = $hostProc.Handle  # cache the handle or ExitCode reads back as null
Start-Sleep -Seconds 4
$clientProc = Start-Process -FilePath $Godot -ArgumentList ($common + @("role=client", "port=$Port")) `
    -PassThru -NoNewWindow -RedirectStandardOutput $clientLog
$null = $clientProc.Handle

if (-not $clientProc.WaitForExit(150000)) { $clientProc.Kill() }
if (-not $hostProc.WaitForExit(60000)) { $hostProc.Kill() }

Get-Content $hostLog | Select-String -Pattern "^(PASS|FAIL|XFAIL|SUMMARY)|SCRIPT ERROR|ERROR:"
Get-Content $clientLog | Select-String -Pattern "^(PASS|FAIL|XFAIL|SUMMARY)|SCRIPT ERROR|ERROR:"

$failed = ($hostProc.ExitCode -ne 0) -or ($clientProc.ExitCode -ne 0)
if ($failed) { Write-Host "NET TEST FAILED (host=$($hostProc.ExitCode) client=$($clientProc.ExitCode))"; exit 1 }
Write-Host "NET TEST PASSED"
exit 0
