# Interface gráfica do WinKit (WPF). Cada operação roda num runspace separado, para a janela não travar;
# o log chega por uma fila e aparece na barra de baixo. Precisa de STA (o winkit.ps1 cuida disso).
# Os blocos de evento não usam GetNewClosure: precisam enxergar as funções e o $script:Gui deste arquivo.

$script:GuiPages = 'PageOverview', 'PageHealth', 'PageApps', 'PageDrivers', 'PageUpdates', 'PageMaint', 'PageHistory'

function Show-WinKitGui {
    [CmdletBinding()]
    param(
        [string]$Screenshot,     # CI: abre, espera os dados, salva um PNG de cada página e fecha
        [int]$ScreenshotWait = 20
    )
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $xaml = [xml](Get-Content (Join-Path $PSScriptRoot 'MainWindow.xaml') -Raw -Encoding UTF8)
    $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    $ui = @{}
    $xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
        $n = $_.Attributes | Where-Object LocalName -eq 'Name' | Select-Object -First 1
        $ui[$n.Value] = $win.FindName($n.Value)
    }
    $script:Gui = @{ Ui = $ui; Win = $win; Busy = $false; Task = $null; Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        ModulePath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'WinKit.psd1'); LastReport = $null; AppBoxes = @{}; UpdBoxes = @{}; DrvBoxes = @{}; VendorUrl = '' }
    $script:Colors = @{ ok = '#3ECF8E'; warn = '#F5B041'; crit = '#FF5C6C'; info = '#7AA2FF' }
    $script:StatusLabel = @{ ok = 'OK'; warn = 'Atenção'; crit = 'Crítico'; info = 'Info' }

    $ui.Version.Text = "WinKit $((Get-Module WinKit).Version)`ngithub.com/webpeak-br/winkit"
    $info = Get-WinKitEnvironment
    $ui.MachineName.Text = $info.ComputerName
    $ui.MachineInfo.Text = "$($info.Caption) · build $($info.Build) · $($info.Edition)$(if ($info.IsVirtual) { ' · máquina virtual' }) · $($info.Manufacturer) $($info.Model)$(if ($info.DomainJoined) { " · domínio $($info.Domain)" })"

    foreach ($b in $ui.NavPanel.Children) { $b.Add_Click({ param($s) Show-GuiPage $s.Tag }) }
    $ui.BtnToggleLog.Add_Click({
        $l = $script:Gui.Ui.LogBox
        $l.Visibility = if ($l.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' }
        $script:Gui.Ui.BtnToggleLog.Content = if ($l.Visibility -eq 'Visible') { 'Esconder log' } else { 'Mostrar log' }
    })

    # Visão geral e diagnóstico
    $ui.BtnRefresh.Add_Click({ Update-GuiCard })
    $ui.BtnQuickHealth.Add_Click({ Show-GuiPage 'PageHealth'; Start-GuiHealth })
    $ui.BtnRunHealth.Add_Click({ Start-GuiHealth })
    $ui.BtnOpenReport.Add_Click({ if ($script:Gui.LastReport) { Start-Process $script:Gui.LastReport } })

    # Aplicativos
    $ui.BtnAppsCheck.Add_Click({ Update-GuiInstalledApp })
    $ui.BtnAppsClear.Add_Click({ foreach ($c in $script:Gui.AppBoxes.Values) { if ($c.IsEnabled) { $c.IsChecked = $false } } })
    $ui.BtnAppsInstall.Add_Click({
        $ids = @($script:Gui.AppBoxes.GetEnumerator() | Where-Object { $_.Value.IsEnabled -and $_.Value.IsChecked } | ForEach-Object Key)
        if (-not $ids.Count) { Set-GuiStatus 'Marque pelo menos um aplicativo.'; return }
        Start-GuiTask -Title "Instalando $($ids.Count) aplicativo(s)" -Arguments @{ Ids = $ids } -Work {
            Invoke-WinKit -Module Apps -Mode invoke -ModuleParams @{ Install = $TaskArgs.Ids } -NoReport -Force
        } -Done { param($r) Show-GuiResult $r 'Instalação'; Update-GuiInstalledApp }
    })
    $ui.BtnAppsUpgrade.Add_Click({
        Start-GuiTask -Title 'Atualizando todos os programas (winget)' -Work {
            Invoke-WinKit -Module Apps -Mode invoke -ModuleParams @{ UpgradeAll = $true } -NoReport -Force
        } -Done { param($r) Show-GuiResult $r 'Atualização de programas' }
    })

    # Drivers
    $ui.BtnDrvScan.Add_Click({ Start-GuiDriverScan })
    $ui.BtnDrvVendor.Add_Click({ if ($script:Gui.VendorUrl) { Start-Process $script:Gui.VendorUrl } })
    $ui.BtnDrvBackup.Add_Click({
        Start-GuiTask -Title 'Backup dos drivers' -Work {
            Import-Module (Join-Path (Split-Path $ModulePath -Parent) 'Modules\Drivers\Drivers.psm1') -Force
            $dest = Join-Path (Get-WinKitDataRoot) ('drivers-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            $r = Export-WinKitDriverBackup -Destination $dest
            [pscustomobject]@{ Ok = $r.Success; Dest = $dest; Code = $r.ExitCode }
        } -Done {
            param($r)
            if ($r -and $r.Ok) { Set-GuiStatus "Backup salvo em $($r.Dest) (restore.ps1 reinstala)."; Start-Process explorer.exe $r.Dest }
            else { Set-GuiStatus "Backup falhou (código $($r.Code)); veja o log." }
        }
    })
    $ui.BtnDrvInstall.Add_Click({
        $ids = @($script:Gui.DrvBoxes.GetEnumerator() | Where-Object { $_.Value.IsChecked } | ForEach-Object Key)
        if (-not $ids.Count) { Set-GuiStatus 'Marque pelo menos um driver.'; return }
        $msg = "Instalar $($ids.Count) driver(s) do Windows Update? Antes, o WinKit faz backup dos drivers atuais."
        if ([Windows.MessageBox]::Show($msg, 'WinKit', 'YesNo') -ne 'Yes') { return }
        Start-GuiTask -Title "Instalando $($ids.Count) driver(s)" -Arguments @{ Ids = $ids } -Work {
            Invoke-WinKit -Module Drivers -Mode invoke -ModuleParams @{ UpdateIds = $TaskArgs.Ids; Backup = $true } -Force
        } -Done {
            param($r)
            Show-GuiResult $r 'Drivers'
            if ($r -and $r.RebootRequired) { [void][Windows.MessageBox]::Show('Reinicie o computador para concluir a instalação dos drivers.', 'WinKit') }
        }
    })

    # Atualizações do Windows
    $ui.BtnUpdFind.Add_Click({ Start-GuiFindUpdate })
    $ui.BtnUpdInstall.Add_Click({
        $ids = @($script:Gui.UpdBoxes.GetEnumerator() | Where-Object { $_.Value.IsChecked } | ForEach-Object Key)
        if (-not $ids.Count) { Set-GuiStatus 'Marque pelo menos uma atualização.'; return }
        $drivers = [bool]$script:Gui.Ui.ChkDrivers.IsChecked
        Start-GuiTask -Title "Instalando $($ids.Count) atualização(ões)" -Arguments @{ Ids = $ids; Drivers = $drivers } -Work {
            Invoke-WinKit -Module Updates -Mode invoke -ModuleParams @{ UpdateIds = $TaskArgs.Ids; IncludeDrivers = $TaskArgs.Drivers } -NoReport -Force
        } -Done {
            param($r)
            Show-GuiResult $r 'Windows Update'
            if ($r -and $r.RebootRequired) { [void][Windows.MessageBox]::Show('Reinicie o computador para concluir as atualizações.', 'WinKit') }
        }
    })

    # Manutenção
    $ui.BtnRepair.Add_Click({
        if ([Windows.MessageBox]::Show('Reparar o Windows com DISM e SFC? Pode levar até uma hora.', 'WinKit', 'YesNo') -ne 'Yes') { return }
        Start-GuiTask -Title 'Reparando o Windows (DISM + SFC)' -Work { Invoke-WinKit -ProfileName 'Reparo-Sistema' -Force } -Done { param($r) Show-GuiResult $r 'Reparo' }
    })
    $ui.BtnRestorePoint.Add_Click({
        Start-GuiTask -Title 'Criando ponto de restauração' -Work { New-WinKitRestorePoint -Description 'WinKit (manual)'; 'ok' } -Done { Set-GuiStatus 'Ponto de restauração solicitado (veja o log).' }
    })
    $ui.BtnOpenData.Add_Click({
        $d = Join-Path (Get-WinKitDataRoot) 'runs'
        if (-not (Test-Path $d)) { New-Item -ItemType Directory $d | Out-Null }
        Start-Process explorer.exe $d
    })
    $ui.BtnHistReload.Add_Click({ Show-GuiHistory })

    # Fila de log -> caixa de log e linha de status, a cada 250 ms; também detecta o fim da tarefa.
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        $line = $null
        while ($script:Gui.Queue.TryDequeue([ref]$line)) {
            $script:Gui.Ui.LogBox.AppendText("$line`r`n")
            $script:Gui.Ui.LogBox.ScrollToEnd()
            Set-GuiStatus ($line -replace '^\S+ \[\w+\] ', '')
        }
        $t = $script:Gui.Task
        if ($t -and $t.Handle.IsCompleted) { Complete-GuiTask }
    })
    $timer.Start()

    Show-GuiPage 'PageOverview'
    Update-GuiCard
    if ($Screenshot) { Save-GuiScreenshot -Path $Screenshot -Wait $ScreenshotWait; $timer.Stop(); return }
    [void]$win.ShowDialog()
    $timer.Stop()
}

