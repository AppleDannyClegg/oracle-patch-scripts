<#
get-mos-token.ps1 - put a My Oracle Support bearer token on this machine, the easy way.

My Oracle Support stopped taking the account password, so the token needs an interactive login. This does
everything around that: it opens the token page, takes the token from the clipboard (or asks you to paste
it), writes it where get-patches.ps1 and the bash scripts look (%USERPROFILE%\.mos-token), locks the file
to you, and checks it against MOS so you know it is good before you run anything.

  .\get-mos-token.ps1                    # open the page, take the token from the clipboard
  .\get-mos-token.ps1 -Paste             # type/paste it instead of using the clipboard
  .\get-mos-token.ps1 -TokenFile X       # write it somewhere else
  .\get-mos-token.ps1 -NoOpen            # do not open a browser
  .\get-mos-token.ps1 -Force             # replace a token that still looks valid
  .\get-mos-token.ps1 -SelfTest          # check the parsing helpers, no network, then exit

The token lasts 60 minutes; run this again when a script says it expired.
#>
[CmdletBinding()]
param(
    [string] $TokenFile = (Join-Path $HOME '.mos-token'),
    [switch] $Paste,
    [switch] $NoOpen,
    [switch] $Force,
    [switch] $SelfTest
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
$MosBase = 'https://updates.oracle.com'
$TokenPage = "$MosBase/Orion/GenToken/get_token"

# a MOS token is a JWT: header.payload.signature, base64url, no padding
function Test-TokenShape([string] $Token) { $Token -match '^[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+$' }

function Get-JwtExpiry([string] $Token) {
    if (-not (Test-TokenShape $Token)) { return $null }
    $p = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
    try {
        $o = ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json)
        if ($o.exp) { return [DateTimeOffset]::FromUnixTimeSeconds([int64]$o.exp).LocalDateTime }
    } catch {}
    return $null
}

function Test-MosToken([string] $Token) {
    if ([string]::IsNullOrWhiteSpace($Token)) { return [pscustomobject]@{ Ok = $false; Code = $null; Message = 'no token to check' } }
    try {
        $r = Invoke-WebRequest -Uri "$MosBase/Orion/Services/search?bug=6880880" -Headers @{ Authorization = "Bearer $Token" } -UseBasicParsing -TimeoutSec 60
        # with NO (or empty) Authorization the request redirects to the OCI IAM login page and comes back 200
        # text/html - so a 200 alone is not an acceptance, the body must be MOS data (Gort, live)
        if ($r.Content -match '<html') { return [pscustomobject]@{ Ok = $false; Code = [int]$r.StatusCode; Message = 'a login page came back (HTML), not MOS data - the token was not accepted' } }
        return [pscustomobject]@{ Ok = $true; Code = [int]$r.StatusCode }
    } catch {
        $code = $null
        if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch {} }
        return [pscustomobject]@{ Ok = $false; Code = $code; Message = $_.Exception.Message }
    }
}

# fixed inputs, no network - so the parsing is covered by a gate (the repo has no other way to run this)
if ($SelfTest) {
    $fail = 0
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"sub":"x","exp":1700000000}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $jwt = "eyJhbGciOiJub25lIn0.$payload.sig"
    if (-not (Test-TokenShape $jwt)) { Write-Host 'FAIL Test-TokenShape rejects a JWT'; $fail++ }
    if (Test-TokenShape 'not a token') { Write-Host 'FAIL Test-TokenShape accepts junk'; $fail++ }
    $exp = Get-JwtExpiry $jwt
    if ($exp -ne [DateTimeOffset]::FromUnixTimeSeconds(1700000000).LocalDateTime) { Write-Host "FAIL Get-JwtExpiry: got [$exp]"; $fail++ }
    if ($null -ne (Get-JwtExpiry 'a.b.c')) { Write-Host 'FAIL Get-JwtExpiry accepts a non-JSON payload'; $fail++ }
    if ($fail -eq 0) { Write-Host 'get-mos-token selftest ok' } else { Write-Host "get-mos-token selftest: $fail failed" }
    exit $(if ($fail -eq 0) { 0 } else { 1 })
}

