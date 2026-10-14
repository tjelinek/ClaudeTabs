#!/usr/bin/env bash
# install.sh: link ClaudeTabs into ~/.local/bin and ~/.config, and register the SessionStart
# hook in ~/.claude/settings.json. Safe to re-run; the repo stays the single source.
set -euo pipefail
repo=$(cd "$(dirname "$0")" && pwd)
for c in tmux kitty claude uuidgen flock jq; do
    command -v "$c" >/dev/null || { echo "install.sh: $c is required but not on PATH" >&2; exit 1; }
done

mkdir -p ~/.local/bin ~/.config/claude-tabs ~/.config/autostart ~/.local/share/applications ~/.claude
for f in "$repo"/bin/*; do ln -sfn "$f" ~/.local/bin/; done
ln -sfn "$repo/tmux.conf" ~/.config/claude-tabs/tmux.conf
ln -sfn "$repo/claude-hub.desktop" ~/.local/share/applications/claude-hub.desktop   # app menu
ln -sfn "$repo/claude-hub.desktop" ~/.config/autostart/claude-hub.desktop           # opens at login

settings=~/.claude/settings.json
hook='~/.local/bin/claude-tab-hook'
[ -f "$settings" ] || echo '{}' > "$settings"
if ! jq -e --arg h "$hook" '[.. | .command? // empty] | index($h)' "$settings" >/dev/null; then
    jq --arg h "$hook" '.hooks.SessionStart += [{hooks: [{type: "command", command: $h, timeout: 5}]}]' \
        "$settings" > "$settings.tmp"
    mv "$settings.tmp" "$settings"
fi
echo "Installed. Add a project with:  claude-hub add <project dir>"
