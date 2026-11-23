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
