#Requires -Modules Pester
# Testes do Core: manifest, perfis, diário/undo, DryRun, execução de processos e relatório.

BeforeAll {
    $env:WINKIT_QUIET = '1'
    $env:WINKIT_DATA = Join-Path $TestDrive 'data'
    Import-Module (Join-Path $PSScriptRoot '..\src\WinKit\WinKit.psd1') -Force
    $healthManifest = Get-Content (Join-Path $PSScriptRoot '..\src\WinKit\Modules\Health\manifest.json') -Raw | ConvertFrom-Json
}

Describe 'Manifest de módulo' {
    It 'aceita o manifest do Health' {
        Test-WinKitManifest -Manifest $healthManifest -Folder 'Health' | Should -BeNullOrEmpty
    }
    It 'exige a função de diagnóstico (test)' {
        $m = $healthManifest | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $m.functions.test = $null
        Test-WinKitManifest -Manifest $m | Should -Contain 'functions.test é obrigatório: todo módulo começa pelo diagnóstico'
    }
    It 'recusa risco, plataforma e nome de função fora do padrão' {
        $m = $healthManifest | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $m.risk = 'extremo'; $m.platforms = @('MacOS'); $m.functions.invoke = 'Remove-Tudo'
        $p = Test-WinKitManifest -Manifest $m
        $p | Should -Contain 'risk inválido: extremo'
        $p | Should -Contain 'plataforma desconhecida: MacOS'
        ($p -join ' ') | Should -Match 'functions.invoke fora do padrão'
    }
    It 'id precisa bater com a pasta' {
        Test-WinKitManifest -Manifest $healthManifest -Folder 'Outro' | Should -Match 'diferente da pasta'
    }
    It 'encontra o Health e filtra por plataforma e build' {
        @(Get-WinKitModule -Id Health).Count | Should -Be 1
        @(Get-WinKitModule -Id Health -Build 10000).Count | Should -Be 0
    }
    It 'parâmetro desconhecido é erro, padrão vem do manifest' {
        $m = Get-WinKitModule -Id Health
        { Resolve-WinKitParameter -Module $m -Params @{ Naoexiste = 1 } } | Should -Throw '*não existe*'
        (Resolve-WinKitParameter -Module $m -Params @{ EventLogHours = 24 }).EventLogHours | Should -Be 24
        (Resolve-WinKitParameter -Module $m).BsodDays | Should -Be 30
    }
}

Describe 'Perfis' {
    It 'herança põe as etapas do perfil-base primeiro' {
        $p = Get-WinKitProfile -Name 'Reparo-Sistema'
        $p.Chain | Should -Be @('Reparo-Sistema', 'Diagnostico')
        $p.Steps.Count | Should -Be 3
        $p.Steps[0].mode | Should -Be 'test'
        $p.Steps[1].mode | Should -Be 'invoke'
    }
    It 'detecta herança circular' {
        $dir = Join-Path $env:WINKIT_DATA 'profiles'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        '{"id":"A","extends":"B","steps":[]}' | Set-Content (Join-Path $dir 'A.json')
        '{"id":"B","extends":"A","steps":[]}' | Set-Content (Join-Path $dir 'B.json')
        { Get-WinKitProfile -Name A } | Should -Throw '*circular*'
    }
    It 'recusa nome de perfil com caminho' {
        { Get-WinKitProfile -Name '..\..\x' } | Should -Throw '*inválido*'
    }
    It 'exporta perfil do usuário e lê de volta' {
        Export-WinKitProfile -Name 'Meu' -Steps @(@{ module = 'Health'; mode = 'test' }) | Should -Exist
        (Get-WinKitProfile -Name 'Meu').Steps[0].module | Should -Be 'Health'
    }
}

