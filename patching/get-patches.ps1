<#
get-patches.ps1 - on a Windows 10/11 machine with internet: read the manifest that patch-manifest.sh wrote on
a server with no internet, work out which patches that server is behind on, and download them from My
Oracle Support, ready to copy to the server. Runs in the PowerShell that ships with Windows (5.1) and in 7.

  .\get-patches.ps1 -Manifest .\patch-manifest-wl1.txt             # plan + download into .\patches-wl1
  .\get-patches.ps1 -Manifest .\patch-manifest-wl1.txt -PlanOnly   # only say what it would download
  .\get-patches.ps1 -Manifest ... -Patch 38123456                  # also download these numbers

What it looks up, for everything in the manifest:
  WebLogic home
  - WLS Stack Patch Bundle (SPB): newest "WLS STACK PATCH BUNDLE <release>.<yymmdd>" in MOS's Recommended
    list. One download carrying the PSU, Coherence, FMW Thirdparty, OSS, JDBC and RDA patches; it is
    applied with the spbat.sh inside it (see its readme), not with wls-patch.sh.
  - only when MOS lists no SPB: the WLS PSU and the Coherence cumulative patch one by one
  - FMW Platform Bundle: newest "FMW PLATFORM BUNDLE PATCH <release>.<yymmdd>", where one is installed
  - OPatch kit 28186730 when OPatch is older than 13.9.4.2.0, or older than the downloaded patches' READMEs ask for
  Database or client home (e.g. a 19c client)
  - newest "Database Release Update 19.N" for the release, and OPatch 6880880 with it when the home's OPatch is
    older than 12.2.0.1.40 or than the RU's README asks for
  OPatch: after the downloads, each PSU/SPB/RU README's "OPatch ... or later" is compared with the OPatch the
  manifest says is installed (the same rule wls-patch.sh and db-patch.sh apply on the server), and the kit is
  fetched and checked against it here, so a too-old OPatch is not first found on a server with no internet.
  EM agent home
  - reported, not downloaded: agent RUs are applied from the OMS
  JDK
  - newest update of each major version in use that has a Linux x86-64 download (one per major)
  FMW product bundles
  - the newest '<FAMILY> BUNDLE PATCH' for every fmw| line the manifest reports (ADF, OPSS, WSM,
    SOA, ...), looked up in the same WebLogic release's Recommended list
Anything else Oracle lists for these homes (MOS Doc 2806740.2): add it with -Patch.

Token: log in to My Oracle Support in a browser, open https://updates.oracle.com/Orion/GenToken/get_token,
press Generate token (valid 60 minutes) and save it as %USERPROFILE%\.mos-token (or pass -TokenFile).
MOS no longer takes the account password.

