<#
get.ps1 - Windows/PowerShell version of get.sh: fetch the Oracle operations scripts
(patching/, operations/, reports/ plus the shared lib/) onto this machine. No git needed.

  irm https://raw.githubusercontent.com/AppleDannyClegg/oracle-patch-scripts/main/get.ps1 | iex

Puts everything in .\oracle-patch-scripts (or the folder given as the first argument).
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

Custom destination (the pipe form cannot take arguments; build a script block instead):

  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/AppleDannyClegg/oracle-patch-scripts/main/get.ps1))) 'C:\tools\oracle-patch-scripts'
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Dest = 'oracle-patch-scripts'
)

# Everything below runs in a CHILD scope, so the plain 'irm | iex' cannot leak this script's
# variables or its $ErrorActionPreference into the caller's session (get.sh runs in a subshell).
& {

$ErrorActionPreference = 'Stop'
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
        if (Test-Path -LiteralPath "$Dest.old") { Remove-Tree "$Dest.old" }
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
    Write-Host ''
    Write-Host "next: read $Dest\README.md, then copy the whole tree to the server (a script needs lib/ two levels up), e.g."
    Write-Host "  scp -r $Dest oracle@server:~/"
    Write-Host "Windows has no Unix exec bit, so if you copied from Windows set it on the server after the copy:"
    Write-Host "  ssh oracle@server 'chmod -R +x ~/$(Split-Path -Leaf $Dest)'"
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
}
