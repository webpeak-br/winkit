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
$files = Get-ChildItem -Path $root -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1', '.json' }

$entries = foreach ($f in $files | Sort-Object FullName) {
    $rel = $f.FullName.Substring($root.Path.Length + 1).Replace('\', '/')
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($f.FullName))
    "    '$rel' = '$b64'"
}
$hash = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes(($entries -join "`n")))) -Algorithm SHA256).Hash.Substring(0, 12)

$bootstrap = @'
#Requires -Version 5.1
# WinKit __VERSION__ (arquivo único gerado por build/Compile.ps1; o código-fonte legível está em https://github.com/webpeak-br/winkit)
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
[IO.File]::WriteAllText($dest, $out, (New-Object Text.UTF8Encoding $true))
$sha = (Get-FileHash $dest -Algorithm SHA256).Hash
"$sha  winkit.ps1" | Set-Content (Join-Path $OutDir 'SHA256SUMS.txt') -Encoding ASCII
Write-Host "Gerado $dest ($([math]::Round((Get-Item $dest).Length / 1KB)) KB, $($files.Count) arquivos, SHA-256 $sha)"
