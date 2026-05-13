Write-Host "Checking for unresolved conflict markers..." -ForegroundColor Cyan

$excludeExt = @(".exe", ".dll", ".zip", ".png", ".jpg", ".pck", ".bin")
$markers    = "<<<<<<<|=======|>>>>>>>"

$conflicts = Get-ChildItem -Recurse -File | Where-Object { 
    $path = $_.FullName
    $ext  = $_.Extension.ToLower()
    $isDirExcluded = $path -match "node_modules|build|\.vcs|\.git|\.dart_tool"
    $isBinary      = $excludeExt -contains $ext
    !$isDirExcluded -and !$isBinary
} | Select-String -Pattern $markers -ErrorAction SilentlyContinue

if ($conflicts) {
    Write-Host "❌ Error: Unresolved conflict markers detected!" -ForegroundColor Red
    foreach ($match in $conflicts) {
        Write-Host "   File: $($match.Path) (Line: $($match.LineNumber))" -ForegroundColor Yellow
    }
    exit 1
}

Write-Host "✅ No conflict markers found." -ForegroundColor Green
exit 0