# Processa os eventos da janela por alguns segundos (sem ShowDialog), para o CI conseguir fotografar.
function Wait-GuiEvent {
    param([double]$Seconds)
    $until = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $until) {
        $frame = New-Object Windows.Threading.DispatcherFrame
        [void][Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background,
            [Windows.Threading.DispatcherOperationCallback] { param($f) $f.Continue = $false; $null }, $frame)
        [Windows.Threading.Dispatcher]::PushFrame($frame)
        Start-Sleep -Milliseconds 100
    }
}

function Save-GuiScreenshot {
    param([string]$Path, [int]$Wait)
    $win = $script:Gui.Win
    $win.Show()
    Wait-GuiEvent $Wait
    $base = [IO.Path]::Combine([IO.Path]::GetDirectoryName($Path), [IO.Path]::GetFileNameWithoutExtension($Path))
    foreach ($p in 'PageOverview', 'PageApps', 'PageDrivers', 'PageMaint') {
        Show-GuiPage $p
        if ($p -eq 'PageDrivers') {
            Start-GuiDriverScan
            $limit = (Get-Date).AddMinutes(6)
            while ($script:Gui.Busy -and (Get-Date) -lt $limit) { Wait-GuiEvent 2 }
        }
        Wait-GuiEvent $(if ($p -eq 'PageApps') { 25 } else { 2 })
        $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]$win.ActualWidth), ([int]$win.ActualHeight), 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
        $bmp.Render($win)
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $fs = [IO.File]::Create("$base-$p.png")
        try { $enc.Save($fs) } finally { $fs.Close() }
    }
    $win.Close()
}

