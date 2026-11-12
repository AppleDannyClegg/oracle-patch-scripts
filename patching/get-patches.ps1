<#
get-patches.ps1 - on a Windows 10/11 machine with internet: read the manifest that patch-manifest.sh wrote on
a server with no internet, work out which patches that server is behind on, and download them from My
Oracle Support, ready to copy to the server. Runs in the PowerShell that ships with Windows (5.1) and in 7.

  .\get-patches.ps1 -Manifest .\patches\manifest-wl1.txt             # plan + download into OUTPUT_DIR\wl1 (-Dest overrides)
  .\get-patches.ps1 -Manifest .\patches\manifest-wl1.txt -PlanOnly   # only say what it would download
  .\get-patches.ps1 -Manifest ... -Patch 38123456                    # also download these numbers
  .\get-patches.ps1 -Manifest ... -Patch 40199083 -PatchKind jdk      # ...into jdk/, if the kind cannot be read

What it looks up, for everything in the manifest:
  WebLogic home
  - WLS Stack Patch Bundle (SPB): newest "WLS STACK PATCH BUNDLE <release>.<yymmdd>" in MOS's Recommended
    list. One download carrying the PSU, Coherence, FMW Thirdparty, OSS, JDBC and RDA patches;
    'wls-patch.sh run <dir>' applies it with the SPBAT inside it, reading <dir>/spb/ too.
  - only when MOS lists no SPB: the WLS PSU and the Coherence cumulative patch one by one
  - FMW Platform Bundle: newest "FMW PLATFORM BUNDLE PATCH <release>.<yymmdd>", where one is installed
  - OPatch kit 28186730 when OPatch is older than 13.9.4.2.0, or older than the downloaded patches' READMEs ask for
  Oracle HTTP Server home (standalone, or collocated in a WebLogic home)
  - newest "OHS (NATIVE) [DB19C] BUNDLE PATCH <release>.<yymmdd>" for Linux x86-64, into ohs/ (not the Apache
    plug-in bundle). 'ohs-patch.sh run <dir>' applies it: preflight, stop, backup, opatch apply, start, verify,
    with an automatic rollback if anything after the backup fails
  - the Database Client 19c installer 34761383 into dbclient/, when the manifest says the home's Database Client
    (oracle.rdbms.rsf) is still below 19 and the current OHS bundle is a DB19C one: that bundle may only go on
    a home whose client was upgraded first (KB585169). 'dbclient-upgrade.sh' runs it; it is an installer, not opatch
  - for a 12.2.1.4 home, the rest of the set 'ohs-quarter.sh' applies in one outage (WLS PSU, DBCLIENT RU, WebGate,
    OSS, FMW Platform BP, JDBC, LibOVD, FMW third-party, PERL, LIBDMS2, LIBIAU, Cloning SPU, RDA), into ohsset/. These
    are FIXED patch numbers, the October 2026 row of MOS Doc 2806740.2 - MOS has no query that returns them, so they
    are not looked up and go stale each quarter: pass that quarter's numbers with -OhsSet <file> ("<number> <folder>"
    per line, the same file ohs-quarter-stage.sh --map reads). A number the home already has is not downloaded. On the
    server, 'ohs-quarter-stage.sh plan <download dir> <patch root>' files everything into the folders ohs-quarter.sh
    reads
  Database or client home (e.g. a 19c client)
  - newest "Database Release Update 19.N" for the release, and OPatch 6880880 with it when the home's OPatch is
    older than 12.2.0.1.40 or than the RU's README asks for
  OPatch: after the downloads, each PSU/RU README's (an SPB brings and installs its own OPatch) "OPatch ... or later" is compared with the OPatch the
  manifest says is installed (the same rule wls-patch.sh and db-patch.sh apply on the server), and the kit is
  fetched and checked against it here, so a too-old OPatch is not first found on a server with no internet.
  EM agent home
  - reported, not downloaded: agent RUs are applied from the OMS
  JDK
  - newest update of each major version in use that has a Linux x86-64 download (one per major)
  FMW product bundles
  - the newest '<FAMILY> BUNDLE PATCH' for every fmw| line the manifest reports (ADF, OPSS, WSM,
    SOA, ...), looked up in the same WebLogic release's Recommended list
Anything else Oracle lists for these homes (MOS Doc 2806740.2): add it with -Patch. Its folder and its apply
step come from -PatchKind (wls|spb|db|jdk|ohs|dbclient|ohsset); a JDK record is recognised on its own, anything else is assumed
WebLogic and says so, because the file names alone cannot tell a database Release Update from a WebLogic PSU.

Token: log in to My Oracle Support in a browser, open https://updates.oracle.com/Orion/GenToken/get_token,
press Generate token (valid 60 minutes) and save it as %USERPROFILE%\.mos-token (or pass -TokenFile).
MOS no longer takes the account password.

