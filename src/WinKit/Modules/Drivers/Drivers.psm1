# Drivers para qualquer máquina: inventário, dispositivos com problema (com o código de hardware), drivers que o
# Windows Update oferece para este hardware e instalação com backup antes. Nada aqui lê texto traduzido:
# CIM, códigos de erro do Gerenciador de Dispositivos e a API COM do Windows Update.
# Nunca grava BIOS ou firmware.

Import-Module (Join-Path $PSScriptRoot '..\Updates\Updates.psm1') -Force -DisableNameChecking

# Códigos do Gerenciador de Dispositivos (ConfigManagerErrorCode) mais comuns.
$script:DeviceErrors = @{
    1 = 'configuração incorreta'; 3 = 'driver corrompido ou sem memória'; 10 = 'não consegue iniciar'; 12 = 'recursos insuficientes'
    14 = 'precisa reiniciar'; 18 = 'reinstalar o driver'; 19 = 'registro corrompido'; 21 = 'sendo removido'; 22 = 'desativado'
    24 = 'ausente ou sem driver'; 28 = 'driver não instalado'; 31 = 'driver não carregou'; 32 = 'serviço do driver desativado'
    37 = 'falha ao iniciar o driver'; 39 = 'driver corrompido ou ausente'; 43 = 'o dispositivo relatou um problema'; 45 = 'desconectado'
    48 = 'driver bloqueado por incompatibilidade'; 52 = 'assinatura do driver inválida'
}

# Páginas oficiais de drivers por fabricante (abertas no navegador quando o Windows Update não resolve).
function Get-WinKitVendorSupportUrl {
    param([string]$Manufacturer, [string]$BoardMaker, [string]$Board, [string]$Serial)
    $q = { param($s) [uri]::EscapeDataString("$s".Trim()) }
    $m = "$Manufacturer $BoardMaker"
    switch -Regex ($m) {
        'Gigabyte' { return "https://www.gigabyte.com/Search?kw=$(& $q $Board)" }
        'ASUS' { return "https://www.asus.com/searchresult?searchType=support&searchKey=$(& $q $Board)" }
        'Micro-Star|MSI' { return "https://www.msi.com/search/$(& $q $Board)" }
        'ASRock' { return "https://www.asrock.com/support/index.asp?cat=Drivers" }
        'Dell' { return $(if ($Serial) { "https://www.dell.com/support/home/product-support/servicetag/$(& $q $Serial)/drivers" } else { 'https://www.dell.com/support/home/' }) }
        'Lenovo' { return $(if ($Serial) { "https://pcsupport.lenovo.com/products/$(& $q $Serial)/downloads" } else { 'https://pcsupport.lenovo.com/' }) }
        'HP|Hewlett' { return 'https://support.hp.com/drivers' }
        'Acer' { return 'https://www.acer.com/support/drivers-and-manuals' }
        'Samsung' { return 'https://www.samsung.com/support/' }
        default { return '' }
    }
}

$script:ChipTools = [ordered]@{
    'Intel (detecção automática)' = 'https://www.intel.com/content/www/us/en/support/detect.html'
    'AMD (detecção automática)' = 'https://www.amd.com/en/support/download/drivers.html'
    'NVIDIA (placa de vídeo)' = 'https://www.nvidia.com/Download/index.aspx'
}

function Get-WinKitDriverInventory {
    $list = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object { $_.DeviceName -and $_.DriverVersion }
    foreach ($d in $list) {
        [pscustomobject]@{
            Device = "$($d.DeviceName)"; Class = "$($d.DeviceClass)"; Provider = "$($d.DriverProviderName)"; Manufacturer = "$($d.Manufacturer)"
            Version = "$($d.DriverVersion)"; Date = $(if ($d.DriverDate) { ([datetime]$d.DriverDate).ToString('yyyy-MM-dd') } else { '' })
            Inf = "$($d.InfName)"; Signed = [bool]$d.IsSigned; HardwareId = "$($d.HardWareID)"
        }
    }
}

