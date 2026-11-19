<#
get.ps1 - Windows/PowerShell version of get.sh: fetch the Oracle operations scripts
(patching/, operations/, reports/ plus the shared lib/) onto this machine. No git needed.

  irm https://raw.githubusercontent.com/AppleDannyClegg/oracle-patch-scripts/main/get.ps1 | iex

Puts everything in $env:ORACLE_OUTPUT_DIR\scripts (OUTPUT_DIR in oracle.conf, or PATCH_BASE, or
$HOME\oracle-patch-scripts by default; or the folder given as the first argument).
Run it again later to pick up the newest version; the previous copy is kept as <folder>.old,
and your own *.conf files are carried across.

HARDENED form (older Windows PowerShell 5.1, or to keep this script's variables out of your
session): the plain 'irm | iex' is one long-lived expression, so get.ps1's variables and its
$ErrorActionPreference leak into your shell, and on a pre-1803 build the bootstrap 'irm' itself
fails because TLS 1.2 is not the default until a line of the script runs. This runs it in a child
scope and sets TLS 1.2 before the download:

  powershell -NoProfile -Command "$u='https://raw.githubusercontent.com/AppleDannyClegg/oracle-patch-scripts/main/get.ps1'; [Net.ServicePointManager]::SecurityProtocol=$([Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12); & ([scriptblock]::Create((irm $u)))"

The scripts themselves are bash. This installer lays the tree down and checks the shared
library; to actually RUN the scripts on Windows you need Git Bash or WSL (bash on PATH).

Copy to the server and make the scripts executable there in one step. Windows has no Unix exec
bit, so a plain scp (or a git pull on Windows and then scp) leaves every script non-executable;
-Server packs the tree, copies it with scp, unpacks it over ssh and runs chmod +x on every *.sh
there (ssh may ask for the password twice):

  .\get.ps1 -Server oracle@dbhost                    # download the newest, then copy to ~/scripts there
  .\get.ps1 -Server oracle@dbhost -PushOnly          # copy THIS tree as it is (e.g. your git checkout)
  .\get.ps1 C:\git\oracle-patch-scripts -Server oracle@dbhost -PushOnly -RemoteParent /u01/app

The tree lands as <RemoteParent>/<folder name> (default: the oracle user's home). .git, *.conf and
downloaded patches (patches-*) are not copied, so the server keeps its own oracle.conf. It fails,
rather than saying done, if tar, scp or ssh fails or any script on the server is still not executable.

Custom destination (the pipe form cannot take arguments; build a script block instead):

  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/AppleDannyClegg/oracle-patch-scripts/main/get.ps1))) 'C:\tools\oracle-patch-scripts'
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Dest,
    # Run the resolver self-test (no network) and exit: the same cases tests/get-patches.ps1 checks.
    [switch]$SelfTest,
    # Copy the tree to a server and make its scripts executable there, e.g. -Server oracle@dbhost.
    # Windows has no Unix exec bit, so a plain scp delivers every script as a non-executable file.
    [string]$Server,
    # The folder on the server that receives the tree (default: the oracle user's home). The tree lands
    # as <RemoteParent>/<folder name>.
    [string]$RemoteParent,
    # With -Server: skip the download and copy the tree as it is (the folder given, or this script's own
    # folder, e.g. a git checkout you have just pulled).
    [switch]$PushOnly
)