Files keep Oracle's names (p<number>_<release>_<platform>.zip), which wls-patch.sh matches on. A JDK patch
zip is unpacked to its .tar.gz, which is what java-patch.sh wants. Every file is SHA-256 checked; a file with
no SHA-256 in the MOS record is refused, not kept.
#>
[CmdletBinding()]
param(
    [string] $Manifest,
    [string] $Dest,
    [string] $TokenFile = (Join-Path $HOME '.mos-token'),
    [string[]] $Patch = @(),
    # where a -Patch number's file goes and which apply step it belongs to: wls|spb|db|jdk|ohs|dbclient|ohsset. Inferred for a
    # JDK record (the only unambiguous case), otherwise 'wls' with a warning - a DB RU and a WLS PSU are both
    # p<number>_<release>_Linux-x86-64.zip, so guessing between them would be a string match dressed as a rule
    [string] $PatchKind = '',
    # this quarter's ohs-quarter.sh set, "<patch number> <runbook folder>" per line ('#' comments) - replaces the
    # built-in October 2026 table. The same file ohs-quarter-stage.sh takes as --map
    [string] $OhsSet = '',
    [switch] $PlanOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Windows PowerShell 5.1 downloads crawl with the progress bar on
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$script:MosBase = 'https://updates.oracle.com'
$script:MosHeaders = @{}
$script:Releases = $null

# MOS product and platform numbers (the same ones lib/oracle-lib.sh uses)
$script:ProductWls = 15991
$script:ProductCoherence = 13964
$script:ProductJdk = 12443
$script:PlatformGeneric = 2000
$script:PlatformLinux = 226
$script:OPatchKit = '28186730'
$script:ProductDatabase = 9480
$script:ProductOhs = 10300
$script:DbOPatch = '6880880'

# the debug/internal markers in an Oracle artifact name. A fastdebug/'internal-bin' build is not what the
# patch tools install (java-patch refuses it), so never plan or pick one when a production file exists.
$script:DevBuild = '(?i)internal|debug|fastdebug|early[_ ]access'

# OUTPUT_DIR: the one base every file this repo creates, downloads or reports goes under, so the downloads
# and reports can be moved off /u01 (or out of %USERPROFILE%) in one place. ORACLE_OUTPUT_DIR in the
# environment wins, then OUTPUT_DIR= in oracle.conf, then the per-machine default. See oracle.conf.example.
# $ConfFiles is an injection point for tests only; callers leave it unset to use the real file order.
function Get-OutputDirSetting {
    param([string[]] $ConfFiles)
    if ($env:ORACLE_OUTPUT_DIR) { return $env:ORACLE_OUTPUT_DIR }
    if (-not $PSBoundParameters.ContainsKey('ConfFiles')) {
        # Last file wins, mirroring lib/oracle-lib.sh's load_config order. $PSScriptRoot is patching/ when the
        # script runs as a file; ../../oracle.conf covers a script run from a nested patch folder.
        $ConfFiles = @(
            (Join-Path $PSScriptRoot '../../oracle.conf'),
            (Join-Path $PSScriptRoot '../oracle.conf'),
            (Join-Path $HOME '.oracle.conf'),
            (Join-Path $PSScriptRoot 'get-patches.conf'),
            (Join-Path $PWD 'get-patches.conf'),
            (Join-Path $HOME '.get-patches.conf')
        )
    }
    $found = $null
    foreach ($f in $ConfFiles) {
        if (-not $f -or -not (Test-Path -LiteralPath $f)) { continue }
        foreach ($line in (Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)) {
            # Allow "export ", as bash's source does; an unquoted trailing comment is a comment, not part of the path.
            if ($line -match '^\s*(?:export\s+)?OUTPUT_DIR\s*=\s*(.*)$') {
                $v = ($Matches[1] -replace '\s+#.*$', '').Trim().Trim('"').Trim("'")
                if ($v) { $found = $v }
            }
        }
    }
    return $found
}

# The resolved base: the configured OUTPUT_DIR, else %USERPROFILE%\oracle-patch-scripts.
function Get-OutputDir {
    param([string[]] $ConfFiles)
    $d = if ($PSBoundParameters.ContainsKey('ConfFiles')) { Get-OutputDirSetting -ConfFiles $ConfFiles } else { Get-OutputDirSetting }
    if ($d) { return $d }
    return (Join-Path $HOME 'oracle-patch-scripts')
}

# An existing install keeps its old %USERPROFILE%\patches location, where get.ps1 put the tree before OUTPUT_DIR,
# so upgrading does not split the tree from the downloads (matches the bash side's "nothing moves" rule).
function Get-LegacyBase {
    if (-not $HOME) { return $null }
    $old = Join-Path $HOME 'patches'
    if (Test-Path -LiteralPath $old) { return $old }
    return $null
}

# Where this host's downloads land when -Dest is not given: OUTPUT_DIR/<host>; PATCH_BASE is honoured when only
# the legacy key is set, then the existing %USERPROFILE%\patches, else the default.
function Get-DefaultDest([string] $HostName) {
    $configured = Get-OutputDirSetting
    $legacy = Get-LegacyBase
    $base = if ($configured) { $configured } elseif ($env:PATCH_BASE) { $env:PATCH_BASE } elseif ($legacy) { $legacy } else { Get-OutputDir }
    return (Join-Path $base $HostName)
}

# ---- network: the only two functions that talk to MOS --------------------------------------------------
# the HTTP status behind a failed MOS call, or 0 when there was no HTTP answer at all (timeout, DNS, a proxy
# that refused, TLS). PowerShell 5.1 and 7 wrap that in different exception types, so walk the chain.
function Get-MosStatus($ErrorRecord) {
    $e = $ErrorRecord.Exception
    while ($e) {
        $r = $e.PSObject.Properties['Response']
        if ($r -and $r.Value -and $r.Value.PSObject.Properties['StatusCode']) { return [int] $r.Value.StatusCode }
        $e = $e.InnerException
    }
    0
}

# a gateway error or a throttle is worth another try in a few seconds; a refused token is not - it cannot fix
# itself while we wait, and retrying it just delays the message the operator needs
function Test-MosRetryable([int] $Status) { $Status -eq 0 -or $Status -eq 429 -or ($Status -ge 500 -and $Status -le 599) }

# a short, safe excerpt of what a failed call returned. A 502 body is the fastest way to see WHY (an "Access
# Denied" page is an expired token; a proxy page names the proxy), and it costs nothing when there is no body
function Get-MosBodyHead($ErrorRecord) {
    $m = $ErrorRecord.ErrorDetails.Message
    if (-not $m) { return '' }
    $t = ($m -replace '\s+', ' ').Trim()
    if ($t.Length -gt 200) { $t = $t.Substring(0, 200) + '...' }
    $t
}

# how old the token file is, in minutes - a MOS token lasts 60, and an expired one looks like a gateway error
function Get-TokenAgeMinutes([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    # [IO.File], not Get-Item -LiteralPath: on macOS that fails for a dotfile in the home directory
    # ("Could not find item /Users/x/.mos-token") although Test-Path finds it - measured 6 Nov 2026
    [int] ((Get-Date) - [IO.File]::GetLastWriteTime($Path)).TotalMinutes
}

# what went wrong, said in terms of who can fix it. A 502/503/504 is Oracle's edge or a proxy in between, NOT the
# token: reporting it as "did not accept the token" sent an operator to re-paste a token that was fine
function Get-MosFailure([string] $Path, $ErrorRecord) {
    $status = Get-MosStatus $ErrorRecord
    $head = Get-MosBodyHead $ErrorRecord
    $tail = if ($head) { " - body starts: $head" } else { '' }
    if ($status -eq 401) { return "MOS refused the token (HTTP 401) - it expires after 60 minutes; get a new one and run again: $Path$tail" }
    if ($status -eq 403) { return "MOS refused the request (HTTP 403) - the token has expired, or it is not entitled to this patch/product: $Path$tail" }
    if ($status -eq 429) { return "MOS is throttling this client (HTTP 429) - wait a few minutes and run again: $Path$tail" }
    # measured 6 Nov 2026: an expired token came back as HTTP 502 through this call, and a fresh one worked
    # immediately, so do not offer 5xx as proof the token is fine - check the token's age first
    if ($status -ge 500 -and $status -le 599) { return "MOS's edge returned HTTP $status. First renew the token - an expired one (over 60 minutes old) looks like this from here. If a fresh token still gets $status, it is Oracle's end or a proxy in between: $Path$tail" }
    if ($status -eq 0) { return "MOS could not be reached (no HTTP answer - network, proxy or DNS): $Path - $($ErrorRecord.Exception.Message)" }
    "MOS returned HTTP ${status}: $Path$tail"
}

function Invoke-MosGet([string] $Path) {
    # a single 500 or a stalled connection aborted the whole plan mid-run; bound each call and retry
    $last = $null
    for ($i = 1; $i -le 3; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $r = Invoke-WebRequest -Uri ($script:MosBase + $Path) -Headers $script:MosHeaders -UseBasicParsing -TimeoutSec 60
            $sw.Stop()
            Write-Verbose ("MOS GET {0} -> {1} {2} bytes in {3} ms" -f $Path, $r.StatusCode, ([string] $r.Content).Length, $sw.ElapsedMilliseconds)
            return [string] $r.Content
        } catch {
            $sw.Stop()
            $last = $_
            $status = Get-MosStatus $last
            Write-Verbose ("MOS GET {0} -> {1} after {2} ms (try {3} of 3)" -f $Path, $(if ($status) { "HTTP $status" } else { $last.Exception.Message }), $sw.ElapsedMilliseconds, $i)
            if (-not (Test-MosRetryable $status)) { throw (Get-MosFailure $Path $last) }
            if ($i -lt 3) { Start-Sleep -Seconds (5 * $i) }
        }
    }
    throw "$(Get-MosFailure $Path $last) (tried 3 times)"
}

# [IO.File] resolves a relative path against the PROCESS working directory, and on Windows that is not always
# PowerShell's location (a PSDrive, or a Set-Location to another drive, leaves it behind). A download into
# ".\patches\<host>\spb" therefore died with "Could not find a part of the path 'U:\patches\...'" on Windows
# while working on macOS. Resolve through the provider, and create the folder before writing to it.
function Get-AbsolutePath([string] $Path) {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Invoke-MosDownload([string] $Url, [string] $OutFile) {
    # the URL redirects to Oracle's CDN; the Authorization header is dropped on that hop, which the CDN expects.
    # Stream it ourselves (not Invoke-WebRequest -OutFile, which with $ProgressPreference='SilentlyContinue' goes
    # quiet for the whole of a multi-GB patch) so the operator sees a live status: percent, size, MB/s.
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.AllowAutoRedirect = $true
    $req.UserAgent = 'get-patches.ps1'
    if ($script:MosHeaders -and $script:MosHeaders['Authorization']) { $req.Headers.Add('Authorization', $script:MosHeaders['Authorization']) }
    $OutFile = Get-AbsolutePath $OutFile
    $OutDir = Split-Path -Parent $OutFile
    if ($OutDir -and -not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    $resp = $req.GetResponse()
    try {
        $total = $resp.ContentLength
        $in = $resp.GetResponseStream()
        try { $out = [IO.File]::Create($OutFile) }
        catch { throw "cannot write $OutFile - $($_.Exception.Message)" }
        try {
            $buf = New-Object byte[] 1048576
            [long] $done = 0
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n); $done += $n
                $secs = [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
                $rate = $done / 1MB / $secs
                if ($total -gt 0) {
                    $pct = [int](100 * $done / $total)
                    Write-Host ("`r    {0,3}%  {1}/{2}  {3,6:N1} MB/s" -f $pct, (Format-Size $done), (Format-Size $total), $rate) -NoNewline
                } else {
                    Write-Host ("`r    {0}  {1,6:N1} MB/s" -f (Format-Size $done), $rate) -NoNewline
                }
            }
            $sw.Stop()
        } finally { $out.Dispose(); $in.Dispose() }
        $secs = [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
        Write-Host ("`r    done: {0} in {1:N0}s ({2:N1} MB/s)" -f (Format-Size $done), $sw.Elapsed.TotalSeconds, ($done / 1MB / $secs))
    } finally { $resp.Dispose() }
}

# bytes -> a short human size, so a small file does not read as '0.0 MB'
function Format-Size([double] $Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ("$([int]$Bytes) B")
}

# ---- small helpers -------------------------------------------------------------------------------------
function Remove-Cdata([string] $Text) { $Text.Replace('<![CDATA[', '').Replace(']]>', '') }

# "1.8.0_471" / "12.2.1.4.0" / "13.9.4.2.23" -> a string that sorts the same way the versions do
function Get-VersionKey([string] $Version) {
    $parts = [regex]::Matches($Version, '\d+') | ForEach-Object { $_.Value.PadLeft(8, '0') }
    ($parts -join '.')
}

# "12.2.1.4" -> "12.2.1.4.0": MOS release labels have five parts
function Get-FivePart([string] $Version) {
    $parts = @($Version.Split('.'))
    while ($parts.Count -lt 5) { $parts += '0' }
    ($parts -join '.')
}

# ---- manifest ------------------------------------------------------------------------------------------
function Read-Manifest([string] $Path) {
    $m = [pscustomobject]@{ Host = ''; Platform = ''; PatchBase = ''; Created = ''; Wls = @(); Homes = @(); Jdks = @(); Fmw = @(); Ohs = @() }
    # a manifest is machine-written, so a line this function does not know is a wrong/truncated file, not noise:
    # throwing beats planning a subset of the host and calling it done (the plan would look complete)
    $known = @('host', 'created', 'plat', 'patch_base', 'wls', 'home', 'ohs', 'patch', 'jdk', 'fmw')
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
        $f = $line.Split('|')
        if ($known -notcontains $f[0]) { throw "$Path line '$line': unrecognised line type '$($f[0])' - is it a patch-manifest.sh file?" }
        switch ($f[0]) {
            'host' { if ($f.Count -lt 2 -or -not $f[1]) { throw "$Path line '$line': 'host|' needs a name" }; $m.Host = $f[1] }
            'created' { if ($f.Count -lt 2 -or -not $f[1]) { throw "$Path line '$line': 'created|' needs a date" }; $m.Created = $f[1] }
            'plat' { if ($f.Count -lt 3 -or -not $f[1] -or -not $f[2]) { throw "$Path line '$line': 'plat|' needs <os>|<arch>" }; $m.Platform = "$($f[1])|$($f[2])" }
            'patch_base' { if ($f.Count -lt 2 -or -not $f[1]) { throw "$Path line '$line': 'patch_base|' needs a path" }; $m.PatchBase = $f[1] }
            'wls' {
                if ($f.Count -lt 5 -or -not $f[1]) { throw "$Path line '$line': 'wls|' needs home|release|opatch|coherence (home is a key)" }
                $m.Wls += [pscustomobject]@{ Home = $f[1]; Release = $f[2]; OPatch = $f[3]; Coherence = ($f[4] -eq 'yes'); Patches = @() }
            }
            'home' {
                if ($f.Count -lt 5 -or -not $f[1] -or -not $f[2]) { throw "$Path line '$line': 'home|' needs home|kind|version|opatch (home and kind are keys)" }
                # Client: the trailing <DB client level> patch-manifest.sh writes for kind ohs (oracle.rdbms.rsf VER, raw,
                # may be empty); '' on every other kind and on a manifest written before the field existed
                $m.Homes += [pscustomobject]@{ Home = $f[1]; Kind = $f[2]; Version = $f[3]; OPatch = $f[4]; Client = $(if ($f.Count -gt 5) { $f[5].Trim() } else { '' }); Patches = @() }
            }
            'patch' {
                if ($f.Count -lt 4 -or -not $f[1] -or -not $f[2]) { throw "$Path line '$line': 'patch|' needs home|number|description (home and number are keys)" }
                $w = @($m.Wls) + @($m.Homes) | Where-Object { $_ -and $_.Home -eq $f[1] } | Select-Object -First 1
                if ($w) { $w.Patches += [pscustomobject]@{ Id = $f[2]; Description = (($f[3..($f.Count - 1)]) -join '|').Trim() } }
            }
            'ohs' {
                if ($f.Count -lt 2 -or -not $f[1]) { throw "$Path line '$line': 'ohs|' needs a WebLogic home" }
                $m.Ohs += [pscustomobject]@{ Home = $f[1]; Release = $(if ($f.Count -gt 2) { $f[2] } else { '' }); Client = $(if ($f.Count -gt 3) { $f[3].Trim() } else { '' }) }
            }
            'jdk' {
                if ($f.Count -lt 4 -or -not $f[1] -or -not $f[2] -or -not $f[3]) { throw "$Path line '$line': 'jdk|' needs home|version|major" }
                $m.Jdks += [pscustomobject]@{ Home = $f[1]; Version = $f[2]; Major = $f[3] }
            }
            'fmw' {
                if ($f.Count -lt 3 -or -not $f[1] -or -not $f[2]) { throw "$Path line '$line': 'fmw|' needs home|family (home and family are keys; version and patch are optional)" }
                $m.Fmw += [pscustomobject]@{ Home = $f[1]; Family = $f[2]; Version = $(if ($f.Count -gt 3) { $f[3] } else { '' }); Patch = $(if ($f.Count -gt 4) { $f[4] } else { '' }) }
            }
        }
    }
    if (-not $m.Host) { throw "$Path has no host| line - is it a patch-manifest.sh file?" }
    # the platform decides which MOS files are fetched; the manifest records it (patch-manifest.sh plat|). An
    # old manifest has none: assume Linux x86-64 but say so. An unknown one is refused, not guessed
    if ($m.Platform) {
        if ($m.Platform.ToLower() -in @('linux|x86_64', 'linux|amd64')) { $script:PlatformLinux = 226 }
    # a bare "unknown platform" tells the operator nothing; name what was read and where to write the manifest
        else { throw "$Path was written on $($m.Platform) - get-patches.ps1 downloads Linux x86-64 patches only; run patch-manifest.sh on the server" }
    } else { Write-Warning "$Path has no plat| line (patch-manifest.sh predates it) - assuming Linux x86-64"; $script:PlatformLinux = 226 }
    if (-not $m.Wls -and -not $m.Homes -and -not $m.Jdks) { throw "$Path has no wls or jdk lines - is it a patch-manifest.sh file?" }
    $m
}

# every OHS home (standalone 'home|..|ohs' or collocated 'ohs|<wls home>'), with how its bundle is applied
function Get-OhsNotes($Manifest) {
    $all = @(@($Manifest.Homes | Where-Object { $_.Kind -eq 'ohs' } | ForEach-Object { [pscustomobject]@{ Home = $_.Home; Release = $_.Version; How = 'standalone' } }) +
        @($Manifest.Ohs | ForEach-Object { [pscustomobject]@{ Home = $_.Home; Release = $_.Release; How = 'collocated in the WebLogic home' } }))
    foreach ($o in $all) {
        $rel = $(if ($o.Release) { $o.Release } else { 'release unknown' })
        "Oracle HTTP Server $rel at $($o.Home) ($($o.How)): its OHS bundle goes in ohs/ - apply it with 'ohs-patch.sh run ohs' on the host (stop, backup, opatch apply, start, verify, rollback on failure)."
    }
}

# ---- MOS lookups ---------------------------------------------------------------------------------------
# every ARU release: Label ("Oracle WebLogic Server 12.2.1.4.0"), Name, Id. 4 MB, fetched once per run.
function Get-MosReleases {
    if ($null -eq $script:Releases) {
        $xml = (Invoke-MosGet '/Orion/Services/metadata?table=aru_releases') -replace "[`r`n]", ''   # as lib does: entries can break lines
        $script:Releases = @([regex]::Matches($xml, '<release id="(\d+)"[^>]*name="([^"]*)"><!\[CDATA\[([^\]]*)\]\]>') | ForEach-Object {
                [pscustomobject]@{ Id = $_.Groups[1].Value; Name = $_.Groups[2].Value; Label = $_.Groups[3].Value }
            })
        if ($script:Releases.Count -eq 0) { throw 'MOS returned an empty release table' }
        # a cut-off table still has rows, but too few: the JDK walk would quietly pick an older update
        if ($xml.TrimEnd() -notmatch '</results>$') { $script:Releases = $null; throw 'the MOS release table arrived incomplete - run again' }
    }
    $script:Releases
}

function Get-ReleaseId([string] $Label, [switch] $Optional) {
    $r = Get-MosReleases | Where-Object { $_.Label -eq $Label } | Select-Object -First 1
    if (-not $r) {
        if ($Optional) { return $null }
        throw "release '$Label' is not in the MOS release table"
    }
    $r.Id
}

# patches filed under a product/release/platform: Number, Abstract, Date (yyyy-mm-dd)
function Get-MosPatchRows([int] $Product, [string] $ReleaseId, [int] $Platform, [switch] $Recommended) {
    $q = "/Orion/Services/search?product=$Product&release=$ReleaseId&platform=$Platform&patch_type=all"
    if ($Recommended) { $q += '&classification=recommended' }
    $xml = (Invoke-MosGet $q) -replace "[`r`n]", ''
    foreach ($blk in ($xml -split '<patch ' | Select-Object -Skip 1)) {
        # the first <number>/<abstract> only: the record goes on to list every bug the patch fixes
        $n = [regex]::Match($blk, '<number>(\d+)')
        $a = [regex]::Match($blk, '<abstract><!\[CDATA\[([^\]]*)')
        $d = [regex]::Match($blk, '<released_date[^>]*>(\d{4}-\d{2}-\d{2})')
        if ($n.Success) { [pscustomobject]@{ Number = $n.Groups[1].Value; Abstract = $a.Groups[1].Value.Trim(); Date = $d.Groups[1].Value } }
    }
}

# Coherence level N from "...12.2.1.4.N..." (either wording), else from "Cumulative Patch N"; 0 when neither
function Get-CoherenceLevel([string] $Text, [string] $Short) {
    $m = [regex]::Match($Text, [regex]::Escape($Short) + '\.(\d+)\b')
    if (-not $m.Success) { $m = [regex]::Match($Text, 'Cumulative Patch (\d+)\b(?!\.)') }
    if ($m.Success) { [int] $m.Groups[1].Value } else { 0 }
}

# ---- the plan ------------------------------------------------------------------------------------------
# For: the Oracle home the patch is for, so the OPatch minimum in its README can be checked against that home
function New-PlanItem([string] $Kind, [string] $What, [string] $Installed, $Row, [string] $Release, [string] $For = '') {
    [pscustomobject]@{ Kind = $Kind; What = $What; Installed = $Installed; Patch = $Row.Number; Abstract = $Row.Abstract; Release = $Release; For = $For }
}

# The kinds a -Patch item can be put in, and the folder each one downloads into.
$script:PatchKinds = @('wls', 'spb', 'db', 'jdk', 'ohs', 'dbclient', 'ohsset')

# 'jdk' when the record says so plainly, otherwise '' - see the -PatchKind comment in param().
function Get-PatchKindFromFiles($Files) {
    $files = @($Files)
    if ($files.Count -eq 0) { return '' }
    # What a bug record actually carries, from this repo's own fixtures: a JDK 8 record is release
    # name '1.8.0_481' (NOT 'Oracle JDK ...' - that is the ARU release-table label), a JDK 11/17 file is
    # jdk-11.0.x_linux-x64_bin.tar.gz, and a WebLogic or database release is five-part (12.2.1.4.0,
    # 19.27.0.0.0). So: three numeric parts with an optional _build, or files named jdk-*.
    $releases = @($files | ForEach-Object { $_.Release } | Where-Object { $_ } | Sort-Object -Unique)
    if ($releases.Count -eq 1 -and $releases[0] -match '^\d+\.\d+\.\d+(_\d+)?$') { return 'jdk' }
    if (@($files | Where-Object { $_.Name -notmatch '^jdk-' }).Count -eq 0) { return 'jdk' }
    ''
}

# One plan item for a patch number the operator asked for with -Patch. No release: the record carries its own,
# and stamping the WebLogic release on a JDK or DB patch is what sent those files to wls/ (Cerebro, 6 Nov).
function Get-PatchItem([string] $Patch, [string] $Kind = '') {
    if ($Kind -and $Kind -notin $script:PatchKinds) {
        throw "-PatchKind '$Kind' is not one of $($script:PatchKinds -join '|') - it decides the folder the file goes in and which patch script applies it"
    }
    if (-not $Kind) {
        $Kind = Get-PatchKindFromFiles (Get-MosFiles $Patch)
        if (-not $Kind) {
            $Kind = 'wls'
            Write-Warning "patch ${Patch}: kind not given and the record does not say - using wls. Pass -PatchKind $($script:PatchKinds -join '|') if it is not a WebLogic patch."
        }
    }
    [pscustomobject]@{ Kind = $Kind; What = 'asked for with -Patch'; Installed = ''; Patch = $Patch; Abstract = ''; Release = '' }
}

# which folder a plan item's file goes in - the item's Kind, in one place so -Patch and the planners agree
function Get-PatchFolder($Item) { $Item.Kind }

# newest row whose abstract matches $Pattern; the first capture group is what is compared
function Select-Newest($Rows, [string] $Pattern) {
    $Rows | Where-Object { $_.Abstract -match $Pattern } |
        Sort-Object { Get-VersionKey ([regex]::Match($_.Abstract, $Pattern).Groups[1].Value) } -Descending |
        Select-Object -First 1
}

function Get-InstalledLevel($Wls, [string] $Pattern) {
    $levels = @($Wls.Patches | Where-Object { $_.Description -match $Pattern } |
            ForEach-Object { [regex]::Match($_.Description, $Pattern).Groups[1].Value })
    $levels | Sort-Object { Get-VersionKey $_ } -Descending | Select-Object -First 1
}

# -OhsHome: the WebLogic inside an Oracle HTTP Server home (a wls| home that Get-OhsHomeList also lists). ohs-quarter.sh
# patches it with the runbook's WLS PSU (the ohsset/ table, wlspsu/), never a Stack Patch Bundle, so neither the SPB
# nor a MOS-looked-up PSU is planned for it: a field run planned the SPB there and ohs-quarter-stage.sh refused it (T1056).
function Get-WlsPlan($Wls, [switch] $OhsHome) {
    $release = $Wls.Release
    if (-not $release) {
        Write-Warning "$($Wls.Home): the manifest has no WebLogic release for this home - fix the wls| line (registry.xml or .product.properties) and run again"
        return
    }
    $short = ($release.Split('.')[0..3]) -join '.'                       # 12.2.1.4.0 -> 12.2.1.4
    $esc = [regex]::Escape($short)
    $wlsRelease = Get-ReleaseId "Oracle WebLogic Server $(Get-FivePart $release)" -Optional
    if (-not $wlsRelease) {
        Write-Warning "$($Wls.Home): MOS has no release 'Oracle WebLogic Server $(Get-FivePart $release)' - skipping its patches"
        return
    }
    $rows = @(Get-MosPatchRows $script:ProductWls $wlsRelease $script:PlatformGeneric -Recommended)

    # Stack Patch Bundle first: it carries the PSU and Coherence (and Thirdparty, OSS, JDBC, RDA)
    $spbPattern = "(?i)^WLS STACK PATCH BUNDLE $esc(?:\.0)?\.(\d{6})"
    $spb = if ($OhsHome) { $null } else { Select-Newest $rows $spbPattern }
    if ($spb) {
        $have = Get-InstalledLevel $Wls $spbPattern
        if (-not $have -or [regex]::Match($spb.Abstract, $spbPattern).Groups[1].Value -gt $have) {
            # its own folder: an SPB is never mixed with single patches - wls-patch.sh applies it with its SPBAT
            New-PlanItem 'spb' "WLS Stack Patch Bundle ($($Wls.Home))" $have $spb $release $Wls.Home
        }
    }

    # no SPB on MOS: the PSU on its own. Exact PSU rows only, not "(BLR)" / MERGE / OVERLAY look-alikes
    $psuPattern = "(?i)^WLS PATCH SET UPDATE $esc(?:\.0)?\.(\d{6})\s*$"
    if (-not $spb -and -not $OhsHome) {
        $newest = Select-Newest $rows $psuPattern
        $have = Get-InstalledLevel $Wls $psuPattern
        if (-not $newest) { Write-Warning "$($Wls.Home): MOS lists no WLS PSU or Stack Patch Bundle for $short - get the number from Doc 2806740.2 and pass -Patch" }
        elseif (-not $have -or [regex]::Match($newest.Abstract, $psuPattern).Groups[1].Value -gt $have) {
            New-PlanItem 'wls' "WLS PSU ($($Wls.Home))" $have $newest $release $Wls.Home
        }
    }

    # FMW Platform Bundle: only where one is installed. An OHS home takes the set's fmwbp/ 36789759 instead (T1067)
    $bundlePattern = "(?i)^FMW PLATFORM BUNDLE PATCH $esc(?:\.0)?\.(\d{6})"
    $have = Get-InstalledLevel $Wls $bundlePattern
    if ($have -and -not $OhsHome) {
        $newest = Select-Newest $rows $bundlePattern
        if (-not $newest) { Write-Host "  $($Wls.Home): FMW Platform Bundle $have is installed; MOS's Recommended list has nothing newer, so nothing to download. For the newest, get the number from Doc 2806740.2 and pass -Patch." }
        elseif ([regex]::Match($newest.Abstract, $bundlePattern).Groups[1].Value -gt $have) {
            New-PlanItem 'wls' "FMW Platform Bundle ($($Wls.Home))" $have $newest $release $Wls.Home
        }
    }

    # Coherence cumulative patch. lspatches says "Coherence Cumulative Patch 12.2.1.4.30"; MOS can say
    # "Coherence 12.2.1.4 Cumulative Patch 30 (12.2.1.4.30)". Both carry the level as <release>.<N>.
    if ($Wls.Coherence -and -not $spb -and -not $OhsHome) {   # an OHS home: the runbook has no Coherence patch
        $cohRelease = Get-ReleaseId "Oracle Coherence $(Get-FivePart $short)" -Optional
        if (-not $cohRelease) { Write-Warning "$($Wls.Home): MOS has no release 'Oracle Coherence $(Get-FivePart $short)' - skipping the Coherence patch" }
        $cohRows = if ($cohRelease) { @(Get-MosPatchRows $script:ProductCoherence $cohRelease $script:PlatformGeneric -Recommended |
                Where-Object { $_.Abstract -match 'Coherence' -and $_.Abstract -match 'Cumulative Patch' }) } else { @() }
        $newest = $cohRows | Sort-Object { Get-CoherenceLevel $_.Abstract $short } -Descending | Select-Object -First 1
        $have = @($Wls.Patches | Where-Object { $_.Description -match 'Coherence' -and $_.Description -match 'Cumulative Patch' } |
                ForEach-Object { Get-CoherenceLevel $_.Description $short } | Sort-Object -Descending)[0]
        if (-not $newest) { Write-Warning "$($Wls.Home): MOS lists no Coherence patch for $short" }
        elseif (-not $have -or (Get-CoherenceLevel $newest.Abstract $short) -gt $have) {
            New-PlanItem 'wls' "Coherence ($($Wls.Home))" $(if ($have) { "Cumulative Patch $short.$have" } else { '' }) $newest $release $Wls.Home
        }
    }

    # OPatch: modern PSUs refuse an OPatch older than 13.9.4.2.0
    if ($Wls.OPatch -and (Get-VersionKey $Wls.OPatch) -lt (Get-VersionKey '13.9.4.2.0')) {
        New-PlanItem 'wls' "OPatch kit ($($Wls.Home))" $Wls.OPatch ([pscustomobject]@{ Number = $script:OPatchKit; Abstract = 'OPatch 13.9.4.x' }) '13.9.4' $Wls.Home
    }
}

function Get-JdkPlan($Jdks) {
    # the EM agent's JDK moves with the agent's own RU, not with java-patch.sh: leave it out of the comparison
    foreach ($group in ($Jdks | Where-Object { $_.Major -and $_.Home -notmatch '/agent' } | Group-Object Major)) {
        $major = $group.Name
        $prefix = if ($major -eq '8') { 'Oracle JDK 1.8.0_' } else { "Oracle JDK $major." }
        $oldest = $group.Group | Sort-Object { Get-VersionKey $_.Version } | Select-Object -First 1
        # one ARU release per update; the newest are announced before their patch exists, so walk down to one with a Linux file
        $candidates = Get-MosReleases |
            Where-Object { $_.Label.StartsWith($prefix) -and $_.Label.Substring($prefix.Length) -notmatch '-|Performance' } |
            Sort-Object { Get-VersionKey $_.Label } -Descending | Select-Object -First 4
        $found = $null
        foreach ($r in $candidates) {
            $rows = @(Get-MosPatchRows $script:ProductJdk $r.Id $script:PlatformLinux)
            # the release's own update is the row titled 'Oracle JDK <n> Update <u>'. MOS also lists one-offs and
            # JRE rows under the same release, and the newest one is often a bug-titled patch whose only artifact
            # is an internal/debug build (40255927 / 8u511, measured 6 Nov 2026) - so rank by the release update's
            # own title, and fall back to any row only when the release carries none
            # NOT $jdkRows: PowerShell looks a variable up the call stack, and Invoke-MosGet (called from
            # Get-MosPatchRows below) reads its OWN $jdkRows - a local with that name here shadows the caller's
            # fixture and the next release's rows come back empty
            $releaseRows = @($rows | Where-Object { $_.Abstract -match '(?i)^Oracle JDK\b' })
            if (-not $releaseRows) { $releaseRows = $rows }
            # the newest release can list only an internal/debug artifact: skip it and take the newest release
            # with a production file, or the host is patched to a build java-patch will refuse (OBDX 5 Nov 2026)
            # the same rule as the download (Select-MosFile), so "worth planning" means "has a file we would take"
            # and the item carries that file: Save-MosPatch re-checks it against the record it reads then
            foreach ($row in ($releaseRows | Sort-Object Date -Descending)) {
                $sel = Select-MosFile @(Get-MosFiles $row.Number) $r.Label.Substring('Oracle JDK '.Length) 'jdk'
                if ($sel.File) { $found = [pscustomobject]@{ Release = $r; Row = $row; File = $sel.File }; break }
            }
            if ($found) { break }
        }
        if (-not $found) { Write-Warning "JDK ${major}: no release with a production (non-internal/debug) Linux x86-64 file - get it from MOS Doc 1439822.2 and pass -Patch"; continue }
        $newVersion = $found.Release.Label.Substring('Oracle JDK '.Length)
        if ((Get-VersionKey $newVersion) -gt (Get-VersionKey $oldest.Version)) {
            New-PlanItem 'jdk' "JDK $major (oldest here: $($oldest.Home))" $oldest.Version $found.Row $newVersion |
                Add-Member -NotePropertyName File -NotePropertyValue $found.File -PassThru
        }
    }
}

# a database or client home: newest Database Release Update for its release, with OPatch 6880880.
# The parameter is $Db, not $Home: that is a read-only automatic variable.
# the database major (19) for a db home: its version, else the Release Update it has, else its path
# (/stage/client/app/product/19.0.0.0). sqlplus -V can fail on the host, leaving the version empty.
function Get-DbMajor($Db) {
    if ($Db.Version -match '^(\d+)\.') { return $Matches[1] }
    foreach ($p in $Db.Patches) { if ($p.Description -match '^Database Release Update\s*:?\s*(\d+)\.') { return $Matches[1] } }
    if ($Db.Home -match '(?:^|/)(\d+)\.\d+\.\d+\.\d+(?:/|$)') { return $Matches[1] }
    return ''
}

function Get-DbPlan($Db) {
    $major = Get-DbMajor $Db
    if (-not $major) {
        Write-Warning "$($Db.Home): the manifest has no database version for this home - skipping its Release Update. Fix the home| line (opatch lsinventory there), or get the number from MOS Doc 2118136.2 and pass -Patch"
        return
    }
    $label = "Oracle Database $major.0.0.0.0"
    $dbRelease = Get-ReleaseId $label -Optional
    if (-not $dbRelease) {
        Write-Warning "$($Db.Home): MOS has no release '$label' - skipping its Release Update. Get the number from MOS Doc 2118136.2 and pass -Patch"
        return
    }
    # ends at "(" or the end: the " - CMAN" / " - GSM" RUs are not for this home (as db-patch.sh)
    # MOS titled RUs '19.N.0.0.<yymmdd>' up to 19.32 and '19.33.0.0.0' from 19.33 on (live, 5 Nov 2026), so the
    # RU number N orders them, and the date only breaks a tie
    $ruPattern = "(?i)^Database Release Update\s*:?\s*$major\.(\d+)\.0\.0\.(\d{6}|0)\s*(?:\(|$)"
    $ruKey = { param([string] $t) $g = [regex]::Match($t, $ruPattern).Groups; [int64]$g[1].Value * 1000000 + [int64]$g[2].Value }
    $rows = @(Get-MosPatchRows $script:ProductDatabase $dbRelease $script:PlatformLinux -Recommended)
    $newest = $rows | Where-Object { $_.Abstract -match $ruPattern } |
        Sort-Object { & $ruKey $_.Abstract } -Descending | Select-Object -First 1
    $have = @($Db.Patches | Where-Object { $_.Description -match $ruPattern } |
            ForEach-Object { & $ruKey $_.Description } | Sort-Object -Descending)[0]
    if (-not $newest) { Write-Warning "$($Db.Home): MOS lists no Database Release Update for $major - get it from MOS Doc 2118136.2 and pass -Patch"; return }
    if (-not $have -or (& $ruKey $newest.Abstract) -gt $have) {
        $installed = @($Db.Patches | Where-Object { $_.Description -match $ruPattern } | ForEach-Object { $_.Description })[0]
        $release = "$major.0.0.0.0"
        New-PlanItem 'db' "Database Release Update ($($Db.Home))" $installed $newest $release $Db.Home
        # the newest OPatch too when this one is older than current RUs need (db-patch.sh's 12.2.0.1.40)
        if (-not $Db.OPatch -or (Get-VersionKey $Db.OPatch) -lt (Get-VersionKey '12.2.0.1.40')) {
            New-PlanItem 'db' "OPatch for $($Db.Home)" $Db.OPatch ([pscustomobject]@{ Number = $script:DbOPatch; Abstract = 'OPatch 12.2.0.1.x (newest)' }) $release $Db.Home
        }
    }
}

# an installed FMW product's bundle: the manifest's fmw| lines name the family and its installed level,
# the newest matching '<FAMILY> BUNDLE PATCH <release>.<yymmdd>' row is the one to download
function Get-FmwPlan($Manifest) {
    foreach ($fw in $Manifest.Fmw) {
        # the producer reports a bundle-shaped patch it could not place as family OTHER; planning a lookup
        # for a family literally called OTHER would be nonsense, and silence would lose it - name it
        if ($fw.Family -eq 'OTHER') {
            # the SPB and Coherence are already planned by Get-WlsPlan, and the PSU is not an FMW product:
            # warning about those would train the operator to ignore the one warning that matters
            if ($fw.Version -notmatch '(?i)WLS STACK PATCH BUNDLE|Coherence|WLS PATCH SET UPDATE') {
                Write-Warning "$($fw.Home): '$($fw.Version)' is a bundle-shaped patch this script cannot place - check MOS Doc 2806740.2 and pass its number with -Patch"
            }
            continue
        }
        $w = $Manifest.Wls | Where-Object { $_.Home -eq $fw.Home } | Select-Object -First 1
        if (-not $w -or -not $w.Release) {
            Write-Warning "$($fw.Home): $($fw.Family) is in the manifest but the home has no WebLogic release - skipping its bundle"
            continue
        }
        $release = $w.Release
        $short = ($release.Split('.')[0..3]) -join '.'
        # a family token can carry its own version ('JDBC19.30', 'OSS 19C'): matching it literally would
        # never see the next release's bundle ('JDBC19.31'), so drop the version and allow one back
        $base = $fw.Family -replace '\s+[0-9][0-9A-Za-z.]*$', '' -replace '[0-9][0-9.]*$', ''
        if (-not $base) { $base = $fw.Family }
        $pat = "(?i)^$([regex]::Escape($base))(?:(?:[ .]?[0-9][0-9A-Za-z.]*)?) BUNDLE PATCH $([regex]::Escape($short))(?:\.0)?\.(\d{6})"
        $wlsRelease = Get-ReleaseId "Oracle WebLogic Server $(Get-FivePart $release)" -Optional
        if (-not $wlsRelease) { Write-Warning "$($fw.Home): MOS has no release 'Oracle WebLogic Server $(Get-FivePart $release)' - skipping the $($fw.Family) bundle"; continue }
        $rows = @(Get-MosPatchRows $script:ProductWls $wlsRelease $script:PlatformGeneric -Recommended)
        $newest = Select-Newest $rows $pat
        if (-not $newest) { Write-Warning "$($fw.Home): MOS lists no $($fw.Family) bundle for $short - check MOS Doc 2806740.2 and pass its number with -Patch"; continue }
        # the manifest field is whatever the producer read (a version or a date): compare the yymmdd when
        # there is one, and plan when there is not - an unreadable installed level must not read current
        $inst = [regex]::Match($fw.Version, '\d{6}').Value
        $new = [regex]::Match($newest.Abstract, $pat).Groups[1].Value
        if (-not $inst -or $new -gt $inst) {
            # kind 'wls', not a new 'fmw': the bundle is applied by wls-patch.sh from the same wls/ folder
            # (Kind only chooses the download subdirectory, and only jdk expands)
            New-PlanItem 'wls' "$($fw.Family) bundle ($($fw.Home))" $fw.Version $newest $release $fw.Home
        }
    }
}

# Oracle HTTP Server: the newest 'OHS (NATIVE) [DB19C] BUNDLE PATCH <release>.<yymmdd>' for every OHS home,
# standalone (home|..|ohs) or collocated in a WebLogic home (ohs|<wls home>). Linux x86-64 only: OHS is native.
# Exact rows only - the 'APACHE PLUGIN BUNDLE PATCH' (the WebLogic plug-in for Apache) is a look-alike.
function Get-OhsHomeList($Manifest) {
    @(@($Manifest.Homes | Where-Object { $_.Kind -eq 'ohs' } | ForEach-Object { [pscustomobject]@{ Home = $_.Home; Release = $_.Version; Client = $_.Client; Patches = $_.Patches } }) +
        @($Manifest.Ohs | ForEach-Object {
                $o = $_; $w = $Manifest.Wls | Where-Object { $_.Home -eq $o.Home } | Select-Object -First 1
                [pscustomobject]@{ Home = $o.Home; Release = $o.Release; Client = $o.Client; Patches = $(if ($w) { $w.Patches } else { @() }) } }))
}

function Get-OhsPlan($Manifest) {
    $homes = Get-OhsHomeList $Manifest
    foreach ($h in $homes) {
        if (-not $h.Release) { Write-Warning "$($h.Home): the manifest has no OHS release for this home - get its OHS bundle from MOS Doc 2806740.2 by hand"; continue }
        $short = ($h.Release.Split('.')[0..3]) -join '.'
        $esc = [regex]::Escape($short)
        $rel = Get-ReleaseId "Oracle HTTP Server $(Get-FivePart $h.Release)" -Optional
        if (-not $rel) { Write-Warning "$($h.Home): MOS has no release 'Oracle HTTP Server $(Get-FivePart $h.Release)' - skipping its OHS bundle"; continue }
        $rows = @(Get-MosPatchRows $script:ProductOhs $rel $script:PlatformLinux)
        $pat = "(?i)^OHS \(NATIVE\) (?:DB19C )?BUNDLE PATCH $esc(?:\.0)?\.(\d{6})\s*$"
        $newest = Select-Newest $rows $pat
        if (-not $newest) { Write-Warning "$($h.Home): MOS lists no OHS (NATIVE) bundle for $short - check MOS Doc 2806740.2"; continue }
        $have = Get-InstalledLevel $h $pat
        # the series matters, not only the date: the DB19C bundle 'must be applied only to an Oracle Fusion Middleware
        # home where the Oracle Database Client 12c has been upgraded to 19c' (40005842 README, Section 2, KB585169).
        # Follow the series the home is on; a home on the plain line is not planned a DB19C bundle
        # The home's Database Client level (oracle.rdbms.rsf, from the manifest) decides when it is there: it is the
        # fact the rule is about. The patch titles are only the fallback for a manifest written before the field
        # existed - 'opatch lspatches' on a real home can print bare patch numbers, and then no title matches at all.
        $clientMajor = $null
        if ($h.Client -match '^\s*(\d+)\.') { $clientMajor = [int] $Matches[1] }
        elseif ($h.Client) { Write-Warning "$($h.Home): the manifest's Database Client level '$($h.Client)' is not a version - falling back to the installed patch titles" }
        $isDb19 = $newest.Abstract -match '(?i)DB19C'
        if ($null -ne $clientMajor) {
            if ($isDb19 -and $clientMajor -lt 19) {
                # the installer is the 12.2.1.4 one (34761383 README); for any other release name the gap, do not guess a number
                if ($short -eq '12.2.1.4') {
                    Write-Warning "$($h.Home): Database Client $($h.Client) - the current OHS bundle $($newest.Number) is a DB19C one, which may only go on a home whose client was upgraded to 19c first (KB585169). Planned the installer 34761383 into dbclient/: run dbclient-upgrade.sh with it BEFORE the bundle."
                    New-PlanItem 'dbclient' "Database Client 19c installer ($($h.Home))" $h.Client ([pscustomobject]@{ Number = '34761383'; Abstract = 'DB Client 19c Upgrade for FMW 12.2.1.4.0' }) $h.Release $h.Home
                } else {
                    Write-Warning "$($h.Home): Database Client $($h.Client) - the current OHS bundle $($newest.Number) is a DB19C one, which needs the client upgraded to 19c first (KB585169). This script knows the installer for 12.2.1.4 only: find the one for $short on MOS and pass it with -Patch <number> -PatchKind dbclient."
                }
            }
        } else {
            $haveDb19 = @($h.Patches | Where-Object { $_.Description -match '(?i)^OHS \(NATIVE\) DB19C BUNDLE PATCH|DB CLIENT 19C UPGRADE' }).Count -gt 0
            $havePlain = @($h.Patches | Where-Object { $_.Description -match '(?i)^OHS \(NATIVE\) BUNDLE PATCH' }).Count -gt 0
            if ($isDb19 -and -not $haveDb19) {
                if ($havePlain) {
                    Write-Warning "$($h.Home): on the plain OHS bundle line ($have) - the current bundle $($newest.Number) is the DB19C one, which needs the home's Database Client upgraded to 19c first (KB585169). Not planned: do that upgrade, then run again."
                    continue
                }
                Write-Warning "$($h.Home): no OHS bundle installed - $($newest.Number) is a DB19C bundle; confirm this home's Database Client was upgraded to 19c (KB585169) before applying it."
            }
        }
        $new = [regex]::Match($newest.Abstract, $pat).Groups[1].Value
        if (-not $have -or $new -gt $have) { New-PlanItem 'ohs' "OHS bundle ($($h.Home))" $have $newest $h.Release $h.Home }
    }
}

# ---- the rest of the ohs-quarter.sh set ---------------------------------------------------------------
# ohs-quarter.sh applies sixteen folders in one outage. The JDK, the OHS bundle and the installer are looked up
# above; the other thirteen are single patches MOS has no "newest of" query for - the FMW CPU Patch Advisor page
# (KA1182 / Doc 2806740.2, 'Oracle HTTP Server 12.2.1.4 (with a DB Client 19c)') names them each quarter. So this
# is a TABLE, not a lookup, and it is the October 2026 row. The same numbers, with the same folders, are the
# built-in table of patching/ohs-quarter/ohs-quarter-stage.sh; tests/get-patches.ps1 fails if the two differ.
$script:OhsSetQuarter = 'October 2026'
$script:OhsSetFolders = @('wlspsu', 'dbclient', 'dbclientru', 'webgate', 'oss', 'ohs', 'fmwbp', 'jdbc', 'libovd', 'fmwthirdparty', 'perl', 'libdms2', 'libiau', 'cloningspu', 'rda')
$script:OhsSetBuiltIn = @(
    '39919567 wlspsu', '34761383 dbclient', '39425385 dbclientru', '39114058 webgate', '39567777 oss', '40005842 ohs', '36789759 fmwbp',
    '39487427 jdbc', '39465265 libovd', '39574504 fmwthirdparty', '38590502 perl', '38098858 libdms2', '38832179 libiau',
    '37056593 cloningspu', '39798204 rda')

# "<number> <folder>" lines -> rows. A line that is not that shape, a folder the runbook does not have, or a
# number or folder given twice is refused: a table read wrongly is a set downloaded wrongly
function ConvertTo-OhsSet([string[]] $Lines, [string] $From) {
    $rows = @()
    foreach ($raw in $Lines) {
        $l = ($raw -replace '#.*$', '').Trim()
        if (-not $l) { continue }
        if ($l -notmatch '^(\d{6,9})\s+(\S+)$') { throw "${From}: '$raw' is not '<patch number> <folder>'" }
        $n = $Matches[1]; $fo = $Matches[2]
        if ($fo -notin $script:OhsSetFolders) { throw "${From}: '$fo' is not a folder ohs-quarter.sh reads ($($script:OhsSetFolders -join ' '))" }
        if ($rows | Where-Object { $_.Number -eq $n -or $_.Folder -eq $fo }) { throw "${From}: patch $n or folder $fo is listed twice" }
        $rows += [pscustomobject]@{ Number = $n; Folder = $fo }
    }
    if ($rows.Count -eq 0) { throw "${From}: no '<patch number> <folder>' lines" }
    $rows
}

function Get-OhsSetTable {
    if ($OhsSet) {
        if (-not (Test-Path -LiteralPath $OhsSet)) { throw "-OhsSet: $OhsSet not found" }
        return [pscustomobject]@{ Rows = @(ConvertTo-OhsSet @(Get-Content -LiteralPath $OhsSet) "-OhsSet $OhsSet"); Label = "-OhsSet $OhsSet" }
    }
    [pscustomobject]@{ Rows = @(ConvertTo-OhsSet $script:OhsSetBuiltIn 'the built-in table'); Label = "the built-in $($script:OhsSetQuarter) table" }
}

# $Planned is what the lookups above already planned: the OHS bundle and the installer are theirs (a MOS lookup
# and the manifest's client level), so the table never adds a second copy of either - with one exception, the
# installer for a home whose manifest carries NO client level, which the lookup cannot decide and so never plans.
function Get-OhsSetPlan($Manifest, $Planned) {
    $homes = @(Get-OhsHomeList $Manifest | Where-Object { $_.Release -and (($_.Release.Split('.')[0..3]) -join '.') -eq '12.2.1.4' })
    if ($homes.Count -eq 0) { return }
    $set = Get-OhsSetTable
    $seen = @{}
    foreach ($p in @($Planned)) { if ($p.Patch) { $seen["$($p.Patch)"] = $true } }
    $tableBundle = @($set.Rows | Where-Object { $_.Folder -eq 'ohs' })[0]
    foreach ($h in $homes) {
        $have = @{}
        foreach ($ip in @($h.Patches)) { if ($ip.Id) { $have["$($ip.Id)".Trim()] = $true } }
        # the one fact MOS does give about the quarter: its current OHS bundle. If that is not the table's, the
        # table is another quarter's and the other rows are probably superseded too - say so, do not guess them
        $mosBundle = @($Planned | Where-Object { $_.Kind -eq 'ohs' -and $_.For -eq $h.Home })[0]
        if ($tableBundle -and $mosBundle -and "$($mosBundle.Patch)" -ne $tableBundle.Number) {
            Write-Warning "$($h.Home): MOS's current OHS bundle is $($mosBundle.Patch) but $($set.Label) has $($tableBundle.Number) - that table is for another quarter, so the ohsset/ numbers below are probably superseded. Take this quarter's from MOS Doc 2806740.2 and pass them with -OhsSet <file>."
        }
        foreach ($r in $set.Rows) {
            if ($r.Folder -eq 'ohs') { continue }
            if ($seen[$r.Number] -or $have[$r.Number]) { continue }
            if ($r.Folder -eq 'dbclient') {
                # a level that is a version means the lookup above decided; anything else (absent, 'unknown') did not
                if ($h.Client -match '^\s*\d+\.') { continue }
                Write-Warning "$($h.Home): the manifest has no readable Database Client level for this home, so whether it needs the 19c installer $($r.Number) cannot be told from here - downloading it into dbclient/ anyway. 'dbclient-upgrade.sh preflight' on the server says whether the home needs it; re-run patch-manifest.sh from a current copy to get the level."
            }
            $seen[$r.Number] = $true
            $kind = if ($r.Folder -eq 'dbclient') { 'dbclient' } else { 'ohsset' }
            New-PlanItem $kind "ohs-quarter set: $($r.Folder) ($($h.Home))" '' ([pscustomobject]@{ Number = $r.Number; Abstract = "$($set.Label), not looked up on MOS" }) $h.Release $h.Home
        }
    }
}

function Get-PatchPlan($Manifest) {
    $ohsHomes = @(Get-OhsHomeList $Manifest | ForEach-Object { $_.Home })
    foreach ($w in $Manifest.Wls) { Get-WlsPlan $w -OhsHome:($ohsHomes -contains $w.Home) }
    foreach ($h in ($Manifest.Homes | Where-Object { $_.Kind -eq 'db' })) { Get-DbPlan $h }
    if ($Manifest.Jdks) { Get-JdkPlan $Manifest.Jdks }
    if ($Manifest.Fmw) { Get-FmwPlan $Manifest }
    if ($Manifest.Ohs -or ($Manifest.Homes | Where-Object { $_.Kind -eq 'ohs' })) {
        # the warnings stay in the warning stream; only the items are kept to tell the set what is already planned
        $ohs = @(Get-OhsPlan $Manifest)
        $ohs
        Get-OhsSetPlan $Manifest $ohs
    }
}

# ---- download ------------------------------------------------------------------------------------------
# one patch's downloadable files from MOS (name, url, sha, release, platform)
function Get-MosFiles([string] $Patch) {
    $xml = Remove-Cdata ((Invoke-MosGet "/Orion/Services/search?bug=$Patch") -replace "[`r`n]", '')
    if ($xml -match '<html') { throw "MOS returned a web page for $Patch - the token was not accepted (expired or mis-pasted?)" }
    # a body cut mid-file still yields a name+url with an empty digest, so guard completeness like Get-MosReleases
    if ($xml.TrimEnd() -notmatch '</results>$') { throw "the MOS response for patch $Patch arrived incomplete - run again" }
    $files = @()
    foreach ($blk in ($xml -split '<patch ' | Select-Object -Skip 1)) {
        $rel = [regex]::Match($blk, '<release[^>]*name="([^"]*)"').Groups[1].Value
        $plat = [regex]::Match($blk, '<platform id="\d+"[^>]*>([^<]*)').Groups[1].Value
        foreach ($f in ($blk -split '<file>' | Select-Object -Skip 1)) {
            $name = [regex]::Match($f, '<name>([^<]*)</name>')
            $url = [regex]::Match($f, '<download_url[^>]*host="([^"]*)"[^>]*>([^<]*)</download_url>')
            $sha = [regex]::Match($f, '<digest type="SHA-256">([^<]*)</digest>')
            if ($name.Success -and $url.Success) {
                $files += [pscustomobject]@{
                    Name = $name.Groups[1].Value.Trim(); Url = ($url.Groups[1].Value + $url.Groups[2].Value).Replace('&amp;', '&')
                    Sha = $sha.Groups[1].Value.Trim().ToLower(); Release = $rel; Platform = $plat
                }
            }
        }
    }
    if ($files.Count -eq 0) { throw "patch ${Patch}: no downloadable files (not entitled, or the number is wrong)" }
    $files
}

# which of a patch's files to take: the ONE rule both the JDK plan and the download use, so the file the plan
# decided was worth planning is the file that is downloaded. In order, none skippable: platform, release ('' = any),
# production (not internal/debug), archive, then for a JDK .tar.gz before .zip before MOS's order.
# Returns File (or $null), Candidates (every file that passed, best first), Reason (why File is $null) and Warning
# (a note for the caller to print). It never throws or prints: the plan skips on $null, the download refuses.
# Two rules hold for every kind: an internal/debug artifact is refused (it is not what a patch tool installs), and
# the single-file fallback under another release label says so instead of taking the file quietly (T229). Beyond
# that only Kind 'jdk' is strict: java-patch.sh takes only a production .tar.gz (or the zip holding one), and the JDK
# is the one product that lists internal builds, .rpm packages and both archive kinds; every other kind keeps the
# courtesy fallbacks it always had, because nobody has shown a record where they pick wrongly.
function Select-MosFile($Files, [string] $Release, [string] $Kind) {
    $jdk = $Kind -eq 'jdk'
    $r = [pscustomobject]@{ File = $null; Candidates = @(); Reason = ''; Warning = '' }
    $names = { param($set) (@($set | ForEach-Object { $_.Name }) -join ', ') }
    $forUs = @($Files | Where-Object { $_.Platform -match 'Generic|Linux x86-64' })
    if ($forUs.Count -eq 0) {
        if ($jdk) { $r.Reason = "no Linux x86-64 or Generic file (listed: $(& $names $Files))"; return $r }
        $forUs = @($Files)
    }
    $matching = $forUs
    if ($Release) {
        $tag = '_' + $Release.Replace('.', '')
        $matching = @($forUs | Where-Object { $_.Release.StartsWith($Release) -or $_.Name.Contains($tag) })
        # one file under another release label is still the patch's file (a -Patch number, a re-labelled record):
        # taken, but never silently - the file's label is not the release asked for (T229)
        if ($matching.Count -eq 0 -and $forUs.Count -eq 1) {
            $matching = $forUs
            $r.Warning = "the record lists one file and it is labelled release '$($forUs[0].Release)', not '$Release' - taking it: $($forUs[0].Name)"
        }
        if ($matching.Count -eq 0) {
            $r.Reason = "several files and none is for release '$Release':`n" + (($forUs | ForEach-Object { "    $($_.Name)  release $($_.Release)  ($($_.Platform))" }) -join "`n")
            return $r
        }
    } else {
        $rels = @($forUs | ForEach-Object { $_.Release } | Where-Object { $_ } | Sort-Object -Unique)
        if ($rels.Count -gt 1) { $r.Warning = "no release given and the record lists several ($($rels -join ', '))" }
    }
    # Oracle lists a production artifact and sometimes an internal/debug one for the same release. A
    # fastdebug/'internal-bin' tarball is not what a patch tool installs (java-patch refuses it)
    $production = @($matching | Where-Object { $_.Name -notmatch $script:DevBuild })
    # every kind refuses here, not just the JDK (T229, Edi #12944): an internal/debug artifact is not what a patch
    # tool installs, so taking it downloads the wrong bytes and reads as a success. Refuse and let -Patch carry it.
    if ($production.Count -eq 0) {
        if ($jdk) { $r.Reason = "only an internal/debug build is listed ($(& $names $matching)) - not a production JDK"; return $r }
        $r.Reason = "only an internal/debug artifact is listed for release '$Release': $($matching[0].Name) - not a production file, so pass -Patch with the number from MOS Doc 2806740.2"; return $r
    }
    # the patch tools take an archive (.zip, .tar.gz); an .rpm/.exe/.deb is for a package manager
    $archives = @($production | Where-Object { $_.Name -match '(?i)\.(zip|t(ar\.)?gz)$' })
    if ($archives.Count -eq 0) {
        if ($jdk) { $r.Reason = "no archive for java-patch.sh, only $(& $names $production)"; return $r }
        $archives = $production
    }
    if ($jdk) {
        $archives = @(@($archives | Where-Object { $_.Name -match '(?i)\.t(ar\.)?gz$' }) + @($archives | Where-Object { $_.Name -notmatch '(?i)\.t(ar\.)?gz$' }))
    }
    $r.Candidates = $archives
    $r.File = $archives[0]
    $r
}

# fetch one patch's file for Linux (or Generic), preferring $Release; returns the saved path.
# -Pin is the file the plan chose (JDK only today): the record is read again here and can have changed since
# (Cerebro, Edi, Jocasta 5 Nov), so the pinned NAME is looked up in the fresh record and its fresh SHA-256 used
function Save-MosPatch {
    [CmdletBinding()]
    param([string] $Patch, [string] $Dest, [string] $Release, [string] $Kind = '', $Pin = $null)
    $files = @(Get-MosFiles $Patch)
    $sel = Select-MosFile $files $Release $Kind
    if ($sel.Warning) { Write-Warning "patch ${Patch}: $($sel.Warning)" }
    $how = if ($Kind -eq 'jdk') { 'get the JDK from MOS Doc 1439822.2 and pass its number with -Patch' } else { 'check the patch number' }
    $pick = $sel.File
    if ($Pin) {
        $now = @($sel.Candidates | Where-Object { $_.Name -eq $Pin.Name }) | Select-Object -First 1
        if ($now) {
            # same name, same version in Oracle's naming: take it, but a moved digest means MOS re-cut the bytes
            if ($Pin.Sha -and $now.Sha -ne $Pin.Sha) {
                Write-Warning "patch ${Patch}: the SHA-256 for $($Pin.Name) changed since the plan ($($Pin.Sha.Substring(0, [Math]::Min(8, $Pin.Sha.Length))) -> $($now.Sha.Substring(0, [Math]::Min(8, $now.Sha.Length)))) - taking the file MOS lists now"
            }
            $pick = $now
        } elseif (@($files | Where-Object { $_.Name -eq $Pin.Name }).Count) {
            # still listed but no longer passes the rule the plan used: the record contradicts the plan - never re-pick
            throw "patch ${Patch}: $($Pin.Name) was planned but the record no longer offers it as a production archive for release '$Release' - run again"
        } elseif ($pick) {
            Write-Warning "patch ${Patch}: $($Pin.Name) was planned but is gone from the record - taking $($pick.Name) instead"
        } else {
            throw "patch ${Patch}: $($Pin.Name) was planned but is gone from the record, and nothing else qualifies: $($sel.Reason) - run again"
        }
    }
    if (-not $pick) { throw "patch ${Patch}: $($sel.Reason) - $how" }
    # an unverified file is not installed, and the check is on $pick BEFORE $Dest is created or a .part is
    # written: both the reuse and the mismatch checks below are pointless without a digest, and MOS always
    # gives one for a downloadable file - so a missing one is a wrong patch response (or a cut-off body)
    if (-not $pick.Sha) { throw "patch ${Patch}: no SHA-256 in the MOS record for $($pick.Name) - run again" }

    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    $out = Join-Path $Dest $pick.Name
    if ((Test-Path -LiteralPath $out) -and ((Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash.ToLower() -eq $pick.Sha)) {
        Write-Host "  $($pick.Name) already here and verified"
        return $out
    }
    Write-Host "  downloading $($pick.Name)"
    Invoke-MosDownload $pick.Url "$out.part"
    if (((Get-FileHash -LiteralPath "$out.part" -Algorithm SHA256).Hash.ToLower() -ne $pick.Sha)) {
        Remove-Item -LiteralPath "$out.part" -Force
        throw "SHA-256 mismatch for $($pick.Name) - deleted it, try again"
    }
    Move-Item -LiteralPath "$out.part" -Destination $out -Force
    $out
}

# a JDK patch zip holds the .tar.gz java-patch.sh wants: unpack it next to the zip
function Expand-JdkTarball([string] $Zip) {
    if (-not $Zip.EndsWith('.zip')) { return }
    # MOS names the JDK patch file innocuously (p40255927_180_511_Linux-x86-64.zip); whether it is a production or
    # an internal/debug build is only visible INSIDE it, so a name filter upstream cannot catch it. Measured
    # 6 Nov 2026: that zip holds exactly one tarball, jdk-8u511-internal-bin-b00-linux-x64-debug-05_nov_2026.tar.gz
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($Zip)
    try { $inner = @($z.Entries | Where-Object { $_.FullName -match '(?i)\.tar\.gz$' } | ForEach-Object { $_.FullName }) }
    finally { $z.Dispose() }
    if (-not $inner) { return }
    $production = @($inner | Where-Object { (Split-Path -Leaf $_) -notmatch $script:DevBuild })
    if (-not $production) {
        throw "$(Split-Path -Leaf $Zip) holds only an internal/debug JDK ($((@($inner | ForEach-Object { Split-Path -Leaf $_ })) -join ', ')) - java-patch refuses those; get the production build from MOS Doc 1439822.2 and pass its number with -Patch"
    }
    $dir = Split-Path -Parent $Zip
    $tmp = Join-Path $dir ('unzip-' + [guid]::NewGuid())
    Expand-Archive -LiteralPath $Zip -DestinationPath $tmp
    Get-ChildItem -LiteralPath $tmp -Recurse -Filter '*.tar.gz' |
        Where-Object { $_.Name -notmatch $script:DevBuild } |
        ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination $dir -Force; Write-Host "  unpacked $($_.Name)" }
    Remove-Item -LiteralPath $tmp -Recurse -Force
}

# ---- OPatch: what the downloaded patches need ----------------------------------------------------------
# The PSU/SPB/RU READMEs name the OPatch they need ("OPatch version 13.9.4.2.20 or later"). wls-patch.sh and
# db-patch.sh read that on the server, but the server has no internet: a too-old OPatch found there means
# another download trip. So read it here, right after the download, and fetch the OPatch kit with the patches.

# the text of every README in the zip's top two levels. HTML: a tag inside a number ("12.2.0.1.<i>46</i>") is
# dropped, any other tag becomes a space, and entities are decoded ("OPatch&#160;utility" reads as words)
function Get-ZipReadmeText([string] $Zip) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $text = foreach ($e in $z.Entries) {
            if ($e.FullName -notmatch '^([^/]+/)?README[^/]*$') { continue }
            $r = New-Object IO.StreamReader ($e.Open())
            try { $raw = $r.ReadToEnd() } finally { $r.Dispose() }
            $raw = $raw -replace '(?<=[\d.])(?:<[^>]*>)+(?=\d)', '' -replace '<[^>]*>', ' '
            [Net.WebUtility]::HtmlDecode($raw) -replace ' ', ' '
        }
        $text -join "`n"
    } finally { $z.Dispose() }
}

