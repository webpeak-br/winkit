# Roda a suíte: instala o Pester 5 se faltar, executa os testes e devolve o código de saída. Usado pelo CI.
$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.5.0' })) {
    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module Pester -MinimumVersion 5.5.0 -Force -Scope CurrentUser -SkipPublisherCheck
}
Import-Module Pester -MinimumVersion 5.5.0
$c = New-PesterConfiguration
$c.Run.Path = $PSScriptRoot
$c.Run.Exit = $true
$c.Output.Verbosity = 'Detailed'
Write-Host "PowerShell $($PSVersionTable.PSVersion) · $([Environment]::OSVersion.VersionString)"
Invoke-Pester -Configuration $c
