# Pull-JarvisBackup.ps1 - copy the newest encrypted JARVIS backup into Google Drive (keep 7)
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File Pull-JarvisBackup.ps1
#
# Runs on the owner's Windows PC from Task Scheduler ("JARVIS backup pull": daily + at logon).
# Pulls over SFTP as the read-only 'backuppull' account (ssh alias 'jarvis-backup' in ~/.ssh/config,
# key ~/.ssh/jarvis_backuppull) from /files on JARVIS (filled by scripts/backup-mirror.sh).
# Files stay age-encrypted; the private key is in the owner's password manager.
# Download -> local staging (C:) -> SHA-256 check -> move into Google Drive -> keep the newest 7.
# Reports to the Uptime Kuma push monitor "Off-site copy (Google Drive)"; the push URL is read from
# %USERPROFILE%\.jarvis\kuma_push_offsite_url (never in the repo).
# Log: %LOCALAPPDATA%\JarvisBackupPull\pull.log
$ErrorActionPreference = 'Stop'

$Dest    = 'G:\My Drive\Jarvis Backups'
$Keep    = 7
$Remote  = 'jarvis-backup'
$Stage   = Join-Path $env:LOCALAPPDATA 'JarvisBackupPull'
$Log     = Join-Path $Stage 'pull.log'
$UrlFile = Join-Path $env:USERPROFILE '.jarvis\kuma_push_offsite_url'
$Sftp    = Join-Path $env:WINDIR 'System32\OpenSSH\sftp.exe'

New-Item -ItemType Directory -Force -Path $Stage | Out-Null

function Write-Log([string]$Message) {
    $line = '[{0} UTC] {1}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $Log -Value $line
    Write-Output $line
}

function Send-Kuma([string]$Status, [string]$Message) {
    if (-not (Test-Path -LiteralPath $UrlFile)) { return }
    $url = (Get-Content -LiteralPath $UrlFile -TotalCount 1).Trim().Split('?')[0]
    try {
        Invoke-RestMethod -UseBasicParsing -TimeoutSec 20 -Uri ('{0}?status={1}&msg={2}' -f $url, $Status, [uri]::EscapeDataString($Message)) | Out-Null
    } catch {
        Write-Log "WARN: Kuma push failed: $($_.Exception.Message)"
    }
}

function Invoke-Sftp([string[]]$Commands) {
    # batch file with LF line ends (piping from PowerShell would add CR to every command)
    $batch = Join-Path $Stage 'sftp-batch.txt'
    [IO.File]::WriteAllText($batch, (($Commands -join "`n") + "`n"))
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'   # sftp writes notes to stderr
    $out = & $Sftp -q -b $batch $Remote 2>&1 | ForEach-Object { "$_" }
    $rc = $LASTEXITCODE; $ErrorActionPreference = $prev
    if ($rc -ne 0) { throw "sftp failed (exit $rc): $($out -join ' | ')" }
    return $out
}

try {
    if (-not (Test-Path -LiteralPath $Dest)) { throw "Google Drive folder not available (Drive for Desktop not running?): $Dest" }

    # newest encrypted archive on JARVIS (names sort by timestamp)
    $remoteFiles = Invoke-Sftp @('ls -1 /files') | ForEach-Object { "$_".Trim() } |
        Where-Object { $_ -match 'jarvis_full_\d{8}_\d{6}\.tar\.gz\.age$' } | ForEach-Object { Split-Path $_ -Leaf }
    if (-not $remoteFiles) { throw 'no encrypted archive in the JARVIS outbox' }
    $name = $remoteFiles | Sort-Object -Descending | Select-Object -First 1

    if (Test-Path -LiteralPath (Join-Path $Dest $name)) {
        Write-Log "up to date: $name already in Google Drive"
    } else {
        Get-ChildItem -LiteralPath $Stage -Filter '*.partial' | Remove-Item -Force
        $part = Join-Path $Stage "$name.partial"
        $sum  = Join-Path $Stage "$name.sha256"
        Write-Log "downloading $name"
        Invoke-Sftp @("get /files/$name `"$part`"", "get /files/$name.sha256 `"$sum`"") | Out-Null

        $expected = ((Get-Content -LiteralPath $sum -TotalCount 1) -split '\s+')[0].ToLower()
        $actual   = (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash.ToLower()
        if ($expected -ne $actual) { Remove-Item -LiteralPath $part, $sum -Force; throw "checksum mismatch for $name" }

        Move-Item -LiteralPath $sum -Destination (Join-Path $Dest "$name.sha256") -Force
        Move-Item -LiteralPath $part -Destination (Join-Path $Dest $name) -Force
        Write-Log ('copied + verified {0} ({1:N1} GB)' -f $name, ((Get-Item -LiteralPath (Join-Path $Dest $name)).Length / 1GB))
    }

    # retention: keep the newest $Keep archives (deleted files go to Drive's Trash for 30 days)
    $all = Get-ChildItem -LiteralPath $Dest -Filter 'jarvis_full_*.tar.gz.age' | Sort-Object Name -Descending
    foreach ($f in ($all | Select-Object -Skip $Keep)) {
        Write-Log "retention: removing $($f.Name)"
        Remove-Item -LiteralPath $f.FullName -Force
        Remove-Item -LiteralPath "$($f.FullName).sha256" -Force -ErrorAction SilentlyContinue
    }
    $count = @(Get-ChildItem -LiteralPath $Dest -Filter 'jarvis_full_*.tar.gz.age').Count
    Write-Log "SUCCESS: newest $name, $count copies in Google Drive"
    Send-Kuma 'up' "OK $name ($count copies)"
} catch {
    Write-Log "FAILED: $($_.Exception.Message)"
    Send-Kuma 'down' "pull failed: $($_.Exception.Message)"
    exit 1
}
