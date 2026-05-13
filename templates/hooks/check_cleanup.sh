#!/bin/bash

echo -e "\033[0;36mChecking for unresolved conflict markers...\033[0m"

CONFLICTS=$(grep -rE "<<<<<<<|=======|>>>>>>>" . \
    --exclude-dir={.git,.vcs,node_modules,build,.dart_tool} \
    --exclude={"*.png","*.jpg","*.exe","*.zip"} \
    --binary-files=without-match)

if [ -n "$CONFLICTS" ]; then
    echo -e "\033[0;31m❌ Error: Unresolved conflict markers detected!\033[0m"
    echo "$CONFLICTS" | awk -F: '{print "\033[0;33m   File: "$1" (Line: "$2")\033[0m"}'
    exit 1
fi

echo -e "\033[0;32m✅ No conflict markers found.\033[0m"
exit 0