function Show-GuiPage {
    param([string]$Page)
    foreach ($p in $script:GuiPages) { $script:Gui.Ui[$p].Visibility = if ($p -eq $Page) { 'Visible' } else { 'Collapsed' } }
    foreach ($b in $script:Gui.Ui.NavPanel.Children) { $b.Background = if ($b.Tag -eq $Page) { '#2A2640' } else { 'Transparent' } }
    if ($Page -eq 'PageApps' -and -not $script:Gui.AppBoxes.Count) { Show-GuiApp }
    if ($Page -eq 'PageHistory') { Show-GuiHistory }
}

function Set-GuiStatus { param([string]$Text) $script:Gui.Ui.StatusLine.Text = $Text }

# Roda um bloco num runspace com o WinKit carregado. $TaskArgs leva os parâmetros; o último valor devolvido vai para -Done.
function Start-GuiTask {
    param([string]$Title, [scriptblock]$Work, [scriptblock]$Done, [hashtable]$Arguments = @{})
    if ($script:Gui.Busy) { Set-GuiStatus 'Aguarde a tarefa atual terminar.'; return }
    $script:Gui.Busy = $true
    $script:Gui.Ui.Busy.Visibility = 'Visible'
    Set-GuiStatus "$Title…"
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('TaskArgs', $Arguments)
    $rs.SessionStateProxy.SetVariable('LogQueue', $script:Gui.Queue)
    $rs.SessionStateProxy.SetVariable('ModulePath', $script:Gui.ModulePath)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript("`$env:WINKIT_QUIET = '1'; Import-Module `$ModulePath -Force; Set-WinKitLogSink `$LogQueue`n" + $Work.ToString())
    $script:Gui.Task = @{ Ps = $ps; Rs = $rs; Handle = $ps.BeginInvoke(); Done = $Done; Title = $Title }
}