# the highest OPatch version a README asks for, or $null - the rule wls-patch.sh (patch_min_opatch) and
# db-patch.sh apply on the server: every version right after the word OPatch, any family, the highest wins.
# 'OPatch' is matched case-sensitively, as the server's grep does, so an '$ opatch apply ...' command line does
# not count. Only an OPatch-shaped number is a candidate - 12.2.0.1.x (database) or 13.9.x (FMW/WLS): a README
# also prints the RU or PSU's own number and home paths near the word ("Use OPatch to apply Database Release
# Update 19.24.0.0.240716", ".../product/19.0.0.0/dbhome_1"), and those are never the OPatch it needs. Up to 80
# characters may sit between the word and the version, digits too ("OPatch (patch 28186730) 12.2.0.1.40"). In
# a sentence that names OPatch, a further version counts only when a minimum phrase follows it ("OPatch
# 13.9.4.2.5 or later, and 13.9.4.2.20 or later for this PSU" needs .20).
function Get-ZipMinOPatch([string] $Zip) {
    $text = Get-ZipReadmeText $Zip
    $ver = '(?:12\.2\.0\.1|13\.9\.\d+)(?:\.\d+)+'
    $found = @([regex]::Matches($text, "\bOPatch\b[^\n]{0,80}?\b($ver)\b") | ForEach-Object { $_.Groups[1].Value })
    foreach ($s in ($text -split '(?<=\.)\s+|\n')) {
        if ($s -cnotmatch '\bOPatch\b') { continue }
        $found += @([regex]::Matches($s, "(?i)\b($ver)\b(?=\s+(?:or\s+later|or\s+higher|or\s+above|or\s+newer|is\s+required|required|minimum))") | ForEach-Object { $_.Groups[1].Value })
    }
    $v = $found | Sort-Object { Get-VersionKey $_ } -Descending | Select-Object -First 1
    if ($v) { $v } else { $null }
}