# Everything below runs in a CHILD scope, so the plain 'irm | iex' cannot leak this script's
# variables or its $ErrorActionPreference into the caller's session (get.sh runs in a subshell).
& {

$ErrorActionPreference = 'Stop'
# read before the default below fills $Dest in ($PSBoundParameters here is this script block's, not the script's)
$DestGiven = -not [string]::IsNullOrEmpty($Dest)

# OUTPUT_DIR: the one base every file this repo creates, downloads or reports goes under, so the tree, the
# patches and the reports can be moved off /u01 (or out of %USERPROFILE%) in one place. ORACLE_OUTPUT_DIR in
# the environment wins, then OUTPUT_DIR= in oracle.conf, then the per-machine default. See oracle.conf.example.
# $ConfFiles is an injection point for the self-test only; callers leave it unset to use the real file order.
function Get-OutputDirSetting {
    param([string[]] $ConfFiles)
    if ($env:ORACLE_OUTPUT_DIR) { return $env:ORACLE_OUTPUT_DIR }
    if (-not $PSBoundParameters.ContainsKey('ConfFiles')) {
        # Last file wins, mirroring lib/oracle-lib.sh's load_config order: a tree oracle.conf, a cwd one,
        # then ~/.oracle.conf, then the tool conf.
        $ConfFiles = @()
        if ($PSScriptRoot) { $ConfFiles += (Join-Path $PSScriptRoot 'oracle.conf') }
        $ConfFiles += (Join-Path $PWD 'oracle.conf')
        $ConfFiles += (Join-Path $HOME '.oracle.conf')
        $ConfFiles += (Join-Path $HOME '.get.ps1.conf')
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

# An existing install keeps its old %USERPROFILE%\patches location, so upgrading get.ps1 does not move the
# tree (matches the bash side's "nothing moves unless OUTPUT_DIR is set" rule).
function Get-LegacyBase {
    if (-not $HOME) { return $null }
    $old = Join-Path $HOME 'patches'
    if (Test-Path -LiteralPath $old) { return $old }
    return $null
}

# Where the tree lands: under OUTPUT_DIR, or PATCH_BASE when only the legacy key is set, or the existing
# %USERPROFILE%\patches, else the default.
if (-not $Dest) {
    $configured = Get-OutputDirSetting
    $legacy = Get-LegacyBase
    $base = if ($configured) { $configured } elseif ($env:PATCH_BASE) { $env:PATCH_BASE } elseif ($legacy) { $legacy } else { Get-OutputDir }
    $Dest = Join-Path $base 'scripts'
}

# Push-Tree: copy the tree to $Server and set the exec bit there. Three steps, each checked: (1) tar the tree
# into a local archive - called directly, no shell, so a path holding $ or spaces is passed as it is; (2) scp
# that one archive to the server; (3) ssh: unpack it, chmod +x every *.sh, count the scripts still not
# executable and all of them. Done only when tar, scp and ssh all exit 0 AND the counts are 0 and >0.
# .git, *.conf and downloaded patches-* are left out, so a push never overwrites the server's own oracle.conf.
function Test-PushArg([string] $Value, [string] $Pattern, [string] $What) {
    if ($Value -notmatch $Pattern) { throw "$What '$Value' is not accepted here (letters, digits and . _ - / @ only, and it may not start with '-')" }
}
function Get-PushCommand([string] $Local, [string] $Target, [string] $Parent) {
    $Local = (Resolve-Path -LiteralPath $Local).Path.TrimEnd('\', '/')
    $leaf = Split-Path -Leaf $Local
    Test-PushArg $Target '^[A-Za-z0-9._][A-Za-z0-9._-]*(@[A-Za-z0-9._][A-Za-z0-9._-]*)?$' 'server'
    Test-PushArg $leaf '^[A-Za-z0-9._][A-Za-z0-9._-]*$' 'folder name'
    $p = if ($Parent) { $Parent.TrimEnd('/') } else { '.' }
    Test-PushArg $p '^[A-Za-z0-9._/][A-Za-z0-9._/-]*$' 'remote folder'
    $tree = "$p/$leaf"
    $archive = '.oracle-push-' + [guid]::NewGuid().ToString('N') + '.tar'
    # no $(...) or $VAR in the remote command; every value in it passed the patterns above
    $remote = "set -e; mkdir -p '$p'; tar -xf '$archive' -C '$p'; rm -f '$archive'; find '$tree' -name '*.sh' -exec chmod +x {} +; echo pushed-ok; find '$tree' -name '*.sh' ! -perm -u+x | wc -l; find '$tree' -name '*.sh' | wc -l"
    $tarArgs = @('-cf', '<archive>', '-C', (Split-Path -Parent $Local), '--exclude=.git', '--exclude=*.conf', '--exclude=*.old', '--exclude=patches-*', '--', $leaf)
    [pscustomobject]@{ Tree = $tree; Leaf = $leaf; Archive = $archive; TarArgs = $tarArgs; Remote = $remote }
}
function Push-Tree([string] $Local, [string] $Target, [string] $Parent) {
    foreach ($tool in 'tar', 'scp', 'ssh') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool not found: Windows 10/11 ship all three (the OpenSSH Client optional feature and tar.exe)" }
    }
    $c = Get-PushCommand $Local $Target $Parent
    $tmpTar = Join-Path ([IO.Path]::GetTempPath()) $c.Archive
    try {
        $tarArgs = $c.TarArgs | ForEach-Object { if ($_ -eq '<archive>') { $tmpTar } else { $_ } }
        & tar @tarArgs
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmpTar)) { throw "tar could not pack $Local (exit $LASTEXITCODE) - nothing was copied" }
        $listed = @(& tar -tf $tmpTar | Where-Object { $_ -like '*.sh' })
        if ($LASTEXITCODE -ne 0 -or $listed.Count -eq 0) { throw "the archive of $Local holds no scripts (tar exit $LASTEXITCODE) - nothing was copied" }
        Write-Host "copying $Local to ${Target}:$($c.Tree) ($($listed.Count) scripts; .git, *.conf and downloaded patches are left out). ssh may ask for the password twice: once to copy, once to unpack"
        & scp -q $tmpTar "${Target}:$($c.Archive)"
        if ($LASTEXITCODE -ne 0) { throw "scp to $Target failed (exit $LASTEXITCODE) - nothing was copied" }
        $out = @(& ssh $Target $c.Remote 2>&1)
        $sshRc = $LASTEXITCODE
        $out | ForEach-Object { Write-Host "  $_" }
        if ($sshRc -ne 0) { throw "on $Target the unpack/chmod step failed (ssh exit $sshRc) - not confirmed; see above. If it never ran, the copied archive ~/$($c.Archive) is still on the server: delete it, or re-run" }
        $lines = @($out | ForEach-Object { "$_".Trim() })
        $i = [array]::LastIndexOf($lines, 'pushed-ok')
        if ($i -lt 0 -or $lines.Count -lt $i + 3 -or $lines[$i + 1] -notmatch '^\d+$' -or $lines[$i + 2] -notmatch '^\d+$') {
            throw "the copy to $Target did not report back (see above) - not confirmed"
        }
        $notExec = [int]$lines[$i + 1]; $scripts = [int]$lines[$i + 2]
        if ($notExec -ne 0 -or $scripts -lt $listed.Count) { throw "on $Target, $notExec of $scripts scripts are not executable after the copy (sent $($listed.Count))" }
        Write-Host "done on ${Target}: $scripts scripts at $($c.Tree), all executable"
    } finally {
        Remove-Item -LiteralPath $tmpTar -Force -ErrorAction SilentlyContinue
    }
}

# -SelfTest covers this copy of the resolver before any network: it cannot be dot-sourced by the other gate
# without running the installer, so it checks itself here.
if ($SelfTest) {
    $fail = 0
    $saved = $env:ORACLE_OUTPUT_DIR
    $conf = Join-Path ([IO.Path]::GetTempPath()) ('get-out-' + [guid]::NewGuid().ToString('N') + '.conf')
    try {
        $env:ORACLE_OUTPUT_DIR = $null
        if ((Get-OutputDirSetting -ConfFiles @()) -ne $null) { $fail++; Write-Host 'FAIL no setting resolves to nothing' }
        Set-Content -LiteralPath $conf -Value "export OUTPUT_DIR=/conf/out  # inline`n"
        if ((Get-OutputDirSetting -ConfFiles @($conf)) -ne '/conf/out') { $fail++; Write-Host 'FAIL export and an inline comment parse to /conf/out' }
        if ((Get-OutputDir -ConfFiles @()) -ne (Join-Path $HOME 'oracle-patch-scripts')) { $fail++; Write-Host 'FAIL the default is $HOME/oracle-patch-scripts' }
        $env:ORACLE_OUTPUT_DIR = '/env/out'
        if ((Get-OutputDirSetting -ConfFiles @($conf)) -ne '/env/out') { $fail++; Write-Host 'FAIL ORACLE_OUTPUT_DIR beats the conf' }
    } finally {
        $env:ORACLE_OUTPUT_DIR = $saved
        Remove-Item -LiteralPath $conf -Force -ErrorAction SilentlyContinue
    }
    # the push command: what is left out, the exec-bit check, and refusal of a value that would break quoting
    $pt = Join-Path ([IO.Path]::GetTempPath()) ('get-push-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $pt 'scripts')
        $c = Get-PushCommand (Join-Path $pt 'scripts') 'oracle@db-1' '/u01/app'
        if ($c.Tree -ne '/u01/app/scripts') { $fail++; Write-Host "FAIL push lands at <parent>/<folder> ($($c.Tree))" }
        foreach ($x in '--exclude=.git', '--exclude=*.conf', '--exclude=patches-*') { if ($c.TarArgs -notcontains $x) { $fail++; Write-Host "FAIL push tar lacks $x" } }
        if ($c.Remote -notlike "*-exec chmod +x*" -or $c.Remote -notlike "*! -perm -u+x*" -or $c.Remote -notlike 'set -e;*') { $fail++; Write-Host 'FAIL push does not chmod and re-check the exec bit under set -e' }
        if ($c.Remote -match '\$') { $fail++; Write-Host 'FAIL the remote command holds a $ the local side could expand' }
        if ((Get-PushCommand (Join-Path $pt 'scripts') 'oracle@db-1' '').Tree -ne './scripts') { $fail++; Write-Host 'FAIL push defaults to the home folder' }
        foreach ($bad in @(@('oracle@db-1;rm -rf /', '/u01'), @('oracle@db-1', "/u01'x"), @('oracle@db-1', '/u01 x'), @('-oProxyCommand=x', '/u01'), @('oracle@db-1', '-x'))) {
            $threw = $false; try { $null = Get-PushCommand (Join-Path $pt 'scripts') $bad[0] $bad[1] } catch { $threw = $true }
            if (-not $threw) { $fail++; Write-Host "FAIL push accepted '$($bad[0])' '$($bad[1])'" }
        }
    } finally { Remove-Item -LiteralPath $pt -Recurse -Force -ErrorAction SilentlyContinue }
    if ($fail -ne 0) { throw "get.ps1 selftest: $fail failed" }
    Write-Host 'get.ps1 selftest ok'
    return
}
if ($PushOnly) {
    if (-not $Server) { throw '-PushOnly needs -Server user@host' }
    $tree = if ($DestGiven) { $Dest } else { $PSScriptRoot }
    if (-not $tree -or -not (Test-Path -LiteralPath (Join-Path $tree 'lib/oracle-lib.sh'))) { throw "$tree is not an oracle-patch-scripts tree (no lib/oracle-lib.sh): pass the folder" }
    Push-Tree $tree $Server $RemoteParent
    return
}
# Windows PowerShell 5.1 still defaults to TLS 1.0/1.1; GitHub needs 1.2 (classic 'Could not create
# SSL/TLS secure channel'). Harmless no-op on PowerShell 7.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
$Repo = 'AppleDannyClegg/oracle-patch-scripts'
# GitHub's branch archive (archive/refs/heads/main.zip) is CDN-cached and can serve a copy from before your
# last push - so a run right after a push gets stale scripts. The per-commit archive is immutable, so resolve
# the branch's commit first; if the API is unreachable, fall back to the (possibly stale) branch archive.
$sha = $null
try { $sha = (Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/commits/main" -Headers @{ 'User-Agent' = 'get.ps1' } -UseBasicParsing).sha } catch { $sha = $null }
$Url = if ($sha) { "https://github.com/$Repo/archive/$sha.zip" } else { "https://github.com/$Repo/archive/refs/heads/main.zip" }
if ([string]::IsNullOrWhiteSpace($Dest)) { throw 'destination is empty; omit the argument or pass a folder name' }
$Dest = $Dest.TrimEnd('\', '/')

# the parent must be writable BEFORE the download and before the previous copy is moved aside,
# or a typo in the target leaves only <folder>.old
$parent = Split-Path -Parent $Dest
if ([string]::IsNullOrEmpty($parent)) { $parent = '.' }
if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
}
if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    throw "cannot write to $parent"
}
# a file where the tree should go: fail early with a clear message (get.sh's [ -d ] guard skips the swap)
if (Test-Path -LiteralPath $Dest -PathType Leaf) {
    throw "$Dest exists and is a file, not a folder"
}
try {
    # resolve the parent to an ABSOLUTE path first: [System.IO.File] resolves a relative path against
    # the process cwd, while Remove-Item resolves against PowerShell's $PWD, and the two diverge under
    # 'irm | iex'. An absolute probe removes the mismatch.
    $parentFull = (Resolve-Path -LiteralPath $parent).Path
    $probe = Join-Path $parentFull ('.oracle-get-w-' + [System.Guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($probe, '')
    Remove-Item -LiteralPath $probe -Force
} catch {
    throw "cannot write to $parent"
}

# Windows: a read-only or hidden file under the tree makes Remove-Item fail, and a file another program
# holds open cannot be deleted at all - clear the attributes, try Remove-Item, then fall back to cmd's rd
function Remove-Tree([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object { try { $_.Attributes = [IO.FileAttributes]::Normal } catch {} }
    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; return } catch {}
    if ($env:OS -eq 'Windows_NT') { $null = cmd /c "rd /s /q `"$Path`"" 2>&1 }
    if (Test-Path -LiteralPath $Path) {
        throw "cannot delete $Path - a file in it is open in another program, or you do not have permission. Close anything using it (an editor, a shell cd'd into the tree, a running script) and re-run, or delete $Path by hand."
    }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('oracle-get-' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    $zip = Join-Path $tmp 'main.zip'
    Write-Host "downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $zip -UseBasicParsing

    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $src = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
    if ($null -eq $src) { throw 'download did not contain a folder' }

    $moved = $false
    if (Test-Path -LiteralPath $Dest) {
        if (Test-Path -LiteralPath "$Dest.old") {
            # never force-delete downloaded patches: get-patches.ps1 defaults its output to .\patches-<host>,
            # inside this tree, so the previous copy can hold multi-GB zips. Keep it aside and say so instead.
            # Which names count is lib/file-patterns 'staged' in the tree just downloaded - the same file
            # get.sh and java-patch read.
            $patternsFile = Join-Path $src.FullName 'lib/file-patterns'
            if (-not (Test-Path -LiteralPath $patternsFile)) { throw "$patternsFile missing from the download" }
            $stagedGlobs = @(Get-Content -LiteralPath $patternsFile |
                             Where-Object { $_ -match '^\s*staged\s*:' } |
                             ForEach-Object { ($_ -split ':', 2)[1].Trim() -split '\s+' } |
                             Where-Object { $_ })
            if (-not $stagedGlobs.Count) { throw "no 'staged:' globs in $patternsFile" }
            $keep = @(Get-ChildItem -LiteralPath "$Dest.old" -Recurse -Force -ErrorAction SilentlyContinue |
                      Where-Object { $n = $_.Name; $hit = $false; foreach ($g in $stagedGlobs) { if ($n -like $g) { $hit = $true; break } }; $hit })
            if ($keep.Count) {
                $aside = "$Dest.old-" + (Get-Date -Format 'yyyyMMddHHmmss')
                Move-Item -LiteralPath "$Dest.old" -Destination $aside
                Write-Host "kept the previous copy as $aside (it holds $(($keep | ForEach-Object { $_.Name }) -join ', ')) - delete it when you are done, or run get-patches.ps1 with -Dest outside the tree"
            } else {
                Remove-Tree "$Dest.old"
            }
        }
        Move-Item -LiteralPath $Dest -Destination "$Dest.old"
        Write-Host "previous copy moved to $Dest.old"
        $moved = $true
    }
    Move-Item -LiteralPath $src.FullName -Destination $Dest

    $lib = Join-Path $Dest 'lib/oracle-lib.sh'
    if (-not (Test-Path -LiteralPath $lib)) {
        throw 'lib/oracle-lib.sh missing from the download; the scripts will not run'
    }

    # get.sh chmod +x's every *.sh. On Windows the exec bit is NTFS metadata and meaningless, but pwsh
    # can run on Linux/macOS or over a WSL/Unix path, so mirror it when chmod exists
    $chmod = Get-Command chmod -ErrorAction SilentlyContinue
    if ($null -ne $chmod) {
        Get-ChildItem -LiteralPath $Dest -Recurse -Filter '*.sh' -File |
            ForEach-Object { & $chmod.Source '+x' $_.FullName }
    }

    # carry the user's *.conf across, but only from the copy just moved aside, and only the depths
    # get.sh migrates: <type>/<script>/*.conf, <type>/*.conf, and oracle.conf at the top
    if ($moved -and (Test-Path -LiteralPath "$Dest.old" -PathType Container)) {
        $oldPath = (Resolve-Path -LiteralPath "$Dest.old").Path
        foreach ($c in Get-ChildItem -LiteralPath $oldPath -Recurse -Filter '*.conf' -File) {
            $parts = $c.FullName.Substring($oldPath.Length + 1) -split '[\\/]'
            $depth = $parts.Count
            if ($depth -gt 3) { continue }
            if ($depth -eq 1 -and $parts[0] -ne 'oracle.conf') { continue }
            $target = $null
            if ($depth -eq 1) {
                $target = $Dest   # oracle.conf at the top of the old tree
            } else {
                # a script folder: patching/<name>, operations/<name>, reports/<name>
                $dirLeaf = $parts[$depth - 2]
                foreach ($t in Get-ChildItem -LiteralPath $Dest -Directory) {
                    $cand = Join-Path $t.FullName $dirLeaf
                    if (Test-Path -LiteralPath $cand -PathType Container) { $target = $cand; break }
                }
            }
            if ($target) {
                Copy-Item -LiteralPath $c.FullName -Destination $target -Force
                $destFull = (Resolve-Path -LiteralPath $Dest).Path
                $tFull = if ($target -eq $Dest) { $destFull } else { (Resolve-Path -LiteralPath $target).Path }
                $rel = $tFull.Substring($destFull.Length).TrimStart([char]'\', [char]'/')
                if (-not $rel) { $rel = Split-Path -Leaf $destFull }   # top-level conf: match get.sh's 'dest/conf'
                Write-Host "kept your $rel/$($c.Name)"
            }
        }
    }

    # The scripts are bash. On Windows, 'Get-Command bash' is usually the WSL launcher
    # (System32\bash.exe), which cannot read a C:\ path, so the selftest would warn for the wrong
    # reason. Skip it on Windows and point at the right place instead.
    if ($env:OS -eq 'Windows_NT') {
        Write-Host 'note: skipping the lib selftest on Windows; run it under WSL/Git Bash: bash lib/oracle-lib.sh selftest'
    } else {
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if ($null -ne $bash) {
            & $bash.Source $lib selftest *> $null
            if ($LASTEXITCODE -eq 0) { Write-Host 'lib/oracle-lib.sh selftest ok' }
            else { Write-Host 'warning: lib/oracle-lib.sh selftest failed on this machine (bash 4+, GNU coreutils?)' }
        } else {
            Write-Host 'note: bash not found. The scripts are bash - install Git Bash or WSL to run them; the tree is laid down only.'
        }
    }

    Write-Host ''
    Write-Host "done: $((Resolve-Path -LiteralPath $Dest).Path)"
    foreach ($t in 'patching', 'operations', 'reports') {
        $sub = Join-Path $Dest $t
        if (-not (Test-Path -LiteralPath $sub)) { continue }
        Write-Host "  $t/"
        foreach ($d in Get-ChildItem -LiteralPath $sub -Directory) {
            $sh = Join-Path $d.FullName "$($d.Name).sh"
            if (-not (Test-Path -LiteralPath $sh)) { continue }
            [string]$desc = (Get-Content -LiteralPath $sh -TotalCount 2)[1] -replace '^# *[a-z-]*\.sh - ', ''
            if ($desc.Length -gt 95) { $desc = $desc.Substring(0, 95) }
            Write-Host ('    {0,-18} {1}' -f $d.Name, $desc)
        }
    }
    Write-Host '  lib/                 shared library, needed by every script above (bash lib/oracle-lib.sh selftest)'
    if ($Server) {
        Write-Host ''
        Push-Tree $Dest $Server $RemoteParent
        return
    }
    Write-Host ''
    Write-Host "next: read $Dest\README.md, then copy the whole tree to the server (a script needs lib/ two levels up), e.g."
    Write-Host "  scp -r $Dest oracle@server:~/"
    Write-Host "Windows has no Unix exec bit, so if you copied from Windows set it on the server after the copy:"
    Write-Host "  ssh oracle@server 'chmod -R +x ~/$(Split-Path -Leaf $Dest)'"
    Write-Host "or let this script do the copy and the chmod in one go next time:  -Server oracle@server"
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
}
