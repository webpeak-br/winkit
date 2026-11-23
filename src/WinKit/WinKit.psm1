# WinKit: prepara, otimiza, protege e diagnostica Windows (Desktop e Server). Carrega o Core e expõe os comandos.

foreach ($f in 'Log', 'Run', 'Environment', 'Journal', 'Exec', 'Download', 'Plugins', 'Profiles', 'Report') {
    . (Join-Path $PSScriptRoot "Core\$f.ps1")
}

# Roda um perfil ou uma lista de módulos. Diagnóstico (test) sempre vem antes; com -DryRun nada é alterado.
function Invoke-WinKit {
    [CmdletBinding()]
    param(
        [string]$ProfileName,
        [string[]]$Module = @(),
        [ValidateSet('test', 'invoke', 'report')][string]$Mode = 'test',
        [switch]$DryRun,
        [switch]$Force,
        [switch]$NoReport
    )
    if (-not $ProfileName -and -not $Module.Count) { throw 'Informe -ProfileName ou -Module.' }
    $envInfo = Get-WinKitEnvironment
    $steps = if ($ProfileName) {
        $p = Get-WinKitProfile -Name $ProfileName
        if ($p.Platforms.Count -and $p.Platforms -notcontains $envInfo.Edition) { throw "O perfil $ProfileName não se aplica a $($envInfo.Edition)." }
        $p.Steps
    } else {
        $Module | ForEach-Object { [pscustomobject]@{ module = $_; mode = $Mode; params = $null } }
    }
    $needsAdmin = @($steps | Where-Object { $_.mode -eq 'invoke' }).Count -gt 0
    if ($needsAdmin -and -not $DryRun) { Assert-WinKitAdmin }

    $run = New-WinKitRun -ProfileName $ProfileName -Modules @($steps | ForEach-Object module) -DryRun:$DryRun
    Write-WinKitLog $envInfo.Summary
    $envInfo | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $run.Dir 'environment.json') -Encoding UTF8
    try {
        if ($needsAdmin -and -not $DryRun -and $envInfo.Edition -eq 'Desktop') { New-WinKitRestorePoint -Description "WinKit $($run.Id)" }
        foreach ($s in $steps) {
            try {
                [void](Invoke-WinKitModule -Id $s.module -Mode $s.mode -Params (ConvertTo-WinKitHashtable $s.params) -Force:$Force)
            } catch {
                Write-WinKitLog "Etapa $($s.module)/$($s.mode) falhou: $($_.Exception.Message)" -Level Error
                [void]$run.Results.Add((New-WinKitResult -Check "$($s.module).erro" -Status crit -Message "Falha ao executar: $($_.Exception.Message)" |
                    Add-Member -NotePropertyName Module -NotePropertyValue $s.module -PassThru))
            }
        }
        $results = @($run.Results)
        if (-not $NoReport) {
            Write-WinKitReportConsole -Results $results
            $rep = Export-WinKitReport -Results $results -Environment $envInfo -Dir $run.Dir
            Write-WinKitLog "Relatório: $($rep.Html)"
        }
        [pscustomobject]@{ RunId = $run.Id; Dir = $run.Dir; Overall = (Get-WinKitOverallStatus -Results $results); Changes = $run.Journal.Count
            RebootRequired = $run.Reboot; Results = $results }
    } finally {
        Complete-WinKitRun
    }
}

# Ponto de restauração (só Desktop). Falhar aqui não impede a execução, mas fica registrado.
function New-WinKitRestorePoint {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Description = 'WinKit')
    if (-not (Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue)) { return }
    if (-not $PSCmdlet.ShouldProcess('Sistema', 'criar ponto de restauração')) { return }
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description $Description -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-WinKitLog 'Ponto de restauração criado.' -Level Ok
    } catch {
        Write-WinKitLog "Não foi possível criar o ponto de restauração: $($_.Exception.Message)" -Level Warn
    }
}

Export-ModuleMember -Function *-WinKit*
