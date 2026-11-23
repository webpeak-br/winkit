<#
.SYNOPSIS
  Gera dist\winkit.ps1: um arquivo único com o Core, os módulos e os perfis, para rodar com
  irm https://github.com/webpeak-br/winkit/releases/latest/download/winkit.ps1 | iex
  (mesmo modelo do winutil: nada para baixar ou extrair à mão).
.NOTES
  Cada arquivo do módulo vai embutido em Base64 (UTF-8). Ao rodar, o script grava os arquivos em
  %ProgramData%\WinKit\app\<versão>\ e carrega o módulo de lá; assim a elevação (UAC) reabre o mesmo código.
#>
param([string]$OutDir = (Join-Path $PSScriptRoot '..\dist'))
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\src')
$version = (Import-PowerShellDataFile (Join-Path $root 'WinKit\WinKit.psd1')).ModuleVersion
$files = Get-ChildItem -Path $root -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1', '.json', '.xaml' }

$entries = foreach ($f in $files | Sort-Object FullName) {
    $rel = $f.FullName.Substring($root.Path.Length + 1).Replace('\', '/')
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($f.FullName))
    "    '$rel' = '$b64'"
}
$hash = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes(($entries -join "`n")))) -Algorithm SHA256).Hash.Substring(0, 12)

$bootstrap = @'
#Requires -Version 5.1
# WinKit __VERSION__ - arquivo unico gerado por build/Compile.ps1. Codigo-fonte legivel: https://github.com/webpeak-br/winkit
# Este arquivo e 100% ASCII e sem BOM: o "irm" do Windows PowerShell 5.1 nao sabe a codificacao e estragaria acentos.
# Uso: irm https://github.com/webpeak-br/winkit/releases/latest/download/winkit.ps1 | iex
# Ou com comando: & ([scriptblock]::Create((irm https://github.com/webpeak-br/winkit/releases/latest/download/winkit.ps1))) run -Module Health
$WinKitVersion = '__VERSION__'
$WinKitBuild = '__HASH__'
$WinKitFiles = @{
__ENTRIES__
}

function Install-WinKitApp {
    $base = if ($env:ProgramData) { $env:ProgramData } else { [IO.Path]::GetTempPath() }
    $dir = Join-Path $base "WinKit\app\$WinKitVersion-$WinKitBuild"
    if (-not (Test-Path (Join-Path $dir 'winkit.ps1'))) {
        foreach ($rel in $WinKitFiles.Keys) {
            $dest = Join-Path $dir ($rel -replace '/', '\')
            New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
            [IO.File]::WriteAllBytes($dest, [Convert]::FromBase64String($WinKitFiles[$rel]))
        }
    }
    return $dir
}

# A politica de execucao padrao (Restricted) bloqueia os arquivos que o WinKit grava. Libera so para esta
# janela do PowerShell (escopo Process), sem mudar a configuracao da maquina, como faz o winutil.
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop } catch {
    Write-Host 'Nao foi possivel liberar a execucao de scripts nesta janela (politica imposta pela empresa / GPO).' -ForegroundColor Red
    Write-Host 'Peca ao administrador do dominio ou rode: powershell -ExecutionPolicy Bypass' -ForegroundColor Red
    return
}
$app = Install-WinKitApp
$cli = Join-Path $app 'winkit.ps1'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$cmdArgs = @($args)
if (-not $isAdmin) {
    Write-Host 'WinKit precisa de administrador: confirme a janela do Windows (UAC).' -ForegroundColor Yellow
    $exe = (Get-Process -Id $PID).Path
    $pass = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$cli`"") + ($cmdArgs | ForEach-Object { "`"$_`"" })
    Start-Process -FilePath $exe -ArgumentList $pass -Verb RunAs
    return
}
& $cli @cmdArgs
'@
$out = $bootstrap.Replace('__VERSION__', $version).Replace('__HASH__', $hash).Replace('__ENTRIES__', ($entries -join "`n"))
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$dest = Join-Path $OutDir 'winkit.ps1'
$bad = [regex]::Matches($out, '[^\x00-\x7F]')
if ($bad.Count) { throw "O arquivo unico precisa ser ASCII; achei $($bad.Count) caractere(s) fora, como '$($bad[0].Value)'." }
[IO.File]::WriteAllText($dest, $out, (New-Object Text.ASCIIEncoding))
$sha = (Get-FileHash $dest -Algorithm SHA256).Hash
"$sha  winkit.ps1" | Set-Content (Join-Path $OutDir 'SHA256SUMS.txt') -Encoding ASCII
Write-Host "Gerado $dest ($([math]::Round((Get-Item $dest).Length / 1KB)) KB, $($files.Count) arquivos, SHA-256 $sha)"