Files keep Oracle's names (p<number>_<release>_<platform>.zip), which wls-patch.sh matches on. A JDK patch
zip is unpacked to its .tar.gz, which is what java-patch.sh wants. Every file is SHA-256 checked.
#>
[CmdletBinding()]
param(
    [string] $Manifest,
    [string] $Dest,
    [string] $TokenFile = (Join-Path $HOME '.mos-token'),
    [string[]] $Patch = @(),
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
$script:DbOPatch = '6880880'

# ---- network: the only two functions that talk to MOS --------------------------------------------------
function Invoke-MosGet([string] $Path) {
    $resp = Invoke-WebRequest -Uri ($script:MosBase + $Path) -Headers $script:MosHeaders -UseBasicParsing
    [string] $resp.Content
}

function Invoke-MosDownload([string] $Url, [string] $OutFile) {
    # the URL redirects to Oracle's CDN; the Authorization header is dropped on that hop, which the CDN expects.
    # Stream it ourselves (not Invoke-WebRequest -OutFile, which with $ProgressPreference='SilentlyContinue' goes
    # quiet for the whole of a multi-GB patch) so the operator sees a live status: percent, size, MB/s.
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.AllowAutoRedirect = $true
    $req.UserAgent = 'get-patches.ps1'
    if ($script:MosHeaders -and $script:MosHeaders['Authorization']) { $req.Headers.Add('Authorization', $script:MosHeaders['Authorization']) }
    $resp = $req.GetResponse()
    try {
        $total = $resp.ContentLength
        $in = $resp.GetResponseStream()
        $out = [IO.File]::Create($OutFile)
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
    $m = [pscustomobject]@{ Host = ''; Wls = @(); Homes = @(); Jdks = @(); Fmw = @() }
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
        $f = $line.Split('|')
        switch ($f[0]) {
            'host' { $m.Host = $f[1] }
            'wls' {
                $m.Wls += [pscustomobject]@{ Home = $f[1]; Release = $f[2]; OPatch = $f[3]; Coherence = ($f[4] -eq 'yes'); Patches = @() }
            }
            'home' {
                $m.Homes += [pscustomobject]@{ Home = $f[1]; Kind = $f[2]; Version = $f[3]; OPatch = $f[4]; Patches = @() }
            }
            'patch' {
                $w = @($m.Wls) + @($m.Homes) | Where-Object { $_ -and $_.Home -eq $f[1] } | Select-Object -First 1
                if ($w) { $w.Patches += [pscustomobject]@{ Id = $f[2]; Description = (($f[3..($f.Count - 1)]) -join '|').Trim() } }
            }
            'jdk' { $m.Jdks += [pscustomobject]@{ Home = $f[1]; Version = $f[2]; Major = $f[3] } }
            'fmw' { $m.Fmw += [pscustomobject]@{ Home = $f[1]; Family = $f[2]; Version = $(if ($f.Count -gt 3) { $f[3] } else { '' }); Patch = $(if ($f.Count -gt 4) { $f[4] } else { '' }) } }
        }
    }
    if (-not $m.Wls -and -not $m.Homes -and -not $m.Jdks) { throw "$Path has no wls or jdk lines - is it a patch-manifest.sh file?" }
    $m
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

function Get-WlsPlan($Wls) {
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
    $spb = Select-Newest $rows $spbPattern
    if ($spb) {
        $have = Get-InstalledLevel $Wls $spbPattern
        if (-not $have -or [regex]::Match($spb.Abstract, $spbPattern).Groups[1].Value -gt $have) {
            # its own folder: wls-patch.sh run applies every zip in wls/, and an SPB is applied with spbat.sh
            New-PlanItem 'spb' "WLS Stack Patch Bundle ($($Wls.Home))" $have $spb $release $Wls.Home
        }
    }

    # no SPB on MOS: the PSU on its own. Exact PSU rows only, not "(BLR)" / MERGE / OVERLAY look-alikes
    $psuPattern = "(?i)^WLS PATCH SET UPDATE $esc(?:\.0)?\.(\d{6})\s*$"
    if (-not $spb) {
        $newest = Select-Newest $rows $psuPattern
        $have = Get-InstalledLevel $Wls $psuPattern
        if (-not $newest) { Write-Warning "$($Wls.Home): MOS lists no WLS PSU or Stack Patch Bundle for $short - get the number from Doc 2806740.2 and pass -Patch" }
        elseif (-not $have -or [regex]::Match($newest.Abstract, $psuPattern).Groups[1].Value -gt $have) {
            New-PlanItem 'wls' "WLS PSU ($($Wls.Home))" $have $newest $release $Wls.Home
        }
    }

    # FMW Platform Bundle: only where one is installed
    $bundlePattern = "(?i)^FMW PLATFORM BUNDLE PATCH $esc(?:\.0)?\.(\d{6})"
    $have = Get-InstalledLevel $Wls $bundlePattern
    if ($have) {
        $newest = Select-Newest $rows $bundlePattern
        if (-not $newest) { Write-Warning "$($Wls.Home): FMW Platform Bundle $have is installed but MOS's Recommended list has none - get the number from Doc 2806740.2 and pass -Patch" }
        elseif ([regex]::Match($newest.Abstract, $bundlePattern).Groups[1].Value -gt $have) {
            New-PlanItem 'wls' "FMW Platform Bundle ($($Wls.Home))" $have $newest $release $Wls.Home
        }
    }

    # Coherence cumulative patch. lspatches says "Coherence Cumulative Patch 12.2.1.4.30"; MOS can say
    # "Coherence 12.2.1.4 Cumulative Patch 30 (12.2.1.4.30)". Both carry the level as <release>.<N>.
    if ($Wls.Coherence -and -not $spb) {
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
            if ($rows.Count -gt 0) { $found = [pscustomobject]@{ Release = $r; Row = ($rows | Sort-Object Date -Descending | Select-Object -First 1) }; break }
        }
        if (-not $found) { Write-Warning "JDK ${major}: no Linux x86-64 patch in the newest MOS releases - get it from MOS Doc 1439822.2 and pass -Patch"; continue }
        $newVersion = $found.Release.Label.Substring('Oracle JDK '.Length)
        if ((Get-VersionKey $newVersion) -gt (Get-VersionKey $oldest.Version)) {
            New-PlanItem 'jdk' "JDK $major (oldest here: $($oldest.Home))" $oldest.Version $found.Row $newVersion
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
    $ruPattern = "(?i)^Database Release Update\s*:?\s*$major\.(\d+)\.0\.0\.(\d{6})\s*(?:\(|$)"
    $rows = @(Get-MosPatchRows $script:ProductDatabase $dbRelease $script:PlatformLinux -Recommended)
    $newest = $rows | Where-Object { $_.Abstract -match $ruPattern } |
        Sort-Object { [regex]::Match($_.Abstract, $ruPattern).Groups[2].Value } -Descending | Select-Object -First 1
    $have = @($Db.Patches | Where-Object { $_.Description -match $ruPattern } |
            ForEach-Object { [regex]::Match($_.Description, $ruPattern).Groups[2].Value } | Sort-Object -Descending)[0]
    if (-not $newest) { Write-Warning "$($Db.Home): MOS lists no Database Release Update for $major - get it from MOS Doc 2118136.2 and pass -Patch"; return }
    if (-not $have -or [regex]::Match($newest.Abstract, $ruPattern).Groups[2].Value -gt $have) {
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

function Get-PatchPlan($Manifest) {
    foreach ($w in $Manifest.Wls) { Get-WlsPlan $w }
    foreach ($h in ($Manifest.Homes | Where-Object { $_.Kind -eq 'db' })) { Get-DbPlan $h }
    if ($Manifest.Jdks) { Get-JdkPlan $Manifest.Jdks }
    if ($Manifest.Fmw) { Get-FmwPlan $Manifest }
}

# ---- download ------------------------------------------------------------------------------------------
# fetch one patch's file for Linux (or Generic), preferring $Release; returns the saved path
function Save-MosPatch([string] $Patch, [string] $Dest, [string] $Release) {
    $xml = Remove-Cdata ((Invoke-MosGet "/Orion/Services/search?bug=$Patch") -replace "[`r`n]", '')
    if ($xml -match '<html') { throw "MOS returned a web page for $Patch - the token was not accepted (expired or mis-pasted?)" }
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

    $forUs = @($files | Where-Object { $_.Platform -match 'Generic|Linux x86-64' })
    if ($forUs.Count -eq 0) { $forUs = $files }
    $pick = $null
    if ($Release) {
        $tag = '_' + $Release.Replace('.', '')
        $pick = $forUs | Where-Object { $_.Release.StartsWith($Release) -or $_.Name.Contains($tag) } | Select-Object -First 1
    }
    if (-not $pick -and $forUs.Count -eq 1) { $pick = $forUs[0] }
    if (-not $pick) {
        $list = ($forUs | ForEach-Object { "    $($_.Name)  release $($_.Release)  ($($_.Platform))" }) -join "`n"
        throw "patch $Patch has several files and none is for release '$Release':`n$list"
    }

    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    $out = Join-Path $Dest $pick.Name
    if ((Test-Path -LiteralPath $out) -and $pick.Sha -and ((Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash.ToLower() -eq $pick.Sha)) {
        Write-Host "  $($pick.Name) already here and verified"
        return $out
    }
    Write-Host "  downloading $($pick.Name)"
    Invoke-MosDownload $pick.Url "$out.part"
    if ($pick.Sha -and ((Get-FileHash -LiteralPath "$out.part" -Algorithm SHA256).Hash.ToLower() -ne $pick.Sha)) {
        Remove-Item -LiteralPath "$out.part" -Force
        throw "SHA-256 mismatch for $($pick.Name) - deleted it, try again"
    }
    Move-Item -LiteralPath "$out.part" -Destination $out -Force
    $out
}

# a JDK patch zip holds the .tar.gz java-patch.sh wants: unpack it next to the zip
function Expand-JdkTarball([string] $Zip) {
    if (-not $Zip.EndsWith('.zip')) { return }
    $dir = Split-Path -Parent $Zip
    $tmp = Join-Path $dir ('unzip-' + [guid]::NewGuid())
    Expand-Archive -LiteralPath $Zip -DestinationPath $tmp
    Get-ChildItem -LiteralPath $tmp -Recurse -Filter '*.tar.gz' | ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination $dir -Force; Write-Host "  unpacked $($_.Name)" }
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
# Up to 80 characters may sit between the word and the version, digits too ("OPatch (patch 28186730)
# 12.2.0.1.40"): a patch number has no dots, so it is never read as the version. In a sentence that names
# OPatch, a further version counts only when a minimum phrase follows it ("OPatch 13.9.4.2.5 or later, and
# 13.9.4.2.20 or later for this PSU" needs .20) - so the PSU or RU's own build number is never the minimum.
function Get-ZipMinOPatch([string] $Zip) {
    $text = Get-ZipReadmeText $Zip
    $ver = '\d+(?:\.\d+){3,5}'
    $found = @([regex]::Matches($text, "(?i)\bOPatch\b[^\n]{0,80}?\b($ver)\b") | ForEach-Object { $_.Groups[1].Value })
    foreach ($s in ($text -split '(?<=\.)\s+|\n')) {
        if ($s -notmatch '(?i)\bOPatch\b') { continue }
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
        if (-not $it.For -or -not $d.Saved -or $it.Kind -notin @('wls', 'spb', 'db') -or $it.Patch -in $kits) { continue }
        $wls = $Manifest.Wls | Where-Object { $_.Home -eq $it.For } | Select-Object -First 1
        $db = $Manifest.Homes | Where-Object { $_.Home -eq $it.For -and $_.Kind -eq 'db' } | Select-Object -First 1
        if ($wls) { $installed = $wls.OPatch } elseif ($db) { $installed = $db.OPatch } else { continue }
        $min = Get-ZipMinOPatch $d.Saved
        if (-not $min) {
            # the README may be missing, deeper in the zip, or worded in a way this does not read: say so, the server would find out too late
            Write-Warning "patch $($it.Patch): no OPatch minimum found in its README - check the README by hand for the OPatch it needs ($($it.For) has $(if ($installed) { $installed } else { 'an unknown version' }))"
            continue
        }
        $cur = $byHome[$it.For]
        if (-not $cur -or (Get-VersionKey $min) -gt (Get-VersionKey $cur.Min)) {
            $byHome[$it.For] = [pscustomobject]@{ Home = $it.For; Min = $min; Installed = $installed; Wls = [bool]$wls; Release = $it.Release; From = $it.Patch }
        }
    }
    foreach ($n in $byHome.Values) {
        if ($n.Installed -and (Get-VersionKey $n.Installed) -ge (Get-VersionKey $n.Min)) { continue }
        $kitNo = if ($n.Wls) { $script:OPatchKit } else { $script:DbOPatch }
        $have = $Downloaded | Where-Object { $_.Item.Patch -eq $kitNo -and $_.Item.For -eq $n.Home -and $_.Saved } | Select-Object -First 1
        $item = $null
        if (-not $have) {
            $item = if ($n.Wls) { New-PlanItem 'wls' "OPatch kit ($($n.Home))" $n.Installed ([pscustomobject]@{ Number = $kitNo; Abstract = "OPatch $($n.Min) or later (patch $($n.From)'s README)" }) '13.9.4' $n.Home }
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
            try { $kit = Save-MosPatch -Patch $n.Item.Patch -Dest (Join-Path $Dest $n.Item.Kind) -Release $n.Item.Release }
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

function Main {
    if (-not $Manifest) { throw 'Pass -Manifest <the file patch-manifest.sh wrote on the server>' }
    $m = Read-Manifest $Manifest
    if (-not $Dest) { $Dest = Join-Path (Get-Location) "patches-$($m.Host)" }

    $script:MosHeaders = @{ Authorization = "Bearer $(Read-MosToken $TokenFile)" }
    try { Invoke-MosGet '/Orion/Services/search?bug=6880880' | Out-Null }
    catch { throw "MOS did not accept the token (expired after 60 minutes, or mis-pasted?), or cannot be reached: $($_.Exception.Message)" }

    Write-Host "Host $($m.Host): looking up the newest patches on My Oracle Support"
    $plan = @(Get-PatchPlan $m)
    foreach ($p in $Patch) { $plan += [pscustomobject]@{ Kind = 'wls'; What = 'asked for with -Patch'; Installed = ''; Patch = $p; Abstract = ''; Release = $(if ($m.Wls) { $m.Wls[0].Release } else { '' }) } }

    if ($plan.Count -eq 0 -and -not ($m.Homes | Where-Object { $_.Kind -ne 'db' })) { Write-Host 'Nothing to download: MOS has nothing newer than what is installed.'; return }
    Write-Host ''
    $plan | Format-Table @{ n = 'what'; e = { $_.What } }, @{ n = 'installed'; e = { $_.Installed } }, @{ n = 'patch'; e = { $_.Patch } }, @{ n = 'MOS says'; e = { $_.Abstract } } -AutoSize -Wrap | Out-Host
    if (-not $m.Fmw) { Write-Host 'Not looked up here: FMW product bundles (ADF/OPSS/OWSM...) - the manifest has no fmw| lines; check MOS Doc 2806740.2 and add them with -Patch.' }
    else { Write-Host "FMW bundles looked up from $($m.Fmw.Count) fmw| line(s); a product installed but not yet patched is only seen if patch-manifest.sh reported it." }
    foreach ($a in ($m.Homes | Where-Object { $_.Kind -eq 'agent' })) {
        $ru = @($a.Patches | ForEach-Object { $_.Description } | Where-Object { $_ -match 'AGENT' })[0]
        Write-Host "EM agent $($a.Version) at $($a.Home) (installed: $(if ($ru) { $ru } else { 'no agent RU' })): not downloaded - agent RUs (and the agent's JDK) are applied from the OMS."
    }
    foreach ($o in ($m.Homes | Where-Object { $_.Kind -eq 'other' })) { Write-Host "Oracle home $($o.Home): not a kind this script knows - check MOS for it by hand." }
    if ($plan | Where-Object { $_.What -like 'WLS Stack Patch Bundle*' }) { Write-Host 'The Stack Patch Bundle is applied with the spbat.sh inside it (see its readme), not with wls-patch.sh.' }
    if ($PlanOnly) { Write-Host 'OPatch: the minimum each patch needs is in its README, read after the download - -PlanOnly cannot tell whether a newer OPatch kit will be added.'; return }

    $failed = 0
    $downloaded = @()
    foreach ($p in $plan) {
        Write-Host "$($p.What): patch $($p.Patch)"
        try {
            $saved = Save-MosPatch -Patch $p.Patch -Dest (Join-Path $Dest $p.Kind) -Release $p.Release
            $downloaded += [pscustomobject]@{ Item = $p; Saved = $saved }
            if ($p.Kind -eq 'jdk') { Expand-JdkTarball $saved }
        }
        catch { $failed++; Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red }
    }
    $failed += Invoke-OPatchFollowUp $m $downloaded $Dest

    Write-Host ''
    Write-Host "Saved under $Dest. Copy to the server (as oracle), then run the patch scripts there:"
    if (Test-Path -LiteralPath (Join-Path $Dest 'wls')) { Write-Host "  scp `"$Dest\wls\*.zip`" oracle@$($m.Host):/u01/patches/wls/" }
    if (Test-Path -LiteralPath (Join-Path $Dest 'spb')) { Write-Host "  scp `"$Dest\spb\*.zip`" oracle@$($m.Host):/u01/patches/spb/" }
    if (Test-Path -LiteralPath (Join-Path $Dest 'db')) { Write-Host "  scp `"$Dest\db\*.zip`" oracle@$($m.Host):/u01/patches/db/" }
    if (Test-Path -LiteralPath (Join-Path $Dest 'jdk')) { Write-Host "  scp `"$Dest\jdk\*.tar.gz`" oracle@$($m.Host):/u01/patches/jdk/" }
    if ($failed -gt 0) { Write-Host "$failed download(s) failed - see above." -ForegroundColor Red; exit 1 }
}

if ($MyInvocation.InvocationName -ne '.') { Main }
