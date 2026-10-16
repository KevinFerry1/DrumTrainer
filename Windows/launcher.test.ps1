$ErrorActionPreference = 'Stop'
$launcher = Join-Path $PSScriptRoot 'Start-DrumTrainer.ps1'
$parseTokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
$probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$probe.Start()
$port = $probe.LocalEndpoint.Port
$probe.Stop()
$testID = [Guid]::NewGuid().ToString()
$stdout = Join-Path ([System.IO.Path]::GetTempPath()) "DrumTrainer-$testID.out.log"
$stderr = Join-Path ([System.IO.Path]::GetTempPath()) "DrumTrainer-$testID.err.log"
$child = $null
try {
  $arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$launcher`" -NoBrowser -Port $port"
  $child = Start-Process powershell.exe -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  $url = "http://127.0.0.1:${port}"
  $ready = $false
  for ($i = 0; $i -lt 30; $i++) {
    try {
      $response = Invoke-WebRequest "$url/" -UseBasicParsing -TimeoutSec 2
      if ($response.StatusCode -eq 200) { $ready = $true; break }
    } catch { $lastRequestError = $_.Exception.Message; Start-Sleep -Milliseconds 250 }
    if ($child.HasExited) { throw "Launcher exited: $(Get-Content $stderr -Raw) $(Get-Content $stdout -Raw)" }
  }
  if (-not $ready) { throw "Local launcher did not become ready. Request: $lastRequestError. Output: $(Get-Content $stdout -Raw). Errors: $(Get-Content $stderr -Raw)" }
  if (-not $response.Content.Contains('DrumTrainer')) { throw 'Unexpected index document.' }
  foreach ($file in @('app.mjs','desktop-shell.mjs','core.mjs','native-scoring.mjs','audio-core.mjs','kick-worklet.mjs')) {
    $module = Invoke-WebRequest "$url/$file" -UseBasicParsing
    if ($module.StatusCode -ne 200 -or $module.Headers['Content-Type'] -notmatch 'text/javascript') { throw "Incorrect module response: $file" }
  }
  $head = Invoke-WebRequest "$url/index.html" -Method Head -UseBasicParsing
  if ($head.StatusCode -ne 200) { throw 'HEAD request failed.' }
  $info = (Invoke-WebRequest "$url/launcher.json" -UseBasicParsing).Content | ConvertFrom-Json
  if ($info.app -ne 'DrumTrainerWindows' -or $info.processID -ne $child.Id -or $info.rootID.Length -ne 64) { throw 'Launcher identity is invalid.' }
  $latest = Join-Path $PSScriptRoot 'Run-Latest.ps1'
  & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $latest -NoBrowser -Port $port
  if ($LASTEXITCODE -ne 0) { throw 'Run latest could not reuse the source server.' }
  $after = (Invoke-WebRequest "$url/launcher.json" -UseBasicParsing).Content | ConvertFrom-Json
  if ($after.processID -ne $info.processID) { throw 'Run latest started a duplicate server.' }
  $shortcutScript = Join-Path $PSScriptRoot 'New-Shortcut.ps1'
  $shortcutFolder = Join-Path ([System.IO.Path]::GetTempPath()) "DrumTrainer-shortcut-$testID"
  [void](New-Item -ItemType Directory -Path $shortcutFolder)
  try {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $shortcutScript -Destination $shortcutFolder
    if ($LASTEXITCODE -ne 0) { throw 'Desktop shortcut creation failed.' }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path $shortcutFolder 'DrumTrainer.lnk'))
    if ($shortcut.TargetPath -ne (Join-Path $PSScriptRoot 'Run latest DrumTrainer.cmd') -or $shortcut.Hotkey -notin @('Ctrl+Alt+R','Alt+Ctrl+R')) { throw 'Shortcut does not launch the source app with Ctrl+Alt+R.' }
  } finally {
    Remove-Item -LiteralPath (Join-Path $shortcutFolder 'DrumTrainer.lnk') -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $shortcutFolder -ErrorAction SilentlyContinue
  }
  # A fresh launch must return promptly while keeping its own server alive.
  $freshProbe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $freshProbe.Start(); $freshPort = $freshProbe.LocalEndpoint.Port; $freshProbe.Stop()
  $freshInfo = $null
  try {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $latest -NoBrowser -Port $freshPort
    if ($LASTEXITCODE -ne 0) { throw 'Run latest could not start a fresh server.' }
    $freshInfo = (Invoke-WebRequest "http://127.0.0.1:$freshPort/launcher.json" -UseBasicParsing).Content | ConvertFrom-Json
    if ($freshInfo.app -ne 'DrumTrainerWindows' -or $freshInfo.rootID -ne $info.rootID) { throw 'Fresh source server identity is invalid.' }
  } finally {
    if ($freshInfo.app -eq 'DrumTrainerWindows' -and $freshInfo.rootID -eq $info.rootID) { Stop-Process -Id $freshInfo.processID -ErrorAction SilentlyContinue }
  }
  # An occupied address must be left alone, rather than launching a stale copy.
  $foreignServer = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $foreignServer.Start()
  try {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $latest -NoBrowser -Port $foreignServer.LocalEndpoint.Port
    if ($LASTEXITCODE -ne 1 -or -not $foreignServer.Server.IsBound) { throw 'An unrelated server was not preserved.' }
  } finally { $foreignServer.Stop() }
  foreach ($route in @('/Mac-practice-backup.json','/README.md','/../README.md','/Mac-recordings/take.m4a')) {
    $status = 0
    try { $result = Invoke-WebRequest "$url$route" -UseBasicParsing; $status = [int]$result.StatusCode }
    catch { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } else { throw } }
    if ($status -ne 404) { throw "Non-app file is exposed by the local server: $route ($status)" }
  }
  Write-Host 'Windows PowerShell launcher, JavaScript MIME types, HEAD and private-file isolation passed.'
} finally {
  if ($child -and -not $child.HasExited) { Stop-Process -Id $child.Id -Force }
  Remove-Item $stdout, $stderr -ErrorAction SilentlyContinue
}
