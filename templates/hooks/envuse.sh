#!/bin/bash

echo "------------------------------------------"
echo "Running Hook: $(basename "$0")"
echo "Track: $VCS_TRACK"
echo "Author: $VCS_AUTHOR"
echo "Snapshot ID: $VCS_SNAPSHOT_ID"
echo "------------------------------------------"

if [ -n "$VCS_PARENT_SNAPSHOT_ID" ]; then
    echo "Parent Snapshot: $VCS_PARENT_SNAPSHOT_ID"
else
    echo "First snapshot in track."
fi

if [ -z "$VCS_AUTHOR" ]; then
    echo "❌ Error: VCS_AUTHOR is required."
    exit 1
fi

echo "✅ Hook execution finished successfully."
exit 0