# the version an OPatch kit zip installs, measured from the kit itself - never from its README, which names the
# minimum it needs and so could pass a too-old kit. Version (or $null) and where it came from:
#   OPatch/version.txt ('OPATCH_VERSION:12.2.0.1.48', the 6880880 kit), else Oracle's file name
#   (p28186730_1394220_Generic.zip -> 13.9.4.2.20, the 13.9.4 kit, which has no version.txt)
function Get-ZipOPatchVersion([string] $Zip) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $e = $z.Entries | Where-Object { $_.FullName -match '(^|/)OPatch/version\.txt$' } | Select-Object -First 1
        if ($e) {
            $r = New-Object IO.StreamReader ($e.Open())
            try { $m = [regex]::Match($r.ReadToEnd(), 'OPATCH_VERSION:\s*([\d.]+)') } finally { $r.Dispose() }
            if ($m.Success) { return [pscustomobject]@{ Version = $m.Groups[1].Value; From = 'OPatch/version.txt' } }
        }
    } finally { $z.Dispose() }
    $n = [regex]::Match((Split-Path -Leaf $Zip), '^p28186730_1394(\d)(\d+)_')
    if ($n.Success) { return [pscustomobject]@{ Version = "13.9.4.$($n.Groups[1].Value).$([int]$n.Groups[2].Value)"; From = 'the file name' } }
    [pscustomobject]@{ Version = $null; From = '' }
}