function Complete-GuiTask {
    $t = $script:Gui.Task
    $script:Gui.Task = $null
    $out = $null
    try { $out = $t.Ps.EndInvoke($t.Handle) } catch { $script:Gui.Queue.Enqueue("ERRO: $($_.Exception.Message)") }
    foreach ($e in $t.Ps.Streams.Error) { $script:Gui.Queue.Enqueue("ERRO: $e") }
    $t.Ps.Dispose()
    $t.Rs.Close()
    $script:Gui.Busy = $false
    $script:Gui.Ui.Busy.Visibility = 'Collapsed'
    Set-GuiStatus "$($t.Title) · concluído."
    $last = if ($out -and $out.Count) { $out[$out.Count - 1] } else { $null }
    if ($t.Done) {
        try { & $t.Done $last } catch { Set-GuiStatus "Erro ao mostrar o resultado: $($_.Exception.Message)" }
    }
}

# ---- componentes visuais -----------------------------------------------------------------------

function New-GuiText {
    param([string]$Text, [string]$Color = '#ECEAF2', [double]$Size = 13, [string]$Weight = 'Normal')
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text
    $t.Foreground = $Color
    $t.FontSize = $Size
    $t.FontWeight = $Weight
    $t.TextWrapping = 'Wrap'
    return $t
}

function New-GuiCard {
    param([string]$Label, [string]$Value, [string]$Sub = '', [string]$Status = 'ok')
    $b = New-Object Windows.Controls.Border
    $b.Background = '#1E1D24'; $b.BorderBrush = '#2E2C38'; $b.BorderThickness = 1; $b.CornerRadius = 10
    $b.Padding = 16; $b.Margin = '0,0,14,14'; $b.Width = 230
    $sp = New-Object Windows.Controls.StackPanel
    [void]$sp.Children.Add((New-GuiText $Label '#A3A0B3' 12))
    $v = New-GuiText $Value $script:Colors[$Status] 24 'SemiBold'
    $v.Margin = '0,4,0,2'
    [void]$sp.Children.Add($v)
    if ($Sub) { [void]$sp.Children.Add((New-GuiText $Sub '#8C899C' 11.5)) }
    $b.Child = $sp
    return $b
}

function Update-GuiCard {
    Start-GuiTask -Title 'Lendo o estado da máquina' -Work {
        $os = Get-CimInstance Win32_OperatingSystem
        $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
        $cpu = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
        $av = Get-WinKitAntivirusStatus
        $fw = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Enabled }).Count
        $hf = Get-HotFix -ErrorAction SilentlyContinue | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1
        [pscustomobject]@{
            Cpu = [int]$cpu
            MemPct = [int](100 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize * 100)
            MemGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
            DiskPct = [int](100 - $c.FreeSpace / $c.Size * 100)
            DiskFree = [math]::Round($c.FreeSpace / 1GB, 1)
            UptimeDays = [int]((Get-Date) - $os.LastBootUpTime).TotalDays
            AvText = $av.Text; AvName = $av.Name; AvStatus = $av.Status
            FirewallOff = $fw
            LastUpdate = if ($hf) { [int]((Get-Date) - $hf.InstalledOn).TotalDays } else { -1 }
        }
    } -Done {
        param($m)
        $cards = $script:Gui.Ui.Cards
        $cards.Children.Clear()
        if (-not $m) { return }
        $lv = { param($v, $w, $c) if ($v -ge $c) { 'crit' } elseif ($v -ge $w) { 'warn' } else { 'ok' } }
        [void]$cards.Children.Add((New-GuiCard 'CPU' "$($m.Cpu)%" 'uso agora' (& $lv $m.Cpu 90 101)))
        [void]$cards.Children.Add((New-GuiCard 'Memória' "$($m.MemPct)%" "de $($m.MemGB) GB" (& $lv $m.MemPct 85 95)))
        [void]$cards.Children.Add((New-GuiCard "Disco $env:SystemDrive" "$($m.DiskPct)%" "$($m.DiskFree) GB livres" (& $lv $m.DiskPct 80 90)))
        [void]$cards.Children.Add((New-GuiCard 'Ligado há' "$($m.UptimeDays) dia(s)" 'desde o último reinício' (& $lv $m.UptimeDays 60 365)))
        [void]$cards.Children.Add((New-GuiCard 'Antivírus' $m.AvText $m.AvName $m.AvStatus))
        $fwText = if ($m.FirewallOff) { "$($m.FirewallOff) perfil(s) desligado(s)" } else { 'ligado' }
        [void]$cards.Children.Add((New-GuiCard 'Firewall' $fwText 'todos os perfis' $(if ($m.FirewallOff) { 'warn' } else { 'ok' })))
        $upText = if ($m.LastUpdate -ge 0) { "há $($m.LastUpdate) dia(s)" } else { '—' }
        [void]$cards.Children.Add((New-GuiCard 'Última atualização' $upText 'Windows Update' $(if ($m.LastUpdate -gt 45) { 'warn' } else { 'ok' })))
    }
}

