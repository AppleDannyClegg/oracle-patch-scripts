<#
  Get-ScreenRpm.ps1 - download GNU screen (and libutempter) RPMs on a Windows
  machine with internet, for a Linux server that has none.

  Usage (PowerShell 5.1 or later):
    powershell -ExecutionPolicy Bypass -File .\Get-ScreenRpm.ps1 -EL 9
    powershell -ExecutionPolicy Bypass -File .\Get-ScreenRpm.ps1 -EL 8 -OutDir C:\temp\screen

  -EL is the server's major version: look at VERSION_ID in /etc/os-release
  (Oracle Linux, RHEL, Rocky and Alma all work). x86_64 only.

  Sources:
    EL7  yum.oracle.com ol7_latest
    EL8  not supported: Oracle's EPEL 8 mirror has no screen, and Fedora's
         download site answers scripts with a bot check. Use tmux there.
    EL9  screen from yum.oracle.com ol9_developer_EPEL,
         libutempter from yum.oracle.com ol9_baseos_latest
  Every package is checked against the checksum the repo publishes.
#>
param(
  [Parameter(Mandatory = $true)][ValidateSet('7', '9')][string]$EL,
  [string]$OutDir = (Join-Path (Get-Location) "screen-el$EL")
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar on PS 5.1

$oracle = 'https://yum.oracle.com/repo/OracleLinux'

function Get-FromOracleRepo([string]$repo, [string]$name) {
  # Reads the repo's primary.xml.gz, picks the newest x86_64 build of $name,
  # downloads it and checks it against the repo's checksum.
  $repomd = [xml](Invoke-WebRequest -UseBasicParsing "$repo/repodata/repomd.xml").Content
  $href = ($repomd.repomd.data | Where-Object { $_.type -eq 'primary' }).location.href
  $tmp = [IO.Path]::GetTempFileName()
  Invoke-WebRequest -UseBasicParsing "$repo/$href" -OutFile $tmp
  # The package list is up to ~1.2 GB uncompressed, so stream it rather than load it.
  $in = [IO.File]::OpenRead($tmp)
  $gz = New-Object IO.Compression.GZipStream($in, [IO.Compression.CompressionMode]::Decompress)
  $settings = New-Object Xml.XmlReaderSettings
  $settings.IgnoreWhitespace = $true
  $settings.DtdProcessing = [Xml.DtdProcessing]::Ignore
  $xr = [Xml.XmlReader]::Create($gz, $settings)
  $pkg = $null
  # ReadElementContentAsString leaves the reader ON the next element, so only
  # move forward when it is not already on the one wanted.
  function MoveTo([string]$el) { if ($xr.NodeType -ne 'Element' -or $xr.Name -ne $el) { [void]$xr.ReadToFollowing($el) } }
  try {
    # Fields come in this order inside each <package>: name, arch, checksum, time, location.
    while ($xr.ReadToFollowing('package')) {
      MoveTo 'name'; $n = $xr.ReadElementContentAsString()
      if ($n -ne $name) { continue }
      MoveTo 'arch'; $arch = $xr.ReadElementContentAsString()
      MoveTo 'checksum'; $ctype = $xr.GetAttribute('type'); $csum = $xr.ReadElementContentAsString()
      MoveTo 'time'; $build = [long]$xr.GetAttribute('build')
      MoveTo 'location'; $href = $xr.GetAttribute('href')
      if ($arch -eq 'x86_64' -and (-not $pkg -or $build -gt $pkg.Build)) {
        $pkg = @{ Href = $href; Type = $ctype; Sum = $csum.ToLower(); Build = $build }
      }
    }
  } finally { $xr.Close(); $in.Close(); Remove-Item $tmp }
  if (-not $pkg) { throw "$name not found in $repo" }
  $file = Join-Path $OutDir (Split-Path $pkg.Href -Leaf)
  Write-Host "downloading $(Split-Path $file -Leaf)"
  Invoke-WebRequest -UseBasicParsing "$repo/$($pkg.Href)" -OutFile $file
  $algo = @{ sha = 'SHA1'; sha1 = 'SHA1'; sha256 = 'SHA256' }[$pkg.Type]
  if (-not $algo) { throw "unexpected checksum type $($pkg.Type) for $file" }
  $got = (Get-FileHash -Algorithm $algo $file).Hash.ToLower()
  if ($got -ne $pkg.Sum) { throw "checksum mismatch for $file (want $($pkg.Sum), got $got)" }
  Write-Host "  $($algo.ToLower()) ok $got"
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
switch ($EL) {
  '7' { Get-FromOracleRepo "$oracle/OL7/latest/x86_64" 'libutempter'
        Get-FromOracleRepo "$oracle/OL7/latest/x86_64" 'screen' }
  '9' { Get-FromOracleRepo "$oracle/OL9/baseos/latest/x86_64" 'libutempter'
        Get-FromOracleRepo "$oracle/OL9/developer/EPEL/x86_64" 'screen' }
}
Write-Host ""
Write-Host "Done. Copy $OutDir and install-screen.sh to the server, e.g.:"
Write-Host "  scp -r `"$OutDir`" .\install-screen.sh user@server:/tmp/"