# a token already in the file that still looks valid: say so instead of replacing it
if ((Test-Path -LiteralPath $TokenFile) -and -not $Force) {
    $old = (Get-Content -LiteralPath $TokenFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') } | Select-Object -First 1)
    if ($old) {
        $exp = Get-JwtExpiry $old.Trim()
        if ($exp -and $exp -gt (Get-Date)) {
            Write-Host "a token in $TokenFile still looks valid until $exp - use -Force to replace it"
            return
        }
    }
}

if (-not $NoOpen) {
    Write-Host "opening $TokenPage"
    Start-Process $TokenPage | Out-Null
}
Write-Host 'log in if asked, press Generate token, then copy it (it lasts 60 minutes).'

$token = $null
if ($Paste) {
    # -AsSecureString so the token is not echoed to the console or a PowerShell transcript
    $sec = Read-Host 'paste the MOS token' -AsSecureString
    $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)).Trim()
} else {
    Write-Host 'waiting for a token on the clipboard... (Ctrl+C to stop)'
    # a re-run usually happens right after a script said 'expired', so the OLD token may still be on the
    # clipboard: ignore whatever is there at the start, and ignore a token whose exp has already passed
    $initial = (Get-Clipboard -Raw -ErrorAction SilentlyContinue)
    if ($initial) { $initial = $initial.Trim() }
    for ($i = 0; $i -lt 900; $i++) {
        $c = Get-Clipboard -Raw -ErrorAction SilentlyContinue
        if ($c) { $c = $c.Trim() }
        if ($c -and $c -ne $initial -and (Test-TokenShape $c)) {
            $exp = Get-JwtExpiry $c
            if ($exp -and $exp -le (Get-Date)) {
                Write-Host 'the token on the clipboard has already expired - copy a fresh one from the page'
                $initial = $c   # do not warn about the same one again
                $c = $null
            } else { $token = $c; break }
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $token) { throw 'no token appeared on the clipboard - re-run with -Paste' }
    # overwrite the live clipboard, then try to drop the Windows Win+V history entry too (and cloud sync may
    # already have mirrored it) - and be honest when we cannot clear the history
    try { Set-Clipboard -Value ' ' } catch {}
    $hist = $false
    if ($env:OS -eq 'Windows_NT') {
        try { [Windows.ApplicationModel.DataTransfer.Clipboard, Windows.ApplicationModel.DataTransfer, ContentType=WindowsRuntime]::ClearHistory(); $hist = $true } catch {}
    }
    if ($hist) { Write-Host 'clipboard and its history cleared' }
    else { Write-Host 'clipboard overwritten - if Windows clipboard history (Win+V) is on, clear it there too (Win+V > Clear all)' }
}
if (-not $token) { throw 'no token given' }

Write-Host 'checking the token against My Oracle Support...'
$v = Test-MosToken $token
if (-not $v.Ok) {
    throw "MOS did not accept the token (HTTP $($v.Code)): expired, or mis-pasted? $($v.Message)"
}
$exp = Get-JwtExpiry $token
Write-Host "token accepted$(if ($exp) { " (valid until $exp)" })"

$dir = Split-Path -Parent $TokenFile
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$header = "# MOS token - generated $(Get-Date -Format 'yyyy-MM-dd HH:mm')" + $(if ($exp) { ", expires $($exp.ToString('yyyy-MM-dd HH:mm'))" }) 
[IO.File]::WriteAllText($TokenFile, "$header`n$token`n", (New-Object Text.UTF8Encoding($false)))
# lock it to the current user (Windows only; harmless elsewhere)
if ($env:OS -eq 'Windows_NT') {
    $me = "$env:USERDOMAIN\$env:USERNAME"
    icacls "$TokenFile" /inheritance:r /grant:r "${me}:F" > $null 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Warning "could not restrict $TokenFile to $me (icacls rc $LASTEXITCODE) - check its permissions by hand" }
} else {
    # pwsh on macOS/Linux: the file lands 644, and the lib hint asks for 600
    & chmod 600 "$TokenFile" 2>$null
}
Write-Host "wrote $TokenFile"
