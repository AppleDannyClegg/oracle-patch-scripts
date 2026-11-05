# get-patches.ps1 - behavioural gate for tools/get-patches.ps1 (no network, no Pester).
#
# Dot-sources the script (its main does not run when dot-sourced), replaces the two network functions
# (Invoke-MosGet, Invoke-MosDownload) with canned My Oracle Support answers, and checks:
#   - the manifest written by patch-manifest.sh is read back correctly
#   - the plan picks the newest WLS PSU, FMW Platform Bundle, Coherence patch and JDK 8, skips look-alikes
#     ("(BLR)" one-offs, JDK releases announced before their patch exists) and is empty for a current host
#   - an old OPatch adds the OPatch kit
#   - a download is saved under Oracle's file name only when its SHA-256 matches
#
# Usage: pwsh -NoProfile -File tests/get-patches.ps1      (also runs under Windows PowerShell 5.1)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'patching/get-patches.ps1')

$script:pass = 0; $script:fail = 0
function Check([bool] $cond, [string] $what) {
    if ($cond) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $what" }
}

# ---- canned MOS answers -------------------------------------------------------------------------------
function Row([string] $num, [string] $abstract, [string] $date) {
    "<patch has_prereqs=`"n`"><name>$num</name><number>$num</number><bug><number>1</number></bug><abstract><![CDATA[$abstract]]></abstract><released_date>$date</released_date></patch>"
}
$releaseXml = @'
<results>
<release id="600" status="A" name="12.2.1.4.0">
<![CDATA[Oracle WebLogic Server 12.2.1.4.0]]></release>
<release id="601" status="A" name="12.2.1.4.0"><![CDATA[Oracle Coherence 12.2.1.4.0]]></release>
<release id="800" status="A" name="19.0.0.0.0"><![CDATA[Oracle Database 19.0.0.0.0]]></release>
<release id="700" status="A" name="1.8.0_491"><![CDATA[Oracle JDK 1.8.0_491]]></release>
<release id="701" status="A" name="1.8.0_481"><![CDATA[Oracle JDK 1.8.0_481]]></release>
<release id="702" status="A" name="1.8.0_471"><![CDATA[Oracle JDK 1.8.0_471]]></release>
<release id="703" status="A" name="1.8.0_499"><![CDATA[Oracle JDK 1.8.0_499-perf Performance]]></release>
</results>
'@
$wlsRows = '<results>' +
    (Row 39000001 'WLS PATCH SET UPDATE 12.2.1.4.260818' '2026-08-18') +
    (Row 39000002 'WLS PATCH SET UPDATE 12.2.1.4.261020' '2026-10-20') +
    (Row 39000009 'WLS PATCH SET UPDATE 12.2.1.4.261031 (BLR)' '2026-10-31') +
    (Row 39000003 'Fmw Platform Bundle Patch 12.2.1.4.261020' '2026-10-20') +
    (Row 39000004 'FMW PLATFORM BUNDLE PATCH 12.2.1.4.260715' '2026-07-15') +
    (Row 39000031 'ADF BUNDLE PATCH 12.2.1.4.261020' '2026-10-20') +
    (Row 39000032 'ADF BUNDLE PATCH 12.2.1.4.250415' '2025-04-15') +
    (Row 39000033 'OPSS BUNDLE PATCH 12.2.1.4.261020' '2026-10-20') +
    (Row 39000041 'FMW Thirdparty Bundle Patch 12.2.1.4.260317' '2026-03-17') + '</results>'
$spbRows = (Row 39500001 'WLS STACK PATCH BUNDLE 12.2.1.4.260522 (Patch 39426129)' '2026-05-22') +
    (Row 39500002 'WLS STACK PATCH BUNDLE 12.2.1.4.261020 (Patch 39500002)' '2026-10-20')
$dbRows = '<results>' +
    (Row 39600001 'Database Release Update : 19.30.0.0.260120 (39600001)' '2026-01-20') +
    (Row 39600003 'Database Release Update : 19.31.0.0.261020 (39600003)' '2026-10-20') +
    (Row 39600004 'OJVM RELEASE UPDATE: 19.31.0.0.261020 (39600004)' '2026-10-20') +
    (Row 39600005 'Database Release Update Revision 19.30.2.0.261020' '2026-10-20') +
    (Row 39600006 'COMBO OF OJVM RU COMPONENT 19.31.0.0.261031 + Database Release Update 19.31.0.0.261031' '2026-10-31') +
    (Row 39600007 'Database Release Update 19.31.0.0.261031 - CMAN' '2026-10-31') + '</results>'
$script:withSpb = $true
$cohRows = '<results>' +
    (Row 39000011 'Coherence 12.2.1.4 Cumulative Patch 32 (12.2.1.4.32)' '2026-07-15') +
    (Row 39000010 'Coherence 12.2.1.4 Cumulative Patch 33 (12.2.1.4.33)' '2026-10-20') + '</results>'
$jdkRows = '<results>' + (Row 39000020 'Oracle JDK 8 Update 481 for Linux x86-64' '2026-10-20') + '</results>'
# the Performance build has a newer number and a download: only the name filter keeps it out
$perfRows = '<results>' + (Row 39000029 'Oracle JDK 8 Update 499 Performance for Linux x86-64' '2026-10-28') + '</results>'
$bug = @'
<results><patch has_prereqs="n"><name>39000002</name><release id="600" name="12.2.1.4.0"/>
<platform id="2000"><![CDATA[Generic Platform]]></platform>
<files><file><name>p39000002_122140_Generic.zip</name><size>17</size>
<download_url host="https://updates.oracle.com"><![CDATA[/Orion/Download/process_form/p39000002_122140_Generic.zip?aru=1&amp;patch_file=p39000002_122140_Generic.zip]]></download_url>
<digest type="SHA-256">SHA_HERE</digest></file></files></patch></results>
'@
$fakeZip = 'fake-zip-39000002'
$sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($fakeZip))).Replace('-', '').ToLower()

$script:asked = @()
$script:downloadedUrl = $null
$script:bugXml = $bug.Replace('SHA_HERE', $sha)
function Invoke-MosGet([string] $Path) {
    $script:asked += $Path
    if ($Path -like '*metadata?table=aru_releases*') { return $releaseXml }
    if ($Path -like '*product=15991&release=600&platform=2000*') {
        if ($script:withSpb) { return $wlsRows.Replace('</results>', $spbRows + '</results>') } else { return $wlsRows }
    }
    if ($Path -like '*product=9480&release=800&platform=226*') { return $dbRows }
    if ($Path -like '*product=13964&release=601&platform=2000*') { return $cohRows }
    if ($Path -like '*product=12443&release=701&platform=226*') { return $jdkRows }
    if ($Path -like '*product=12443&release=703&platform=226*') { return $perfRows }
    if ($Path -like '*product=12443&*') { return '<results></results>' }
    if ($Path -like '*search?bug=39000002*') { return $script:bugXml }
    throw "unexpected MOS call $Path"
}
function Invoke-MosDownload([string] $Url, [string] $OutFile) {
    $script:downloadedUrl = $Url
    [IO.File]::WriteAllText($OutFile, $fakeZip)
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("gp-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    # ---- manifest -------------------------------------------------------------------------------------
    $behind = Join-Path $tmp 'behind.txt'
    @(
        '# patch-manifest v1',
        'host|wl1',
        'created|2026-11-03 15:00',
        'wls|/u01/fmw|12.2.1.4.0|13.9.4.2.23|yes',
        'patch|/u01/fmw|39426213|WLS STACK PATCH BUNDLE 12.2.1.4.260522 (Patch 39426129)',
        'patch|/u01/fmw|38102345|WLS PATCH SET UPDATE 12.2.1.4.260514',
        'patch|/u01/fmw|1221430|Coherence Cumulative Patch 12.2.1.4.30',   # the real lspatches shape
        'patch|/u01/fmw|36946553| FMW PLATFORM BUNDLE PATCH 12.2.1.4.240812',   # opatch can leave a space after the ;
        'home|/stage/client/app/product/19.0.0.0|db|19.27.0.0.0|12.2.0.1.36',
        'patch|/stage/client/app/product/19.0.0.0|37642901|Database Release Update : 19.27.0.0.250415 (37642901)',
        'home|/u01/app/oracle/agent/agent_24.1.0.0.0|agent|24.1.0.0.0|13.9.4.2.20',
        'patch|/u01/app/oracle/agent/agent_24.1.0.0.0|38000111|EM-AGENT Patch Set Update 24.1.0.0.250131',
        'jdk|/home/oracle/java|1.8.0_471|8',
        'jdk|/u01/app/oracle/agent/agent_24.1.0.0.0/oracle_common/jdk|1.8.0_431|8'
    ) | Set-Content -LiteralPath $behind

    $m = Read-Manifest $behind
    Check ($m.Host -eq 'wl1') "manifest host: [$($m.Host)]"
    Check (@($m.Wls).Count -eq 1) "one WebLogic home, got $(@($m.Wls).Count)"
    Check ($m.Wls[0].Release -eq '12.2.1.4.0' -and $m.Wls[0].OPatch -eq '13.9.4.2.23' -and $m.Wls[0].Coherence) "wls line fields"
    Check (@($m.Wls[0].Patches).Count -eq 4) "four installed patches, got $(@($m.Wls[0].Patches).Count)"
    Check (@($m.Jdks).Count -eq 2) "two JDKs, got $(@($m.Jdks).Count)"

    # ---- plan for a host that is behind ---------------------------------------------------------------
    Check (@($m.Homes).Count -eq 2) "two non-WebLogic homes, got $(@($m.Homes).Count)"
    Check ((@($m.Homes | Where-Object { $_.Kind -eq 'db' })[0].Patches).Count -eq 1) "the client home's patch is attached to it"

    $plan = @(Get-PatchPlan $m)
    $nums = @($plan | ForEach-Object { $_.Patch })
    Check ($nums -contains '39500002') "newest Stack Patch Bundle 39500002 planned (got $($nums -join ','))"
    Check (@($plan | Where-Object { $_.Patch -eq '39500002' })[0].Kind -eq 'spb') "the SPB goes to its own folder (wls-patch.sh applies every zip in wls/)"
    Check (-not ($nums -contains '39000002')) "the PSU is not fetched separately when the SPB carries it"
    Check (-not ($nums -contains '39000010')) "Coherence is not fetched separately when the SPB carries it"
    Check ($nums -contains '39000003') "newest FMW Platform Bundle 39000003 planned"
    Check ($nums -contains '39000020') "JDK 8u481 (39000020) planned: 491 has no patch yet, the Performance build is skipped"
    Check (@($plan | Where-Object { $_.Kind -eq 'jdk' }).Count -eq 1) "one JDK download per major version"
    Check (-not ($nums -contains '28186730')) "no OPatch kit for OPatch 13.9.4.2.23"
    Check ($nums -contains '39600003') "19c client: newest Database Release Update 19.31 (39600003), not OJVM or a Revision"
    Check (-not ($nums -contains '39600007')) "19c client: the ' - CMAN' variant is not the database RU"
    Check ($nums -contains '6880880') "19c client with OPatch 12.2.0.1.36: OPatch 6880880 with the RU"
    Check (@($plan | Where-Object { $_.What -like '*agent*' }).Count -eq 0) "nothing downloaded for the EM agent (its RU comes from the OMS)"
    Check ($plan.Count -eq 5) "five patches planned, got $($plan.Count): $($nums -join ',')"

    # ---- no Stack Patch Bundle on MOS: PSU and Coherence one by one -----------------------------------
    $script:withSpb = $false
    $planNoSpb = @(Get-PatchPlan $m)
    $nums = @($planNoSpb | ForEach-Object { $_.Patch })
    Check ($nums -contains '39000002') "no SPB listed: newest PSU 39000002 planned (got $($nums -join ','))"
    Check (-not ($nums -contains '39000009')) "the (BLR) one-off is not the PSU"
    Check ($nums -contains '39000010') "no SPB listed: Coherence Cumulative Patch 33 (39000010) planned"
    $script:withSpb = $true
    $jdkItem = $plan | Where-Object { $_.Kind -eq 'jdk' } | Select-Object -First 1
    Check ($jdkItem.Installed -eq '1.8.0_471') "JDK compared with the WebLogic JDK, not the EM agent's: [$($jdkItem.Installed)]"

    # ---- Coherence already at the newest: nothing to fetch --------------------------------------------
    $cohCurrent = Join-Path $tmp 'cohcurrent.txt'
    @('host|wl4', 'wls|/u01/fmw|12.2.1.4.0|13.9.4.2.23|yes', 'patch|/u01/fmw|39000002|WLS PATCH SET UPDATE 12.2.1.4.261020',
      'patch|/u01/fmw|39000010|Coherence Cumulative Patch 12.2.1.4.33') | Set-Content -LiteralPath $cohCurrent
    $plan4 = @(Get-PatchPlan (Read-Manifest $cohCurrent))
    Check (@($plan4 | Where-Object { $_.What -like 'Coherence*' }).Count -eq 0) "Coherence .33 installed and .33 newest: not planned (got $(@($plan4 | ForEach-Object { $_.Patch }) -join ','))"

    # ---- a truncated release table is refused, not used ------------------------------------------------
    $saveXml = $releaseXml
    $releaseXml = $saveXml.Substring(0, $saveXml.IndexOf('<release id="702"'))
    $script:Releases = $null
    $threw = $false
    try { Get-MosReleases | Out-Null } catch { $threw = $true }
    Check $threw "a release table without </results> throws"
    $releaseXml = $saveXml
    $script:Releases = $null

    # ---- a current host plans nothing -----------------------------------------------------------------
    $current = Join-Path $tmp 'current.txt'
    @(
        'host|wl2',
        'wls|/u01/fmw|12.2.1.4.0|13.9.4.2.23|yes',
        'patch|/u01/fmw|39500002|WLS STACK PATCH BUNDLE 12.2.1.4.261020 (Patch 39500002)',
        'patch|/u01/fmw|39000002|WLS PATCH SET UPDATE 12.2.1.4.261020',
        'patch|/u01/fmw|39000010|Coherence Cumulative Patch 12.2.1.4.33',
        'patch|/u01/fmw|39000003| FMW PLATFORM BUNDLE PATCH 12.2.1.4.261020',
        'home|/stage/client/app/product/19.0.0.0|db|19.31.0.0.0|12.2.0.1.48',
        'patch|/stage/client/app/product/19.0.0.0|39600003|Database Release Update : 19.31.0.0.261020 (39600003)',   # opatch can leave a space after the ;
        'jdk|/home/oracle/java|1.8.0_481|8',
        'jdk|/u01/app/oracle/agent/agent_24.1.0.0.0/oracle_common/jdk|1.8.0_431|8'   # EM agent: its own RU, not ours
    ) | Set-Content -LiteralPath $current
    $plan2 = @(Get-PatchPlan (Read-Manifest $current))
    Check ($plan2.Count -eq 0) "current host plans nothing, got $(@($plan2 | ForEach-Object { $_.Patch }) -join ',')"

    # ---- a client whose OPatch is current gets the RU but no OPatch kit; an 'other' home is tolerated -----
    $cur = Join-Path $tmp 'clientopatch.txt'
    @('host|wl5', 'home|/stage/client/app/product/19.0.0.0|db|19.27.0.0.0|12.2.0.1.44',
      'patch|/stage/client/app/product/19.0.0.0|37642901|Database Release Update : 19.27.0.0.250415 (37642901)',
      'home|/opt/thing|other||13.9.4.2.1') | Set-Content -LiteralPath $cur
    $m5 = Read-Manifest $cur
    Check (@($m5.Homes | Where-Object { $_.Kind -eq 'other' }).Count -eq 1) "an 'other' home with no version is read"
    $plan5 = @(Get-PatchPlan $m5)
    $n5 = @($plan5 | ForEach-Object { $_.Patch })
    Check (($n5 -contains '39600003') -and -not ($n5 -contains '6880880')) "OPatch 12.2.0.1.44: RU planned, no OPatch kit (got $($n5 -join ','))"

    # ---- old OPatch adds the kit ----------------------------------------------------------------------
    $oldOpatch = Join-Path $tmp 'oldopatch.txt'
    @('host|wl3', 'wls|/u01/fmw|12.2.1.4.0|13.9.4.0.0|no', 'patch|/u01/fmw|39000002|WLS PATCH SET UPDATE 12.2.1.4.261020') | Set-Content -LiteralPath $oldOpatch
    $plan3 = @(Get-PatchPlan (Read-Manifest $oldOpatch))
    Check (@($plan3 | Where-Object { $_.Patch -eq '28186730' }).Count -eq 1) "OPatch 13.9.4.0.0 adds the OPatch kit 28186730"

    # ---- download: verified file under Oracle's name --------------------------------------------------
    $dest = Join-Path $tmp 'wls'
    $saved = ''
    try { $saved = Save-MosPatch -Patch '39000002' -Dest $dest -Release '12.2.1.4.0' } catch { Check $false "first download threw: $($_.Exception.Message)" }
    Check ((Split-Path -Leaf $saved) -eq 'p39000002_122140_Generic.zip') "saved under Oracle's name, got [$saved]"
    Check ((Get-Content -LiteralPath $saved -Raw) -eq $fakeZip) "saved content"
    Check ($script:downloadedUrl -eq 'https://updates.oracle.com/Orion/Download/process_form/p39000002_122140_Generic.zip?aru=1&patch_file=p39000002_122140_Generic.zip') "CDATA stripped and &amp; decoded in the URL: [$script:downloadedUrl]"
    Check (-not (Test-Path -LiteralPath "$saved.part")) "no .part left behind"

    # ---- a file already here and verified is not fetched again ----------------------------------------
    $script:downloadedUrl = $null
    try { Save-MosPatch -Patch '39000002' -Dest $dest -Release '12.2.1.4.0' | Out-Null } catch { Check $false "second download threw: $($_.Exception.Message)" }
    Check ($null -eq $script:downloadedUrl) "a verified file already in place is not downloaded again"

    # ---- download: SHA-256 mismatch keeps nothing -----------------------------------------------------
    $script:bugXml = $bug.Replace('SHA_HERE', ('0' * 64))
    $dest2 = Join-Path $tmp 'wls2'
    $threw = $false
    try { Save-MosPatch -Patch '39000002' -Dest $dest2 -Release '12.2.1.4.0' | Out-Null } catch { $threw = $true }
    Check $threw "SHA-256 mismatch throws"
    Check (@(Get-ChildItem -LiteralPath $dest2 -ErrorAction SilentlyContinue).Count -eq 0) "SHA-256 mismatch leaves no file"
    # ---- a db home with no version in the manifest: warn and skip, do not abort the whole run ---------
    # Get-PatchPlan is a simple function (no CmdletBinding), so capture warnings off stream 3, not -WarningVariable
    function PlanWithWarnings($Manifest) {
        $raw = @(Get-PatchPlan $Manifest 3>&1)
        [pscustomobject]@{
            Warnings = @($raw | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
            Plan     = @($raw | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })
        }
    }

    $noVer = Join-Path $tmp 'noversion.txt'
    @('host|wl6',
      'home|/stage/client/dbhome_1|db||12.2.0.1.44',   # no version, no RU, no version in the path
      'wls|/u01/fmw|12.2.1.4.0|13.9.4.2.23|no',
      'patch|/u01/fmw|39000002|WLS PATCH SET UPDATE 12.2.1.4.261020') | Set-Content -LiteralPath $noVer
    $r6 = PlanWithWarnings (Read-Manifest $noVer)
    Check (($r6.Warnings -join ' ') -match 'no database version') "an empty db version warns"
    Check (@($r6.Plan | Where-Object { $_.Kind -eq 'db' }).Count -eq 0) "an empty db version plans no db patch"
    Check (@($r6.Plan | Where-Object { $_.Kind -eq 'spb' }).Count -eq 1) "the WebLogic lookup still ran after the db home was skipped"

    # ---- empty db version (sqlplus -V failed on a real WebLogic host): the major comes from the RU, else the path
    $fromRu = Join-Path $tmp 'noversion-ru.txt'
    @('host|wl8', 'home|/stage/client/dbhome_1|db||12.2.0.1.44',
      'patch|/stage/client/dbhome_1|37642901|Database Release Update : 19.27.0.0.250415 (37642901)') | Set-Content -LiteralPath $fromRu
    $n8 = @((PlanWithWarnings (Read-Manifest $fromRu)).Plan | ForEach-Object { $_.Patch })
    Check ($n8 -contains '39600003') "no version: the major comes from the RU it has, 19.31 planned (got $($n8 -join ','))"
    $fromPath = Join-Path $tmp 'noversion-path.txt'
    @('host|wl9', 'home|/stage/client/app/product/19.0.0.0|db||12.2.0.1.44') | Set-Content -LiteralPath $fromPath
    $n9 = @((PlanWithWarnings (Read-Manifest $fromPath)).Plan | ForEach-Object { $_.Patch })
    Check ($n9 -contains '39600003') "no version, no RU: the major comes from the home path 19.0.0.0 (got $($n9 -join ','))"

    # ---- a db release MOS does not list: warn by name, skip -------------------------------------------
    $noRel = Join-Path $tmp 'norelease.txt'
    @('host|wl7', 'home|/x/23.0.0.0|db|23.0.0.0.0|12.2.0.1.44') | Set-Content -LiteralPath $noRel
    $r7 = PlanWithWarnings (Read-Manifest $noRel)
    Check (($r7.Warnings -join ' ') -match 'Oracle Database 23.0.0.0.0') "an unknown db release warns by name"

    # ---- a wls home with no release, and one MOS does not list: warn, do not throw --------------------
    $wlsNoRel = Join-Path $tmp 'wlsnorelease.txt'
    @('host|wl8', 'wls|/u01/fmw||13.9.4.2.23|yes') | Set-Content -LiteralPath $wlsNoRel
    $r8 = PlanWithWarnings (Read-Manifest $wlsNoRel)
    Check (($r8.Warnings -join ' ') -match 'no WebLogic release') "an empty wls release warns"

    $wlsUnknown = Join-Path $tmp 'wlsunknown.txt'
    @('host|wl9', 'wls|/u01/fmw|14.1.2.0.0|13.9.4.2.23|no') | Set-Content -LiteralPath $wlsUnknown
    $r9 = PlanWithWarnings (Read-Manifest $wlsUnknown)
    Check (($r9.Warnings -join ' ') -match 'Oracle WebLogic Server 14.1.2.0.0') "an unknown wls release warns by name"

    # ---- FMW product bundles reported by the manifest ------------------------------------------------
    $fmw = Join-Path $tmp 'fmw.txt'
    @(
        'host|wl-fmw',
        'wls|/u01/app/fmw/home1|12.2.1.4.0|13.9.4.2.23|yes',
        'patch|/u01/app/fmw/home1|36946553|FMW PLATFORM BUNDLE PATCH 12.2.1.4.240812',
        'fmw|/u01/app/fmw/home1|ADF|12.2.1.4.250415|39000032',
        'fmw|/u01/app/fmw/home1|OPSS|12.2.1.4.261020|39000033',
        'fmw|/u01/app/fmw/home1|WSM|12.2.1.4.260415|39000099',
        'fmw|/u01/app/fmw/home1|FMW THIRDPARTY|12.2.1.4.250228|39000040'
    ) | Set-Content -LiteralPath $fmw
    $rFmw = PlanWithWarnings (Read-Manifest $fmw)
    $nf = @($rFmw.Plan | ForEach-Object { $_.Patch })
    Check ($nf -contains '39000031') "ADF behind: newest ADF BUNDLE PATCH 39000031 planned (got $($nf -join ','))"
    Check (-not ($nf -contains '39000032')) "the installed ADF level is not planned again"
    Check (-not ($nf -contains '39000033')) "OPSS already at the newest bundle: nothing planned"
    Check (@($rFmw.Warnings | Where-Object { $_ -match 'WSM' }).Count -ge 1) "a family MOS has no row for WARNs instead of being silent"
    Check (@($rFmw.Plan | Where-Object { $_.What -like 'ADF bundle (*' }).Count -eq 1) "the ADF row names the family and home"
    Check ($nf -contains '39000041') "a mixed-case MOS abstract ('FMW Thirdparty Bundle Patch') is planned, not read as current (got $($nf -join ','))"
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "get-patches gate: $script:pass passed, $script:fail failed"
if ($script:fail -ne 0) { exit 1 }
