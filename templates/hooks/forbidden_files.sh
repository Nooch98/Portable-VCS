#!/bin/bash

echo -e "\033[0;36mChecking for forbidden files...\033[0m"

FORBIDDEN=(".env" "config.local.json" "*.log" "Thumbs.db" ".DS_Store" "*.tmp")
EXIT_CODE=0

for pattern in "${FORBIDDEN[@]}"; do
    MATCHES=$(find . -name "$pattern" \
        -not -path "*/node_modules/*" \
        -not -path "*/build/*" \
        -not -path "*/.dart_tool/*" \
        -not -path "*/.*/*")
    if [ -n "$MATCHES" ]; then
        echo -e "\033[0;31m❌ Forbidden file detected:\033[0m"
        echo "$MATCHES" | sed 's/^/   /'
        EXIT_CODE=1
    fi
done

[ $EXIT_CODE -eq 1 ] && exit 1
echo -e "\033[0;32m✅ No forbidden files found.\033[0m"
exit 0
