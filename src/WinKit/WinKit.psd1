@{
    RootModule        = 'WinKit.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = '6f2a8a7e-3c41-4c7e-9a52-1d3b7f0e9c11'
    Author            = 'Webpeak e colaboradores'
    CompanyName       = 'Webpeak'
    Copyright         = '(c) Webpeak. Licença MIT.'
    Description       = 'Prepara, otimiza, protege e diagnostica Windows 10/11 e Windows Server 2016-2025 (inclusive Server Core), com DryRun e undo.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport = @(
        'Invoke-WinKit', 'New-WinKitRestorePoint', 'Write-WinKitLog', 'Set-WinKitLogSink', 'Get-WinKitDataRoot', 'New-WinKitRun', 'Get-WinKitRun',
        'Complete-WinKitRun', 'Get-WinKitRunList', 'Test-WinKitAdmin', 'Assert-WinKitAdmin', 'Start-WinKitElevated', 'Get-WinKitEdition',
        'Get-WinKitEnvironment', 'Add-WinKitJournal', 'Save-WinKitJournal', 'Test-WinKitDryRun', 'Get-WinKitRegistryValue',
        'Set-WinKitRegistryValue', 'Set-WinKitServiceStartup', 'Add-WinKitCustomChange', 'Undo-WinKitEntry', 'Undo-WinKitRun',
        'Invoke-WinKitProcess', 'Get-WinKitCacheDir', 'Test-WinKitSignature', 'Test-WinKitDownloadedFile', 'Get-WinKitDownload',
        'Test-WinKitManifest', 'Get-WinKitModule', 'Import-WinKitModuleCode', 'Invoke-WinKitModule', 'Resolve-WinKitParameter',
        'New-WinKitResult', 'Get-WinKitProfileDirectory', 'Read-WinKitProfileFile', 'Get-WinKitProfile', 'ConvertTo-WinKitHashtable',
        'Export-WinKitProfile', 'Get-WinKitOverallStatus', 'Write-WinKitReportConsole', 'ConvertTo-WinKitHtml', 'Export-WinKitReport'
    )
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
