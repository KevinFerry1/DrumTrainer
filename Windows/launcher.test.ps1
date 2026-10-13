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
  $child = Start-Process powershell.exe -ArgumentList $arguments -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  $url = "http://localhost:${port}"
  $ready = $false
  for ($i = 0; $i -lt 30; $i++) {
    try {
      $response = Invoke-WebRequest "$url/" -UseBasicParsing -TimeoutSec 2
      if ($response.StatusCode -eq 200) { $ready = $true; break }
    } catch { Start-Sleep -Milliseconds 250 }
    if ($child.HasExited) { throw "Launcher exited: $(Get-Content $stderr -Raw) $(Get-Content $stdout -Raw)" }
  }
  if (-not $ready) { throw 'Local launcher did not become ready.' }
  if (-not $response.Content.Contains('DrumTrainer')) { throw 'Unexpected index document.' }
  foreach ($file in @('app.mjs','core.mjs','native-scoring.mjs','audio-core.mjs','kick-worklet.mjs')) {
    $module = Invoke-WebRequest "$url/$file" -UseBasicParsing
    if ($module.StatusCode -ne 200 -or $module.Headers['Content-Type'] -notmatch 'text/javascript') { throw "Incorrect module response: $file" }
  }
  $head = Invoke-WebRequest "$url/index.html" -Method Head -UseBasicParsing
  if ($head.StatusCode -ne 200) { throw 'HEAD request failed.' }
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
