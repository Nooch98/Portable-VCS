#!/bin/bash

echo -e "\033[0;36mChecking for secrets and API Keys...\033[0m"

PATTERNS=(
    "AIza[0-9A-Za-z-_]{35}"
    "sq0atp-[0-9A-Za-z-_]{22}"
    "sk_live_[0-9a-zA-Z]{24}"
    "(AKIA|ASAA|AGPA|AIDA)([0-9A-Z]{16})"
    "ghp_[a-zA-Z0-9]{36}"
    "hooks\.slack\.com/services/[A-Z0-9]+/[A-Z0-9]+/[A-Za-z0-9]+"
    "-----BEGIN RSA PRIVATE KEY-----"
    "-----BEGIN OPENSSH PRIVATE KEY-----"
)

TOTAL_FOUND=0


EXCLUDE_DIRS=(
    ".git" ".vcs" ".dart_tool" "node_modules" "build" ".gradle" 
    ".idea" ".vscode" "bin" "obj" "vendor" "__pycache__"
)

FIND_CMD="find . -type f"
for dir in "${EXCLUDE_DIRS[@]}"; do
    FIND_CMD+=" -not -path '*/$dir/*'"
done


FIND_CMD+=" -not -name '*.png' -not -name '*.jpg' -not -name '*.exe' -not -name '*.zip' -not -name '*.dll' -not -name '*.pck'"

FILES=$(eval $FIND_CMD)

for FILE in $FILES; do
    [ ! -f "$FILE" ] && continue
    LINE_NUM=0
    while IFS= read -r line || [ -n "$line" ]; do
        ((LINE_NUM++))
        MATCHED=0
        for regex in "${PATTERNS[@]}"; do
            if [[ $line =~ $regex ]]; then MATCHED=1; break; fi
        done
        
        # Check genéricos (api_key, password)
        if echo "$line" | grep -iqE "password|api_key"; then MATCHED=1; fi

        if [ $MATCHED -eq 1 ]; then
            ((TOTAL_FOUND++))
            echo -e "\n\033[41;37m[!] FINDING #$TOTAL_FOUND\033[0m"
            echo -e "\033[0;33m   File: $FILE\033[0m"

            START=$((LINE_NUM > 2 ? LINE_NUM - 2 : 1))
            END=$((LINE_NUM + 2))
            
            sed -n "${START},${END}p" "$FILE" | while read -r context_line; do
                if echo "$context_line" | grep -qF "$line"; then
                    echo -e "\033[41;37m>> $LINE_NUM: $(echo "$context_line" | xargs)\033[0m"
                else
                    echo -e "   ---: $(echo "$context_line" | xargs)"
                fi
            done
            echo -e "\033[0;90m----------------------------------------\033[0m"
        fi
    done < "$FILE"
done

if [ $TOTAL_FOUND -gt 0 ]; then
    echo -e "\n\033[0;33m[!] Scan finished. Risks found: $TOTAL_FOUND\033[0m"
    exit 1
else
    echo -e "\033[0;32mOK: No obvious secrets detected.\033[0m"
    exit 0
fi
