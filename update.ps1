<#
.SYNOPSIS
    Update pinned image digests in docker-compose*.yml safely.

.DESCRIPTION
    For each `image: <ref>@sha256:...` line, finds the corresponding tag
    from the `# tag: <ref>:tag` annotation directly above it.

    docker pulls that tag, inspects the upstream image's Created date.
    If the upstream image is older than the quarantine window (default
    7 days), and its digest differs from the pinned one, proposes an
    update — but the quarantine ensures you never roll forward to a
    fresh image that hasn't had time to be reviewed by the community.

    Default is dry-run. Use -Apply to actually rewrite the YAML files.

.PARAMETER Apply
    Rewrite the YAML files in place. A `.bak` copy is kept of each.

.PARAMETER QuarantineDays
    Don't propose updating to upstream images younger than this many
    days. Default 7. Use 0 to disable (NOT recommended).

.EXAMPLE
    .\update.ps1
    Dry-run: report what would change.

.EXAMPLE
    .\update.ps1 -Apply
    Rewrite the YAML in place.

.EXAMPLE
    .\update.ps1 -QuarantineDays 30
    Use a stricter 30-day quarantine window.
#>

[CmdletBinding()]
param(
    [switch]$Apply,
    [int]$QuarantineDays = 7
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

function Write-Step($msg)    { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-OK($msg)      { Write-Host "    $msg" -ForegroundColor Green }
function Write-WarnMsg($msg) { Write-Host "    $msg" -ForegroundColor Yellow }
function Write-ErrMsg($msg)  { Write-Host "    $msg" -ForegroundColor Red }

# --- Sanity checks ----------------------------------------------------------
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-ErrMsg "Docker is not installed."; exit 1
}
try { docker info --format '{{.ServerVersion}}' 2>$null | Out-Null }
catch { Write-ErrMsg "Docker daemon is not running."; exit 1 }

$mode = if ($Apply) { "APPLY" } else { "DRY-RUN" }
Write-Step "Update mode: $mode (quarantine $QuarantineDays days)"

# --- Parse compose files ----------------------------------------------------
$composeFiles = @("docker-compose.yml")
if (Test-Path -LiteralPath "docker-compose.vpn.yml")      { $composeFiles += "docker-compose.vpn.yml" }
if (Test-Path -LiteralPath "docker-compose.telegram.yml") { $composeFiles += "docker-compose.telegram.yml" }

$tagRx   = [regex]'^\s*#\s*tag:\s*(\S+)\s*$'
$imageRx = [regex]'^(\s*image:\s*)(\S+?)@sha256:([0-9a-f]{64})\s*$'

$pinned = @()
foreach ($file in $composeFiles) {
    $lines = Get-Content -LiteralPath $file
    $pendingTag = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $m = $tagRx.Match($line)
        if ($m.Success) { $pendingTag = $m.Groups[1].Value; continue }
        $m = $imageRx.Match($line)
        if ($m.Success) {
            if ($pendingTag) {
                $pinned += [pscustomobject]@{
                    Tag           = $pendingTag
                    Repo          = $m.Groups[2].Value
                    CurrentDigest = $m.Groups[3].Value
                    File          = $file
                    LineNo        = $i + 1
                }
            } else {
                Write-WarnMsg "no '# tag:' annotation above ${file}:$($i+1)"
            }
            $pendingTag = $null
        } elseif ($line.Trim() -and -not $line.TrimStart().StartsWith('#')) {
            # any non-comment, non-blank line resets the pending tag
            $pendingTag = $null
        }
    }
}

if ($pinned.Count -eq 0) {
    Write-ErrMsg "No pinned images found. Make sure each 'image: ...@sha256:...' line has"
    Write-ErrMsg "a '# tag: ...' comment directly above it."
    exit 1
}
Write-OK "Found $($pinned.Count) pinned image(s)"
Write-Host ""

# --- Check each ------------------------------------------------------------
$changes = @()
foreach ($p in $pinned) {
    $shortOld = $p.CurrentDigest.Substring(0, 12)
    Write-Host "==> $($p.Tag)" -ForegroundColor Cyan
    Write-Host "    file:  $($p.File):$($p.LineNo)"
    Write-Host "    pinned digest:  sha256:$shortOld..."

    docker pull $p.Tag 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-ErrMsg "pull failed; skipping"; continue }

    $upstreamRef = docker inspect --format='{{index .RepoDigests 0}}' $p.Tag 2>$null
    if (-not $upstreamRef) { Write-ErrMsg "couldn't read upstream digest; skipping"; continue }
    $upstreamDigest = ($upstreamRef -split '@sha256:')[1]

    if ($upstreamDigest -eq $p.CurrentDigest) { Write-OK "up-to-date"; Write-Host ""; continue }

    $createdStr = docker inspect --format='{{.Created}}' $p.Tag
    $created    = [DateTime]::Parse($createdStr).ToUniversalTime()
    $ageDays    = [Math]::Floor(((Get-Date).ToUniversalTime() - $created).TotalDays)
    $shortNew   = $upstreamDigest.Substring(0, 12)
    Write-Host ("    upstream digest: sha256:{0}...  (built {1:yyyy-MM-dd}, {2} days ago)" -f $shortNew, $created, $ageDays)

    if ($ageDays -lt $QuarantineDays) {
        Write-WarnMsg "SKIP — upstream image is younger than $QuarantineDays-day quarantine"
        Write-Host ""; continue
    }

    Write-Step "READY TO UPDATE"
    $changes += [pscustomobject]@{
        File   = $p.File
        OldDig = $p.CurrentDigest
        NewDig = $upstreamDigest
        Tag    = $p.Tag
    }
    Write-Host ""
}

if ($changes.Count -eq 0) {
    Write-Step "Nothing to update."
    exit 0
}

Write-Step "$($changes.Count) image(s) ready to update"
if (-not $Apply) {
    Write-WarnMsg "Dry-run only. To apply: .\update.ps1 -Apply"
    exit 0
}

# --- Apply: backup and rewrite ---------------------------------------------
$filesToBackup = $changes | Select-Object -ExpandProperty File -Unique
Write-Step "Backing up files"
foreach ($f in $filesToBackup) {
    Copy-Item -LiteralPath $f -Destination "$f.bak" -Force
    Write-OK "$f -> $f.bak"
}

Write-Step "Applying digest updates"
foreach ($c in $changes) {
    $content = Get-Content -LiteralPath $c.File -Raw
    if (-not $content.Contains($c.OldDig)) {
        Write-WarnMsg "old digest $($c.OldDig.Substring(0,12))... not found in $($c.File)"
        continue
    }
    $content = $content.Replace($c.OldDig, $c.NewDig)
    [System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $c.File).Path, $content, [System.Text.UTF8Encoding]::new($false))
    Write-OK "$($c.Tag):  $($c.OldDig.Substring(0,12))... -> $($c.NewDig.Substring(0,12))...  in $($c.File)"
}

Write-Host ""
Write-Step "Done."
Write-Host "    Files updated. Backups: *.bak"
Write-Host ""
Write-Host "    Restart your stack with the new pinned digests:"
Write-Host "      docker compose pull"
Write-Host "      docker compose up -d"
Write-Host ""
Write-Host "    If anything misbehaves, restore the old digests:"
Write-Host '      Get-ChildItem docker-compose*.yml.bak | ForEach-Object { Move-Item $_ ($_ -replace ".bak$","") -Force }'
