Write-Host "------------------------------------------" -ForegroundColor Cyan
Write-Host "Running Hook: $($MyInvocation.MyCommand.Name)" -ForegroundColor Cyan
Write-Host "Track: $env:VCS_TRACK"
Write-Host "Author: $env:VCS_AUTHOR"
Write-Host "Snapshot ID: $env:VCS_SNAPSHOT_ID"
Write-Host "------------------------------------------"

if ($env:VCS_PARENT_SNAPSHOT_ID) {
    Write-Host "Parent Snapshot: $env:VCS_PARENT_SNAPSHOT_ID"
} else {
    Write-Host "First snapshot in track."
}

$repoRoot = $env:VCS_REPO_ROOT
Write-Host "Repository root: $repoRoot"

if (-not $env:VCS_AUTHOR) {
    Write-Host "❌ Error: VCS_AUTHOR is required." -ForegroundColor Red
    exit 1
}

Write-Host "✅ Hook execution finished successfully." -ForegroundColor Green
exit 0