# 'ok' / 'low' / 'unknown': is the downloaded kit at least what the patches need. 'unknown' is not ok: the caller
# counts it as a failure, so a kit whose version cannot be measured is never passed
function Test-OPatchKit([string] $Min, [string] $Kit) {
    $v = (Get-ZipOPatchVersion $Kit).Version
    if (-not $v) { return 'unknown' }
    if ((Get-VersionKey $v) -ge (Get-VersionKey $Min)) { 'ok' } else { 'low' }
}

# per home: the highest OPatch its downloaded patches need, against the OPatch the manifest says is installed.
# $Downloaded: @{ Item = <plan item>; Saved = <zip> }. Returns one row per home that needs a newer (or unknown)
# OPatch: Home, Min, Installed, From, Item (the kit to download, or $null when one is already downloaded) and
# KitSaved (that download). A downloaded patch whose README names no OPatch minimum WARNs - never a silent skip.
function Get-OPatchNeeds($Manifest, $Downloaded) {
    $kits = @($script:OPatchKit, $script:DbOPatch)
    $byHome = @{}
    foreach ($d in $Downloaded) {
        $it = $d.Item
        # not 'spb': a Stack Patch Bundle carries its own OPatch and SPBAT -phase apply upgrades it 'from any version'
        # (real SPB README, 5 Nov 2026) - the OPatch its README names is the one it installs, not a minimum
        if (-not $it.For -or -not $d.Saved -or $it.Kind -notin @('wls', 'db', 'ohs') -or $it.Patch -in $kits) { continue }
        $wls = $Manifest.Wls | Where-Object { $_.Home -eq $it.For } | Select-Object -First 1
        $db = $Manifest.Homes | Where-Object { $_.Home -eq $it.For -and $_.Kind -eq 'db' } | Select-Object -First 1
        # a standalone OHS home takes the FMW OPatch (13.9.x) like a WebLogic home
        $ohs = $Manifest.Homes | Where-Object { $_.Home -eq $it.For -and $_.Kind -eq 'ohs' } | Select-Object -First 1
        if ($wls) { $installed = $wls.OPatch } elseif ($db) { $installed = $db.OPatch } elseif ($ohs) { $installed = $ohs.OPatch } else { continue }
        $min = Get-ZipMinOPatch $d.Saved
        if (-not $min) {
            # the README may be missing, deeper in the zip, or worded in a way this does not read: say so, the server would find out too late
            Write-Warning "patch $($it.Patch): no OPatch minimum found in its README - check the README by hand for the OPatch it needs ($($it.For) has $(if ($installed) { $installed } else { 'an unknown version' }))"
            continue
        }
        $cur = $byHome[$it.For]
        if (-not $cur -or (Get-VersionKey $min) -gt (Get-VersionKey $cur.Min)) {
            $byHome[$it.For] = [pscustomobject]@{ Home = $it.For; Min = $min; Installed = $installed; Wls = [bool]($wls -or $ohs); Folder = $(if ($ohs) { 'ohs' } else { 'wls' }); Release = $it.Release; From = $it.Patch }
        }
    }
    foreach ($n in $byHome.Values) {
        if ($n.Installed -and (Get-VersionKey $n.Installed) -ge (Get-VersionKey $n.Min)) { continue }
        $kitNo = if ($n.Wls) { $script:OPatchKit } else { $script:DbOPatch }
        $have = $Downloaded | Where-Object { $_.Item.Patch -eq $kitNo -and $_.Item.For -eq $n.Home -and $_.Saved } | Select-Object -First 1
        $item = $null
        if (-not $have) {
            $item = if ($n.Wls) { New-PlanItem $n.Folder "OPatch kit ($($n.Home))" $n.Installed ([pscustomobject]@{ Number = $kitNo; Abstract = "OPatch $($n.Min) or later (patch $($n.From)'s README)" }) '13.9.4' $n.Home }
                    else { New-PlanItem 'db' "OPatch for $($n.Home)" $n.Installed ([pscustomobject]@{ Number = $kitNo; Abstract = "OPatch $($n.Min) or later (patch $($n.From)'s README)" }) $n.Release $n.Home }
        }
        [pscustomobject]@{ Home = $n.Home; Min = $n.Min; Installed = $n.Installed; From = $n.From; Item = $item; KitSaved = $(if ($have) { $have.Saved } else { $null }) }
    }
}

