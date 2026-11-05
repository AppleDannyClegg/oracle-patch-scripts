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
<release id="610" status="A" name="12.2.1.4.0"><![CDATA[Oracle HTTP Server 12.2.1.4.0]]></release>
<release id="800" status="A" name="19.0.0.0.0"><![CDATA[Oracle Database 19.0.0.0.0]]></release>
<release id="700" status="A" name="1.8.0_491"><![CDATA[Oracle JDK 1.8.0_491]]></release>
<release id="701" status="A" name="1.8.0_481"><![CDATA[Oracle JDK 1.8.0_481]]></release>
<release id="702" status="A" name="1.8.0_471"><![CDATA[Oracle JDK 1.8.0_471]]></release>
<release id="703" status="A" name="1.8.0_499"><![CDATA[Oracle JDK 1.8.0_499-perf Performance]]></release>
</results>
'@
$wlsRows = '<results>' +
    (Row 39000001 'Wls Patch Set Update 12.2.1.4.260818' '2026-08-18') +
    (Row 39000002 'WLS Patch Set Update 12.2.1.4.261020' '2026-10-20') +
    (Row 39000009 'WLS PATCH SET UPDATE 12.2.1.4.261031 (BLR)' '2026-10-31') +
    (Row 39000003 'Fmw Platform Bundle Patch 12.2.1.4.261020' '2026-10-20') +
    (Row 39000004 'FMW PLATFORM BUNDLE PATCH 12.2.1.4.260715' '2026-07-15') +
    (Row 39000031 'ADF BUNDLE PATCH 12.2.1.4.261020' '2026-10-20') +
    (Row 39000032 'ADF BUNDLE PATCH 12.2.1.4.250415' '2025-04-15') +
    (Row 39000033 'OPSS BUNDLE PATCH 12.2.1.4.261020' '2026-10-20') +
    (Row 39000041 'FMW Thirdparty Bundle Patch 12.2.1.4.260317' '2026-03-17') +
    (Row 39000042 'JDBC19.31 BUNDLE PATCH 12.2.1.4.260216' '2026-02-16') +
    (Row 39000043 'OSS 19C BUNDLE PATCH 12.2.1.4.0.260228' '2026-02-28') + '</results>'
$spbRows = (Row 39500001 'WLS STACK PATCH BUNDLE 12.2.1.4.260522 (Patch 39426129)' '2026-05-22') +
    (Row 39500002 'Wls Stack Patch Bundle 12.2.1.4.261020 (Patch 39500002)' '2026-10-20')
$dbRows = '<results>' +
    (Row 39600001 'Database Release Update : 19.30.0.0.260120 (39600001)' '2026-01-20') +
    (Row 39600003 'database release update : 19.31.0.0.261020 (39600003)' '2026-10-20') +
    (Row 39600004 'OJVM RELEASE UPDATE: 19.31.0.0.261020 (39600004)' '2026-10-20') +
    (Row 39600005 'Database Release Update Revision 19.30.2.0.261020' '2026-10-20') +
    (Row 39600006 'COMBO OF OJVM RU COMPONENT 19.31.0.0.261031 + Database Release Update 19.31.0.0.261031' '2026-10-31') +
    (Row 39600007 'Database Release Update 19.31.0.0.261031 - CMAN' '2026-10-31') + '</results>'
$script:withSpb = $true
$cohRows = '<results>' +
    (Row 39000011 'Coherence 12.2.1.4 Cumulative Patch 32 (12.2.1.4.32)' '2026-07-15') +
    (Row 39000010 'Coherence 12.2.1.4 Cumulative Patch 33 (12.2.1.4.33)' '2026-10-20') + '</results>'
