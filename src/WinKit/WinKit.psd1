@{
    RootModule        = 'WinKit.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '6f2a8a7e-3c41-4c7e-9a52-1d3b7f0e9c11'
    Author            = 'Webpeak e colaboradores'
    CompanyName       = 'Webpeak'
    Copyright         = '(c) Webpeak. Licença MIT.'
    Description       = 'Prepara, otimiza, protege e diagnostica Windows 10/11 e Windows Server 2016-2025 (inclusive Server Core), com DryRun e undo.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport = '*'
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('Windows', 'WindowsServer', 'Diagnostics', 'Hardening', 'Drivers', 'Maintenance', 'MSP')
            LicenseUri   = 'https://github.com/webpeak-br/winkit/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/webpeak-br/winkit'
            ReleaseNotes = 'https://github.com/webpeak-br/winkit/blob/main/CHANGELOG.md'
        }
    }
}
