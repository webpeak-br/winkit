# Aplicativos pelo winget. O que está instalado vem do "winget export" (JSON, não depende do idioma);
# a instalação usa só ids do catálogo ou com formato de id winget, e decide pelo código de saída.

$script:Catalog = Get-Content (Join-Path $PSScriptRoot 'catalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$script:IdPattern = '^[A-Za-z0-9][A-Za-z0-9.+_-]{1,99}$'
# Códigos do winget que não são falha: já instalado, nenhuma atualização aplicável.
$script:WingetOk = @(0, -1978335189, -1978335135)

function Get-WinKitAppCatalog { $script:Catalog }

function Get-WingetPath {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # Em sessão elevada o alias do App Installer às vezes não está no PATH.
    $pkg = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($pkg) { return $pkg.FullName }
    return $null
}

# Ids instalados que o winget reconhece.
function Get-WinKitInstalledAppId {
    $winget = Get-WingetPath
    if (-not $winget) { return @() }
    $file = Join-Path ([IO.Path]::GetTempPath()) ("winkit-export-{0}.json" -f [guid]::NewGuid().ToString('N'))
    try {
        $r = Invoke-WinKitProcess -FilePath $winget -ArgumentList 'export', '-o', $file, '--accept-source-agreements', '--disable-interactivity' -AllowInDryRun -TimeoutSeconds 300 -SuccessCodes 0, -1978335226
        if (-not (Test-Path $file)) { Write-WinKitLog "winget export não gerou arquivo (código $($r.ExitCode))." -Level Warn; return @() }
        $data = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($data.Sources | ForEach-Object { $_.Packages } | ForEach-Object { $_.PackageIdentifier })
    } finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
}

function Test-WinKitApp {
    [CmdletBinding()]
    param()
    $winget = Get-WingetPath
    if (-not $winget) {
        return New-WinKitResult -Check 'apps.winget' -Status warn -Code 'winget_missing' -Message 'winget não encontrado.' `
            -Fix 'Instale o "Instalador de Aplicativo" pela Microsoft Store (Windows 10/11). No Windows Server, o winget existe a partir do 2025.'
    }
    $installed = Get-WinKitInstalledAppId
    $known = @($script:Catalog | Where-Object { $installed -contains $_.id })
    New-WinKitResult -Check 'apps.installed' -Status ok -Message "$($installed.Count) programa(s) reconhecido(s) pelo winget; $($known.Count) do catálogo do WinKit." `
        -Detail @{ installed = $installed; catalog = @($known | ForEach-Object id) }
}

function Invoke-WinKitApp {
    [CmdletBinding()]
    param([string[]]$Install = @(), [bool]$UpgradeAll = $false)
    $winget = Get-WingetPath
    if (-not $winget) { return New-WinKitResult -Check 'apps.winget' -Status crit -Code 'winget_missing' -Message 'winget não encontrado; nada foi instalado.' }
    $common = @('--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity', '--source', 'winget')
    foreach ($id in $Install) {
        if ($id -notmatch $script:IdPattern) { New-WinKitResult -Check "apps.$id" -Status crit -Message "Id inválido: $id"; continue }
        $name = ($script:Catalog | Where-Object id -eq $id | Select-Object -First 1).name
        if (-not $name) { $name = $id }
        Write-WinKitLog "Instalando $name ($id)…"
        $r = Invoke-WinKitProcess -FilePath $winget -ArgumentList (@('install', '--id', $id, '--exact') + $common) -TimeoutSeconds 1800 -SuccessCodes $script:WingetOk
        if ($r.DryRun) { New-WinKitResult -Check "apps.$id" -Status info -Message "DryRun: instalaria $name." }
        elseif ($r.Success) {
            Add-WinKitCustomChange -Module 'Apps' -Description "instalou $name" -Data @{ id = $id }
            New-WinKitResult -Check "apps.$id" -Status ok -Message "$name instalado$(if ($r.ExitCode -ne 0) { ' (já estava)' })."
        } else { New-WinKitResult -Check "apps.$id" -Status crit -Message "$name falhou (código $($r.ExitCode))." -Detail $r.Output }
    }
    if ($UpgradeAll) {
        Write-WinKitLog 'Atualizando todos os programas pelo winget…'
        $r = Invoke-WinKitProcess -FilePath $winget -ArgumentList (@('upgrade', '--all', '--include-unknown') + $common) -TimeoutSeconds 5400 -SuccessCodes $script:WingetOk
        if ($r.DryRun) { New-WinKitResult -Check 'apps.upgrade' -Status info -Message 'DryRun: atualizaria todos os programas.' }
        elseif ($r.Success) { New-WinKitResult -Check 'apps.upgrade' -Status ok -Message 'Programas atualizados.' }
        else { New-WinKitResult -Check 'apps.upgrade' -Status warn -Message "Atualização terminou com código $($r.ExitCode); alguns programas podem não ter sido atualizados." -Detail $r.Output }
    }
}

# Undo: desinstala o que o WinKit instalou nesta execução.
function Undo-WinKitApp {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Data)
    $winget = Get-WingetPath
    if (-not $winget) { throw 'winget não encontrado.' }
    if ("$($Data.id)" -notmatch $script:IdPattern) { throw "Id inválido: $($Data.id)" }
    $r = Invoke-WinKitProcess -FilePath $winget -ArgumentList 'uninstall', '--id', $Data.id, '--exact', '--silent', '--disable-interactivity' -TimeoutSeconds 1800 -SuccessCodes 0
    if (-not $r.Success) { throw "winget uninstall terminou com código $($r.ExitCode)" }
}

Export-ModuleMember -Function Test-WinKitApp, Invoke-WinKitApp, Undo-WinKitApp, Get-WinKitAppCatalog, Get-WinKitInstalledAppId
