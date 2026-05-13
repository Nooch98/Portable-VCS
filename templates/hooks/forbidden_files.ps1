Write-Host "Checking for forbidden files..." -ForegroundColor Cyan

$forbiddenPatterns = @(".env", "config.local.json", "*.log", "Thumbs.db", ".DS_Store", "*.tmp")
$found = @()

foreach ($pattern in $forbiddenPatterns) {
    $matches = Get-ChildItem -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue | Where-Object {
        $_.FullName -notmatch "node_modules|build|\.vcs|\.git|\.dart_tool|bin|obj"
    }
    if ($matches) { $found += $matches.FullName }
}

if ($found.Count -gt 0) {
    Write-Host "`n❌ Error: Forbidden files found:" -ForegroundColor Red
    foreach ($file in $found) { Write-Host "   [FORBIDDEN] $file" -ForegroundColor Yellow }
    exit 1
}

Write-Host "✅ No forbidden files found." -ForegroundColor Green
exit 0
