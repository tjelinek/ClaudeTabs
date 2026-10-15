#!/usr/bin/env bash
# install.sh: link ClaudeTabs into ~/.local/bin and ~/.config, open the hub at login, and
# register the SessionStart hook in ~/.claude/settings.json. Safe to re-run; the repo stays
# the single source. Linux: kitty window via XDG autostart. macOS: Terminal window via launchd.
set -euo pipefail
repo=$(cd "$(dirname "$0")" && pwd)
os=$(uname)
need="tmux claude uuidgen perl jq"; [ "$os" = Linux ] && need+=" kitty"
for c in $need; do
    command -v "$c" >/dev/null || { echo "install.sh: $c is required but not on PATH" >&2; exit 1; }
done

mkdir -p ~/.local/bin ~/.config/claude-tabs ~/.claude
for f in "$repo"/bin/*; do ln -sfn "$f" ~/.local/bin/; done
ln -sfn "$repo/tmux.conf" ~/.config/claude-tabs/tmux.conf
case $os in
    Linux)
        mkdir -p ~/.config/autostart ~/.local/share/applications
        ln -sfn "$repo/claude-hub.desktop" ~/.local/share/applications/claude-hub.desktop   # app menu
        ln -sfn "$repo/claude-hub.desktop" ~/.config/autostart/claude-hub.desktop           # login
        ;;
    Darwin)
        mkdir -p ~/Library/LaunchAgents
        cat > ~/Library/LaunchAgents/com.github.claudetabs.hub.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.github.claudetabs.hub</string>
    <key>ProgramArguments</key>
    <array><string>/usr/bin/open</string><string>-a</string><string>Terminal</string><string>$HOME/.local/bin/claude-hub</string></array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
        ;;
    *) echo "install.sh: unsupported OS $os" >&2; exit 1 ;;
esac

settings=~/.claude/settings.json
hook='~/.local/bin/claude-tab-hook'
[ -f "$settings" ] || echo '{}' > "$settings"
if ! jq -e --arg h "$hook" '[.. | .command? // empty] | index($h)' "$settings" >/dev/null; then
    jq --arg h "$hook" '.hooks.SessionStart += [{hooks: [{type: "command", command: $h, timeout: 5}]}]' \
        "$settings" > "$settings.tmp"
    mv "$settings.tmp" "$settings"
fi
echo "Installed. Add a project with:  claude-hub add <project dir>"