function Get-WinKitProblemDevice {
    $bad = Get-CimInstance -ClassName Win32_PnPEntity -Filter 'ConfigManagerErrorCode<>0' -ErrorAction SilentlyContinue |
        Where-Object { $_.ConfigManagerErrorCode -ne 22 }   # 22 = desativado de propósito
    foreach ($d in $bad) {
        $code = [int]$d.ConfigManagerErrorCode
        [pscustomobject]@{
            Name = $(if ($d.Name) { "$($d.Name)" } else { 'Dispositivo desconhecido' }); Code = $code
            Problem = $(if ($script:DeviceErrors[$code]) { $script:DeviceErrors[$code] } else { "erro $code" })
            Class = "$($d.PNPClass)"; HardwareIds = @($d.HardwareID); InstanceId = "$($d.PNPDeviceID)"
            CatalogUrl = $(if (@($d.HardwareID).Count) { "https://www.catalog.update.microsoft.com/Search.aspx?q=$([uri]::EscapeDataString((@($d.HardwareID)[0] -replace '&REV_[0-9A-F]+$','')))" } else { '' })
        }
    }
}

# Drivers que o Windows Update oferece para este hardware, ligados aos dispositivos com problema pelo código de hardware.
function Find-WinKitDriverUpdate {
    param([object[]]$ProblemDevices = @())
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    Write-WinKitLog 'Procurando drivers no Windows Update (de 1 a 5 minutos)…'
    $result = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Driver'")
    for ($i = 0; $i -lt $result.Updates.Count; $i++) {
        ConvertFrom-WinKitDriverUpdate -Update $result.Updates.Item($i) -ProblemDevices $ProblemDevices
    }
}

function ConvertFrom-WinKitDriverUpdate {
    param($Update, [object[]]$ProblemDevices = @())
    $hwid = "$($Update.DriverHardwareID)"
    $fixes = @($ProblemDevices | Where-Object { @($_.HardwareIds) | Where-Object { $_ -and ($_.ToUpper().StartsWith($hwid.ToUpper()) -or $hwid.ToUpper().StartsWith($_.ToUpper())) } } | ForEach-Object Name)
    [pscustomobject]@{
        Id = "$($Update.Identity.UpdateID)"; Title = "$($Update.Title)"; Model = "$($Update.DriverModel)"; Provider = "$($Update.DriverProvider)"
        Class = "$($Update.DriverClass)"; Date = $(if ($Update.DriverVerDate) { ([datetime]$Update.DriverVerDate).ToString('yyyy-MM-dd') } else { '' })
        HardwareId = $hwid; SizeMB = [math]::Round([double]$Update.MaxDownloadSize / 1MB, 1); FixesDevices = $fixes
    }
}