# after the downloads: fetch the OPatch kit for every home whose patches need a newer OPatch than it has, and
# check each kit against that need. Returns the number of failures: a kit that failed to download, is still too
# old, or whose version cannot be measured.
function Invoke-OPatchFollowUp($Manifest, $Downloaded, [string] $Dest) {
    $failed = 0
    foreach ($n in @(Get-OPatchNeeds $Manifest $Downloaded)) {
        Write-Host "OPatch for $($n.Home): $(if ($n.Installed) { $n.Installed } else { 'version unknown' }) installed, patch $($n.From)'s README needs $($n.Min) or later"
        $kit = $n.KitSaved
        if ($n.Item) {
            Write-Host "$($n.Item.What): patch $($n.Item.Patch)"
            try { $kit = Save-MosPatch -Patch $n.Item.Patch -Dest (Join-Path $Dest $n.Item.Kind) -Release $n.Item.Release -Kind $n.Item.Kind }
            catch { $failed++; Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red; continue }
        }
        $kv = Get-ZipOPatchVersion $kit
        switch (Test-OPatchKit $n.Min $kit) {
            'ok' { Write-Host "  $(Split-Path -Leaf $kit) is OPatch $($kv.Version) (from $($kv.From)): enough" }
            'low' { $failed++; Write-Host "  $(Split-Path -Leaf $kit) is OPatch $($kv.Version) (from $($kv.From)), still below $($n.Min) - the patch will not apply with it. Check MOS for a newer OPatch before going to the server." -ForegroundColor Red }
            default { $failed++; Write-Host "  could not measure the OPatch version of $(Split-Path -Leaf $kit) (no OPatch/version.txt, not Oracle's file name) - check by hand that it is $($n.Min) or later" -ForegroundColor Red }
        }
    }
    $failed
}

