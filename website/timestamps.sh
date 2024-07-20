#!/bin/bash

set -euo pipefail

json_file="timestamps.json"
rm -f "$json_file"

# Get all mdx files
find src -name "*.mdx" | while read -r f; do
    # Get the last modified date
    last_modified=$(git log -1 --format="%ad" --date=format:'%B %d, %Y' -- "$f")

    # Strip src/app prefix and /readme.mdx suffix to turn file path into URL path
    f=${f#"src/app"}
    f=${f%"/readme.mdx"}

    if [ -s "$json_file" ]; then
        echo ",\"$f\":\"$last_modified\"" >>"$json_file"
    else
        echo "{\"$f\":\"$last_modified\"" >"$json_file"
    fi
done

# Close the JSON
echo "}" >>"$json_file"
