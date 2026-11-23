#Requires -Modules Pester
# Módulos Aplicativos e Atualizações, sem winget nem Windows Update de verdade.

BeforeAll {
    $env:WINKIT_QUIET = '1'
    $env:WINKIT_DATA = Join-Path $TestDrive 'data'
    Import-Module (Join-Path $PSScriptRoot '..\src\WinKit\WinKit.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\src\WinKit\Modules\Apps\Apps.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot '..\src\WinKit\Modules\Updates\Updates.psm1') -Force -Global
}

Describe 'Catálogo de aplicativos' {
    It 'ids no formato do winget, sem repetição, todos com nome e categoria' {
        $c = Get-WinKitAppCatalog
        $c.Count | Should -BeGreaterThan 30
        ($c.id | Sort-Object -Unique).Count | Should -Be $c.Count
        foreach ($a in $c) { $a.id | Should -Match '^[A-Za-z0-9][A-Za-z0-9.+_-]{1,99}$'; $a.name | Should -Not -BeNullOrEmpty; $a.category | Should -Not -BeNullOrEmpty }
    }
}

Describe 'Instalação pelo winget' {
    It 'sem winget o diagnóstico explica como instalar' {
        Mock -ModuleName Apps Get-WingetPath { $null }
        (Test-WinKitApp).Code | Should -Be 'winget_missing'
    }
    It 'id com caractere de shell é recusado antes de chamar o winget' {
        Mock -ModuleName Apps Get-WingetPath { 'C:\winget.exe' }
        Mock -ModuleName Apps Invoke-WinKitProcess { throw 'não deveria executar' }
        $r = Invoke-WinKitApp -Install @('7zip.7zip & calc')
        $r.Status | Should -Be 'crit'
    }
    It 'já instalado (código do winget) não é falha' {
        Mock -ModuleName Apps Get-WingetPath { 'C:\winget.exe' }
        Mock -ModuleName Apps Invoke-WinKitProcess { [pscustomobject]@{ ExitCode = -1978335135; Success = $true; DryRun = $false; Output = '' } }
        New-WinKitRun | Out-Null
        (Invoke-WinKitApp -Install @('7zip.7zip')).Status | Should -Be 'ok'
        Complete-WinKitRun
    }
}

Describe 'Windows Update' {
    It 'reconhece atualização de segurança pela categoria (id estável, não pelo nome traduzido)' {
        $u = [pscustomobject]@{
            Title = 'Atualização cumulativa'; Identity = [pscustomobject]@{ UpdateID = 'abc' }; KBArticleIDs = @('5050001'); MsrcSeverity = ''
            Categories = @([pscustomobject]@{ Name = 'Qualquer nome'; CategoryID = '0fa1201d-4330-4fa8-8ae9-b877473b6441' }); Type = 1
            MaxDownloadSize = 104857600; IsDownloaded = $false; RebootRequired = $true
        }
        $i = ConvertFrom-ComUpdate $u
        $i.Security | Should -BeTrue
        $i.KB | Should -Be 'KB5050001'
        $i.SizeMB | Should -Be 100
        $i.Driver | Should -BeFalse
    }
}
