param([string]$Destination = [Environment]::GetFolderPath('Desktop'))
$ErrorActionPreference = 'Stop'
$launcher = Join-Path $PSScriptRoot 'Run latest DrumTrainer.cmd'
if (-not (Test-Path -LiteralPath $launcher)) { throw 'Keep the shortcut creator in the DrumTrainer folder.' }
$shell = New-Object -ComObject WScript.Shell
try {
  $shortcut = $shell.CreateShortcut((Join-Path $Destination 'DrumTrainer.lnk'))
  $shortcut.TargetPath = $launcher
  $shortcut.WorkingDirectory = $PSScriptRoot
  $shortcut.Description = 'Run the latest DrumTrainer code. Ctrl+R reloads changes in the app.'
  $shortcut.Hotkey = 'CTRL+ALT+R'
  $shortcut.WindowStyle = 7
  $shortcut.Save()
  Write-Host "Created $Destination\DrumTrainer.lnk (Ctrl+Alt+R)."
} finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
