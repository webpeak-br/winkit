# Perfis (receitas): JSON em src\WinKit\profiles com etapas { module, mode, params }. "extends" herda as etapas de outro perfil.
# Perfis do usuário ficam em %ProgramData%\WinKit\profiles e têm prioridade sobre os que vêm com o WinKit.

$script:ProfileRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'profiles'

function Get-WinKitProfileDirectory {
    @((Join-Path (Get-WinKitDataRoot) 'profiles'), $script:ProfileRoot) | Where-Object { Test-Path $_ }
}

function Read-WinKitProfileFile {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') { throw "Nome de perfil inválido: $Name" }
    foreach ($dir in Get-WinKitProfileDirectory) {
        $f = Join-Path $dir "$Name.json"
        if (Test-Path $f) { return Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json }
    }
    throw "Perfil não encontrado: $Name"
}

# Devolve o perfil com as etapas já resolvidas (herança aplicada, sem ciclos).
function Get-WinKitProfile {
    param([string]$Name)
    if (-not $Name) {
        return Get-WinKitProfileDirectory | ForEach-Object { Get-ChildItem $_ -Filter *.json } | ForEach-Object {
            $p = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            [pscustomobject]@{ Id = $p.id; Description = $p.description; Platforms = $p.platforms; File = $_.FullName }
        } | Sort-Object Id -Unique
    }
    $chain = New-Object System.Collections.ArrayList
    $cur = $Name
    while ($cur) {
        if ($chain -contains $cur) { throw "Herança circular de perfis: $($chain -join ' -> ') -> $cur" }
        [void]$chain.Add($cur)
        if ($chain.Count -gt 10) { throw 'Herança de perfis profunda demais.' }
        $p = Read-WinKitProfileFile -Name $cur
        if ($cur -eq $Name) { $top = $p }
        $cur = $p.extends
    }
    # Etapas do perfil-base primeiro, depois as de quem herda.
    $steps = New-Object System.Collections.ArrayList
    for ($i = $chain.Count - 1; $i -ge 0; $i--) {
        foreach ($s in @((Read-WinKitProfileFile -Name $chain[$i]).steps)) { [void]$steps.Add($s) }
    }
    [pscustomobject]@{ Id = $top.id; Description = $top.description; Platforms = @($top.platforms); Chain = @($chain); Steps = @($steps) }
}

function ConvertTo-WinKitHashtable {
    param($Object)
    $h = @{}
    if ($Object) { foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    return $h
}

# Grava um perfil do usuário a partir de uma lista de etapas (ex.: o que foi rodado numa máquina modelo).
function Export-WinKitProfile {
    param([Parameter(Mandatory)][string]$Name, [string]$Description = '', [string[]]$Platforms = @('Desktop', 'Server', 'ServerCore'),
          [Parameter(Mandatory)][object[]]$Steps, [string]$Extends)
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') { throw "Nome de perfil inválido: $Name" }
    $dir = Join-Path (Get-WinKitDataRoot) 'profiles'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $obj = [ordered]@{ id = $Name; description = $Description; extends = $Extends; platforms = $Platforms; steps = $Steps }
    $file = Join-Path $dir "$Name.json"
    $obj | ConvertTo-Json -Depth 8 | Set-Content -Path $file -Encoding UTF8
    return $file
}
