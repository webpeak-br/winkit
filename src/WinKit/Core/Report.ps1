# Relatório: semáforo no console, report.json (máquina e painel) e report.html (gente), na pasta da execução.

$script:StatusOrder = @{ crit = 0; warn = 1; info = 2; ok = 3 }
$script:StatusLabel = @{ crit = 'CRÍTICO'; warn = 'ATENÇÃO'; info = 'INFO'; ok = 'OK' }

function Get-WinKitOverallStatus {
    param([object[]]$Results = @())
    foreach ($s in 'crit', 'warn') { if (@($Results | Where-Object Status -eq $s).Count) { return $s } }
    return 'ok'
}

function Write-WinKitReportConsole {
    param([object[]]$Results = @())
    $colors = @{ crit = 'Red'; warn = 'Yellow'; info = 'Cyan'; ok = 'Green' }
    foreach ($r in ($Results | Sort-Object { $script:StatusOrder[$_.Status] }, Module, Check)) {
        Write-Host ('[{0,-8}] ' -f $script:StatusLabel[$r.Status]) -ForegroundColor $colors[$r.Status] -NoNewline
        Write-Host ("{0} · {1}" -f $r.Module, $r.Message)
        if ($r.Fix -and $r.Status -ne 'ok') { Write-Host ("           → {0}" -f $r.Fix) -ForegroundColor DarkGray }
    }
}

function ConvertTo-WinKitHtml {
    param([string]$Text)
    return [System.Net.WebUtility]::HtmlEncode("$Text")
}

function Export-WinKitReport {
    param([object[]]$Results = @(), $Environment, [string]$Dir)
    $overall = Get-WinKitOverallStatus -Results $Results
    $data = [ordered]@{ generated = (Get-Date).ToString('o'); overall = $overall; environment = $Environment; results = $Results }
    $json = Join-Path $Dir 'report.json'
    $data | ConvertTo-Json -Depth 8 | Set-Content -Path $json -Encoding UTF8

    $rows = ($Results | Sort-Object { $script:StatusOrder[$_.Status] }, Module, Check | ForEach-Object {
        "<tr class='$($_.Status)'><td><span class='pill'>$($script:StatusLabel[$_.Status])</span></td><td>$(ConvertTo-WinKitHtml $_.Module)</td>" +
        "<td>$(ConvertTo-WinKitHtml $_.Message)$(if ($_.Fix -and $_.Status -ne 'ok') { "<div class='fix'>$(ConvertTo-WinKitHtml $_.Fix)</div>" })</td></tr>"
    }) -join "`n"
    $title = ConvertTo-WinKitHtml "WinKit · $($Environment.ComputerName)"
    $html = @"
<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>$title</title>
<style>body{font:14px/1.5 system-ui,Segoe UI,sans-serif;margin:24px;color:#222;background:#fafafa}h1{font-size:20px}
table{border-collapse:collapse;width:100%;background:#fff}td{padding:8px 10px;border-bottom:1px solid #eee;vertical-align:top}
.pill{font-size:11px;font-weight:600;padding:2px 8px;border-radius:10px;background:#eee}.crit .pill{background:#ffd9dd;color:#a1121f}
.warn .pill{background:#ffefcc;color:#8a5a00}.ok .pill{background:#d8f5e6;color:#0b6b3a}.info .pill{background:#dde8ff;color:#24439a}
.fix{color:#666;font-size:12px;margin-top:4px}.meta{color:#666}</style></head><body>
<h1>$title</h1><p class="meta">$(ConvertTo-WinKitHtml $Environment.Summary) · $(ConvertTo-WinKitHtml (Get-Date -Format 'dd/MM/yyyy HH:mm')) · geral: <b>$($script:StatusLabel[$overall])</b></p>
<table>$rows</table></body></html>
"@
    $htmlFile = Join-Path $Dir 'report.html'
    Set-Content -Path $htmlFile -Value $html -Encoding UTF8
    [pscustomobject]@{ Json = $json; Html = $htmlFile; Overall = $overall }
}
