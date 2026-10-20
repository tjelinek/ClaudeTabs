#!/usr/bin/env bash
# smoke.sh: install into a throwaway HOME, run the hub against a fake `claude` on a private
# tmux socket, simulate a reboot and check every tab comes back with its conversation.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
export HOME CLAUDE_TABS_SOCKET=ctsmoke$$
HOME=$(mktemp -d)
trap 'tmux -L "$CLAUDE_TABS_SOCKET" kill-server 2>/dev/null; rm -rf "$HOME"' EXIT
echo "bash ${BASH_VERSION}, $(tmux -V), $(uname); using $(command -v sed awk tr jq perl | tr '\n' ' ')"

fail() { echo "FAIL: $*" >&2; [ -f "$HOME/log" ] && cat "$HOME/log" >&2; exit 1; }
wait_for() {   # wait_for <description> <command...>: retry for up to 10 s
    local what=$1 i; shift
    for i in $(seq 100); do "$@" && return; sleep 0.1; done
    fail "$what"
}

# Fake claude: logs its arguments, writes a transcript, fires the SessionStart hook like the
# real one, then waits. A picker (--resume with no id), --fork-session or --session-id picks
# the session id.
mkdir -p "$HOME/.local/bin" "$HOME/fakebin"
cat > "$HOME/fakebin/claude" <<'EOF'
#!/usr/bin/env bash
sid=$(uuidgen | tr 'A-F' 'a-f')
while [ $# -gt 0 ]; do
    case $1 in --session-id) sid=$2; shift ;; --resume) [ $# -gt 1 ] && { sid=$2; shift; } ;;
            --fork-session) sid=$(uuidgen | tr 'A-F' 'a-f') ;; esac
    shift
done
tdir="$HOME/.claude/projects/$(printf '%s' "$PWD" | sed 's#[/._]#-#g')"
mkdir -p "$tdir"; echo '{}' > "$tdir/$sid.jsonl"
printf '{"session_id": "%s"}' "$sid" | "$HOME/.local/bin/claude-tab-hook"
echo "$sid $$" >> "$HOME/log"
exec sleep 1000
EOF
printf '#!/bin/sh\n' > "$HOME/fakebin/kitty"
chmod +x "$HOME/fakebin/"*
export PATH="$HOME/fakebin:$PATH"

"$repo/install.sh"
jq -e '.hooks.SessionStart[0].hooks[0].command == "~/.local/bin/claude-tab-hook"' "$HOME/.claude/settings.json" >/dev/null \
    || fail "hook not registered"
if [ "$(uname)" = Darwin ]; then plutil -lint "$HOME/Library/LaunchAgents/com.github.claudetabs.hub.plist"; fi

proj="$HOME/my proj"; mkdir -p "$proj"
state="$HOME/.local/state/claude-tabs/$(printf '%s' "$proj" | tr -c 'A-Za-z0-9\n' '-')"
sess="cc$(basename "$state")"
lines() { grep -c . "$state" || true; }   # grep -c prints 0 but exits 1 on no match
started() { [ -f "$HOME/log" ] && [ "$(grep -c . "$HOME/log")" -ge "$1" ]; }
has_lines() { [ "$(lines)" -eq "$1" ]; }

"$HOME/.local/bin/claude-hub" add "$proj" | grep -q "Added my proj" || fail "claude-hub add"
wait_for "first tab starts" started 1
tmux -L "$CLAUDE_TABS_SOCKET" new-window -d -t "=$sess" -c "$proj" "$HOME/.local/bin/claude-tab new second"
wait_for "second tab starts" started 2
wait_for "two state lines" has_lines 2
grep -q "	second$" "$state" || fail "tab name not recorded"

# /clear in tab 1: the hook points the tab at a new conversation (one with a transcript).
key1=$(head -1 "$state" | cut -f1)
new=11111111-2222-3333-4444-555555555555
echo '{}' > "$HOME/.claude/projects/$(printf '%s' "$proj" | sed 's#[/._]#-#g')/$new.jsonl"
printf '{"session_id": "%s"}' "$new" | CLAUDE_TAB_KEY=$key1 CLAUDE_TABS_STATE=$state "$HOME/.local/bin/claude-tab-hook"
[ "$(head -1 "$state" | cut -f2)" = "$new" ] || fail "hook did not switch tab 1 to $new"
sid2=$(sed -n 2p "$state" | cut -f2)

# Fork tab 1 into a third tab: it gets a new session id, recorded by the hook.
tmux -L "$CLAUDE_TABS_SOCKET" new-window -d -t "=$sess" -c "$proj" "$HOME/.local/bin/claude-tab fork $new 'side quest'"
wait_for "forked tab starts" started 3
wait_for "three state lines" has_lines 3
sid3=$(sed -n 3p "$state" | cut -f2)
[ "$sid3" != forking ] && [ "$sid3" != "$new" ] || fail "fork not recorded with its own session id ($sid3)"
grep -q "	side quest$" "$state" || fail "fork name not recorded"
kill "$(grep "^$sid3 " "$HOME/log" | cut -d' ' -f2)"
wait_for "forked tab closed" has_lines 2

# Reboot: the tmux server dies with the tabs, the state stays.
tmux -L "$CLAUDE_TABS_SOCKET" kill-server
sleep 0.5
has_lines 2 || fail "state lost on reboot"
: > "$HOME/log"
out=$("$HOME/.local/bin/claude-hub" 2>&1 </dev/null) || true     # restores, then attach fails: no tty here
grep -q "not a terminal" <<<"$out" || fail "claude-hub: $out"
wait_for "both tabs restored" started 2
grep -q "^$new " "$HOME/log" || fail "tab 1 not resumed as $new"
grep -q "^$sid2 " "$HOME/log" || fail "tab 2 not resumed as $sid2"
wait_for "restored state has two lines" has_lines 2

# Quitting Claude in a tab forgets it.
kill "$(grep "^$sid2 " "$HOME/log" | cut -d' ' -f2)"
wait_for "closed tab forgotten" has_lines 1
echo "smoke test passed"