function New-GuiResultRow {
    param($Result)
    $st = "$($Result.Status)"
    $b = New-Object Windows.Controls.Border
    $b.Background = '#1E1D24'; $b.BorderBrush = '#2E2C38'; $b.BorderThickness = 1; $b.CornerRadius = 8; $b.Padding = '14,10'; $b.Margin = '0,0,0,8'
    $g = New-Object Windows.Controls.DockPanel
    $dot = New-Object Windows.Shapes.Ellipse
    $dot.Width = 10; $dot.Height = 10; $dot.Fill = $script:Colors[$st]; $dot.Margin = '0,4,12,0'; $dot.VerticalAlignment = 'Top'
    [Windows.Controls.DockPanel]::SetDock($dot, 'Left')
    [void]$g.Children.Add($dot)
    $tag = New-GuiText ($script:StatusLabel[$st].ToUpper()) $script:Colors[$st] 11 'SemiBold'
    $tag.Margin = '12,2,0,0'
    [Windows.Controls.DockPanel]::SetDock($tag, 'Right')
    [void]$g.Children.Add($tag)
    $sp = New-Object Windows.Controls.StackPanel
    [void]$sp.Children.Add((New-GuiText "$($Result.Message)" '#ECEAF2' 13.5))
    if ($Result.Fix -and $st -ne 'ok') {
        $f = New-GuiText "→ $($Result.Fix)" '#A3A0B3' 12
        $f.Margin = '0,3,0,0'
        [void]$sp.Children.Add($f)
    }
    [void]$g.Children.Add($sp)
    $b.Child = $g
    return $b
}

function Show-GuiResult {
    param($Run, [string]$What)
    if (-not $Run) { Set-GuiStatus "$What terminou sem resultado (veja o log)."; return }
    $list = $script:Gui.Ui.HealthList
    $list.Children.Clear()
    $order = @{ crit = 0; warn = 1; info = 2; ok = 3 }
    foreach ($r in (@($Run.Results) | Sort-Object { $order["$($_.Status)"] })) { [void]$list.Children.Add((New-GuiResultRow $r)) }
    $report = Join-Path $Run.Dir 'report.html'
    if (Test-Path $report) { $script:Gui.LastReport = $report; $script:Gui.Ui.BtnOpenReport.IsEnabled = $true }
    $o = "$($Run.Overall)"
    $script:Gui.Ui.StatusText.Text = "${What}: $($script:StatusLabel[$o])"
    $script:Gui.Ui.StatusPill.Background = $script:Colors[$o]
    $script:Gui.Ui.StatusText.Foreground = '#141318'
    if ($What -ne 'Diagnóstico') { Show-GuiPage 'PageHealth' }
    Set-GuiStatus "${What} concluído: $($script:StatusLabel[$o])$(if ($Run.RebootRequired) { ' · reinicie para concluir' })."
}

function Start-GuiHealth {
    $script:Gui.Ui.HealthList.Children.Clear()
    [void]$script:Gui.Ui.HealthList.Children.Add((New-GuiText 'Analisando… (de 30 segundos a alguns minutos)' '#A3A0B3'))
    Start-GuiTask -Title 'Diagnóstico' -Work { Invoke-WinKit -ProfileName 'Diagnostico' } -Done { param($r) Show-GuiResult $r 'Diagnóstico' }
}

function Show-GuiApp {
    $list = $script:Gui.Ui.AppsList
    $list.Children.Clear()
    $catalog = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules\Apps\catalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($group in ($catalog | Group-Object category)) {
        $h = New-GuiText $group.Name '#B5BAFE' 14 'SemiBold'
        $h.Margin = '0,10,0,6'
        [void]$list.Children.Add($h)
        $wrap = New-Object Windows.Controls.WrapPanel
        foreach ($a in $group.Group) {
            $cb = New-Object Windows.Controls.CheckBox
            $cb.Content = $a.name
            $cb.Width = 230
            $cb.ToolTip = $a.id
            $script:Gui.AppBoxes[$a.id] = $cb
            [void]$wrap.Children.Add($cb)
        }
        [void]$list.Children.Add($wrap)
    }
    Update-GuiInstalledApp
}

function Update-GuiInstalledApp {
    Start-GuiTask -Title 'Verificando programas instalados' -Work {
        Import-Module (Join-Path (Split-Path $ModulePath -Parent) 'Modules\Apps\Apps.psm1') -Force
        , @(Get-WinKitInstalledAppId)
    } -Done {
        param($ids)
        foreach ($kv in $script:Gui.AppBoxes.GetEnumerator()) {
            $on = @($ids) -contains $kv.Key
            $kv.Value.IsEnabled = -not $on
            if ($on) { $kv.Value.IsChecked = $true; $kv.Value.Foreground = '#3ECF8E' }
        }
        Set-GuiStatus "$(@($ids).Count) programa(s) reconhecido(s) pelo winget; os do catálogo já instalados estão em verde."
    }
}

