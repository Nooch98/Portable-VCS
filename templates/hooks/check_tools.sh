#!/bin/bash

echo -e "\033[0;36mScanning for TODOs and FIXMEs in comments...\033[0m"

REGEX="(//|#|\*|<!--)[[:space:]]*\b(TODO|FIXME)\b"

FOUND=$(grep -rE "$REGEX" . \
    --exclude-dir={.git,.vcs,node_modules,build,.dart_tool,bin,obj} \
    --exclude={"*.sh","*.ps1","*.png","*.jpg","*.exe","*.zip","*.dll"} \
    --binary-files=without-match)

if [ -n "$FOUND" ]; then
    echo -e "\033[0;33m⚠️  Pending tasks found in comments:\033[0m"
    echo "$FOUND" | while read -r line; do
        echo -e "\033[0;90m   [!] $line\033[0m"
    done
    echo -e "\n\033[0;37m(Push allowed, but consider reviewing these tasks.)\033[0m"
fi
exit 0