Describe 'Diário e undo' {
    BeforeAll { $key = 'HKCU:\Software\WinKitTest' }
    AfterEach { Remove-Item $key -Recurse -Force -ErrorAction SilentlyContinue }

    It 'DryRun não altera o registro nem grava diário' {
        $run = New-WinKitRun -DryRun
        Set-WinKitRegistryValue -Path $key -Name 'X' -Value 1 | Should -BeTrue
        Test-Path $key | Should -BeFalse
        $run.Journal.Count | Should -Be 0
        Complete-WinKitRun
    }
    It 'desfaz valor criado (remove) e valor alterado (volta ao anterior)' {
        New-Item $key -Force | Out-Null
        New-ItemProperty -Path $key -Name 'Antigo' -Value 'a' -PropertyType String | Out-Null
        $run = New-WinKitRun
        Set-WinKitRegistryValue -Path $key -Name 'Novo' -Value 5 | Should -BeTrue
        Set-WinKitRegistryValue -Path $key -Name 'Antigo' -Value 'b' -Kind String | Should -BeTrue
        Set-WinKitRegistryValue -Path $key -Name 'Antigo' -Value 'b' -Kind String | Should -BeFalse   # idempotente
        $id = $run.Id
        Complete-WinKitRun
        (Get-ItemProperty $key).Antigo | Should -Be 'b'
        $r = Undo-WinKitRun -RunId $id
        $r.Undone | Should -Be 2
        $r.Failed | Should -Be 0
        (Get-ItemProperty $key).Antigo | Should -Be 'a'
        (Get-Item $key).GetValueNames() | Should -Not -Contain 'Novo'
    }
    It 'chave criada pelo WinKit some no undo' {
        $run = New-WinKitRun
        Set-WinKitRegistryValue -Path "$key\Sub" -Name 'Y' -Value 1 | Out-Null
        $id = $run.Id
        Complete-WinKitRun
        Undo-WinKitRun -RunId $id | Out-Null
        Test-Path "$key\Sub" | Should -BeFalse
    }
    It 'RunId inválido é recusado' {
        { Undo-WinKitRun -RunId '..\..\Windows' } | Should -Throw '*inválido*'
    }
}

Describe 'Execução de processos' {
    It 'trata 3010 como sucesso com reinício' {
        $r = Invoke-WinKitProcess -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/c', 'exit 3010'
        $r.Success | Should -BeTrue
        $r.RebootRequired | Should -BeTrue
    }
    It 'código fora da lista de sucesso falha' {
        $r = Invoke-WinKitProcess -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/c', 'exit 5'
        $r.Success | Should -BeFalse
        $r.ExitCode | Should -Be 5
    }
    It 'no DryRun não executa' {
        New-WinKitRun -DryRun | Out-Null
        $r = Invoke-WinKitProcess -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/c', 'exit 7'
        $r.DryRun | Should -BeTrue
        $r.ExitCode | Should -Be 0
        Complete-WinKitRun
    }
}

Describe 'Download' {
    It 'só aceita HTTPS' {
        { Get-WinKitDownload -Url 'http://exemplo.com/a.exe' } | Should -Throw '*só HTTPS*'
    }
    It 'recusa nome de arquivo com caminho' {
        { Get-WinKitDownload -Url 'https://exemplo.com/a.exe' -FileName '..\x.exe' } | Should -Throw '*inválido*'
    }
}

Describe 'Relatório' {
    It 'escapa HTML e calcula o status geral' {
        $res = @(
            (New-WinKitResult -Check 'a' -Status ok -Message 'tudo certo' | Add-Member -NotePropertyName Module -NotePropertyValue 'X' -PassThru),
            (New-WinKitResult -Check 'b' -Status warn -Message '<script>alert(1)</script>' | Add-Member -NotePropertyName Module -NotePropertyValue 'X' -PassThru)
        )
        Get-WinKitOverallStatus -Results $res | Should -Be 'warn'
        $info = [pscustomobject]@{ ComputerName = 'PC'; Summary = 'teste' }
        $r = Export-WinKitReport -Results $res -Environment $info -Dir $TestDrive
        $html = Get-Content $r.Html -Raw
        $html | Should -Not -Match '<script>'
        $html | Should -Match '&lt;script&gt;'
        (Get-Content $r.Json -Raw | ConvertFrom-Json).overall | Should -Be 'warn'
    }
}

