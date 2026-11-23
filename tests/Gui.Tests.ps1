#Requires -Modules Pester
# A janela é carregada de verdade (sem exibir) no Windows PowerShell, que roda em STA.

BeforeDiscovery { $script:canWpf = $IsWindows -ne $false -and [Threading.Thread]::CurrentThread.ApartmentState -eq 'STA' }

Describe 'Interface gráfica' -Skip:(-not $script:canWpf) {
    BeforeAll {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        $gui = Join-Path $PSScriptRoot '..\src\WinKit\Gui'
        $xaml = [xml](Get-Content (Join-Path $gui 'MainWindow.xaml') -Raw -Encoding UTF8)
        $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
        $code = Get-Content (Join-Path $gui 'WinKitGui.ps1') -Raw -Encoding UTF8
    }
    It 'o XAML carrega' { $win | Should -Not -BeNullOrEmpty }
    It 'todo controle citado no código existe na janela' {
        $names = [regex]::Matches($code, '(?:\$ui|Ui)\.([A-Z][A-Za-z]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $names.Count | Should -BeGreaterThan 15
        foreach ($n in $names) { $win.FindName($n) | Should -Not -BeNullOrEmpty -Because "o código usa $n" }
    }
    It 'cada botão do menu aponta para uma página que existe' {
        foreach ($b in $win.FindName('NavPanel').Children) { $win.FindName($b.Tag) | Should -Not -BeNullOrEmpty }
    }
    It 'o script da interface não tem erro de sintaxe' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }
}
