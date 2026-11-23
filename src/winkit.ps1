<#
.SYNOPSIS
  Linha de comando do WinKit.
.EXAMPLE
  winkit                   (abre a janela; no Server Core, o menu)
  winkit menu              (menu de texto)
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
    [Parameter(Position = 0)][ValidateSet('auto', 'gui', 'menu', 'run', 'undo', 'report', 'list', 'env', 'runs', 'help')][string]$Command = 'auto',
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

$needsElevation = ($Command -in 'auto', 'gui', 'menu') -or ($Command -eq 'undo') -or ($Command -eq 'run' -and $Mode -eq 'invoke' -and -not $DryRun) -or ($Command -eq 'run' -and $ProfileName -and -not $DryRun)
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

# Abre a janela gráfica; se não der, explica o motivo e cai no menu de texto.
function Open-WinKitWindow {
    $why = ''
    if ((Get-WinKitEnvironment).Edition -eq 'ServerCore') { $why = 'o Windows Server Core não tem interface gráfica' }
    else {
        try { Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop }
        catch { $why = "o WPF não carregou ($($_.Exception.Message))" }
    }
    if (-not $why -and [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        # WPF precisa de STA; o Windows PowerShell 5.1 (sempre presente) abre assim.
        Write-Host 'Abrindo a janela do WinKit em outra janela do PowerShell…' -ForegroundColor Cyan
        Start-Process -FilePath "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList '-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", 'gui'
        return
    }
    if (-not $why) {
        try {
            . (Join-Path $PSScriptRoot 'WinKit\Gui\WinKitGui.ps1')
            Write-Host 'Abrindo a janela do WinKit… (esta janela mostra o log; pode deixar aberta)' -ForegroundColor Cyan
            Show-WinKitGui
            return
        } catch {
            $why = "a janela falhou: $($_.Exception.Message)"
            $log = Join-Path (Get-WinKitDataRoot) 'gui-error.log'
            "$(Get-Date -Format o) $($_ | Out-String) $($_.ScriptStackTrace)" | Add-Content -Path $log -Encoding UTF8
            Write-Host "Detalhes em $log" -ForegroundColor DarkGray
        }
    }
    Write-Host "Não foi possível abrir a janela: $why. Abrindo o menu de texto." -ForegroundColor Yellow
    Start-Sleep -Seconds 2
    Show-WinKitMenu
}

# Menu interativo (o que abre com "irm … | iex"): cada opção chama os mesmos comandos da linha de comando.
function Show-WinKitMenu {
    $info = Get-WinKitEnvironment
    while ($true) {
        Clear-Host
        Write-Host "WinKit $((Get-Module WinKit).Version) · $($info.Summary)" -ForegroundColor Cyan
        Write-Host "Edição: $($info.Edition)$(if ($info.IsVirtual) { ' · máquina virtual' })$(if ($info.DomainJoined) { " · domínio $($info.Domain)" })`n"
        Write-Host '  1  Diagnóstico completo (não altera nada)'
        Write-Host '  2  Reparar o Windows (DISM + SFC): mostra antes o que faria'
        Write-Host '  3  Abrir o último relatório'
        Write-Host '  4  Execuções anteriores e desfazer'
        Write-Host '  5  Módulos e perfis'
        Write-Host '  6  Abrir a janela do WinKit'
        Write-Host '  0  Sair'
        $op = Read-Host "`nEscolha"
        switch ($op) {
            '1' { $r = Invoke-WinKit -ProfileName 'Diagnostico'; Write-Host "`nGeral: $($r.Overall). Relatório: $(Join-Path $r.Dir 'report.html')"; Start-Process (Join-Path $r.Dir 'report.html') }
            '2' {
                Invoke-WinKit -ProfileName 'Reparo-Sistema' -DryRun -NoReport | Out-Null
                if ((Read-Host "`nExecutar de verdade? (S/N)") -match '^[sS]') { $r = Invoke-WinKit -ProfileName 'Reparo-Sistema'; Start-Process (Join-Path $r.Dir 'report.html') }
            }
            '3' { $last = @(Get-WinKitRunList)[0]; if ($last) { Start-Process (Join-Path (Join-Path (Join-Path (Get-WinKitDataRoot) 'runs') $last.id) 'report.html') } else { Write-Host 'Nenhuma execução ainda.' } }
            '4' {
                Get-WinKitRunList | Select-Object -First 15 | Format-Table id, profile, dryRun, changes, reboot -AutoSize | Out-Host
                $id = Read-Host 'RunId para desfazer (Enter volta)'
                if ($id) { Undo-WinKitRun -RunId $id | Format-List | Out-Host }
            }
            '5' { Get-WinKitModule -Edition $info.Edition -Build $info.Build | Format-Table id, risk, description -AutoSize | Out-Host; Get-WinKitProfile | Format-Table Id, Description -AutoSize | Out-Host }
            '6' { Open-WinKitWindow; continue }
            '0' { return }
            default { continue }
        }
        Read-Host "`nEnter para voltar ao menu" | Out-Null
    }
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
    'help' { Get-Help $PSCommandPath -Examples }
    'menu' { Show-WinKitMenu }
    default { Open-WinKitWindow }
}
