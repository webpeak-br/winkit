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

# Resumo usado pelo diagnóstico e pela janela: antivírus de terceiros ativo vale; senão, o estado do Defender.
function Get-WinKitAntivirusStatus {
    $third = @(Get-WinKitAntivirus | Where-Object { -not $_.Defender -and $_.Enabled })
    if ($third.Count) {
        $av = $third[0]
        return [pscustomobject]@{ Status = $(if ($av.UpToDate) { 'ok' } else { 'warn' }); Name = $av.Name
            Text = $(if ($av.UpToDate) { 'ativo' } else { 'desatualizado' }); Code = $(if ($av.UpToDate) { '' } else { 'antivirus_outdated' }) }
    }
    $mp = try { Get-MpComputerStatus -ErrorAction Stop } catch { $null }
    if (-not $mp -or -not $mp.AntivirusEnabled) { return [pscustomobject]@{ Status = 'crit'; Name = 'Nenhum antivírus'; Text = 'desligado'; Code = 'antivirus_off' } }
    if (-not $mp.RealTimeProtectionEnabled) { return [pscustomobject]@{ Status = 'warn'; Name = 'Microsoft Defender'; Text = 'sem tempo real'; Code = 'antivirus_realtime_off' } }
    if ($mp.AntivirusSignatureAge -gt 3) { return [pscustomobject]@{ Status = 'warn'; Name = 'Microsoft Defender'; Text = "assinaturas com $($mp.AntivirusSignatureAge) dias"; Code = 'antivirus_outdated' } }
    [pscustomobject]@{ Status = 'ok'; Name = 'Microsoft Defender'; Text = 'ativo'; Code = '' }
}