function Start-GuiFindUpdate {
    $list = $script:Gui.Ui.UpdList
    $list.Children.Clear()
    [void]$list.Children.Add((New-GuiText 'Procurando no Windows Update… (pode levar alguns minutos)' '#A3A0B3'))
    $drivers = [bool]$script:Gui.Ui.ChkDrivers.IsChecked
    Start-GuiTask -Title 'Procurando atualizações' -Arguments @{ Drivers = $drivers } -Work {
        Import-Module (Join-Path (Split-Path $ModulePath -Parent) 'Modules\Updates\Updates.psm1') -Force
        $r = Test-WinKitUpdate -IncludeDrivers $TaskArgs.Drivers
        , @($r.Detail)
    } -Done {
        param($items)
        $list = $script:Gui.Ui.UpdList
        $list.Children.Clear()
        $script:Gui.UpdBoxes = @{}
        $items = @($items | Where-Object { $_ -and $_.Id })
        if (-not $items.Count) {
            [void]$list.Children.Add((New-GuiText 'Nenhuma atualização pendente. O Windows está em dia.' '#3ECF8E' 14))
            $script:Gui.Ui.BtnUpdInstall.IsEnabled = $false
            return
        }
        foreach ($u in $items) {
            $cb = New-Object Windows.Controls.CheckBox
            $cb.IsChecked = $true
            $cb.Content = "$($u.Title)$(if ($u.KB) { "  ($($u.KB))" })$(if ($u.SizeMB) { " · $($u.SizeMB) MB" })"
            if ($u.Security) { $cb.Foreground = '#F5B041' }
            $script:Gui.UpdBoxes[$u.Id] = $cb
            [void]$list.Children.Add($cb)
        }
        $script:Gui.Ui.BtnUpdInstall.IsEnabled = $true
        Set-GuiStatus "$($items.Count) atualização(ões) encontrada(s); as de segurança estão em amarelo."
    }
}

function Show-GuiHistory {
    $list = $script:Gui.Ui.HistList
    $list.Children.Clear()
    $runs = @(Get-WinKitRunList | Select-Object -First 40)
    if (-not $runs.Count) { [void]$list.Children.Add((New-GuiText 'Nenhuma execução registrada ainda.' '#A3A0B3')); return }
    foreach ($r in $runs) {
        $b = New-Object Windows.Controls.Border
        $b.Background = '#1E1D24'; $b.BorderBrush = '#2E2C38'; $b.BorderThickness = 1; $b.CornerRadius = 8; $b.Padding = '14,10'; $b.Margin = '0,0,0,8'
        $d = New-Object Windows.Controls.DockPanel
        $btns = New-Object Windows.Controls.StackPanel
        $btns.Orientation = 'Horizontal'
        [Windows.Controls.DockPanel]::SetDock($btns, 'Right')
        $report = Join-Path (Join-Path (Join-Path (Get-WinKitDataRoot) 'runs') $r.id) 'report.html'
        if (Test-Path $report) {
            $o = New-Object Windows.Controls.Button
            $o.Content = 'Relatório'
            $o.Tag = $report
            $o.Add_Click({ param($s) Start-Process $s.Tag })
            [void]$btns.Children.Add($o)
        }
        if ($r.changes -gt 0 -and -not $r.dryRun) {
            $u = New-Object Windows.Controls.Button
            $u.Content = 'Desfazer'
            $u.Tag = $r.id
            $u.Add_Click({
                param($s)
                if ([Windows.MessageBox]::Show("Desfazer as alterações da execução $($s.Tag)?", 'WinKit', 'YesNo') -ne 'Yes') { return }
                Start-GuiTask -Title "Desfazendo $($s.Tag)" -Arguments @{ Id = $s.Tag } -Work { Undo-WinKitRun -RunId $TaskArgs.Id } -Done {
                    param($x)
                    Set-GuiStatus "Desfeito: $($x.Undone) alteração(ões), $($x.Failed) falha(s)."
                    Show-GuiHistory
                }
            })
            [void]$btns.Children.Add($u)
        }
        [void]$d.Children.Add($btns)
        $sp = New-Object Windows.Controls.StackPanel
        $what = if ($r.profile) { "Perfil $($r.profile)" } else { "Módulos: $(@($r.modules) -join ', ')" }
        [void]$sp.Children.Add((New-GuiText $what '#ECEAF2' 13.5 'SemiBold'))
        $when = try { ([datetime]$r.started).ToString('dd/MM/yyyy HH:mm') } catch { "$($r.started)" }
        [void]$sp.Children.Add((New-GuiText "$when · $($r.changes) alteração(ões)$(if ($r.dryRun) { ' · simulação' })$(if ($r.reboot) { ' · pediu reinício' })" '#A3A0B3' 12))
        [void]$d.Children.Add($sp)
        $b.Child = $d
        [void]$list.Children.Add($b)
    }
}

