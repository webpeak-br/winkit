# Downloads: só HTTPS, com novas tentativas, cache local e verificação de SHA-256 e da assinatura Authenticode.
# O WinKit nunca redistribui binários de terceiros: baixa da fonte oficial na hora e confere antes de executar.

function Get-WinKitCacheDir {
    $d = Join-Path (Get-WinKitDataRoot) 'cache'
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $d
}

# Assinatura válida e emitida para quem esperamos (ex.: 'Microsoft Corporation', 'Intel Corporation').
function Test-WinKitSignature {
    param([Parameter(Mandatory)][string]$Path, [string[]]$ExpectedSigner = @())
    $sig = Get-AuthenticodeSignature -FilePath $Path
    $subject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
    $signerOk = -not $ExpectedSigner.Count -or @($ExpectedSigner | Where-Object { $subject -match "CN=`"?$([regex]::Escape($_))" }).Count -gt 0
    [pscustomobject]@{ Valid = ($sig.Status -eq 'Valid') -and $signerOk; Status = "$($sig.Status)"; Subject = $subject; SignerMatches = $signerOk }
}

# Devolve o motivo da recusa ou vazio se o arquivo confere com o hash e o assinante esperados.
function Test-WinKitDownloadedFile {
    param([Parameter(Mandatory)][string]$Path, [string]$Sha256, [string[]]$ExpectedSigner = @(), [bool]$RequireSignature = $false)
    if ($Sha256 -and (Get-FileHash -Path $Path -Algorithm SHA256).Hash -ne $Sha256.ToUpper()) { return 'SHA-256 diferente do esperado' }
    if ($RequireSignature -or $ExpectedSigner.Count) {
        $s = Test-WinKitSignature -Path $Path -ExpectedSigner $ExpectedSigner
        if (-not $s.Valid) { return "assinatura inválida ($($s.Status), $($s.Subject))" }
    }
    return ''
}

function Get-WinKitDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$FileName,
        [string]$Sha256,
        [string[]]$ExpectedSigner = @(),
        [switch]$RequireSignature,
        [int]$Retries = 3
    )
    if ($Url -notmatch '^https://') { throw "Download recusado (só HTTPS): $Url" }
    if (-not $FileName) { $FileName = [IO.Path]::GetFileName(([uri]$Url).AbsolutePath) }
    if ($FileName -notmatch '^[\w.\- ()]+$') { throw "Nome de arquivo inválido: $FileName" }
    $dest = Join-Path (Get-WinKitCacheDir) $FileName

    $check = @{ Sha256 = $Sha256; ExpectedSigner = $ExpectedSigner; RequireSignature = [bool]$RequireSignature }
    if ((Test-Path $dest) -and -not (Test-WinKitDownloadedFile -Path $dest @check)) { Write-WinKitLog "Usando cache: $FileName" -Level Debug; return $dest }

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $tmp = "$dest.part"
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Write-WinKitLog "Baixando $Url (tentativa $i)"
            $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'   # a barra de progresso deixa o PS 5.1 muito lento
            try { Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -UserAgent 'WinKit (+https://github.com/webpeak-br/winkit)' }
            finally { $ProgressPreference = $old }
            $problem = Test-WinKitDownloadedFile -Path $tmp @check
            if ($problem) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue; throw "Arquivo recusado: $problem" }
            Move-Item -Path $tmp -Destination $dest -Force
            return $dest
        } catch {
            Write-WinKitLog "Falha no download: $($_.Exception.Message)" -Level Warn
            if ($_.Exception.Message -like 'Arquivo recusado*' -or $i -eq $Retries) { throw }
            Start-Sleep -Seconds ([math]::Pow(2, $i))
        }
    }
}
