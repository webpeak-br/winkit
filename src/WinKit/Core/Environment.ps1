# Detecção do ambiente: edição (Desktop, Server, Server Core), versão, domínio, VM ou físico, fabricante e placa.
# Tudo por CIM e registro, sem ler texto localizado.

function Test-WinKitAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-WinKitAdmin {
    if (-not (Test-WinKitAdmin)) {
        throw 'O WinKit precisa rodar como administrador. Use WinKit.cmd, que pede a elevação sozinho.'
    }
}

# Reabre o mesmo comando elevado (UAC). Usado pelo WinKit.cmd/winkit.ps1 quando não está como administrador.
function Start-WinKitElevated {
    param([Parameter(Mandatory)][string]$ScriptPath, [string[]]$Arguments = @())
    $exe = (Get-Process -Id $PID).Path
    $quoted = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"") + ($Arguments | ForEach-Object { "`"$($_ -replace '"', '\"')`"" })
    Start-Process -FilePath $exe -ArgumentList $quoted -Verb RunAs -Wait
}

function Get-WinKitEdition {
    param($OperatingSystem, [string]$InstallationType)
    # ProductType: 1 = estação de trabalho, 2 = controlador de domínio, 3 = servidor
    if ($OperatingSystem.ProductType -eq 1) { return 'Desktop' }
    if ($InstallationType -eq 'Server Core') { return 'ServerCore' }
    return 'Server'
}

function Get-WinKitEnvironment {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $bb = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue | Select-Object -First 1
    $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue

    $edition = Get-WinKitEdition -OperatingSystem $os -InstallationType $cv.InstallationType
    $model = "$($cs.Manufacturer) $($cs.Model)"
    # HypervisorPresent sozinho não basta: com VBS/Hyper-V ligado, máquina física também responde true.
    $isVm = ($cs.Model -match 'Virtual|VMware|KVM|QEMU|HVM domU|VirtualBox|Bochs|Standard PC') -or
            ($cs.Manufacturer -match 'QEMU|Xen|innotek|Parallels|VMware|Red Hat|Nutanix|Amazon EC2|Google') -or
            ($bios.Version -match 'VRTUAL|Xen|QEMU|VBOX')

    $roles = @()
    if ($edition -ne 'Desktop' -and (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue)) {
        $roles = @(Get-WindowsFeature | Where-Object { $_.Installed -and $_.FeatureType -eq 'Role' } | ForEach-Object Name)
    }

    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        Edition      = $edition
        Caption      = $os.Caption
        Version      = $os.Version
        Build        = [int]$os.BuildNumber
        UBR          = $cv.UBR
        DisplayVersion = $cv.DisplayVersion
        Architecture = $os.OSArchitecture
        Domain       = $cs.Domain
        DomainJoined = [bool]$cs.PartOfDomain
        DomainRole   = [int]$cs.DomainRole   # 4 e 5 = controlador de domínio
        IsVirtual    = [bool]$isVm
        Manufacturer = $cs.Manufacturer
        Model        = $cs.Model
        BaseBoard    = if ($bb) { [pscustomobject]@{ Manufacturer = $bb.Manufacturer; Product = $bb.Product; Version = $bb.Version } } else { $null }
        BiosVersion  = $bios.SMBIOSBIOSVersion
        MemoryGB     = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        Roles        = $roles
        PSVersion    = $PSVersionTable.PSVersion.ToString()
        IsAdmin      = Test-WinKitAdmin
        Summary      = "$($os.Caption) build $($os.BuildNumber) · $model"
    }
}

# Antivírus registrados na Central de Segurança do Windows (só existe no Desktop). O productState é um número
# cujos bytes dizem se o produto está ligado (byte do meio 0x10 ou 0x11) e se as definições estão em dia (byte final 0x00).
function ConvertFrom-WinKitAvState {
    param([Parameter(Mandatory)][int]$State)
    $hex = '{0:x6}' -f $State
    [pscustomobject]@{ Enabled = @('10', '11') -contains $hex.Substring(2, 2); UpToDate = $hex.Substring(4, 2) -eq '00' }
}

function Get-WinKitAntivirus {
    $list = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue)
    foreach ($p in $list) {
        $st = ConvertFrom-WinKitAvState -State ([int]$p.productState)
        [pscustomobject]@{ Name = "$($p.displayName)"; Enabled = $st.Enabled; UpToDate = $st.UpToDate
            Defender = "$($p.displayName)" -match 'Defender' }
    }
}

# Serviços de antivírus conhecidos, para quando o produto não se registra na Central de Segurança
# (ex.: alguns agentes corporativos). Nome do serviço -> nome do produto.
$script:KnownAvServices = [ordered]@{
    'EPSecurityService' = 'Bitdefender Endpoint Security Tools'; 'EPProtectedService' = 'Bitdefender Endpoint Security Tools'
    'bdservicehost' = 'Bitdefender'; 'VSSERV' = 'Bitdefender'
    'AVP' = 'Kaspersky'; 'klnagent' = 'Kaspersky Endpoint'; 'ekrn' = 'ESET'; 'SAVService' = 'Sophos'; 'Sophos Endpoint Defense Service' = 'Sophos'
    'CSFalconService' = 'CrowdStrike Falcon'; 'SentinelAgent' = 'SentinelOne'; 'ntrtscan' = 'Trend Micro'; 'TmCCSF' = 'Trend Micro'
    'McShield' = 'McAfee/Trellix'; 'mfemms' = 'McAfee/Trellix'; 'avast! Antivirus' = 'Avast'; 'AvastWscReporter' = 'Avast'; 'AVG Antivirus' = 'AVG'
    'WRSVC' = 'Webroot'; 'SepMasterService' = 'Symantec Endpoint Protection'; 'CylanceSvc' = 'Cylance'; 'HitmanPro.Alert' = 'Sophos HitmanPro'
}

function Get-WinKitAvService {
    foreach ($name in $script:KnownAvServices.Keys) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { return $script:KnownAvServices[$name] }
    }
    return $null
}

# Resumo usado pelo diagnóstico e pela janela. Ordem: antivírus de terceiros registrado na Central de Segurança;
# Defender em modo passivo (sinal do próprio Windows de que outro antivírus assumiu); serviço conhecido rodando;
# por último, o estado do Defender.
function Get-WinKitAntivirusStatus {
    $mp = try { Get-MpComputerStatus -ErrorAction Stop } catch { $null }
    $passive = $mp -and "$($mp.AMRunningMode)" -match 'Passive|EDR Block'
    $third = @(Get-WinKitAntivirus | Where-Object { -not $_.Defender })
    $svcName = Get-WinKitAvService
    $active = @($third | Where-Object Enabled)
    $name = if ($active.Count) { $active[0].Name } elseif ($third.Count) { $third[0].Name } elseif ($svcName) { $svcName } else { '' }
    if ($active.Count -or (($third.Count -or $svcName) -and ($passive -or ($mp -and -not $mp.RealTimeProtectionEnabled)))) {
        $outdated = $active.Count -and -not $active[0].UpToDate
        return [pscustomobject]@{ Status = $(if ($outdated) { 'warn' } else { 'ok' }); Name = $name
            Text = $(if ($outdated) { 'desatualizado' } else { 'ativo' }); Code = $(if ($outdated) { 'antivirus_outdated' } else { '' }) }
    }
    if ($passive) { return [pscustomobject]@{ Status = 'ok'; Name = 'Outro antivírus (Defender em modo passivo)'; Text = 'ativo'; Code = '' } }
    if (-not $mp -or -not $mp.AntivirusEnabled) {
        if ($svcName) { return [pscustomobject]@{ Status = 'ok'; Name = $svcName; Text = 'ativo'; Code = '' } }
        return [pscustomobject]@{ Status = 'crit'; Name = 'Nenhum antivírus'; Text = 'desligado'; Code = 'antivirus_off' }
    }
    if (-not $mp.RealTimeProtectionEnabled) { return [pscustomobject]@{ Status = 'warn'; Name = 'Microsoft Defender'; Text = 'sem tempo real'; Code = 'antivirus_realtime_off' } }
    if ($mp.AntivirusSignatureAge -gt 3) { return [pscustomobject]@{ Status = 'warn'; Name = 'Microsoft Defender'; Text = "assinaturas com $($mp.AntivirusSignatureAge) dias"; Code = 'antivirus_outdated' } }
    [pscustomobject]@{ Status = 'ok'; Name = 'Microsoft Defender'; Text = 'ativo'; Code = '' }
}