function New-GuiLink {
    param([string]$Text, [string]$Url)
    $t = New-Object Windows.Controls.TextBlock
    $h = New-Object Windows.Documents.Hyperlink
    $h.Inlines.Add($Text) | Out-Null
    $h.NavigateUri = [uri]$Url
    $h.Foreground = '#B5BAFE'
    $h.Add_RequestNavigate({ Start-Process $_.Uri.AbsoluteUri })
    [void]$t.Inlines.Add($h)
    $t.Margin = '0,2,14,0'
    return $t
}

function New-GuiBox {
    $b = New-Object Windows.Controls.Border
    $b.Background = '#1E1D24'; $b.BorderBrush = '#2E2C38'; $b.BorderThickness = 1; $b.CornerRadius = 8; $b.Padding = '14,10'; $b.Margin = '0,0,0,8'
    return $b
}

function Start-GuiDriverScan {
    $list = $script:Gui.Ui.DrvList
    $list.Children.Clear()
    [void]$list.Children.Add((New-GuiText 'Analisando dispositivos e procurando drivers no Windows Update… (de 1 a 5 minutos)' '#A3A0B3'))
    $script:Gui.Ui.BtnDrvInstall.IsEnabled = $false
    Start-GuiTask -Title 'Analisando drivers' -Work {
        Import-Module (Join-Path (Split-Path $ModulePath -Parent) 'Modules\Drivers\Drivers.psm1') -Force
        $res = @(Test-WinKitDriver -SearchWindowsUpdate $true)
        , $res
    } -Done { param($res) Show-GuiDriver @($res) }
}