# ---- main ----------------------------------------------------------------------------------------------
function Read-MosToken([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "No MOS token at $Path. Generate one at https://updates.oracle.com/Orion/GenToken/get_token (60 minutes) and save it there." }
    $t = Get-Content -LiteralPath $Path | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') } | Select-Object -First 1
    if (-not $t) { throw "$Path has no token line" }
    $t.Trim()
}

function Get-UploadHints([string] $HostName, [string] $Dest, [string] $Base) {
    # the whole hint block, so patch_base| can be asserted on it (Cerebro seam suite): one string per kind.
    # $Base (patch_base|, or the /u01/patches fallback) is normalised HERE, so a trailing slash cannot make '//'
    $b = if ($Base) { $Base.TrimEnd('/') } else { '/u01/patches' }
    # the LOCAL half of the hint is this machine's path, so it uses this machine's separator - a Windows-style
    # hint printed on macOS gives scp a path that cannot exist (seen 6 Nov 2026). The remote half is Linux: '/'
    $sep = [IO.Path]::DirectorySeparatorChar
    # a hint describes what is IN the folder, not that the folder exists: a run whose JDK download was refused
    # still told the operator to scp jdk/*.tar.gz, a line that cannot be run (6 Nov 2026)
    $line = {
        param([string] $Kind, [string] $Filter, [string] $Trailer)
        $dir = Join-Path $Dest $Kind
        if (-not (Test-Path -LiteralPath $dir)) { return }
        if (-not (Get-ChildItem -LiteralPath $dir -Filter $Filter -File -ErrorAction SilentlyContinue)) { return }
        "  scp `"$Dest$sep$Kind$sep$Filter`" oracle@${HostName}:$b/$Kind/$Trailer"
    }
    $out = @()
    $l = & $line 'wls' '*.zip' "   then: wls-patch.sh run $b/wls"; if ($l) { $out += $l }
    $l = & $line 'spb' '*.zip' "   then: wls-patch.sh run $b/spb"; if ($l) { $out += $l }
    # dbclient before ohs: the DB19C OHS bundle may only go on a home whose client is already 19c (KB585169)
    $l = & $line 'dbclient' '*.zip' "   then: dbclient-upgrade.sh preflight $b/dbclient   (before any OHS DB19C bundle)"; if ($l) { $out += $l }
    $l = & $line 'ohs' '*.zip' "   then: ohs-patch.sh run $b/ohs"; if ($l) { $out += $l }
    # the set is not applied from ohsset/: the stage helper files it, by patch number, into the runbook's folders
    $l = & $line 'ohsset' '*.zip' "   then: ohs-quarter-stage.sh plan $b <a new patch root>   (files the whole download for ohs-quarter.sh; do not point ohs-patch.sh at ohsset/)"; if ($l) { $out += $l }
    $l = & $line 'db' '*.zip' ''; if ($l) { $out += $l }
    $l = & $line 'jdk' '*.tar.gz' ''; if ($l) { $out += $l }
    $out
}

# the created| freshness: a manifest older than this may describe a host that has changed. Kept out of Main so
# it can be tested (Cerebro 22:18:37); returns the warning text, or '' for fresh/absent/unparseable.
function Get-ManifestFreshnessWarning([string] $Created, [datetimeoffset] $Now) {
    if (-not $Created) { return '' }
    $made = $null; try { $made = [datetimeoffset]::Parse($Created, [Globalization.CultureInfo]::InvariantCulture) } catch { return "the manifest's created| value '$Created' did not parse - cannot tell how old the manifest is; check the producer" }
    if ($null -eq $made) { return '' }
    $age = ($Now - $made).TotalDays
    if ($age -gt 14) { return "the manifest was made $([int][math]::Floor($age)) days ago ($Created) - the host may have changed since; re-run patch-manifest.sh if in doubt" }
    ''
}

# the closing block of a run: what is missing comes FIRST, because "Copy to the server" over an incomplete set
# is how an operator patches a host with half of what it needs and finds out on the server
function Get-DownloadSummary([int] $Total, [string[]] $Failed, [string] $Dest) {
    $lines = @()
    if ($Failed.Count -gt 0) {
        $lines += "NOT READY TO COPY: $($Failed.Count) of $Total downloads failed - $($Failed -join ', ')."
        $lines += "Fix the failure(s) above and run again. What did download is under ${Dest}:"
    }
    else { $lines += "Saved under $Dest. Copy to the server (as oracle), then run the patch scripts there:" }
    [pscustomobject]@{ Ready = ($Failed.Count -eq 0); Lines = $lines }
}

function Main {
    if (-not $Manifest) { throw 'Pass -Manifest <the file patch-manifest.sh wrote on the server>' }
    $m = Read-Manifest $Manifest
    # the manifest carries the server's $PATCH_BASE; PATCH_BASE can be exported with a trailing slash
    $script:ServerBase = if ($m.PatchBase) { $m.PatchBase.TrimEnd('/') } else { '/u01/patches' }
    $fw = Get-ManifestFreshnessWarning $m.Created ([datetimeoffset]::UtcNow)
    if ($fw) { Write-Warning $fw }
    # The downloads land under OUTPUT_DIR/<host>; PATCH_BASE is honoured when only the legacy key is set, and
    # the default is %USERPROFILE%\oracle-patch-scripts, so nothing depends on the current directory.
    if (-not $Dest) { $Dest = Get-DefaultDest $m.Host }
    # absolute from here on: the operator sees where the files go, and nothing downstream depends on the
    # process working directory (see Get-AbsolutePath)
    $Dest = Get-AbsolutePath $Dest

    $script:MosHeaders = @{ Authorization = "Bearer $(Read-MosToken $TokenFile)" }
    # a MOS token lasts 60 minutes and an expired one fails as HTTP 502 or 401 halfway through a run - say the
    # age up front, so the operator renews it before a long download rather than after
    $tokenAge = Get-TokenAgeMinutes $TokenFile
    Write-Verbose "token: $TokenFile ($(if ($null -ne $tokenAge) { "$tokenAge minutes old" } else { 'age unknown' }))"
    if ($null -ne $tokenAge -and $tokenAge -ge 55) {
        Write-Warning "the MOS token in $TokenFile is $tokenAge minutes old and these expire at 60 - generate a new one at https://updates.oracle.com/Orion/GenToken/get_token if this run is longer than a few minutes"
    }
    # Invoke-MosGet already says which of the three it was (token, gateway, unreachable), so do not re-guess here
    try { Invoke-MosGet '/Orion/Services/search?bug=6880880' | Out-Null }
    catch { throw "the MOS check failed: $($_.Exception.Message)" }

    Write-Host "Host $($m.Host): looking up the newest patches on My Oracle Support"
    $plan = @(Get-PatchPlan $m)
    foreach ($p in $Patch) { $plan += Get-PatchItem -Patch $p -Kind $PatchKind }

    if ($plan.Count -eq 0 -and -not ($m.Homes | Where-Object { $_.Kind -ne 'db' }) -and -not $m.Ohs) { Write-Host 'Nothing to download: MOS has nothing newer than what is installed.'; return }
    Write-Host ''
    $plan | Format-Table @{ n = 'what'; e = { $_.What } }, @{ n = 'installed'; e = { $_.Installed } }, @{ n = 'patch'; e = { $_.Patch } }, @{ n = 'MOS says'; e = { $_.Abstract } } -AutoSize -Wrap | Out-Host
    if (-not $m.Fmw) { Write-Host 'Not looked up here: FMW product bundles (ADF/OPSS/OWSM...) - the manifest has no fmw| lines; check MOS Doc 2806740.2 and add them with -Patch.' }
    else { Write-Host "FMW bundles looked up from $($m.Fmw.Count) fmw| line(s); a product installed but not yet patched is only seen if patch-manifest.sh reported it." }
    foreach ($a in ($m.Homes | Where-Object { $_.Kind -eq 'agent' })) {
        $ru = @($a.Patches | ForEach-Object { $_.Description } | Where-Object { $_ -match 'AGENT' })[0]
        Write-Host "EM agent $($a.Version) at $($a.Home) (installed: $(if ($ru) { $ru } else { 'no agent RU' })): not downloaded - agent RUs (and the agent's JDK) are applied from the OMS."
    }
    foreach ($n in (Get-OhsNotes $m)) { Write-Host $n }
    foreach ($o in ($m.Homes | Where-Object { $_.Kind -eq 'other' })) { Write-Host "Oracle home $($o.Home): not a kind this script knows - check MOS for it by hand." }
    if ($plan | Where-Object { $_.What -like 'WLS Stack Patch Bundle*' }) { Write-Host 'The Stack Patch Bundle goes in its own folder: wls-patch.sh run applies it with the SPBAT inside it. Do not put single patches (wls/) in the same folder.' }
    if ($PlanOnly) { Write-Host 'OPatch: the minimum each patch needs is in its README, read after the download - -PlanOnly cannot tell whether a newer OPatch kit will be added.'; return }

    $failed = @()
    $downloaded = @()
    foreach ($p in $plan) {
        Write-Host "$($p.What): patch $($p.Patch)"
        try {
            $saved = Save-MosPatch -Patch $p.Patch -Dest (Join-Path $Dest (Get-PatchFolder -Item $p)) -Release $p.Release -Kind $p.Kind -Pin $p.File
            $downloaded += [pscustomobject]@{ Item = $p; Saved = $saved }
            if ($p.Kind -eq 'jdk') { Expand-JdkTarball $saved }
        }
        catch { $failed += $p.What; Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red }
    }
    $followUp = Invoke-OPatchFollowUp $m $downloaded $Dest

    # say what is missing FIRST: "Copy to the server" over an incomplete set is how an operator ends up patching
    # a host with half of what it needs and finding out on the server
    Write-Host ''
    $closing = Get-DownloadSummary $plan.Count $failed $Dest
    $i = 0
    foreach ($l in $closing.Lines) { $i++; if ($i -eq 1 -and -not $closing.Ready) { Write-Host $l -ForegroundColor Red } else { Write-Host $l } }
    Get-UploadHints $m.Host $Dest $script:ServerBase | ForEach-Object { Write-Host $_ }
    if ($failed.Count -gt 0 -or $followUp -gt 0) { exit 1 }
}

if ($MyInvocation.InvocationName -ne '.') { Main }