function Test-WinKitDriver {
    [CmdletBinding()]
    param([bool]$SearchWindowsUpdate = $true)
    $inv = @(Get-WinKitDriverInventory)
    $bad = @(Get-WinKitProblemDevice)
    $cs = Get-CimInstance Win32_ComputerSystem
    $bb = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue | Select-Object -First 1
    $vendor = Get-WinKitVendorSupportUrl -Manufacturer $cs.Manufacturer -BoardMaker $bb.Manufacturer -Board $bb.Product -Serial $bios.SerialNumber
    $updates = @()
    if ($SearchWindowsUpdate) {
        try { $updates = @(Find-WinKitDriverUpdate -ProblemDevices $bad) }
        catch { New-WinKitResult -Check 'drivers.wu' -Status info -Message "Windows Update indisponível para drivers: $($_.Exception.Message)" }
    }
    $machine = @{ manufacturer = "$($cs.Manufacturer)"; model = "$($cs.Model)"; board = "$($bb.Manufacturer) $($bb.Product)"; bios = "$($bios.SMBIOSBIOSVersion)"
        vendorUrl = $vendor; chipTools = $script:ChipTools }
    New-WinKitResult -Check 'drivers.inventory' -Status ok -Message "$($inv.Count) driver(s) instalado(s)." -Detail @{ machine = $machine; drivers = $inv }
    if ($bad.Count) {
        $fixable = @($bad | Where-Object { $n = $_.Name; @($updates | Where-Object { $_.FixesDevices -contains $n }).Count })
        New-WinKitResult -Check 'drivers.problems' -Status warn -Code 'drivers_missing' -Detail $bad `
            -Message "$($bad.Count) dispositivo(s) com problema$(if ($SearchWindowsUpdate) { "; o Windows Update tem driver para $($fixable.Count)" })." `
            -Fix 'Instale os drivers encontrados; para os demais, use o link do Microsoft Update Catalog ou a página do fabricante.'
    } else {
        New-WinKitResult -Check 'drivers.problems' -Status ok -Message 'Todos os dispositivos estão com driver funcionando.'
    }
    if ($SearchWindowsUpdate) {
        New-WinKitResult -Check 'drivers.updates' -Status $(if ($updates.Count) { 'info' } else { 'ok' }) -Code $(if ($updates.Count) { 'drivers_available' } else { '' }) `
            -Message $(if ($updates.Count) { "$($updates.Count) driver(s) disponível(is) no Windows Update." } else { 'O Windows Update não tem drivers novos para esta máquina.' }) -Detail $updates
    }
}

# Exporta todos os drivers de terceiros (DISM) e gera um restore.ps1 que os reinstala sem internet.
function Export-WinKitDriverBackup {
    param([Parameter(Mandatory)][string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $r = Invoke-WinKitProcess -FilePath (Join-Path $env:SystemRoot 'System32\dism.exe') -ArgumentList '/Online', '/Export-Driver', "/Destination:$Destination" -TimeoutSeconds 1800
    if (-not $r.DryRun) {
        @'
# Reinstala os drivers exportados pelo WinKit (rode como administrador).
pnputil.exe /add-driver "$PSScriptRoot\*.inf" /subdirs /install
'@ | Set-Content -Path (Join-Path $Destination 'restore.ps1') -Encoding UTF8
    }
    return $r
}

function Invoke-WinKitDriver {
    [CmdletBinding()]
    param([string[]]$UpdateIds = @(), [bool]$Backup = $true)
    Assert-WinKitAdmin
    $ids = @($UpdateIds | Where-Object { $_ })
    if (-not $ids.Count) {
        # Sem escolha explícita: só os drivers que resolvem dispositivos com problema.
        $ids = @(Find-WinKitDriverUpdate -ProblemDevices @(Get-WinKitProblemDevice) | Where-Object { $_.FixesDevices.Count } | ForEach-Object Id)
        if (-not $ids.Count) { return New-WinKitResult -Check 'drivers.install' -Status ok -Message 'Nenhum driver do Windows Update resolve os dispositivos com problema.' }
    }
    if ($Backup) {
        $run = Get-WinKitRun
        $dest = Join-Path $(if ($run) { $run.Dir } else { Get-WinKitDataRoot }) 'drivers-backup'
        Write-WinKitLog "Backup dos drivers atuais em $dest…"
        $b = Export-WinKitDriverBackup -Destination $dest
        if (-not $b.DryRun -and -not $b.Success) {
            return New-WinKitResult -Check 'drivers.backup' -Status crit -Message "Backup dos drivers falhou (código $($b.ExitCode)); nada foi instalado." -Detail $b.Output
        }
        if (-not $b.DryRun) { New-WinKitResult -Check 'drivers.backup' -Status ok -Message "Backup dos drivers salvo em $dest (restore.ps1 reinstala)." }
    }
    Invoke-WinKitUpdate -IncludeDrivers $true -UpdateIds $ids
}

Export-ModuleMember -Function Test-WinKitDriver, Invoke-WinKitDriver, Get-WinKitDriverInventory, Get-WinKitProblemDevice, Find-WinKitDriverUpdate,
    ConvertFrom-WinKitDriverUpdate, Get-WinKitVendorSupportUrl, Export-WinKitDriverBackup
