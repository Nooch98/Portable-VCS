Write-Host "Scanning for TODOs and FIXMEs in comments..." -ForegroundColor Cyan

$excludeList = @(".vcs", ".git", "node_modules", "build", ".dart_tool", "bin", "obj")
$excludeExt  = @(".exe", ".dll", ".zip", ".png", ".jpg", ".jpeg", ".gif", ".pdf", ".pck", ".bin")
$foundTasks = @()

$commentRegex = "(//|#|/\*|\*|<!--)\s*\b(TODO|FIXME)\b"

$files = Get-ChildItem -Recurse -File | Where-Object {
    $path = $_.FullName
    $ext  = $_.Extension.ToLower()
    
    $isDirExcluded = $false
    foreach ($exclude in $excludeList) {
        if ($path -like "*\$exclude\*") { $isDirExcluded = $true; break }
    }
    
    $isBinary = $excludeExt -contains $ext
    !$isDirExcluded -and !$isBinary
}

foreach ($file in $files) {
    try {
        $matches = Select-String -Path $file.FullName -Pattern $commentRegex -Exclude "*.ps1", "*.sh" -ErrorAction SilentlyContinue
        if ($matches) {
            foreach ($match in $matches) {
                $foundTasks += "[!] $($file.Name):$($match.LineNumber) -> $($match.Line.Trim())"
            }
        }
    } catch { continue }
}

if ($foundTasks.Count -gt 0) {
    Write-Host "`n⚠️  Pending tasks found in comments:" -ForegroundColor Yellow
    $foundTasks | ForEach-Object { Write-Host "   $_" -ForegroundColor Gray }
    Write-Host "`n(Push allowed, but consider reviewing these tasks.)" -ForegroundColor White
} else {
    Write-Host "✅ No pending tasks found." -ForegroundColor Green
}
exit 0
