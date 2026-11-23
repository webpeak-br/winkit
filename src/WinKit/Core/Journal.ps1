# Diário de alterações e undo. Módulos nunca alteram registro ou serviço direto: usam as funções daqui, que
# guardam o estado anterior no journal.json da execução antes de mudar e respeitam o DryRun.
# "winkit undo -RunId X" lê o diário e desfaz na ordem inversa.

function Add-WinKitJournal {
    param([Parameter(Mandatory)][hashtable]$Entry)
    $run = Get-WinKitRun
    if (-not $run) { throw 'Nenhuma execução em andamento (New-WinKitRun).' }
    $Entry.at = (Get-Date).ToString('o')
    [void]$run.Journal.Add([pscustomobject]$Entry)
    Save-WinKitJournal
}

function Save-WinKitJournal {
    $run = Get-WinKitRun
    if ($run) { ConvertTo-Json -InputObject @($run.Journal) -Depth 6 | Set-Content -Path (Join-Path $run.Dir 'journal.json') -Encoding UTF8 }
}

function Test-WinKitDryRun { $run = Get-WinKitRun; return [bool]($run -and $run.DryRun) }

function Get-WinKitRegistryValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    if (-not (Test-Path $Path)) { return [pscustomobject]@{ KeyExisted = $false; Exists = $false; Kind = $null; Value = $null } }
    $key = Get-Item -Path $Path
    if ($key.GetValueNames() -notcontains $Name) { return [pscustomobject]@{ KeyExisted = $true; Exists = $false; Kind = $null; Value = $null } }
    [pscustomobject]@{ KeyExisted = $true; Exists = $true; Kind = $key.GetValueKind($Name).ToString(); Value = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames') }
}

function Set-WinKitRegistryValue {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Value,
          [ValidateSet('String', 'ExpandString', 'DWord', 'QWord', 'MultiString', 'Binary')][string]$Kind = 'DWord', [string]$Reason = '')
    $before = Get-WinKitRegistryValue -Path $Path -Name $Name
    if ($before.Exists -and $before.Kind -eq $Kind -and "$($before.Value)" -eq "$Value") {
        Write-WinKitLog "Registro já ok: $Path\$Name = $Value" -Level Debug
        return $false
    }
    if (Test-WinKitDryRun) { Write-WinKitLog "[DryRun] registro $Path\$Name : $($before.Value) -> $Value $Reason"; return $true }
    if (-not $PSCmdlet.ShouldProcess("$Path\$Name", "definir $Value")) { return $false }
    Add-WinKitJournal @{ type = 'registry'; path = $Path; name = $Name; keyExisted = $before.KeyExisted; existed = $before.Exists
        kind = $before.Kind; value = $before.Value; newValue = $Value; reason = $Reason }
    if (-not $before.KeyExisted) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Kind -Force | Out-Null
    Write-WinKitLog "Registro $Path\$Name = $Value $Reason" -Level Ok
    return $true
}

function Set-WinKitServiceStartup {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][ValidateSet('Automatic', 'Manual', 'Disabled')][string]$StartupType,
          [switch]$Stop, [string]$Reason = '')
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { Write-WinKitLog "Serviço $Name não existe nesta máquina; ignorado." -Level Debug; return $false }
    if ("$($svc.StartType)" -eq $StartupType -and -not ($Stop -and $svc.Status -eq 'Running')) { return $false }
    if (Test-WinKitDryRun) { Write-WinKitLog "[DryRun] serviço $Name : $($svc.StartType) -> $StartupType $Reason"; return $true }
    if (-not $PSCmdlet.ShouldProcess($Name, "inicialização $StartupType")) { return $false }
    Add-WinKitJournal @{ type = 'service'; name = $Name; startType = "$($svc.StartType)"; wasRunning = ($svc.Status -eq 'Running'); reason = $Reason }
    Set-Service -Name $Name -StartupType $StartupType
    if ($Stop -and $svc.Status -eq 'Running') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
    Write-WinKitLog "Serviço ${Name}: inicialização $StartupType $Reason" -Level Ok
    return $true
}

# Alteração que só o módulo sabe desfazer: o diário guarda o módulo e os dados; o undo chama Undo-<Módulo> com eles.
function Add-WinKitCustomChange {
    param([Parameter(Mandatory)][string]$Module, [Parameter(Mandatory)][string]$Description, [hashtable]$Data = @{})
    if (Test-WinKitDryRun) { return }
    Add-WinKitJournal @{ type = 'custom'; module = $Module; description = $Description; data = $Data }
}

function Undo-WinKitEntry {
    param([Parameter(Mandatory)]$Entry)
    switch ($Entry.type) {
        'registry' {
            if (-not $Entry.existed) {
                if (Test-Path $Entry.path) { Remove-ItemProperty -Path $Entry.path -Name $Entry.name -ErrorAction SilentlyContinue }
                if (-not $Entry.keyExisted -and (Test-Path $Entry.path) -and -not (Get-Item $Entry.path).ValueCount -and -not (Get-ChildItem $Entry.path)) {
                    Remove-Item -Path $Entry.path -ErrorAction SilentlyContinue
                }
            } else {
                New-ItemProperty -Path $Entry.path -Name $Entry.name -Value $Entry.value -PropertyType $Entry.kind -Force | Out-Null
            }
            return "registro $($Entry.path)\$($Entry.name)"
        }
        'service' {
            Set-Service -Name $Entry.name -StartupType $Entry.startType
            if ($Entry.wasRunning) { Start-Service -Name $Entry.name -ErrorAction SilentlyContinue }
            return "serviço $($Entry.name)"
        }
        'custom' {
            $mod = Get-WinKitModule -Id $Entry.module
            if (-not $mod -or -not $mod.functions.undo) { throw "Módulo $($Entry.module) não sabe desfazer: $($Entry.description)" }
            Import-WinKitModuleCode -Module $mod
            & $mod.functions.undo -Data $Entry.data
            return $Entry.description
        }
        default { throw "Tipo de alteração desconhecido no diário: $($Entry.type)" }
    }
}

function Undo-WinKitRun {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$RunId)
    if ($RunId -notmatch '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$') { throw "RunId inválido: $RunId" }
    $file = Join-Path (Join-Path (Join-Path (Get-WinKitDataRoot) 'runs') $RunId) 'journal.json'
    if (-not (Test-Path $file)) { throw "Execução $RunId não encontrada ou sem alterações." }
    $entries = @(Get-Content $file -Raw | ConvertFrom-Json)
    [array]::Reverse($entries)
    $ok = 0; $fail = 0
    foreach ($e in $entries) {
        if (-not $PSCmdlet.ShouldProcess("$($e.type) $($e.path)$($e.name)", 'desfazer')) { continue }
        try { $what = Undo-WinKitEntry -Entry $e; Write-WinKitLog "Desfeito: $what" -Level Ok; $ok++ }
        catch { Write-WinKitLog "Falhou ao desfazer: $($_.Exception.Message)" -Level Error; $fail++ }
    }
    [pscustomobject]@{ RunId = $RunId; Undone = $ok; Failed = $fail }
}
