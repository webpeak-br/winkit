# Plugins: cada pasta em Modules\ é um módulo com manifest.json + <Id>.psm1.
# O Core lê o manifest, confere plataforma e build, carrega o código e chama as funções declaradas.

$script:ModuleRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules'
$script:Risks = @('none', 'low', 'medium', 'high')
$script:Platforms = @('Desktop', 'Server', 'ServerCore')

function Test-WinKitManifest {
    param([Parameter(Mandatory)]$Manifest, [string]$Folder = '')
    $errors = New-Object System.Collections.ArrayList
    foreach ($f in 'id', 'name', 'description', 'version', 'platforms', 'risk', 'functions') {
        if (-not ($Manifest.PSObject.Properties.Name -contains $f)) { [void]$errors.Add("campo obrigatório ausente: $f") }
    }
    if ($Manifest.id -and $Manifest.id -notmatch '^[A-Z][A-Za-z0-9]{1,39}$') { [void]$errors.Add("id inválido: $($Manifest.id) (PascalCase, só letras e números)") }
    if ($Folder -and $Manifest.id -and $Manifest.id -ne $Folder) { [void]$errors.Add("id ($($Manifest.id)) diferente da pasta ($Folder)") }
    if ($Manifest.risk -and $script:Risks -notcontains $Manifest.risk) { [void]$errors.Add("risk inválido: $($Manifest.risk)") }
    foreach ($p in @($Manifest.platforms)) { if ($script:Platforms -notcontains $p) { [void]$errors.Add("plataforma desconhecida: $p") } }
    if ($Manifest.functions) {
        if (-not $Manifest.functions.test) { [void]$errors.Add('functions.test é obrigatório: todo módulo começa pelo diagnóstico') }
        foreach ($k in 'test', 'invoke', 'undo', 'report') {
            $fn = $Manifest.functions.$k
            if ($fn -and $fn -notmatch '^(Test|Invoke|Undo|Get)-WinKit[A-Za-z0-9]+$') { [void]$errors.Add("functions.$k fora do padrão: $fn") }
        }
    }
    return @($errors)
}

function Get-WinKitModule {
    param([string]$Id, [string]$Edition, [int]$Build = 0, [string]$Root = $script:ModuleRoot)
    $all = foreach ($dir in Get-ChildItem -Path $Root -Directory -ErrorAction SilentlyContinue) {
        $file = Join-Path $dir.FullName 'manifest.json'
        if (-not (Test-Path $file)) { continue }
        $m = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
        $problems = Test-WinKitManifest -Manifest $m -Folder $dir.Name
        if ($problems.Count) { Write-WinKitLog "Módulo $($dir.Name) ignorado: $($problems -join '; ')" -Level Warn; continue }
        $m | Add-Member -NotePropertyName Path -NotePropertyValue $dir.FullName -Force
        $m
    }
    if ($Id) { $all = @($all | Where-Object { $_.id -eq $Id }) }
    if ($Edition) { $all = @($all | Where-Object { @($_.platforms) -contains $Edition }) }
    if ($Build) { $all = @($all | Where-Object { -not $_.minBuild -or $Build -ge [int]$_.minBuild }) }
    return @($all)
}

function Import-WinKitModuleCode {
    param([Parameter(Mandatory)]$Module)
    $psm = Join-Path $Module.Path "$($Module.id).psm1"
    if (-not (Test-Path $psm)) { throw "Módulo $($Module.id) sem $($Module.id).psm1" }
    Import-Module $psm -Force -Global -DisableNameChecking
}

# Executa uma etapa: test (diagnóstico), invoke (aplica), report. Risco médio/alto exige -Force ou confirmação.
function Invoke-WinKitModule {
    param(
        [Parameter(Mandatory)][string]$Id,
        [ValidateSet('test', 'invoke', 'report')][string]$Mode = 'test',
        [hashtable]$Params = @{},
        [switch]$Force
    )
    $mod = @(Get-WinKitModule -Id $Id)[0]
    if (-not $mod) { throw "Módulo não encontrado: $Id" }
    $envInfo = Get-WinKitEnvironment
    if (@($mod.platforms) -notcontains $envInfo.Edition) {
        Write-WinKitLog "Módulo $Id não se aplica a $($envInfo.Edition); ignorado." -Level Warn
        return @()
    }
    $fn = $mod.functions.$Mode
    if (-not $fn) { Write-WinKitLog "Módulo $Id não tem etapa '$Mode'." -Level Warn; return @() }
    if ($Mode -eq 'invoke' -and @('medium', 'high') -contains $mod.risk -and -not $Force -and -not (Test-WinKitDryRun)) {
        $answer = Read-Host "O módulo $Id tem risco $($mod.risk). Digite SIM para continuar"
        if ($answer -ne 'SIM') { Write-WinKitLog "Módulo $Id pulado pelo usuário." -Level Warn; return @() }
    }
    Import-WinKitModuleCode -Module $mod
    $p = Resolve-WinKitParameter -Module $mod -Params $Params
    # Cada função recebe só os parâmetros que declara (Test- e Invoke- usam partes diferentes do manifest).
    $accepted = (Get-Command $fn).Parameters.Keys
    foreach ($k in @($p.Keys)) { if ($accepted -notcontains $k) { $p.Remove($k) } }
    Write-WinKitLog "== $($mod.name) ($Mode) =="
    $res = @(& $fn @p)
    $run = Get-WinKitRun
    foreach ($r in $res) {
        if ($r -and $r.PSObject.Properties.Name -contains 'Status') {
            $r | Add-Member -NotePropertyName Module -NotePropertyValue $Id -Force
            if ($run) { [void]$run.Results.Add($r) }
        }
    }
    return $res
}

# Junta os padrões do manifest com o que o perfil ou a linha de comando passou; parâmetro desconhecido é erro.
function Resolve-WinKitParameter {
    param([Parameter(Mandatory)]$Module, [hashtable]$Params = @{})
    $out = @{}
    $decl = $Module.parameters
    if ($decl) { foreach ($prop in $decl.PSObject.Properties) { if ($null -ne $prop.Value.default) { $out[$prop.Name] = $prop.Value.default } } }
    foreach ($k in $Params.Keys) {
        if (-not $decl -or -not ($decl.PSObject.Properties.Name -contains $k)) { throw "Parâmetro '$k' não existe no módulo $($Module.id)." }
        $out[$k] = $Params[$k]
    }
    return $out
}

# Resultado padrão de um diagnóstico: o relatório e o painel (Linux Control) entendem este formato.
function New-WinKitResult {
    param(
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][ValidateSet('ok', 'info', 'warn', 'crit')][string]$Status,
        [Parameter(Mandatory)][string]$Message,
        [string]$Code = '',      # código estável do problema (ex.: disk_smart), igual ao do painel
        $Detail = $null,
        [string]$Fix = ''        # o que fazer, em texto
    )
    [pscustomobject]@{ Check = $Check; Status = $Status; Message = $Message; Code = $Code; Detail = $Detail; Fix = $Fix }
}
