#!/usr/bin/env bash
# smoke.sh: install into a throwaway HOME, run the hub against a fake `claude` on a private
# tmux socket, simulate a reboot and check every tab comes back with its conversation.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
export HOME CLAUDE_TABS_SOCKET=ctsmoke$$
HOME=$(mktemp -d)
trap 'tmux -L "$CLAUDE_TABS_SOCKET" kill-server 2>/dev/null || true; rm -rf "$HOME"' EXIT   # no server is left once the last test removes the project
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

# Drag tab 2 before tab 1: the state follows the tab order.
T() { tmux -L "$CLAUDE_TABS_SOCKET" "$@"; }
T swap-window -d -s "=$sess:1" -t "=$sess:2"
(cd "$proj" && "$HOME/.local/bin/claude-tabs" --sync)
[ "$(cut -f2 "$state" | tr '\n' ' ')" = "$sid2 $new " ] || fail "state not reordered after a move"

# A second project: the top row lists projects alphabetically until one is moved; then the order
# file decides, and removing a project drops it from both.
proj2="$HOME/aaa"; mkdir -p "$proj2"
"$HOME/.local/bin/claude-hub" add "$proj2" >/dev/null
wait_for "second project starts" started 4
bar() { T show -gv 'status-format[0]' | grep -o '}  [^#]*  #\[norange' | sed 's/^}  //; s/  #\[norange$//' | tr '\n' ','; }
row_is() { [ "$(bar)" = "$1" ]; }
wait_for "top row lists both projects" row_is "aaa,my proj,"
"$HOME/.local/bin/claude-hub" move "$sess" -1
[ "$(bar)" = "my proj,aaa," ] || fail "project not moved in the top row: $(bar)"
[ "$(tr '\n' ',' < "$HOME/.local/state/claude-tabs/order")" = "$proj,$proj2," ] || fail "order file not written"
"$HOME/.local/bin/claude-hub" remove "$proj2"
wait_for "removed project left the top row" row_is "my proj,"
[ "$(cat "$HOME/.local/state/claude-tabs/order")" = "$proj" ] || fail "removed project still in the order file"

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
order() { [ "$(cut -f2 "$state" | tr '\n' ' ')" = "$sid2 $new " ]; }
wait_for "tabs restored in their order" order

# Quitting Claude in a tab forgets it.
kill "$(grep "^$sid2 " "$HOME/log" | cut -d' ' -f2)"
wait_for "closed tab forgotten" has_lines 1

# Closing a tab from the bar (claude-tabs --close) forgets it too, though Claude is killed.
T new-window -d -t "=$sess" -c "$proj" "$HOME/.local/bin/claude-tab new doomed"
wait_for "doomed tab recorded" has_lines 2
(cd "$proj" && "$HOME/.local/bin/claude-tabs" --close "$(T list-windows -t "=$sess" -F '#{window_id}' | tail -1)")
has_lines 1 || fail "closed tab still in the state"

# Removing the project closes its tabs and forgets it.
"$HOME/.local/bin/claude-hub" remove "$proj"
! T has-session -t "=$sess" 2>/dev/null || fail "project session survived remove"
[ ! -e "$state" ] && [ ! -e "$state.path" ] || fail "project state survived remove"
echo "smoke test passed"
