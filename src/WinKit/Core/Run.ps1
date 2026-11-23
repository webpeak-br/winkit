# Execução: cada "winkit run" ganha um RunId e uma pasta com log, estado antes/depois, diário de alterações e undo.
# %ProgramData%\WinKit\runs\<RunId>\  (log.txt, journal.json, before.json, after.json, report.json, report.html)

$script:WinKitRun = $null

function Get-WinKitDataRoot {
    $base = if ($env:WINKIT_DATA) { $env:WINKIT_DATA } elseif ($env:ProgramData) { Join-Path $env:ProgramData 'WinKit' } else { Join-Path ([IO.Path]::GetTempPath()) 'WinKit' }
    if (-not (Test-Path $base)) { New-Item -ItemType Directory -Path $base -Force | Out-Null }
    return $base
}

function New-WinKitRun {
    param([string]$ProfileName = '', [string[]]$Modules = @(), [switch]$DryRun)
    $id = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $dir = Join-Path (Join-Path (Get-WinKitDataRoot) 'runs') $id
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $script:WinKitRun = [pscustomobject]@{
        Id       = $id
        Dir      = $dir
        Started  = (Get-Date).ToString('o')
        Profile  = $ProfileName
        Modules  = $Modules
        DryRun   = [bool]$DryRun
        Journal  = New-Object System.Collections.ArrayList
        Results  = New-Object System.Collections.ArrayList
        Reboot   = $false
    }
    Write-WinKitLog "Execução $id$(if ($DryRun) { ' (DryRun: nada será alterado)' })"
    return $script:WinKitRun
}

function Get-WinKitRun { return $script:WinKitRun }

function Complete-WinKitRun {
    $run = $script:WinKitRun
    if (-not $run) { return }
    Save-WinKitJournal
    $meta = [ordered]@{ id = $run.Id; started = $run.Started; finished = (Get-Date).ToString('o'); profile = $run.Profile
        modules = $run.Modules; dryRun = $run.DryRun; reboot = $run.Reboot; changes = $run.Journal.Count }
    $meta | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $run.Dir 'run.json') -Encoding UTF8
    Write-WinKitLog "Execução $($run.Id) concluída: $($run.Journal.Count) alteração(ões) registradas$(if ($run.Reboot) { '; reinício necessário' })."
    $script:WinKitRun = $null
}

function Get-WinKitRunList {
    $root = Join-Path (Get-WinKitDataRoot) 'runs'
    if (-not (Test-Path $root)) { return @() }
    Get-ChildItem -Path $root -Directory | Sort-Object Name -Descending | ForEach-Object {
        $f = Join-Path $_.FullName 'run.json'
        if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json }
    }
}
