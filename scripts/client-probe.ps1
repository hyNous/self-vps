param(
    [string]$PushUrl = $env:SELF_VPS_PUSH_URL,
    [string]$Proxy = "http://127.0.0.1:7890",
    [string]$ConfigPath = (Join-Path $env:APPDATA "self-vps\probe.url")
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if ([string]::IsNullOrWhiteSpace($PushUrl)) {
    if (Test-Path $ConfigPath) {
        $PushUrl = (Get-Content -Raw $ConfigPath).Trim()
    }
}
if ([string]::IsNullOrWhiteSpace($PushUrl)) {
    throw "Push URL is not configured in SELF_VPS_PUSH_URL or $ConfigPath"
}

$start = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
try {
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        throw "curl.exe is not available"
    }

    $egress = (& curl.exe -4 -sS --max-time 20 -x $Proxy https://api.ipify.org 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $egress -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        throw "proxy request failed (curve=$LASTEXITCODE, body=$egress)"
    }

    $ping = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $start
    $url = "{0}?status=up&msg={1}&ping={2}" -f $PushUrl, [uri]::EscapeDataString("egress=$egress"), $ping
    Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 15 | Out-Null
    Write-Output "UP egress=$egress ping=${ping}ms"
    exit 0
}
catch {
    $message = $_.Exception.Message
    $ping = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $start
    try {
        $url = "{0}?status=down&msg={1}&ping={2}" -f $PushUrl, [uri]::EscapeDataString($message), $ping
        Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 15 | Out-Null
    }
    catch {
        # Keep the original failure as the process result.
    }
    Write-Error "DOWN $message"
    exit 1
}
