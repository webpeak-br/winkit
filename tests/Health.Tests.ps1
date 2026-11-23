#Requires -Modules Pester
# Testes do módulo Health com mocks de CIM, Storage e Event Log: cada verificação vira o resultado e o código certos.

BeforeAll {
    $env:WINKIT_QUIET = '1'
    $env:WINKIT_DATA = Join-Path $TestDrive 'data'
    Import-Module (Join-Path $PSScriptRoot '..\src\WinKit\WinKit.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\src\WinKit\Modules\Health\Health.psm1') -Force -Global
}

Describe 'Espaço em disco' {
    It 'acima de 90% é crítico com código disk_full' {
        Mock -ModuleName Health Get-CimInstance { [pscustomobject]@{ DeviceID = 'C:'; Size = 100GB; FreeSpace = 5GB } } -ParameterFilter { $ClassName -eq 'Win32_LogicalDisk' }
        $r = InModuleScope Health { Test-HealthDiskSpace }
        $r.Status | Should -Be 'crit'
        $r.Code | Should -Be 'disk_full'
    }
    It 'com folga fica ok e sem código' {
        Mock -ModuleName Health Get-CimInstance { [pscustomobject]@{ DeviceID = 'D:'; Size = 100GB; FreeSpace = 60GB } } -ParameterFilter { $ClassName -eq 'Win32_LogicalDisk' }
        $r = InModuleScope Health { Test-HealthDiskSpace }
        $r.Status | Should -Be 'ok'
        $r.Code | Should -BeNullOrEmpty
    }
}

Describe 'Saúde física dos discos' {
    BeforeEach {
        Mock -ModuleName Health Get-CimInstance { @() } -ParameterFilter { $ClassName -eq 'MSStorageDriver_FailurePredictStatus' }
    }
    It 'erro de leitura não corrigido é crítico (disk_sectors)' {
        Mock -ModuleName Health Get-PhysicalDisk { [pscustomobject]@{ DeviceId = 0; FriendlyName = 'SSD X'; HealthStatus = 'Healthy'; MediaType = 'SSD'; BusType = 'NVMe' } }
        Mock -ModuleName Health Get-HealthReliability { [pscustomobject]@{ ReadErrorsUncorrected = 12; Wear = 10; Temperature = 40 } }
        $r = InModuleScope Health { Test-HealthPhysicalDisk }
        $r.Code | Should -Be 'disk_sectors'
        $r.Status | Should -Be 'crit'
    }
    It 'falha prevista pelo SMART é crítica (disk_smart)' {
        Mock -ModuleName Health Get-PhysicalDisk { [pscustomobject]@{ DeviceId = 1; FriendlyName = 'HD'; HealthStatus = 'Unhealthy' } }
        Mock -ModuleName Health Get-HealthReliability { [pscustomobject]@{ ReadErrorsUncorrected = 0 } }
        (InModuleScope Health { Test-HealthPhysicalDisk }).Code | Should -Be 'disk_smart'
    }
    It 'desgaste alto do SSD é atenção (disk_wear)' {
        Mock -ModuleName Health Get-PhysicalDisk { [pscustomobject]@{ DeviceId = 0; FriendlyName = 'SSD'; HealthStatus = 'Healthy' } }
        Mock -ModuleName Health Get-HealthReliability { [pscustomobject]@{ ReadErrorsUncorrected = 0; Wear = 95 } }
        $r = InModuleScope Health { Test-HealthPhysicalDisk }
        $r.Code | Should -Be 'disk_wear'
        $r.Status | Should -Be 'warn'
    }
    It 'sem discos visíveis (VM) é só informação' {
        Mock -ModuleName Health Get-PhysicalDisk { @() }
        (InModuleScope Health { Test-HealthPhysicalDisk }).Status | Should -Be 'info'
    }
}

Describe 'Event Log' {
    It 'erro do driver de disco vira disk_io_errors, Kernel-Power 41 vira desligamento inesperado' {
        Mock -ModuleName Health Get-WinEvent {
            [pscustomobject]@{ ProviderName = 'disk'; Id = 7; Level = 2; TimeCreated = Get-Date }
            [pscustomobject]@{ ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; Level = 1; TimeCreated = Get-Date }
            [pscustomobject]@{ ProviderName = 'Service Control Manager'; Id = 7000; Level = 2; TimeCreated = Get-Date }
        }
        $r = @(InModuleScope Health { Test-HealthEventLog -Hours 24 })
        ($r | Where-Object Code -eq 'disk_io_errors').Status | Should -Be 'crit'
        ($r | Where-Object Code -eq 'unexpected_shutdown').Status | Should -Be 'warn'
        ($r | Where-Object Check -eq 'eventlog.system').Message | Should -Match '^3 erro'
    }
}

Describe 'Dispositivos' {
    It 'dispositivo sem driver (código 28) gera drivers_missing com o HWID' {
        Mock -ModuleName Health Get-CimInstance {
            [pscustomobject]@{ Name = 'Controlador desconhecido'; ConfigManagerErrorCode = 28; HardwareID = @('PCI\VEN_8086&DEV_7A23'); PNPClass = $null }
            [pscustomobject]@{ Name = 'Desativado'; ConfigManagerErrorCode = 22; HardwareID = @('X'); PNPClass = 'Net' }
        } -ParameterFilter { $ClassName -eq 'Win32_PnPEntity' }
        $r = InModuleScope Health { Test-HealthDevices }
        $r.Code | Should -Be 'drivers_missing'
        $r.Message | Should -Match '^1 dispositivo'
        $r.Detail[0].hwid | Should -Contain 'PCI\VEN_8086&DEV_7A23'
    }
}

Describe 'Telas azuis' {
    It 'três ou mais no período é crítico e traz o código de parada' {
        Mock -ModuleName Health Get-ChildItem { 1..3 | ForEach-Object { [pscustomobject]@{ Name = "d$_.dmp"; LastWriteTime = Get-Date } } }
        Mock -ModuleName Health Get-WinEvent { [pscustomobject]@{ Properties = @([pscustomobject]@{ Value = '0x0000009f' }) } }
        $r = InModuleScope Health { Test-HealthBsod -Days 30 }
        $r.Status | Should -Be 'crit'
        $r.Detail.bugchecks | Should -Contain '0x0000009f'
    }
}

Describe 'Test-WinKitHealth' {
    It 'uma verificação que falha não derruba as outras' {
        Mock -ModuleName Health Get-HotFix { throw 'sem acesso' }
        $r = @(Test-WinKitHealth -CheckImageHealth $false)
        $r.Count | Should -BeGreaterThan 5
        ($r | Where-Object Check -like 'erro.Atualiza*').Status | Should -Be 'info'
    }
    It 'todo resultado tem status válido' {
        $r = @(Test-WinKitHealth -CheckImageHealth $false)
        $r | ForEach-Object { $_.Status | Should -BeIn @('ok', 'info', 'warn', 'crit') }
    }
}