$jdkRows = '<results>' + (Row 39000020 'Oracle JDK 8 Update 481 for Linux x86-64' '2026-10-20') + '</results>'
# the 8u481 patch's files: Get-JdkPlan now fetches them to require a production (non-internal/debug) artifact
$jdkBug481 = @'
<results><patch has_prereqs="n"><name>39000020</name><release id="701" name="1.8.0_481"/>
<platform id="226"><![CDATA[Linux x86-64]]></platform>
<files><file><name>jdk-8u481-linux-x64.tar.gz</name><size>17</size>
<download_url host="https://updates.oracle.com"><![CDATA[/Orion/Download/process_form/jdk-8u481-linux-x64.tar.gz?aru=1]]></download_url>
<digest type="SHA-256">SHA_HERE</digest></file></files></patch></results>
'@
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
# a JDK patch serving a production tarball AND an internal/debug one for the same release: the debug file is
# listed first, so a plain 'Select -First 1' would take it
$bugJdk = @'
<results><patch has_prereqs="n"><name>39555001</name><release id="704" name="1.8.0_511"/>
<platform id="226"><![CDATA[Linux x86-64]]></platform>
<files>
<file><name>jdk-8u511-internal-bin-b00-linux-x64-debug-05_nov_2026.tar.gz</name><size>17</size>
<download_url host="https://updates.oracle.com"><![CDATA[/Orion/Download/process_form/jdk-8u511-internal-bin-b00-linux-x64-debug-05_nov_2026.tar.gz?aru=1]]></download_url>
<digest type="SHA-256">SHA_HERE</digest></file>
<file><name>jdk-8u511-linux-x64.tar.gz</name><size>17</size>
<download_url host="https://updates.oracle.com"><![CDATA[/Orion/Download/process_form/jdk-8u511-linux-x64.tar.gz?aru=1]]></download_url>
<digest type="SHA-256">SHA_HERE</digest></file>
</files></patch></results>
'@
$script:bugXmlJdk = $bugJdk.Replace('SHA_HERE', $sha)
$script:bugXmlJdk481 = $jdkBug481.Replace('SHA_HERE', $sha)
# a file block with NO <digest>: the MOS record is incomplete (or the body was cut) - must be refused, not kept
$bugNoSha = @'
<results><patch has_prereqs="n"><name>30966770</name><release id="600" name="12.2.1.4.0"/>
<platform id="226"><![CDATA[Linux x86-64]]></platform>
<files><file><name>p30966770_122140_Linux-x86-64.zip</name><size>17</size>
<download_url host="https://updates.oracle.com"><![CDATA[/Orion/Download/process_form/p30966770_122140_Linux-x86-64.zip?aru=1]]></download_url>
</file></files></patch></results>
'@
# OHS 12.2.1.4 on Linux x86-64: the real abstract shapes (MOS, 5 Nov 2026) - the DB19C bundle is the current
# line, the plain one stopped in Jan 2024; the Apache plug-in bundle and a tracking bug are look-alikes
$ohsRows = '<results>' +
    (Row 40005842 'OHS (NATIVE) DB19C BUNDLE PATCH 12.2.1.4.260910' '2026-10-19') +
    (Row 39611663 'OHS (NATIVE) DB19C BUNDLE PATCH 12.2.1.4.260624' '2026-07-20') +
    (Row 36187026 'OHS (NATIVE) BUNDLE PATCH 12.2.1.4.240115' '2024-01-29') +
    (Row 40030272 'APACHE PLUGIN BUNDLE PATCH FOR DB19C 12.2.1.4.261020' '2026-09-16') +
    (Row 38832126 'TRACKING BUG FOR BUG 38727102 FOR DEBUGGING' '2026-01-09') + '</results>'
