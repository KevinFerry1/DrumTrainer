# Runs on Windows 10's included Windows PowerShell 5.1. No installation or administrator rights.
param([switch]$NoBrowser, [ValidateRange(1024,65535)][int]$Port = 8765)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
$files = @{
  '/' = @('index.html', 'text/html; charset=utf-8')
  '/index.html' = @('index.html', 'text/html; charset=utf-8')
  '/style.css' = @('style.css', 'text/css; charset=utf-8')
  '/app.mjs' = @('app.mjs', 'text/javascript; charset=utf-8')
  '/core.mjs' = @('core.mjs', 'text/javascript; charset=utf-8')
  '/native-scoring.mjs' = @('native-scoring.mjs', 'text/javascript; charset=utf-8')
  '/audio-core.mjs' = @('audio-core.mjs', 'text/javascript; charset=utf-8')
  '/midi.mjs' = @('midi.mjs', 'text/javascript; charset=utf-8')
  '/legacy-data.mjs' = @('legacy-data.mjs', 'text/javascript; charset=utf-8')
  '/practice-progress.mjs' = @('practice-progress.mjs', 'text/javascript; charset=utf-8')
  '/backup-state.mjs' = @('backup-state.mjs', 'text/javascript; charset=utf-8')
  '/kick-worklet.mjs' = @('kick-worklet.mjs', 'text/javascript; charset=utf-8')
}
try {
  $listener.Start()
  $url = "http://localhost:${port}/"
  $candidates = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
  )
  $browser = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if (-not $NoBrowser) {
    if ($browser) { Start-Process -FilePath $browser -ArgumentList "--app=$url" }
    else { Start-Process $url }
  }
  Write-Host ''
  Write-Host 'DrumTrainer is running. Keep this window open while practicing.' -ForegroundColor Green
  Write-Host "If the app did not open, open Microsoft Edge or Chrome and visit $url"
  Write-Host 'Close this window to stop the local server.'
  Write-Host 'Connect your USB MIDI kit and microphone, then grant browser permissions.'
  while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
      $client.ReceiveTimeout = 3000
      $client.SendTimeout = 3000
      $network = $client.GetStream()
      $reader = [System.IO.StreamReader]::new($network, [System.Text.Encoding]::ASCII, $false, 1024, $true)
      $request = $reader.ReadLine()
      if (-not $request) { continue }
      $headerBytes = 0
      do {
        $line = $reader.ReadLine()
        $headerBytes += $line.Length
        if ($headerBytes -gt 16384) { throw 'Request headers too large.' }
      } while ($line)
      $parts = $request.Split(' ')
      $method = $parts[0]
      $route = $parts[1].Split('?')[0]
      $status = '200 OK'
      $mime = 'text/plain; charset=utf-8'
      if ($method -ne 'GET' -and $method -ne 'HEAD') {
        $status = '405 Method Not Allowed'
        $body = [System.Text.Encoding]::UTF8.GetBytes('Only local static files are served.')
      } elseif ($files.ContainsKey($route)) {
        $entry = $files[$route]
        $mime = $entry[1]
        $body = [System.IO.File]::ReadAllBytes((Join-Path $root $entry[0]))
      } else {
        $status = '404 Not Found'
        $body = [System.Text.Encoding]::UTF8.GetBytes('Not found')
      }
      $headers = "HTTP/1.1 $status`r`nContent-Type: $mime`r`nContent-Length: $($body.Length)`r`nConnection: close`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`n`r`n"
      $bytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
      $network.Write($bytes, 0, $bytes.Length)
      if ($method -ne 'HEAD') { $network.Write($body, 0, $body.Length) }
      $network.Flush()
    } catch {
      # Browsers may cancel speculative requests. Continue serving subsequent requests.
      Write-Verbose $_.Exception.Message
      if ($NoBrowser) { Write-Host "Local request failed: $($_.Exception.Message)" }
    } finally {
      if ($reader) { $reader.Dispose(); $reader = $null }
      $client.Close()
    }
  }
} catch {
  Write-Host "Could not start DrumTrainer: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host 'If another DrumTrainer window is already running, close it and try again.'
  Write-Host 'If your computer blocks PowerShell, ask its administrator to allow this launcher.'
  exit 1
} finally {
  $listener.Stop()
}
