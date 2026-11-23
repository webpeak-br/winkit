# Execução de programas externos. A decisão é sempre pelo código de saída, nunca pelo texto da saída,
# que muda conforme o idioma do Windows (pnputil, dism, sfc…).

# Códigos de sucesso conhecidos: 3010 e 1641 = sucesso, precisa reiniciar (MSI/Windows Installer).
$script:RebootCodes = @(3010, 1641)

function Invoke-WinKitProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int[]]$SuccessCodes = @(0),
        [int]$TimeoutSeconds = 3600,
        [switch]$AllowInDryRun   # comandos só de leitura (ex.: dism /CheckHealth) rodam também no DryRun
    )
    $cmdline = "$FilePath $($ArgumentList -join ' ')"
    if ((Test-WinKitDryRun) -and -not $AllowInDryRun) {
        Write-WinKitLog "[DryRun] executaria: $cmdline"
        return [pscustomobject]@{ ExitCode = 0; Success = $true; RebootRequired = $false; Output = ''; DryRun = $true; TimedOut = $false }
    }
    Write-WinKitLog "Executando: $cmdline" -Level Debug
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($ArgumentList | ForEach-Object { if ($_ -match '\s' -and $_ -notmatch '^".*"$') { "`"$_`"" } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    # Lê de forma assíncrona: ler stdout e stderr em sequência trava quando um dos buffers enche.
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    $timedOut = -not $p.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) { try { $p.Kill() } catch { Write-WinKitLog "Não consegui encerrar $FilePath após o prazo." -Level Warn } }
    $code = if ($timedOut) { -1 } else { $p.ExitCode }
    $reboot = $script:RebootCodes -contains $code
    $ok = -not $timedOut -and (($SuccessCodes -contains $code) -or $reboot)
    if ($reboot) { $run = Get-WinKitRun; if ($run) { $run.Reboot = $true } }
    [pscustomobject]@{
        ExitCode = $code; Success = $ok; RebootRequired = $reboot; TimedOut = $timedOut; DryRun = $false
        Output = ($out.Result + $err.Result).Trim()
    }
}
