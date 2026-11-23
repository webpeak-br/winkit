# Windows Update pela API COM (Microsoft.Update.Session): resultado estruturado, sem ler texto traduzido.
# No WSUS a máquina usa o servidor configurado por política; nada aqui muda essa configuração.

$script:ResultCode = @{ 0 = 'não iniciado'; 1 = 'em andamento'; 2 = 'concluído'; 3 = 'concluído com erros'; 4 = 'falhou'; 5 = 'cancelado' }
$script:SecurityCategories = @('Security Updates', 'Critical Updates', 'Atualizações de Segurança', 'Atualizações Críticas')

function New-UpdateSession { New-Object -ComObject Microsoft.Update.Session }

# Converte um IUpdate em objeto simples (também usado pelos testes com objetos falsos).
function ConvertFrom-ComUpdate {
    param($Update)
    $cats = @($Update.Categories | ForEach-Object { $_.Name })
    # CategoryIDs estáveis: 0FA1201D… = Security Updates, E6CF1350… = Critical Updates, EBFC1FC5… = Drivers
    $catIds = @($Update.Categories | ForEach-Object { "$($_.CategoryID)".ToUpper() })
    $security = [bool]($catIds | Where-Object { $_ -like '0FA1201D*' -or $_ -like 'E6CF1350*' }) -or [bool]($cats | Where-Object { $script:SecurityCategories -contains $_ }) -or [bool]$Update.MsrcSeverity
    [pscustomobject]@{
        Id         = "$($Update.Identity.UpdateID)"
        Title      = "$($Update.Title)"
        KB         = (@($Update.KBArticleIDs) | ForEach-Object { "KB$_" }) -join ', '
        Severity   = "$($Update.MsrcSeverity)"
        Security   = $security
        Driver     = "$($Update.Type)" -eq '2' -or [bool]($catIds | Where-Object { $_ -like 'EBFC1FC5*' })
        SizeMB     = [math]::Round([double]$Update.MaxDownloadSize / 1MB, 1)
        Downloaded = [bool]$Update.IsDownloaded
        Reboot     = [bool]$Update.RebootRequired
    }
}

function Find-WinKitUpdate {
    param([bool]$IncludeDrivers = $false)
    $session = New-UpdateSession
    $searcher = $session.CreateUpdateSearcher()
    $criteria = if ($IncludeDrivers) { 'IsInstalled=0 and IsHidden=0' } else { "IsInstalled=0 and IsHidden=0 and Type='Software'" }
    Write-WinKitLog 'Procurando atualizações no Windows Update (pode levar alguns minutos)…'
    $result = $searcher.Search($criteria)
    $list = @()
    for ($i = 0; $i -lt $result.Updates.Count; $i++) { $list += , @{ com = $result.Updates.Item($i); info = (ConvertFrom-ComUpdate $result.Updates.Item($i)) } }
    return , $list
}

function Test-WinKitUpdate {
    [CmdletBinding()]
    param([bool]$IncludeDrivers = $false)
    $found = Find-WinKitUpdate -IncludeDrivers $IncludeDrivers
    $items = @($found | ForEach-Object { $_.info })
    $sec = @($items | Where-Object Security)
    if (-not $items.Count) { return New-WinKitResult -Check 'updates.pending' -Status ok -Message 'Windows atualizado: nenhuma atualização pendente.' }
    $status = if ($sec.Count) { 'warn' } else { 'info' }
    New-WinKitResult -Check 'updates.pending' -Status $status -Code $(if ($sec.Count) { 'updates_security' } else { 'updates_available' }) `
        -Message "$($items.Count) atualização(ões) pendente(s)$(if ($sec.Count) { ", $($sec.Count) de segurança" })." -Detail $items `
        -Fix 'Instale pela tela Atualizações ou: winkit run -Module Updates -Mode invoke'
}

function Invoke-WinKitUpdate {
    [CmdletBinding()]
    param([bool]$IncludeDrivers = $false, [bool]$OnlySecurity = $false, [string[]]$UpdateIds = @())
    Assert-WinKitAdmin
    $found = Find-WinKitUpdate -IncludeDrivers $IncludeDrivers
    $chosen = @($found | Where-Object { (-not $UpdateIds.Count -or $UpdateIds -contains $_.info.Id) -and (-not $OnlySecurity -or $_.info.Security) })
    if (-not $chosen.Count) { return New-WinKitResult -Check 'updates.install' -Status ok -Message 'Nada para instalar.' }
    if (Test-WinKitDryRun) {
        return New-WinKitResult -Check 'updates.install' -Status info -Message "DryRun: instalaria $($chosen.Count) atualização(ões)." -Detail @($chosen | ForEach-Object { $_.info })
    }
    $session = New-UpdateSession
    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $chosen) { if (-not $u.com.EulaAccepted) { $u.com.AcceptEula() }; [void]$coll.Add($u.com) }
    Write-WinKitLog "Baixando $($coll.Count) atualização(ões)…"
    $down = $session.CreateUpdateDownloader(); $down.Updates = $coll
    [void]$down.Download()
    Write-WinKitLog 'Instalando…'
    $inst = $session.CreateUpdateInstaller(); $inst.Updates = $coll
    $res = $inst.Install()
    $run = Get-WinKitRun
    if ($res.RebootRequired -and $run) { $run.Reboot = $true }
    $detail = for ($i = 0; $i -lt $coll.Count; $i++) {
        @{ title = $coll.Item($i).Title; result = $script:ResultCode[[int]$res.GetUpdateResult($i).ResultCode] }
    }
    $code = [int]$res.ResultCode
    $status = if ($code -eq 2) { 'ok' } elseif ($code -eq 3) { 'warn' } else { 'crit' }
    New-WinKitResult -Check 'updates.install' -Status $status -Message "Windows Update: $($script:ResultCode[$code]) ($($coll.Count) atualização(ões))$(if ($res.RebootRequired) { '. Reinicie para concluir.' })" `
        -Code $(if ($res.RebootRequired) { 'reboot_required' } else { '' }) -Detail @($detail)
}

Export-ModuleMember -Function Test-WinKitUpdate, Invoke-WinKitUpdate, ConvertFrom-ComUpdate
