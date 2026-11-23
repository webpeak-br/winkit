# Log: console colorido + log.txt da execução em andamento.

function Write-WinKitLog {
    param([Parameter(Mandatory, Position = 0)][string]$Message, [ValidateSet('Info', 'Ok', 'Warn', 'Error', 'Debug')][string]$Level = 'Info')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level.ToUpper(), $Message
    $run = Get-WinKitRun
    if ($run) { Add-Content -Path (Join-Path $run.Dir 'log.txt') -Value $line -Encoding UTF8 }
    if ($Level -eq 'Debug' -and -not $env:WINKIT_DEBUG) { return }
    $color = @{ Info = 'Gray'; Ok = 'Green'; Warn = 'Yellow'; Error = 'Red'; Debug = 'DarkGray' }[$Level]
    if (-not $env:WINKIT_QUIET) { Write-Host $line -ForegroundColor $color }
}
