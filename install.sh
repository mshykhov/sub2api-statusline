#!/usr/bin/env bash
# Installs statusline.sh into the Claude Code config dir and points `statusLine` at it.
set -euo pipefail

RAW_URL="https://raw.githubusercontent.com/mshykhov/sub2api-statusline/main/statusline.sh"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TARGET="$CONFIG_DIR/sub2api-statusline.sh"
SETTINGS="$CONFIG_DIR/settings.json"

for dep in jq curl; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "Missing dependency: $dep" >&2
        exit 1
    fi
done

mkdir -p "$CONFIG_DIR"

src_dir=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    src_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fi
if [ -n "$src_dir" ] && [ -f "$src_dir/statusline.sh" ]; then
    cp "$src_dir/statusline.sh" "$TARGET"
else
    curl -fsSL "$RAW_URL" -o "$TARGET"
fi
chmod +x "$TARGET"

if [ ! -s "$SETTINGS" ]; then
    echo '{}' > "$SETTINGS"
fi
backup="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS" "$backup"

tmp=$(mktemp)
jq --arg cmd "$TARGET" '.statusLine = {type: "command", command: $cmd, padding: 0}' "$SETTINGS" > "$tmp"
# Write through instead of mv so a symlinked settings.json stays a symlink
cat "$tmp" > "$SETTINGS"
rm -f "$tmp"

echo "Installed: $TARGET"
echo "Updated statusLine in $SETTINGS (backup: $backup)"
echo "Restart Claude Code or send a message to see the new status line."
