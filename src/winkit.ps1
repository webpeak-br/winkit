<#
.SYNOPSIS
  Linha de comando do WinKit.
.EXAMPLE
  winkit run -Profile Server-Base -DryRun
  winkit run -Module Health
  winkit run -Module Updates -Mode invoke
  winkit undo -RunId 20261124-101500-a1b2c3
  winkit report            (última execução)
  winkit list              (módulos e perfis)
  winkit runs              (execuções anteriores)
  winkit env               (ambiente detectado)
#>
param(
    [Parameter(Position = 0)][ValidateSet('run', 'undo', 'report', 'list', 'env', 'runs', 'help')][string]$Command = 'help',
    [Alias('Profile')][string]$ProfileName,
    [string[]]$Module = @(),
    [ValidateSet('test', 'invoke', 'report')][string]$Mode = 'test',
    [string]$RunId,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WinKit\WinKit.psd1') -Force
# Pelo WinKit.cmd (-File) uma lista chega como "A,B": separa de novo.
$Module = @($Module | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

$needsElevation = ($Command -eq 'undo') -or ($Command -eq 'run' -and $Mode -eq 'invoke' -and -not $DryRun) -or ($Command -eq 'run' -and $ProfileName -and -not $DryRun)
if ($needsElevation -and -not (Test-WinKitAdmin)) {
    Write-Host 'Pedindo permissão de administrador…' -ForegroundColor Yellow
    # Repassa os mesmos parâmetros para a janela elevada.
    $fwd = @($Command)
    foreach ($k in $PSBoundParameters.Keys) {
        if ($k -eq 'Command') { continue }
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $fwd += "-$k" } } else { $fwd += "-$k"; $fwd += (@($v) -join ',') }
    }
    Start-WinKitElevated -ScriptPath $PSCommandPath -Arguments $fwd
    exit
}

switch ($Command) {
    'run' {
        $r = Invoke-WinKit -ProfileName $ProfileName -Module $Module -Mode $Mode -DryRun:$DryRun -Force:$Force
        if ($Json) { $r | ConvertTo-Json -Depth 8 } else { Write-Host "`nExecução $($r.RunId) · geral: $($r.Overall) · alterações: $($r.Changes)$(if ($r.RebootRequired) { ' · REINÍCIO NECESSÁRIO' })" }
        if ($r.Changes) { Write-Host "Para desfazer: winkit undo -RunId $($r.RunId)" -ForegroundColor DarkGray }
        # Código de saída para automação: 0 ok, 1 atenção, 2 crítico.
        exit @{ ok = 0; warn = 1; crit = 2 }[$r.Overall]
    }
    'undo' { if (-not $RunId) { throw 'Informe -RunId (veja winkit runs).' }; Undo-WinKitRun -RunId $RunId }
    'report' {
        $last = if ($RunId) { Get-WinKitRunList | Where-Object id -eq $RunId } else { @(Get-WinKitRunList)[0] }
        if (-not $last) { Write-Host 'Nenhuma execução registrada.'; break }
        $html = Join-Path (Join-Path (Join-Path (Get-WinKitDataRoot) 'runs') $last.id) 'report.html'
        if (Test-Path $html) { Write-Host $html; if (-not $Json) { Start-Process $html } } else { Write-Host 'Execução sem relatório.' }
    }
    'list' {
        $info = Get-WinKitEnvironment
        Write-Host "Módulos para $($info.Edition):" -ForegroundColor Cyan
        Get-WinKitModule -Edition $info.Edition -Build $info.Build | Format-Table @{ n = 'Módulo'; e = 'id' }, @{ n = 'Risco'; e = 'risk' }, @{ n = 'Descrição'; e = 'description' } -AutoSize
        Write-Host 'Perfis:' -ForegroundColor Cyan
        Get-WinKitProfile | Format-Table Id, Description -AutoSize
    }
    'runs' { Get-WinKitRunList | Format-Table id, profile, dryRun, changes, reboot -AutoSize }
    'env' { if ($Json) { Get-WinKitEnvironment | ConvertTo-Json -Depth 5 } else { Get-WinKitEnvironment | Format-List } }
    default { Get-Help $PSCommandPath -Examples }
}
