<#
get.ps1 - Windows/PowerShell version of get.sh: fetch the Oracle operations scripts
(patching/, operations/, reports/ plus the shared lib/) onto this machine. No git needed.

  irm https://raw.githubusercontent.com/AppleDannyClegg/oracle-patch-scripts/main/get.ps1 | iex

Puts everything in .\oracle-patch-scripts (or the folder given as the first argument).
Run it again later to pick up the newest version; the previous copy is kept as <folder>.old,
and your own *.conf files are carried across.

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

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 still defaults to TLS 1.0/1.1; GitHub needs 1.2 (classic 'Could not create
# SSL/TLS secure channel'). Harmless no-op on PowerShell 7.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
$Repo = 'AppleDannyClegg/oracle-patch-scripts'
$Url  = "https://github.com/$Repo/archive/refs/heads/main.zip"
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
try {
    $probe = Join-Path $parent ('.oracle-get-w-' + [System.Guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($probe, '')
    Remove-Item -LiteralPath $probe -Force
} catch {
    throw "cannot write to $parent"
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
        if (Test-Path -LiteralPath "$Dest.old") { Remove-Item -LiteralPath "$Dest.old" -Recurse -Force }
        Move-Item -LiteralPath $Dest -Destination "$Dest.old"
        Write-Host "previous copy moved to $Dest.old"
        $moved = $true
    }
    Move-Item -LiteralPath $src.FullName -Destination $Dest

    $lib = Join-Path $Dest 'lib/oracle-lib.sh'
    if (-not (Test-Path -LiteralPath $lib)) {
        throw 'lib/oracle-lib.sh missing from the download; the scripts will not run'
    }

    # carry the user's *.conf across, but only from the copy just moved aside
    if ($moved) {
        $oldPath = (Resolve-Path -LiteralPath "$Dest.old").Path
        $oldLeaf = Split-Path -Leaf $oldPath
        foreach ($c in Get-ChildItem -LiteralPath $oldPath -Recurse -Filter '*.conf' -File) {
            $dirLeaf = Split-Path -Leaf (Split-Path -Parent $c.FullName)
            $target = $null
            if ($dirLeaf -eq $oldLeaf) {
                $target = $Dest   # oracle.conf at the top of the old tree
            } else {
                # a script folder: patching/<name>, operations/<name>, reports/<name>
                foreach ($t in Get-ChildItem -LiteralPath $Dest -Directory) {
                    $cand = Join-Path $t.FullName $dirLeaf
                    if (Test-Path -LiteralPath $cand -PathType Container) { $target = $cand; break }
                }
            }
            if ($target) {
                Copy-Item -LiteralPath $c.FullName -Destination $target -Force
                Write-Host "kept your $(Split-Path -Leaf $target)/$($c.Name)"
            }
        }
    }

    # bash is not on Windows by default: run the library self-test only if we can find it
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if ($null -ne $bash) {
        & $bash.Source $lib selftest *> $null
        if ($LASTEXITCODE -eq 0) { Write-Host 'lib/oracle-lib.sh selftest ok' }
        else { Write-Host 'warning: lib/oracle-lib.sh selftest failed on this machine (bash 4+, GNU coreutils?)' }
    } else {
        Write-Host 'note: bash not found. The scripts are bash - install Git Bash or WSL to run them; the tree is laid down only.'
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
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