Describe 'Ambiente' {
    It 'classifica a edição pelo ProductType e InstallationType' {
        Get-WinKitEdition -OperatingSystem @{ ProductType = 1 } -InstallationType 'Client' | Should -Be 'Desktop'
        Get-WinKitEdition -OperatingSystem @{ ProductType = 3 } -InstallationType 'Server Core' | Should -Be 'ServerCore'
        Get-WinKitEdition -OperatingSystem @{ ProductType = 2 } -InstallationType 'Server' | Should -Be 'Server'
    }
    It 'detecta a máquina atual' {
        $e = Get-WinKitEnvironment
        $e.Build | Should -BeGreaterThan 10000
        $e.Edition | Should -BeIn @('Desktop', 'Server', 'ServerCore')
    }
}

Describe 'Antivírus' {
    It 'decodifica o productState da Central de Segurança' {
        (ConvertFrom-WinKitAvState -State 397568).Enabled | Should -BeTrue      # 0x061100: ligado, em dia
        (ConvertFrom-WinKitAvState -State 397568).UpToDate | Should -BeTrue
        (ConvertFrom-WinKitAvState -State 393472).Enabled | Should -BeFalse     # 0x060100: desligado
        (ConvertFrom-WinKitAvState -State 397584).UpToDate | Should -BeFalse    # 0x061110: definições velhas
    }
    It 'antivírus de terceiros ativo vale mais que o Defender passivo' {
        Mock -ModuleName WinKit Get-WinKitAntivirus { [pscustomobject]@{ Name = 'Bitdefender Endpoint Security Tools'; Enabled = $true; UpToDate = $true; Defender = $false } }
        Mock -ModuleName WinKit Get-MpComputerStatus { [pscustomobject]@{ AntivirusEnabled = $true; RealTimeProtectionEnabled = $false } }
        $s = Get-WinKitAntivirusStatus
        $s.Status | Should -Be 'ok'
        $s.Name | Should -Match 'Bitdefender'
    }
    It 'Bitdefender que não se registra: serviço rodando + Defender passivo = ativo' {
        Mock -ModuleName WinKit Get-WinKitAntivirus { @() }
        Mock -ModuleName WinKit Get-WinKitAvService { 'Bitdefender Endpoint Security Tools' }
        Mock -ModuleName WinKit Get-MpComputerStatus { [pscustomobject]@{ AntivirusEnabled = $true; RealTimeProtectionEnabled = $false; AMRunningMode = 'Passive Mode' } }
        $s = Get-WinKitAntivirusStatus
        $s.Status | Should -Be 'ok'
        $s.Name | Should -Match 'Bitdefender'
    }
    It 'registrado na Central com estado que não entendemos, mas Defender sem tempo real: vale o de terceiros' {
        Mock -ModuleName WinKit Get-WinKitAntivirus { [pscustomobject]@{ Name = 'Bitdefender Endpoint Security Tools'; Enabled = $false; UpToDate = $false; Defender = $false } }
        Mock -ModuleName WinKit Get-WinKitAvService { $null }
        Mock -ModuleName WinKit Get-MpComputerStatus { [pscustomobject]@{ AntivirusEnabled = $true; RealTimeProtectionEnabled = $false; AMRunningMode = 'Normal' } }
        (Get-WinKitAntivirusStatus).Status | Should -Be 'ok'
    }
    It 'sem terceiros, Defender sem tempo real é atenção' {
        Mock -ModuleName WinKit Get-WinKitAvService { $null }
        Mock -ModuleName WinKit Get-WinKitAntivirus { @() }
        Mock -ModuleName WinKit Get-MpComputerStatus { [pscustomobject]@{ AntivirusEnabled = $true; RealTimeProtectionEnabled = $false } }
        (Get-WinKitAntivirusStatus).Code | Should -Be 'antivirus_realtime_off'
    }
}
