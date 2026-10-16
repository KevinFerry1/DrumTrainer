# Run directly from the edited source folder; no build, copy, or ZIP extraction.
param([switch]$NoBrowser, [ValidateRange(1024,65535)][int]$Port = 8765)
$ErrorActionPreference = 'Stop'
$url = "http://127.0.0.1:${Port}/"
$root = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\').ToLowerInvariant()
$hasher = [System.Security.Cryptography.SHA256]::Create()
try { $rootID = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($root))).Replace('-','') }
finally { $hasher.Dispose() }
function Get-DrumServer {
  try { return (Invoke-WebRequest "${url}launcher.json" -UseBasicParsing -TimeoutSec 2).Content | ConvertFrom-Json }
  catch { return $null }
}
try {
  $server = Get-DrumServer
  $probe = [System.Net.Sockets.TcpClient]::new()
  try { $probe.Connect('127.0.0.1',$Port); $portBusy = $true } catch { $portBusy = $false } finally { $probe.Dispose() }
  if ($portBusy -and ($server.app -ne 'DrumTrainerWindows' -or $server.rootID -ne $rootID)) {
    throw 'An older DrumTrainer copy or another app is using the practice address. Close its launcher, then run this shortcut again. Your saved practice data stays in the browser.'
  }
  if (-not $portBusy) {
    $launcher = Join-Path $PSScriptRoot 'Start-DrumTrainer.ps1'
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $launcher + '" -NoBrowser -Port ' + $Port
    $child = Start-Process powershell.exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
      $server = Get-DrumServer
      if ($server.app -eq 'DrumTrainerWindows' -and $server.rootID -eq $rootID) { break }
      if ($child.HasExited) { throw 'The practice server could not start. Run Start DrumTrainer.cmd to see the launcher error.' }
      Start-Sleep -Milliseconds 200
    }
    if ($server.app -ne 'DrumTrainerWindows' -or $server.rootID -ne $rootID) { throw 'The practice server did not become ready.' }
  }
  if (-not $NoBrowser) {
    $candidates = @(
      "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
      "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
      "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe",
      "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
      "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
      "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    $browser = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($browser) { Start-Process -FilePath $browser -ArgumentList "--app=$url" }
    else { Start-Process $url }
  }
  Write-Host 'DrumTrainer is ready. Ctrl+R in the app reloads the latest code.'
} catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }
