# Diagnóstico e saúde do Windows. Test-WinKitHealth só lê; Invoke-WinKitHealth repara a imagem (DISM e SFC).
# Cada verificação devolve resultados padrão (New-WinKitResult) com um código estável, igual ao do painel Linux Control.
# Nada aqui lê texto localizado: só propriedades de CIM, códigos de evento e códigos de saída.

$script:Limits = @{ DiskWarn = 80; DiskCrit = 90; MemWarn = 90; UptimeWarnDays = 60; UpdateWarnDays = 45; SigWarnDays = 3; WearWarn = 90 }

# Eventos do log System que indicam falha de disco ou de sistema de arquivos (provedor e id, independentes do idioma).
$script:DiskEvents = @(
    @{ Provider = 'disk'; Id = 7 }, @{ Provider = 'disk'; Id = 51 }, @{ Provider = 'disk'; Id = 153 },
    @{ Provider = 'Ntfs'; Id = 55 }, @{ Provider = 'Ntfs'; Id = 98 }, @{ Provider = 'Microsoft-Windows-Ntfs'; Id = 55 },
    @{ Provider = 'volmgr'; Id = 161 }, @{ Provider = 'stornvme'; Id = 11 }, @{ Provider = 'storahci'; Id = 129 }
)

function Get-HealthUptime {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $days = [math]::Floor(((Get-Date) - $os.LastBootUpTime).TotalDays)
    if ($days -ge $script:Limits.UptimeWarnDays) {
        return New-WinKitResult -Check 'uptime' -Status warn -Code 'uptime_long' -Message "Ligado há $days dias sem reiniciar." -Fix 'Reinicie numa janela de manutenção para aplicar atualizações.'
    }
    New-WinKitResult -Check 'uptime' -Status ok -Message "Ligado há $days dia(s)."
}

function Test-HealthPendingReboot {
    $reasons = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'atualização de componentes' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'Windows Update' }
    $pfro = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($pfro -and $pfro.PendingFileRenameOperations) { $reasons += 'arquivos aguardando substituição' }
    if ($reasons.Count) {
        return New-WinKitResult -Check 'reboot' -Status warn -Code 'reboot_required' -Message "Reinício pendente ($($reasons -join ', '))." -Fix 'Reinicie para concluir.'
    }
    New-WinKitResult -Check 'reboot' -Status ok -Message 'Nenhum reinício pendente.'
}

function Test-HealthDiskSpace {
    # DriveType 3 = disco local fixo
    foreach ($v in Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3') {
        if (-not $v.Size) { continue }
        $pct = [math]::Round(100 - ($v.FreeSpace / $v.Size * 100))
        $free = [math]::Round($v.FreeSpace / 1GB, 1)
        $status = if ($pct -ge $script:Limits.DiskCrit) { 'crit' } elseif ($pct -ge $script:Limits.DiskWarn) { 'warn' } else { 'ok' }
        New-WinKitResult -Check "disk_space.$($v.DeviceID)" -Status $status -Code $(if ($status -ne 'ok') { 'disk_full' } else { '' }) `
            -Message "Disco $($v.DeviceID) com $pct% de uso ($free GB livres)." -Detail @{ drive = $v.DeviceID; pct = $pct; freeGB = $free } `
            -Fix $(if ($status -ne 'ok') { 'Rode a limpeza (módulo Cleanup) ou libere espaço.' } else { '' })
    }
}

# Contadores de confiabilidade de um disco (isolado para os testes simularem sem um disco de verdade).
function Get-HealthReliability {
    param($Disk)
    $Disk | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
}

# Saúde física: Storage (Get-PhysicalDisk + contadores de confiabilidade) e o aviso de falha do SMART (root\wmi).
function Test-HealthPhysicalDisk {
    $disks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
    if (-not $disks.Count) { return New-WinKitResult -Check 'disk_health' -Status info -Message 'Não foi possível ler os discos físicos (máquina virtual ou sem acesso).' }
    $predict = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue | Where-Object PredictFailure)
    foreach ($d in $disks) {
        $name = "Disco $($d.DeviceId) ($($d.FriendlyName))"
        $rc = Get-HealthReliability -Disk $d
        $detail = @{ model = $d.FriendlyName; media = "$($d.MediaType)"; bus = "$($d.BusType)"; health = "$($d.HealthStatus)"
            temperature = $rc.Temperature; wear = $rc.Wear; readErrorsUncorrected = $rc.ReadErrorsUncorrected; powerOnHours = $rc.PowerOnHours }
        if ("$($d.HealthStatus)" -eq 'Unhealthy' -or $predict.Count) {
            New-WinKitResult -Check "disk_health.$($d.DeviceId)" -Status crit -Code 'disk_smart' -Message "$name com falha prevista pelo próprio disco." -Detail $detail -Fix 'Faça backup agora e troque o disco.'
        } elseif ($rc.ReadErrorsUncorrected -gt 0) {
            New-WinKitResult -Check "disk_health.$($d.DeviceId)" -Status crit -Code 'disk_sectors' -Message "$name com $($rc.ReadErrorsUncorrected) erro(s) de leitura não corrigidos." -Detail $detail -Fix 'Faça backup e planeje a troca do disco.'
        } elseif ("$($d.HealthStatus)" -eq 'Warning') {
            New-WinKitResult -Check "disk_health.$($d.DeviceId)" -Status warn -Code 'disk_smart' -Message "$name em estado de atenção." -Detail $detail -Fix 'Acompanhe; rode o relatório completo de disco.'
        } elseif ($rc.Wear -ge $script:Limits.WearWarn) {
            New-WinKitResult -Check "disk_health.$($d.DeviceId)" -Status warn -Code 'disk_wear' -Message "$name com $($rc.Wear)% da vida útil consumida." -Detail $detail -Fix 'Planeje a troca do SSD.'
        } else {
            New-WinKitResult -Check "disk_health.$($d.DeviceId)" -Status ok -Message "$name saudável$(if ($rc.Temperature) { ", $($rc.Temperature) °C" })." -Detail $detail
        }
    }
}

function Test-HealthEventLog {
    param([int]$Hours)
    $since = (Get-Date).AddHours(-$Hours)
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $since } -MaxEvents 2000 -ErrorAction SilentlyContinue)
    $diskErr = @($events | Where-Object { $e = $_; @($script:DiskEvents | Where-Object { $_.Provider -eq $e.ProviderName -and $_.Id -eq $e.Id }).Count })
    if ($diskErr.Count) {
        New-WinKitResult -Check 'eventlog.disk' -Status crit -Code 'disk_io_errors' -Message "$($diskErr.Count) erro(s) de disco ou sistema de arquivos nas últimas $Hours h." `
            -Detail @($diskErr | Select-Object -First 20 | ForEach-Object { @{ time = $_.TimeCreated.ToString('o'); provider = $_.ProviderName; id = $_.Id } }) `
            -Fix 'Rode o relatório de disco; se o disco tiver setores ruins, faça backup e troque.'
    }
    # Kernel-Power 41: o sistema reiniciou sem desligar direito (queda de energia, travamento, tela azul).
    $power = @($events | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $_.Id -eq 41 })
    if ($power.Count) {
        New-WinKitResult -Check 'eventlog.power' -Status warn -Code 'unexpected_shutdown' -Message "$($power.Count) desligamento(s) inesperado(s) nas últimas $Hours h." `
            -Fix 'Verifique energia, temperatura e telas azuis.'
    }
    $crit = @($events | Where-Object Level -eq 1)
    $top = $events | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 5 |
        ForEach-Object { @{ source = $_.Name; count = $_.Count } }
    $status = if ($crit.Count) { 'warn' } else { 'ok' }
    New-WinKitResult -Check 'eventlog.system' -Status $status -Code $(if ($crit.Count) { 'eventlog_critical' } else { '' }) `
        -Message "$($events.Count) erro(s) e $($crit.Count) evento(s) crítico(s) no log do sistema nas últimas $Hours h." -Detail @{ top = @($top) }
}

# Telas azuis: arquivos de minidump e o evento 1001 (BugCheck) com o código de parada.
function Test-HealthBsod {
    param([int]$Days)
    $since = (Get-Date).AddDays(-$Days)
    $dir = Join-Path $env:SystemRoot 'Minidump'
    $dumps = @(Get-ChildItem -Path $dir -Filter *.dmp -ErrorAction SilentlyContinue | Where-Object LastWriteTime -ge $since)
    $bug = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since } -ErrorAction SilentlyContinue)
    $codes = @($bug | ForEach-Object { if ($_.Properties.Count) { "$($_.Properties[0].Value)" } } | Where-Object { $_ })
    $count = [math]::Max($dumps.Count, $bug.Count)
    if (-not $count) { return New-WinKitResult -Check 'bsod' -Status ok -Message "Nenhuma tela azul nos últimos $Days dias." }
    $status = if ($count -ge 3) { 'crit' } else { 'warn' }
    New-WinKitResult -Check 'bsod' -Status $status -Code 'bsod' -Message "$count tela(s) azul(is) nos últimos $Days dias." `
        -Detail @{ dumps = @($dumps | ForEach-Object Name); bugchecks = $codes } -Fix 'Rode a análise de minidump (causa provável e driver envolvido).'
}

function Test-HealthDefender {
    $mp = $null
    try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch { $mp = $null }
    $other = @()
    if ((Get-WinKitEnvironment).Edition -eq 'Desktop') {
        $other = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue | Where-Object displayName -notmatch 'Defender')
    }
    if (-not $mp -or -not $mp.AntivirusEnabled) {
        if ($other.Count) { return New-WinKitResult -Check 'antivirus' -Status ok -Message "Antivírus ativo: $($other[0].displayName)." }
        return New-WinKitResult -Check 'antivirus' -Status crit -Code 'antivirus_off' -Message 'Nenhum antivírus ativo.' -Fix 'Ative o Microsoft Defender.'
    }
    if (-not $mp.RealTimeProtectionEnabled) {
        return New-WinKitResult -Check 'antivirus' -Status warn -Code 'antivirus_realtime_off' -Message 'Defender sem proteção em tempo real.' -Fix 'Ligue a proteção em tempo real.'
    }
    if ($mp.AntivirusSignatureAge -gt $script:Limits.SigWarnDays) {
        return New-WinKitResult -Check 'antivirus' -Status warn -Code 'antivirus_outdated' -Message "Assinaturas do Defender com $($mp.AntivirusSignatureAge) dias." -Fix 'Atualize o Defender (Update-MpSignature).'
    }
    New-WinKitResult -Check 'antivirus' -Status ok -Message 'Defender ativo, em tempo real e atualizado.'
}

function Test-HealthFirewall {
    $off = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Enabled } | ForEach-Object Name)
    if ($off.Count) { return New-WinKitResult -Check 'firewall' -Status warn -Code 'firewall_off' -Message "Firewall desligado nos perfis: $($off -join ', ')." -Fix 'Ligue o firewall do Windows.' }
    New-WinKitResult -Check 'firewall' -Status ok -Message 'Firewall ligado em todos os perfis.'
}

# Dispositivos com problema. Código 28 = sem driver; os demais são driver com erro ou desativado.
function Test-HealthDevices {
    $bad = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter 'ConfigManagerErrorCode<>0' -ErrorAction SilentlyContinue |
        Where-Object { $_.ConfigManagerErrorCode -ne 22 })   # 22 = desativado de propósito
    if (-not $bad.Count) { return New-WinKitResult -Check 'devices' -Status ok -Message 'Todos os dispositivos com driver funcionando.' }
    $missing = @($bad | Where-Object ConfigManagerErrorCode -eq 28)
    $detail = @($bad | ForEach-Object { @{ name = $_.Name; code = $_.ConfigManagerErrorCode; hwid = @($_.HardwareID | Select-Object -First 3); class = $_.PNPClass } })
    New-WinKitResult -Check 'devices' -Status warn -Code 'drivers_missing' -Detail $detail `
        -Message "$($bad.Count) dispositivo(s) com problema$(if ($missing.Count) { ", $($missing.Count) sem driver" })." -Fix 'Rode o módulo Drivers para localizar e instalar.'
}

function Test-HealthUpdates {
    $last = Get-HotFix -ErrorAction SilentlyContinue | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1
    if (-not $last) { return New-WinKitResult -Check 'updates' -Status info -Message 'Não foi possível ler o histórico de atualizações.' }
    $days = [math]::Floor(((Get-Date) - $last.InstalledOn).TotalDays)
    if ($days -gt $script:Limits.UpdateWarnDays) {
        return New-WinKitResult -Check 'updates' -Status warn -Code 'updates_stale' -Message "Última atualização instalada há $days dias ($($last.HotFixID))." -Fix 'Rode o módulo Updates.'
    }
    New-WinKitResult -Check 'updates' -Status ok -Message "Última atualização há $days dia(s) ($($last.HotFixID))."
}

function Test-HealthMemory {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $pct = [math]::Round(100 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize * 100))
    if ($pct -ge $script:Limits.MemWarn) { return New-WinKitResult -Check 'memory' -Status warn -Code 'mem_high' -Message "Memória em $pct%." -Fix 'Veja os processos que mais consomem.' }
    New-WinKitResult -Check 'memory' -Status ok -Message "Memória em $pct%."
}

function Test-HealthImage {
    if (-not (Test-WinKitAdmin)) { return New-WinKitResult -Check 'image' -Status info -Message 'Integridade do Windows não verificada (precisa de administrador).' }
    $r = Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop
    switch ("$($r.ImageHealthState)") {
        'Healthy' { New-WinKitResult -Check 'image' -Status ok -Message 'Imagem do Windows íntegra.' }
        'Repairable' { New-WinKitResult -Check 'image' -Status warn -Code 'image_corrupt' -Message 'Arquivos do Windows corrompidos (reparável).' -Fix 'Rode o reparo: winkit run -Module Health -Mode invoke' }
        default { New-WinKitResult -Check 'image' -Status crit -Code 'image_corrupt' -Message "Imagem do Windows em estado $($r.ImageHealthState)." -Fix 'Reparo com mídia de instalação ou reinstalação in-place.' }
    }
}

function Test-HealthTemperature {
    $zones = @(Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue)
    if (-not $zones.Count) { return }   # muitos computadores não expõem; sem dado não vira problema
    $max = [math]::Round((($zones | Measure-Object CurrentTemperature -Maximum).Maximum / 10) - 273.15)
    if ($max -le 0 -or $max -gt 150) { return }   # leitura inválida (comum em VM)
    $status = if ($max -ge 90) { 'crit' } elseif ($max -ge 80) { 'warn' } else { 'ok' }
    New-WinKitResult -Check 'temperature' -Status $status -Code $(if ($status -ne 'ok') { 'temperature_high' } else { '' }) -Message "Temperatura máxima das zonas térmicas: $max °C."
}

function Test-WinKitHealth {
    [CmdletBinding()]
    param([int]$EventLogHours = 72, [int]$BsodDays = 30, [bool]$CheckImageHealth = $true)
    $checks = [ordered]@{
        'Tempo ligado' = { Get-HealthUptime }
        'Reinício pendente' = { Test-HealthPendingReboot }
        'Espaço em disco' = { Test-HealthDiskSpace }
        'Saúde dos discos' = { Test-HealthPhysicalDisk }
        'Event Log' = { Test-HealthEventLog -Hours $EventLogHours }
        'Telas azuis' = { Test-HealthBsod -Days $BsodDays }
        'Antivírus' = { Test-HealthDefender }
        'Firewall' = { Test-HealthFirewall }
        'Dispositivos' = { Test-HealthDevices }
        'Atualizações' = { Test-HealthUpdates }
        'Memória' = { Test-HealthMemory }
        'Temperatura' = { Test-HealthTemperature }
    }
    if ($CheckImageHealth) { $checks['Integridade do Windows'] = { Test-HealthImage } }
    foreach ($name in $checks.Keys) {
        try { & $checks[$name] }
        catch { New-WinKitResult -Check "erro.$name" -Status info -Message "Verificação '$name' não pôde ser feita: $($_.Exception.Message)" }
    }
}

# Reparo da imagem do Windows: DISM /RestoreHealth e depois SFC. Só códigos de saída decidem o resultado.
function Invoke-WinKitHealth {
    [CmdletBinding()]
    param([bool]$RunDism = $true, [bool]$RunSfc = $true)
    Assert-WinKitAdmin
    $sys = Join-Path $env:SystemRoot 'System32'
    if ($RunDism) {
        $r = Invoke-WinKitProcess -FilePath (Join-Path $sys 'dism.exe') -ArgumentList '/Online', '/Cleanup-Image', '/RestoreHealth', '/NoRestart' -TimeoutSeconds 5400
        if ($r.DryRun) { New-WinKitResult -Check 'repair.dism' -Status info -Message 'DryRun: DISM /RestoreHealth seria executado.' }
        elseif ($r.Success) { New-WinKitResult -Check 'repair.dism' -Status ok -Message 'DISM /RestoreHealth concluído.' }
        else { New-WinKitResult -Check 'repair.dism' -Status crit -Code 'image_corrupt' -Message "DISM /RestoreHealth falhou (código $($r.ExitCode))." -Fix 'Use uma mídia de instalação como fonte (/Source).' }
    }
    if ($RunSfc) {
        $r = Invoke-WinKitProcess -FilePath (Join-Path $sys 'sfc.exe') -ArgumentList '/scannow' -TimeoutSeconds 5400
        if ($r.DryRun) { New-WinKitResult -Check 'repair.sfc' -Status info -Message 'DryRun: sfc /scannow seria executado.' }
        elseif ($r.Success) { New-WinKitResult -Check 'repair.sfc' -Status ok -Message 'SFC concluído (detalhes em %windir%\Logs\CBS\CBS.log).' }
        else { New-WinKitResult -Check 'repair.sfc' -Status warn -Code 'image_corrupt' -Message "SFC terminou com código $($r.ExitCode)." -Fix 'Veja %windir%\Logs\CBS\CBS.log.' }
    }
}

Export-ModuleMember -Function Test-WinKitHealth, Invoke-WinKitHealth
