Write-Host "Checking for secrets and API Keys..." -ForegroundColor Cyan

$patterns = @(
    "AIza[0-9A-Za-z-_]{35}",                          # Google API Key
    "sq0atp-[0-9A-Za-z-_]{22}",                       # Square Access Token
    "sk_live_[0-9a-zA-Z]{24}",                        # Stripe Live Key
    "(AKIA|ASAA|AGPA|AIDA)([0-9A-Z]{16})",            # AWS Access Key ID
    "([^A-Z0-9])[A-Za-z0-9+/]{40}([^A-Z0-9])",        # AWS Secret Access Key
    "ghp_[a-zA-Z0-9]{36}",                            # GitHub Token
    "hooks\.slack\.com/services/[A-Z0-9]+/[A-Z0-9]+/[A-Za-z0-9]+", # Slack
    "(?i)password\s*[:=]\s*['`"].+['`"]",             # Passwords
    "(?i)api_key\s*[:=]\s*['`"].+['`"]",              # Generic API Keys
    "-----BEGIN RSA PRIVATE KEY-----",                # Private Keys
    "-----BEGIN OPENSSH PRIVATE KEY-----"
)

$totalFound = 0

$excludeList = @(
    ".vcs", ".git", ".dart_tool", "node_modules", "build", 
    ".gradle", ".idea", ".vscode", "bin", "obj", "vendor",
    "debug", "release", "__pycache__", ".ipynb_checkpoints"
)

$excludeExt = @(".exe", ".zip", ".png", ".jpg", ".jpeg", ".gif", ".dll", ".pck", ".pdf", ".iso", ".bin")

$files = Get-ChildItem -Recurse -File | Where-Object { 
    $path = $_.FullName
    $ext = $_.Extension.ToLower()
    
    $isExcludedDir = $false
    foreach ($exclude in $excludeList) { 
        if ($path -like "*\$exclude\*") { $isExcludedDir = $true; break } 
    }
    
    $isBinary = $excludeExt -contains $ext
    
    !$isExcludedDir -and !$isBinary
}

foreach ($file in $files) {
    try {
        $content = Get-Content $file.FullName -ErrorAction SilentlyContinue
    } catch { continue }

    if ($null -eq $content) { continue }
    $lines = @($content)

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        foreach ($regex in $patterns) {
            if ($line -match $regex) {
                $totalFound++
                Write-Host "`n[!] FINDING #$totalFound" -ForegroundColor Red -BackgroundColor Black
                Write-Host "   File: $($file.FullName)" -ForegroundColor Yellow
                
                $start = [Math]::Max(0, $i - 2)
                $end = [Math]::Min($lines.Count - 1, $i + 2)
                
                for ($j = $start; $j -le $end; $j++) {
                    $prefix = if ($j -eq $i) { ">> " } else { "   " }
                    if ($j -eq $i) {
                        Write-Host "$prefix${j}: $($lines[$j].Trim())" -ForegroundColor White -BackgroundColor DarkRed
                    } else {
                        Write-Host "$prefix${j}: $($lines[$j].Trim())" -ForegroundColor Gray
                    }
                }
                Write-Host ("-" * 40) -ForegroundColor Gray
            }
        }
    }
}

if ($totalFound -gt 0) {
    Write-Host "`n[!] Scan finished. Total potential risks found: $totalFound" -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "OK: No obvious secrets detected." -ForegroundColor Green
    exit 0
}