function Show-GuiDriver {
    param([object[]]$Results)
    $ui = $script:Gui.Ui
    $list = $ui.DrvList
    $list.Children.Clear()
    $script:Gui.DrvBoxes = @{}
    $inv = $Results | Where-Object Check -eq 'drivers.inventory' | Select-Object -First 1
    $probs = $Results | Where-Object Check -eq 'drivers.problems' | Select-Object -First 1
    $upd = $Results | Where-Object Check -eq 'drivers.updates' | Select-Object -First 1
    foreach ($x in @($Results | Where-Object Check -eq 'drivers.wu')) { [void]$list.Children.Add((New-GuiText $x.Message '#F5B041')) }
    if (-not $inv) { [void]$list.Children.Add((New-GuiText 'A análise não terminou (veja o log).' '#FF5C6C')); return }
    $m = $inv.Detail.machine
    $ui.DrvMachine.Text = "Máquina: $($m.manufacturer) $($m.model) · placa $($m.board) · BIOS $($m.bios)"
    $script:Gui.VendorUrl = $m.vendorUrl
    $ui.BtnDrvVendor.IsEnabled = [bool]$m.vendorUrl

    # 1. Dispositivos com problema
    $bad = @($probs.Detail | Where-Object { $_ -and $_.Name })
    $h = New-GuiText "Dispositivos com problema ($($bad.Count))" $(if ($bad.Count) { '#F5B041' } else { '#3ECF8E' }) 15 'SemiBold'
    $h.Margin = '0,4,0,8'; [void]$list.Children.Add($h)
    if (-not $bad.Count) { [void]$list.Children.Add((New-GuiText 'Nenhum: todos os dispositivos estão com driver funcionando.' '#A3A0B3')) }
    foreach ($d in $bad) {
        $b = New-GuiBox
        $sp = New-Object Windows.Controls.StackPanel
        [void]$sp.Children.Add((New-GuiText "$($d.Name) — $($d.Problem)" '#ECEAF2' 13.5 'SemiBold'))
        [void]$sp.Children.Add((New-GuiText "Código de hardware: $(@($d.HardwareIds | Select-Object -First 2) -join '  ·  ')" '#A3A0B3' 12))
        $links = New-Object Windows.Controls.WrapPanel
        if ($d.CatalogUrl) { [void]$links.Children.Add((New-GuiLink 'Procurar no Microsoft Update Catalog' $d.CatalogUrl)) }
        if ($m.vendorUrl) { [void]$links.Children.Add((New-GuiLink 'Página de drivers do fabricante' $m.vendorUrl)) }
        [void]$sp.Children.Add($links)
        $b.Child = $sp
        [void]$list.Children.Add($b)
    }

    # 2. Drivers disponíveis no Windows Update
    $ups = @($upd.Detail | Where-Object { $_ -and $_.Id })
    $h = New-GuiText "Disponíveis no Windows Update ($($ups.Count))" '#B5BAFE' 15 'SemiBold'
    $h.Margin = '0,14,0,8'; [void]$list.Children.Add($h)
    if (-not $ups.Count) { [void]$list.Children.Add((New-GuiText 'Nenhum driver novo oferecido para esta máquina.' '#A3A0B3')) }
    foreach ($u in $ups) {
        $cb = New-Object Windows.Controls.CheckBox
        $fix = @($u.FixesDevices)
        $cb.IsChecked = $fix.Count -gt 0
        $cb.Content = "$($u.Title)$(if ($u.Date) { " · $($u.Date)" })$(if ($u.SizeMB) { " · $($u.SizeMB) MB" })$(if ($fix.Count) { "  → resolve: $($fix -join ', ')" })"
        if ($fix.Count) { $cb.Foreground = '#3ECF8E' }
        $cb.ToolTip = "Fornecedor: $($u.Provider) · Classe: $($u.Class) · Hardware: $($u.HardwareId)"
        $script:Gui.DrvBoxes[$u.Id] = $cb
        [void]$list.Children.Add($cb)
    }
    $ui.BtnDrvInstall.IsEnabled = $ups.Count -gt 0

    # 3. Ferramentas oficiais dos fabricantes de chips
    $h = New-GuiText 'Ferramentas oficiais' '#B5BAFE' 15 'SemiBold'
    $h.Margin = '0,14,0,6'; [void]$list.Children.Add($h)
    $tools = New-Object Windows.Controls.WrapPanel
    foreach ($k in @($m.chipTools.Keys)) { if ($k) { [void]$tools.Children.Add((New-GuiLink $k $m.chipTools[$k])) } }
    [void]$list.Children.Add($tools)

    # 4. Drivers instalados
    $drv = @($inv.Detail.drivers | Where-Object { $_ } | Sort-Object Class, Device)
    $h = New-GuiText "Drivers instalados ($($drv.Count))" '#B5BAFE' 15 'SemiBold'
    $h.Margin = '0,14,0,6'; [void]$list.Children.Add($h)
    $grid = New-Object Windows.Controls.DataGrid
    $grid.ItemsSource = $drv | Select-Object @{ n = 'Dispositivo'; e = { $_.Device } }, @{ n = 'Classe'; e = { $_.Class } }, @{ n = 'Fornecedor'; e = { $_.Provider } },
        @{ n = 'Versão'; e = { $_.Version } }, @{ n = 'Data'; e = { $_.Date } }, @{ n = 'Assinado'; e = { if ($_.Signed) { 'sim' } else { 'NÃO' } } }
    $grid.IsReadOnly = $true; $grid.AutoGenerateColumns = $true; $grid.HeadersVisibility = 'Column'; $grid.MaxHeight = 420
    $grid.Background = '#1E1D24'; $grid.RowBackground = '#1E1D24'; $grid.AlternatingRowBackground = '#23222A'; $grid.Foreground = '#ECEAF2'
    $grid.BorderBrush = '#2E2C38'; $grid.GridLinesVisibility = 'None'; $grid.CanUserAddRows = $false
    $hs = New-Object Windows.Style ([Windows.Controls.Primitives.DataGridColumnHeader])
    $H = [Windows.Controls.Primitives.DataGridColumnHeader]
    $setters = @(@($H::BackgroundProperty, '#26242E'), @($H::ForegroundProperty, '#A3A0B3'), @($H::PaddingProperty, '8,6'), @($H::BorderThicknessProperty, '0'))
    foreach ($pair in $setters) {
        $conv = [ComponentModel.TypeDescriptor]::GetConverter($pair[0].PropertyType)
        $hs.Setters.Add((New-Object Windows.Setter ($pair[0], $conv.ConvertFromInvariantString($pair[1]))))
    }
    $grid.ColumnHeaderStyle = $hs
    [void]$list.Children.Add($grid)
    Set-GuiStatus "$($drv.Count) drivers instalados · $($bad.Count) dispositivo(s) com problema · $($ups.Count) driver(s) no Windows Update."
}