function Invoke-MosGet([string] $Path) {
    $script:asked += $Path
    if ($Path -like '*metadata?table=aru_releases*') { return $releaseXml }
    if ($Path -like '*product=15991&release=600&platform=2000*') {
        if ($script:withSpb) { return $wlsRows.Replace('</results>', $spbRows + '</results>') } else { return $wlsRows }
    }
    if ($Path -like '*product=9480&release=800&platform=226*') { return $dbRows }
    if ($Path -like '*product=10300&release=610&platform=226*') { return $ohsRows }
    if ($Path -like '*product=13964&release=601&platform=2000*') { return $cohRows }
    if ($Path -like '*product=12443&release=701&platform=226*') { return $jdkRows }
    if ($Path -like '*product=12443&release=703&platform=226*') { return $perfRows }
    if ($Path -like '*product=12443&*') { return '<results></results>' }
    if ($Path -like '*search?bug=39000002*') { return $script:bugXml }
    if ($Path -like '*search?bug=39000020*') { return $script:bugXmlJdk481 }
    if ($Path -like '*search?bug=39555001*') { return $script:bugXmlJdk }
    if ($Path -like '*search?bug=30966770*') { return $bugNoSha }
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

    # ---- from 19.33 MOS titles the RU with no date: 'DATABASE RELEASE UPDATE 19.33.0.0.0' (live, 5 Nov 2026) ----
    $savedDbRows = $script:dbRows
    $script:dbRows = $script:dbRows.Replace('</results>', (Row 39600008 'DATABASE RELEASE UPDATE 19.33.0.0.0' '2026-10-10') + '</results>')
    $n33 = @(Get-PatchPlan $m | ForEach-Object { $_.Patch })
    Check ($n33 -contains '39600008') "an undated RU title 19.33.0.0.0 is found and is newer than 19.31.0.0.261031 (got $($n33 -join ','))"
    Check (-not ($n33 -contains '39600003')) "the dated 19.31 RU is not planned once 19.33 is listed"
    $on33 = Join-Path $tmp 'on33.txt'
    @('host|wl6', 'home|/stage/client/app/product/19.0.0.0|db|19.33.0.0.0|12.2.0.1.52',
      'patch|/stage/client/app/product/19.0.0.0|39600008|Database Release Update : 19.33.0.0.0 (39600008)') | Set-Content -LiteralPath $on33
    $p33 = @(Get-PatchPlan (Read-Manifest $on33) | Where-Object { $_.Kind -eq 'db' })
    Check ($p33.Count -eq 0) "a home already on the undated 19.33 RU plans no RU, got $(@($p33 | ForEach-Object { $_.Patch }) -join ',')"
    $script:dbRows = $savedDbRows

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

    # ---- a file with no SHA-256 in the record is refused, not downloaded or kept (Weyland [P1]) ---------------
    # NB: this must run BEFORE the OPatch section defines a mock Save-MosPatch (~:490), which shadows the real one
    $destNo = Join-Path $tmp 'nosha'
    $script:downloadedUrl = $null
    $threw = $false; $msg = ''
    try { Save-MosPatch -Patch '30966770' -Dest $destNo -Release '12.2.1.4.0' | Out-Null } catch { $threw = $true; $msg = $_.Exception.Message }
    Check $threw "a file with no SHA-256 digest in the record throws (got [$msg])"
    Check ($msg -match 'no SHA-256') "the refusal names the missing digest: [$msg]"
    Check ($msg -notmatch '-Patch') "the refusal does not advertise -Patch (broken for the record shape it is offered for)"
    Check ($null -eq $script:downloadedUrl) "the unverifiable file is not even downloaded"
    Check (@(Get-ChildItem -LiteralPath $destNo -ErrorAction SilentlyContinue).Count -eq 0) "the unverifiable file is not kept"

    # ---- a JDK patch with a production and an internal/debug artifact picks the production one ---------
    $dest3 = Join-Path $tmp 'jdk'
    $saved3 = ''
    try { $saved3 = Save-MosPatch -Patch '39555001' -Dest $dest3 -Release '1.8.0_511' } catch { Check $false "the JDK download threw: $($_.Exception.Message)" }
    Check ((Split-Path -Leaf $saved3) -eq 'jdk-8u511-linux-x64.tar.gz') "a JDK patch with a production and a debug artifact picks the production one, got [$saved3]"
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
        'fmw|/u01/app/fmw/home1|FMW THIRDPARTY|12.2.1.4.250228|39000040',
        'fmw|/u01/app/fmw/home1|OTHER|RDA release 26.2-2026421 for OFM 12.2.1.4 SPB|38887908',
        'fmw|/u01/app/fmw/home1|OTHER|WLS STACK PATCH BUNDLE 12.2.1.4.260522 (Patch 39426129)|39426213',
        'fmw|/u01/app/fmw/home1|OTHER|Coherence Cumulative Patch 12.2.1.4.30|1221430',
        'fmw|/u01/app/fmw/home1|OSS 19C|12.2.1.4.250228|39024181'
        'fmw|/u01/app/fmw/home1|JDBC19.30|12.2.1.4.250216|38970574'
    ) | Set-Content -LiteralPath $fmw
    $rFmw = PlanWithWarnings (Read-Manifest $fmw)
    $nf = @($rFmw.Plan | ForEach-Object { $_.Patch })
    Check ($nf -contains '39000031') "ADF behind: newest ADF BUNDLE PATCH 39000031 planned (got $($nf -join ','))"
    Check (-not ($nf -contains '39000032')) "the installed ADF level is not planned again"
    Check (-not ($nf -contains '39000033')) "OPSS already at the newest bundle: nothing planned"
    Check (@($rFmw.Warnings | Where-Object { $_ -match 'WSM' }).Count -ge 1) "a family MOS has no row for WARNs instead of being silent"
    Check (@($rFmw.Plan | Where-Object { $_.What -like 'ADF bundle (*' }).Count -eq 1) "the ADF row names the family and home"
    Check ($nf -contains '39000041') "a mixed-case MOS abstract ('FMW Thirdparty Bundle Patch') is planned, not read as current (got $($nf -join ','))"
    Check (($rFmw.Warnings -join ' ') -notmatch 'family OTHER|no OTHER bundle') "an OTHER line is not looked up as a family called OTHER"
    Check (($rFmw.Warnings -join ' ') -match 'RDA release 26\.2-2026421') "an OTHER line is named in a warning instead of being dropped"
    Check (($rFmw.Warnings -join ' ') -notmatch 'WLS STACK PATCH BUNDLE|Coherence Cumulative') "the SPB and Coherence are not warned about again - Get-WlsPlan plans them"
    Check ($nf -contains '39000043') "a five-part MOS abstract ('12.2.1.4.0.yymmdd') is matched (got $($nf -join ','))"
    Check ($nf -contains '39000042') "a versioned family token (JDBC19.30) finds the next release's JDBC19.31 bundle (got $($nf -join ','))"

    # ---- OPatch minimum from the downloaded patches' READMEs ------------------------------------------
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    function New-TestZip([string] $Path, [hashtable] $Entries) {
        $z = [IO.Compression.ZipFile]::Open($Path, 'Create')
        try {
            foreach ($k in $Entries.Keys) {
                $w = New-Object IO.StreamWriter ($z.CreateEntry($k).Open())
                try { $w.Write($Entries[$k]) } finally { $w.Dispose() }
            }
        } finally { $z.Dispose() }
        $Path
    }
    $zd = Join-Path $tmp 'zips'; New-Item -ItemType Directory -Path $zd | Out-Null
    $psuZip = New-TestZip (Join-Path $zd 'p39000002_122140_Generic.zip') @{
        '39000002/README.txt' = "Prerequisites`nYou must have OPatch version 13.9.4.2.5 or later, and for this PSU OPatch 13.9.4.2.20 or higher.`nopatch apply`n" }
    $ruZip = New-TestZip (Join-Path $zd 'p39600003_190000_Linux-x86-64.zip') @{
        '39600003/README.html' = '<p>You must use the <b>OPatch</b> utility version <b>12.2.0.1.46</b> or later to apply this patch.</p><p>Database 19.31.0.0.0</p>' }
    $noReadme = New-TestZip (Join-Path $zd 'p39000003_122140_Generic.zip') @{ '39000003/etc/config/inventory.xml' = '<x/>' }
    Check ((Get-ZipMinOPatch $psuZip) -eq '13.9.4.2.20') "README.txt: the highest OPatch it names is the minimum, got [$(Get-ZipMinOPatch $psuZip)]"
    Check ((Get-ZipMinOPatch $ruZip) -eq '12.2.0.1.46') "README.html (tags between the words): 12.2.0.1.46, got [$(Get-ZipMinOPatch $ruZip)]"
    Check ($null -eq (Get-ZipMinOPatch $noReadme)) "a zip with no README gives no minimum"
    $wordy = New-TestZip (Join-Path $zd 'p39000044_122140_Generic.zip') @{ '39000044/README.txt' = 'Apply OPatch (patch 28186730) 13.9.4.2.21 or later first.' }
    Check ((Get-ZipMinOPatch $wordy) -eq '13.9.4.2.21') "a patch number between 'OPatch' and the version still matches (Cerebro 13:48:26), got [$(Get-ZipMinOPatch $wordy)]"
    $build = New-TestZip (Join-Path $zd 'p39000046_122140_Generic.zip') @{ '39000046/README.txt' = "You need OPatch 13.9.4.2.20 or later. The PSU is 13.9.4.2.260522.`nThis RU moves the home to 19.31.0.0.0 and needs OPatch 12.2.0.1.46 or later to apply 19.31.0.0.0." }
    Check ((Get-ZipMinOPatch $build) -eq '13.9.4.2.20') "the PSU/RU build number is never the minimum (Ash 13:48:41), got [$(Get-ZipMinOPatch $build)]"
    $two = New-TestZip (Join-Path $zd 'p39000047_122140_Generic.zip') @{ '39000047/README.txt' = 'OPatch 13.9.4.2.5 or later, and 13.9.4.2.20 or later for this PSU.' }
    Check ((Get-ZipMinOPatch $two) -eq '13.9.4.2.20') "a second version after one 'OPatch', followed by 'or later', counts (GERTY/Ash), got [$(Get-ZipMinOPatch $two)]"
    $noPhrase = New-TestZip (Join-Path $zd 'p39000048_122140_Generic.zip') @{ '39000048/README.txt' = 'OPatch 13.9.4.2.5 or later; tested on 13.9.4.2.260522 builds.' }
    Check ((Get-ZipMinOPatch $noPhrase) -eq '13.9.4.2.5') "a bare version with no minimum phrase after it does not count, got [$(Get-ZipMinOPatch $noPhrase)]"
    $ent = New-TestZip (Join-Path $zd 'p39600008_190000_Linux-x86-64.zip') @{ '39600008/README.html' = '<p>OPatch&#160;utility 12.2.0.1.40 or later, and 12.2.0.1.46&#160;or&#160;later for this RU.</p>' }
    Check ((Get-ZipMinOPatch $ent) -eq '12.2.0.1.46') "HTML entities are decoded, so '&#160;or&#160;later' is a minimum phrase (Baymax 13:49:29), got [$(Get-ZipMinOPatch $ent)]"
    $split = New-TestZip (Join-Path $zd 'p39600009_190000_Linux-x86-64.zip') @{ '39600009/README.html' = '<p>OPatch utility version 12.2.0.1.<i>47</i> or later</p>' }
    Check ((Get-ZipMinOPatch $split) -eq '12.2.0.1.47') "a tag inside the number is dropped, not spaced (Baymax 13:49:29), got [$(Get-ZipMinOPatch $split)]"

    # Baymax 13:54:10: a DB RU README prints opatch command lines and the RU's own number near the word OPatch
    $t1 = New-TestZip (Join-Path $zd 'p39600010_190000_Linux-x86-64.zip') @{ '39600010/README.txt' = "You must use the OPatch utility version 12.2.0.1.42 or later to apply this patch.`n`$ opatch apply -oh /u01/app/oracle/product/19.0.0.0/dbhome_1" }
    Check ((Get-ZipMinOPatch $t1) -eq '12.2.0.1.42') "an 'opatch apply' line with a 19.0.0.0 path is not the minimum, got [$(Get-ZipMinOPatch $t1)]"
    $t2 = New-TestZip (Join-Path $zd 'p39600011_190000_Linux-x86-64.zip') @{ '39600011/README.txt' = "You must use the OPatch utility version 12.2.0.1.42 or later to apply this patch.`nUse OPatch to apply Database Release Update 19.24.0.0.240716." }
    Check ((Get-ZipMinOPatch $t2) -eq '12.2.0.1.42') "'Use OPatch to apply ... 19.24.0.0.240716' is not the minimum, got [$(Get-ZipMinOPatch $t2)]"
    $t3 = New-TestZip (Join-Path $zd 'p39000050_122140_Generic.zip') @{ '39000050/README.txt' = "OPatch 13.9.4.2.20 or later is required. Use OPatch to apply WLS PATCH SET UPDATE 12.2.1.4.260522 (or later) to 12.2.1.4.0 homes." }
    Check ((Get-ZipMinOPatch $t3) -eq '13.9.4.2.20') "a WLS PSU number or release after 'Use OPatch' is not the minimum, got [$(Get-ZipMinOPatch $t3)]"
    $t4 = New-TestZip (Join-Path $zd 'p39600012_190000_Linux-x86-64.zip') @{ '39600012/README.txt' = "You must use the OPatch utility version 12.2.0.1.42 or later to apply this patch.`nThe opatch 12.2.0.1.50 binary is not needed." }
    Check ((Get-ZipMinOPatch $t4) -eq '12.2.0.1.42') "lower-case 'opatch' does not count, as on the server, got [$(Get-ZipMinOPatch $t4)]"

    $kitZip = New-TestZip (Join-Path $zd 'p6880880_190000_Linux-x86-64.zip') @{ 'OPatch/version.txt' = "OPATCH_VERSION:12.2.0.1.48`n" }
    $kitOld = New-TestZip (Join-Path $zd 'p6880880_old.zip') @{ 'OPatch/version.txt' = "OPATCH_VERSION:12.2.0.1.44`n" }
    $wlsKit = New-TestZip (Join-Path $zd 'p28186730_1394220_Generic.zip') @{ 'README.txt' = 'This kit needs OPatch 13.9.4.2.30 or later on the home'; 'opatch_generic.jar' = 'x' }
    $kitNoName = New-TestZip (Join-Path $zd 'opatch-kit.zip') @{ 'README.txt' = 'OPatch 13.9.4.2.30'; 'opatch_generic.jar' = 'x' }
    Check ((Get-ZipOPatchVersion $kitZip).Version -eq '12.2.0.1.48') "an OPatch kit's version is read from OPatch/version.txt"
    $wv = Get-ZipOPatchVersion $wlsKit
    Check ($wv.Version -eq '13.9.4.2.20' -and $wv.From -eq 'the file name') "the 13.9.4 kit: version from Oracle's file name, not from the higher 13.9.4.2.30 its README names (Baymax/Weyland), got [$($wv.Version) $($wv.From)]"
    Check ($null -eq (Get-ZipOPatchVersion $kitNoName).Version) "a kit with no version.txt and not Oracle's name: no version (its README is not believed)"

    # a WebLogic home on 13.9.4.2.10 (above the old 13.9.4.2.0 floor) whose PSU asks for 13.9.4.2.20; a client on 12.2.0.1.44
    $opm = Join-Path $tmp 'opatch-readme.txt'
    @('host|wl-op', 'wls|/u01/fmw|12.2.1.4.0|13.9.4.2.10|no', 'home|/u01/client19|db|19.27.0.0.0|12.2.0.1.44') | Set-Content -LiteralPath $opm
    $mo = Read-Manifest $opm
    $got = @(
        [pscustomobject]@{ Item = (New-PlanItem 'wls' 'WLS PSU (/u01/fmw)' '' ([pscustomobject]@{ Number = '39000002'; Abstract = 'x' }) '12.2.1.4.0' '/u01/fmw'); Saved = $psuZip },
        [pscustomobject]@{ Item = (New-PlanItem 'db' 'Database Release Update (/u01/client19)' '' ([pscustomobject]@{ Number = '39600003'; Abstract = 'x' }) '19.0.0.0.0' '/u01/client19'); Saved = $ruZip }
    )
    $needs = @(Get-OPatchNeeds $mo $got)
    $wn = $needs | Where-Object { $_.Home -eq '/u01/fmw' }
    $dn = $needs | Where-Object { $_.Home -eq '/u01/client19' }
    Check ($wn -and $wn.Min -eq '13.9.4.2.20' -and $wn.Item.Patch -eq '28186730' -and $wn.Item.Kind -eq 'wls') "OPatch 13.9.4.2.10 < the PSU README's 13.9.4.2.20: the kit 28186730 is added (got $($wn.Min) $($wn.Item.Patch))"
    Check ($dn -and $dn.Min -eq '12.2.0.1.46' -and $dn.Item.Patch -eq '6880880' -and $dn.Item.Release -eq '19.0.0.0.0') "OPatch 12.2.0.1.44 < the RU README's 12.2.0.1.46: 6880880 for 19.0.0.0.0 is added (got $($dn.Min) $($dn.Item.Patch) $($dn.Item.Release))"
    Check (@($needs).Count -eq 2) "one OPatch need per home, got $(@($needs).Count)"

    # enough already: nothing added
    $enough = Join-Path $tmp 'opatch-enough.txt'
    @('host|wl-op2', 'wls|/u01/fmw|12.2.1.4.0|13.9.4.2.20|no') | Set-Content -LiteralPath $enough
    Check (@(Get-OPatchNeeds (Read-Manifest $enough) @($got[0])).Count -eq 0) "OPatch 13.9.4.2.20 meets the README's 13.9.4.2.20: no kit"
    # unknown installed OPatch: the kit is added (the server would have to guess)
    $unknown = Join-Path $tmp 'opatch-unknown.txt'
    @('host|wl-op3', 'wls|/u01/fmw|12.2.1.4.0||no') | Set-Content -LiteralPath $unknown
    Check (@(Get-OPatchNeeds (Read-Manifest $unknown) @($got[0])).Count -eq 1) "an unreadable installed OPatch with a README minimum: the kit is added"

    # an SPB brings its own OPatch and SPBAT -phase apply upgrades it 'from any version' (real SPB README, 5 Nov
    # 2026): the OPatch it installs is not a minimum, so no kit is added for it
    $spbZip = New-TestZip (Join-Path $zd 'p39500002_122140_Generic.zip') @{ 'WLS_SPB_12.2.1.4.261020/README.html' = '<h3>3.4 Check OPatch Version</h3><p>The Critical Patch Update program includes OPATCH 13.9.4.2.25 FOR FMW/WLS 12.2.1.4.0. The WebLogic Server Patch Set Update requires OPatch 13.9.4.2.13 or later in order to successfully apply new updates.</p><p>Note : OPatch will be upgraded to OPATCH 13.9.4.2.25 from any version if only running SPBAT -phase apply .</p>' }
    $onSpb = Join-Path $tmp 'opatch-spb.txt'
    @('host|wl-spb', 'wls|/u01/fmw|12.2.1.4.0|13.9.4.2.13|no') | Set-Content -LiteralPath $onSpb
    $spbGot = @([pscustomobject]@{ Item = (New-PlanItem 'spb' 'WLS Stack Patch Bundle (/u01/fmw)' '' ([pscustomobject]@{ Number = '39500002'; Abstract = 'x' }) '12.2.1.4.0' '/u01/fmw'); Saved = $spbZip })
    $spbNeeds = @(Get-OPatchNeeds (Read-Manifest $onSpb) $spbGot)
    Check ($spbNeeds.Count -eq 0) "an SPB on OPatch 13.9.4.2.13: no kit for the 13.9.4.2.25 the SPB installs itself, got $(@($spbNeeds | ForEach-Object { "$($_.Min) $($_.Item.Patch)" }) -join ',')"
    # the kit is already planned for that home (old-floor rule): it is not added twice, but the need is still reported
    $already = @($got[0]) + @([pscustomobject]@{ Item = (New-PlanItem 'wls' 'OPatch kit (/u01/fmw)' '13.9.4.2.10' ([pscustomobject]@{ Number = '28186730'; Abstract = 'OPatch 13.9.4.x' }) '13.9.4' '/u01/fmw'); Saved = $wlsKit })
    $na = @(Get-OPatchNeeds $mo $already)
    Check ($na.Count -eq 1 -and $null -eq $na[0].Item -and $na[0].KitSaved -eq $wlsKit) "a kit already downloaded for the home is reused, not planned again"

    # a README that names no OPatch minimum is not skipped silently (Cerebro 13:48:26: no silent skip)
    $silent = New-TestZip (Join-Path $zd 'p39000045_122140_Generic.zip') @{ '39000045/README.txt' = 'Apply with the usual tools.' }
    $sd = @([pscustomobject]@{ Item = (New-PlanItem 'wls' 'WLS PSU (/u01/fmw)' '' ([pscustomobject]@{ Number = '39000045'; Abstract = 'x' }) '12.2.1.4.0' '/u01/fmw'); Saved = $silent })
    $sw = @(Get-OPatchNeeds $mo $sd 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
    Check (($sw -join ' ') -match '39000045.*no OPatch') "a README with no OPatch minimum WARNs by patch number (got [$($sw -join ' | ')])"

    # the plan carries the home each patch is for
    Check (@($plan | Where-Object { $_.Kind -eq 'spb' })[0].For -eq '/u01/fmw') "plan items carry their home (For)"
    Check (@($plan | Where-Object { $_.Kind -eq 'db' -and $_.Patch -eq '39600003' })[0].For -eq '/stage/client/app/product/19.0.0.0') "a db RU carries its home"

    # the downloaded kit is checked against the minimum
    Check ((Test-OPatchKit '12.2.0.1.46' $kitZip) -eq 'ok') "kit 12.2.0.1.48 meets 12.2.0.1.46"
    Check ((Test-OPatchKit '12.2.0.1.46' $kitOld) -eq 'low') "kit 12.2.0.1.44 is below 12.2.0.1.46: reported, not passed"
    Check ((Test-OPatchKit '12.2.0.1.46' $noReadme) -eq 'unknown') "a kit whose version cannot be read is 'unknown', not ok"

    # the step after the downloads: the kit is fetched for the home that needs it, and a kit still too old counts as a failure
    $script:kitFetched = @()
    $script:kitToServe = @{ '28186730' = $wlsKit; '6880880' = $kitZip }
    function Save-MosPatch([string] $Patch, [string] $Dest, [string] $Release) { $script:kitFetched += "$Patch|$Release|$(Split-Path -Leaf $Dest)"; $script:kitToServe[$Patch] }
    $f1 = Invoke-OPatchFollowUp $mo $got (Join-Path $tmp 'dl') 6>$null
    Check ($script:kitFetched -contains '28186730|13.9.4|wls' -and $script:kitFetched -contains '6880880|19.0.0.0.0|db') "both kits fetched into their folders (got $($script:kitFetched -join ','))"
    Check ($f1 -eq 0) "kits 13.9.4.2.22 and 12.2.0.1.48 meet 13.9.4.2.20 and 12.2.0.1.46: no failure (got $f1)"
    $script:kitFetched = @(); $script:kitToServe['6880880'] = $kitOld
    $f2 = Invoke-OPatchFollowUp $mo $got (Join-Path $tmp 'dl') 6>$null
    Check ($f2 -eq 1) "the newest 6880880 is only 12.2.0.1.44, below the RU's 12.2.0.1.46: one failure (got $f2)"
    $script:kitFetched = @()
    $f3 = Invoke-OPatchFollowUp (Read-Manifest $enough) @($got[0]) (Join-Path $tmp 'dl') 6>$null
    Check ($script:kitFetched.Count -eq 0 -and $f3 -eq 0) "OPatch already enough: no kit fetched, no failure"
    $script:kitToServe['28186730'] = $kitNoName
    $f4 = Invoke-OPatchFollowUp $mo @($got[0]) (Join-Path $tmp 'dl') 6>$null
    Check ($f4 -eq 1) "a kit whose version cannot be measured counts as a failure, not a pass (got $f4)"

    # any family, as the server reads it (Roy 13:48:49 / Weyland 13:50:01): a WebLogic home on a 12.2.0.1 OPatch
    $wls12 = Join-Path $tmp 'opatch-wls12.txt'
    $r40 = New-TestZip (Join-Path $zd 'p39000049_122140_Generic.zip') @{ '39000049/README.txt' = 'OPatch 12.2.0.1.40 or later' }
    $g40 = @([pscustomobject]@{ Item = (New-PlanItem 'wls' 'WLS PSU (/u01/fmw)' '' ([pscustomobject]@{ Number = '39000049'; Abstract = 'x' }) '12.2.1.4.0' '/u01/fmw'); Saved = $r40 })
    @('host|wl-12', 'wls|/u01/fmw|12.2.1.4.0|12.2.0.1.44|no') | Set-Content -LiteralPath $wls12
    Check (@(Get-OPatchNeeds (Read-Manifest $wls12) $g40).Count -eq 0) "WebLogic home on OPatch 12.2.0.1.44, README asks 12.2.0.1.40: no kit"
    @('host|wl-12', 'wls|/u01/fmw|12.2.1.4.0|12.2.0.1.30|no') | Set-Content -LiteralPath $wls12
    $n12 = @(Get-OPatchNeeds (Read-Manifest $wls12) $g40)
    Check ($n12.Count -eq 1 -and $n12[0].Item.Patch -eq '28186730') "WebLogic home on OPatch 12.2.0.1.30, README asks 12.2.0.1.40: the kit is planned, not skipped (got $($n12.Count))"
}
finally {
    # ---- OHS: a standalone and a collocated home are both named for a manual fetch, never dropped ----------
    $ohsM = Join-Path $tmp 'ohs.txt'
    @('host|wl6', 'wls|/u01/fmw|12.2.1.4.0|13.9.4.2.23|no', 'ohs|/u01/fmw|12.2.1.4.0',
      'home|/u01/ohs|ohs|12.2.1.4.0|13.9.4.2.23',
      'patch|/u01/ohs|39611663|OHS (NATIVE) DB19C BUNDLE PATCH 12.2.1.4.260624',
      'home|/u01/ohsold|ohs|12.2.1.4.0|13.9.4.2.23',
      'patch|/u01/ohsold|36187026|OHS (NATIVE) BUNDLE PATCH 12.2.1.4.240115') | Set-Content -LiteralPath $ohsM
    $m6 = Read-Manifest $ohsM
    $ohs6 = @($m6.Ohs)
    Check ($ohs6.Count -eq 1) "a collocated ohs| line is read: [$($ohs6.Count)]"
    if ($ohs6.Count -eq 1) { Check ($ohs6[0].Home -eq '/u01/fmw' -and $ohs6[0].Release -eq '12.2.1.4.0') "collocated ohs| fields: [$($ohs6[0].Home)] [$($ohs6[0].Release)]" }
    Check (@($m6.Homes | Where-Object { $_.Kind -eq 'ohs' }).Count -eq 2 -and @($m6.Homes[0].Patches).Count -eq 1) "the standalone OHS homes and their patches are read"
    $notes6 = @(Get-OhsNotes $m6)
    Check ($notes6.Count -eq 3) "every OHS home is named, got $($notes6.Count)"
    Check (@($notes6 | Where-Object { $_ -like '*/u01/ohs (standalone)*' }).Count -eq 1) "the standalone OHS home is named: $($notes6 -join ' / ')"
    Check (@($notes6 | Where-Object { $_ -like '*/u01/fmw (collocated*' }).Count -eq 1) "the collocated OHS home is named: $($notes6 -join ' / ')"
    # the plan: the newest OHS (NATIVE) bundle for each OHS home, in its own ohs/ folder; never the Apache plug-in
    $all6 = @(Get-PatchPlan $m6 3>&1)
    $w6 = @($all6 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
    $p6 = @($all6 | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] -and $_.Kind -eq 'ohs' })
    Check ($p6.Count -eq 2) "an OHS bundle planned for the DB19C home and the collocated one, got $($p6.Count)"
    # the DB19C bundle 'must be applied only to an Oracle Fusion Middleware home where the Oracle Database Client 12c has
    # been upgraded to 19c' (40005842 README, Section 2): a home on the plain line is not planned it, and is told why
    Check (-not ($p6 | Where-Object { $_.For -eq '/u01/ohsold' })) "a home on the plain OHS line is NOT planned the DB19C bundle"
    Check (@($w6 | Where-Object { "$_" -like '*/u01/ohsold*KB585169*' }).Count -eq 1) "the plain-line home warns about the DB client 19c upgrade (KB585169): $(@($w6) -join ' / ')"
    Check (@($w6 | Where-Object { "$_" -like '*/u01/fmw*no OHS bundle installed*KB585169*' }).Count -eq 1) "a home with no OHS bundle yet warns to confirm the DB client 19c upgrade: $(@($w6) -join ' / ')"
    Check (@($p6 | Where-Object { $_.Patch -eq '40005842' }).Count -eq 2) "the newest OHS DB19C bundle 40005842 is planned: $(@($p6 | ForEach-Object { $_.Patch }) -join ',')"
    Check (@($p6 | Where-Object { $_.For -eq '/u01/ohs' -and $_.Installed -eq '260624' }).Count -eq 1) "the standalone home's installed OHS level is read (260624)"
    Check (@($p6 | Where-Object { $_.For -eq '/u01/fmw' }).Count -eq 1) "the collocated OHS home gets its own OHS item"
    Check (-not ($p6 | Where-Object { $_.Patch -eq '40030272' })) "the Apache plug-in bundle is not planned as the OHS bundle"
    # current: an OHS home already on 260910 plans nothing
    $ohsCur = Join-Path $tmp 'ohscur.txt'
    @('host|wl7', 'home|/u01/ohs|ohs|12.2.1.4.0|13.9.4.2.23',
      'patch|/u01/ohs|40005842|OHS (NATIVE) DB19C BUNDLE PATCH 12.2.1.4.260910') | Set-Content -LiteralPath $ohsCur
    $p7 = @(Get-PatchPlan (Read-Manifest $ohsCur) | Where-Object { $_.Kind -eq 'ohs' })
    Check ($p7.Count -eq 0) "an OHS home on the newest bundle plans nothing, got $($p7.Count)"

    # ---- Read-Manifest refuses a garbled/unknown line, a short line, and an unknown platform (Weyland [P2]) ---
    $bad = Join-Path $tmp 'bad.txt'
    @('host|wl1', 'wsl|/u01/wls|12.2.1.4.0|13.9.4.2.0|yes', 'jdk|/j|1.8.0_471|8') | Set-Content -LiteralPath $bad
    $threw = $false; try { Read-Manifest $bad | Out-Null } catch { $threw = $true }
    Check $threw "an unknown line type (wsl|) throws instead of being ignored"
    @('host|wl1', 'wls|/u01/wls', 'jdk|/j|1.8.0_471|8') | Set-Content -LiteralPath $bad
    $threw = $false; try { Read-Manifest $bad | Out-Null } catch { $threw = $true }
    Check $threw "a truncated wls| line throws"
    @('host|wl1', 'plat|solaris|sparc', 'jdk|/j|1.8.0_471|8') | Set-Content -LiteralPath $bad
    $threw = $false; try { Read-Manifest $bad | Out-Null } catch { $threw = $true }
    Check $threw "an unknown plat| throws (refuse to plan for the wrong platform)"
    @('jdk|/j|1.8.0_471|8') | Set-Content -LiteralPath $bad
    $threw = $false; try { Read-Manifest $bad | Out-Null } catch { $threw = $true }
    Check $threw "a manifest with no host| line throws"

    # ---- patch_base| drives the upload hints, and the hints carry no /u01/patches (Cerebro seam suite) ---
    $hintDest = Join-Path $tmp 'hint'
    foreach ($k in 'wls', 'spb', 'ohs', 'db', 'jdk') { New-Item -ItemType Directory -Force -Path (Join-Path $hintDest $k) | Out-Null }
    $h = @(Get-UploadHints 'wl1' $hintDest '/u02/patches')
    Check ($h.Count -eq 5) "five upload hints for five kinds, got $($h.Count)"
    Check (@($h | Where-Object { $_ -match '/u01/patches' }).Count -eq 0) "the hint block names no /u01/patches when patch_base is /u02/patches"
    Check (@($h | Where-Object { $_ -match '/u02/patches/(wls|spb|ohs|db|jdk)/' }).Count -eq 5) "each hint target uses patch_base"
    Check (@($h | Where-Object { $_ -match 'wls-patch.sh run /u02/patches/(wls|spb)' }).Count -eq 2) "the run text on the wls/spb hints uses patch_base"
    Check (@($h | Where-Object { $_ -like '*wl1*' }).Count -eq 5) "every hint names the manifest host"

    # ---- created| freshness: warn when old, silent when absent, fresh or unparseable (Cerebro 22:18:37) ---
    $now = [datetimeoffset]::Parse('2026-11-05T12:00:00+00:00')
    Check ((Get-ManifestFreshnessWarning '2026-10-01 09:00 +0000' $now) -match 'days ago') "a 35-day-old manifest warns"
    Check ((Get-ManifestFreshnessWarning '2026-11-04 09:00 +0000' $now) -eq '') "a 1-day-old manifest is silent"
    Check ((Get-ManifestFreshnessWarning '' $now) -eq '') "an absent created| is silent"
    Check ((Get-ManifestFreshnessWarning 'not-a-date' $now) -eq '') "an unparseable created| is silent"
    Check ((Get-ManifestFreshnessWarning '2026-10-22 02:24 +0000' $now) -match 'made 14 days') "14.4 days old warns and prints 14 (floor; the docstring's rule is 'older than 14')"
    Check ((Get-ManifestFreshnessWarning '2026-10-22 12:00 +0000' $now) -eq '') "exactly 14.0 days old is silent"
    Check ((Get-ManifestFreshnessWarning '2026-10-21 21:36 +0000' $now) -match 'made 14 days') "14.6 days old warns and prints 14 (floor, not round)"

    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "get-patches gate: $script:pass passed, $script:fail failed"
if ($script:fail -ne 0) { exit 1 }
