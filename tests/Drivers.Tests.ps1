#Requires -Modules Pester
# Módulo Drivers com mocks de CIM e de objetos do Windows Update.

BeforeAll {
    $env:WINKIT_QUIET = '1'
    $env:WINKIT_DATA = Join-Path $TestDrive 'data'
    Import-Module (Join-Path $PSScriptRoot '..\src\WinKit\WinKit.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\src\WinKit\Modules\Drivers\Drivers.psm1') -Force -Global
}

Describe 'Dispositivos com problema' {
    It 'traduz o código do Gerenciador de Dispositivos e monta o link do Update Catalog sem a revisão' {
        Mock -ModuleName Drivers Get-CimInstance {
            [pscustomobject]@{ Name = $null; ConfigManagerErrorCode = 28; PNPClass = $null; PNPDeviceID = 'PCI\X'; HardwareID = @('PCI\VEN_8086&DEV_7A23&SUBSYS_00000000&REV_11', 'PCI\VEN_8086&DEV_7A23') }
            [pscustomobject]@{ Name = 'Placa desativada'; ConfigManagerErrorCode = 22; HardwareID = @('X') }
        } -ParameterFilter { $ClassName -eq 'Win32_PnPEntity' }
        $d = @(Get-WinKitProblemDevice)
        $d.Count | Should -Be 1
        $d[0].Name | Should -Be 'Dispositivo desconhecido'
        $d[0].Problem | Should -Be 'driver não instalado'
        $d[0].CatalogUrl | Should -Be 'https://www.catalog.update.microsoft.com/Search.aspx?q=PCI%5CVEN_8086%26DEV_7A23%26SUBSYS_00000000'
    }
}

Describe 'Drivers do Windows Update' {
    It 'liga o driver oferecido ao dispositivo com problema pelo código de hardware' {
        $u = [pscustomobject]@{ Identity = [pscustomobject]@{ UpdateID = 'u1' }; Title = 'Intel - System - 10.1.1.1'; DriverModel = 'Serial IO'
            DriverProvider = 'Intel'; DriverClass = 'System'; DriverVerDate = [datetime]'2026-01-02'; DriverHardwareID = 'pci\ven_8086&dev_7a23'; MaxDownloadSize = 2097152 }
        $dev = [pscustomobject]@{ Name = 'Controlador PCI'; HardwareIds = @('PCI\VEN_8086&DEV_7A23&SUBSYS_00000000&REV_11') }
        $r = ConvertFrom-WinKitDriverUpdate -Update $u -ProblemDevices @($dev)
        $r.FixesDevices | Should -Contain 'Controlador PCI'
        $r.Date | Should -Be '2026-01-02'
        $r.SizeMB | Should -Be 2
    }
}

Describe 'Página do fabricante' {
    It 'placa Gigabyte vira busca no site da Gigabyte; Dell usa a etiqueta de serviço' {
        Get-WinKitVendorSupportUrl -Manufacturer 'Gigabyte Technology Co., Ltd.' -BoardMaker 'Gigabyte Technology Co., Ltd.' -Board 'Z790 GAMING X AX' |
            Should -Be 'https://www.gigabyte.com/Search?kw=Z790%20GAMING%20X%20AX'
        Get-WinKitVendorSupportUrl -Manufacturer 'Dell Inc.' -Serial 'ABC1234' | Should -Match 'servicetag/ABC1234/drivers'
        Get-WinKitVendorSupportUrl -Manufacturer 'Fabricante Desconhecido' | Should -BeNullOrEmpty
    }
}
