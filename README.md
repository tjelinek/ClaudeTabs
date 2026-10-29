# ClaudeTabs: all Claude Code sessions in one window

One terminal window, the **Claude hub** (kitty on Linux, Terminal on macOS), holds the [Claude Code](https://claude.com/claude-code)
sessions of every project as clickable tabs. Each project is a tmux session, so sessions keep
running when the window closes, and after a reboot every tab comes back resumed from its last
message. Nothing asks questions.

## Install

- **Linux** with an XDG desktop (GNOME tested): `tmux` 3.4+, `kitty`, `jq`, `uuidgen`, `perl`.
- **macOS** 15+: only `brew install tmux`; the rest ships with macOS. To use the Alt keys
  below, tick Terminal → Settings → Profiles → Keyboard → "Use Option as Meta key"; clicking
  works without it.

Both need [Claude Code](https://claude.com/claude-code) (`claude`) on PATH.

```bash
git clone https://github.com/tjelinek/ClaudeTabs.git && ClaudeTabs/install.sh
claude-hub add ~/path/to/project
claude-hub
```

`install.sh` symlinks the scripts into `~/.local/bin` and the tmux profile into
`~/.config/claude-tabs/`, makes the hub open at login (Linux: an app menu and autostart entry;
macOS: a LaunchAgent, `~/Library/LaunchAgents/com.github.claudetabs.hub.plist`), and adds a
SessionStart hook to `~/.claude/settings.json`. Your own `~/.tmux.conf` is not touched.

**Claude flags.** Tabs start plain `claude`. To give every tab extra flags, put them on one
line in `~/.config/claude-tabs/claude-flags`, for example:

```bash
echo --dangerously-skip-permissions > ~/.config/claude-tabs/claude-flags
```

## The bar at the bottom
- **Top row, projects:** click one to switch to it, or roll the mouse wheel over the row.
  (Keys: Alt+↑ / Alt+↓)
- **Too many to fit?** Either row shows `<` and `>` where it is cut off and scrolls to keep
  the selected item in view; the wheel or the arrow keys walk through the hidden ones.
- **Add a project:** click the `+` at the end of the top row and type its folder (Tab
  completes), or run `claude-hub add <dir>`.
- **Remove a project:** right-click it in the top row and press `y`, or run
  `claude-hub remove <dir>`. Its tabs close; the conversations stay in Claude's `/resume` list,
  and adding the project again starts it with one fresh tab.
- **Bottom row, that project's tabs:** click one to switch, or roll the wheel over the row.
  (Keys: Alt+← / Alt+→)
- **Reorder tabs:** drag a tab along the bottom row, or Alt+Shift+← / Alt+Shift+→. The order
  is remembered and comes back after a reboot.
- **+ new** (bottom right, or Alt+N): a new session in the selected project. It asks for a
  name, or press Enter for the default ("myproject 2"); type `r` to reopen a past chat instead.
  The name shows on the tab, in the `/resume` list and in the mobile app. Rename later inside
  Claude with `/rename <name>`.
- **Close a tab for good:** right-click it and press `y`, or quit Claude in it (Ctrl+C
  twice). A project whose last tab you close disappears from the top row.
- **Branch a conversation:** ask the Claude in a tab to branch out (the `branch-tab` skill, or
  `claude-tab fork <session-id> <name>` by hand). A new tab opens in the background with the
  same conversation so far; both tabs then go their own way.
- `/resume` or `/clear` inside a tab is fine: the tab remembers whatever conversation it
  shows now, and that is what comes back after a reboot.

## Everyday
- **Switch off the computer:** just do it. After the next login the hub rebuilds every
  project's tabs.
- **Closed the hub window?** Sessions keep running. Type `claude-hub` in any terminal (on
  Linux also "Claude hub" in the app menu) to see them again.
- **One project's tabs in another terminal** (an IDE's, say): run `claude-tabs` in the
  project directory. It shows the same live sessions as the hub.

## Pieces
| File | Role |
|---|---|
| `bin/claude-hub` | the window: restores every project, then attaches; `add` and `remove` a project |
| `bin/claude-tabs` | one project's tmux session, rebuilt from its state file when missing; `--sync` orders the state like the tabs, `--close` closes one for good |
| `bin/claude-tab` | one Claude session; records which conversation the tab shows; `fork` branches one |
| `bin/claude-tab-hook` | SessionStart hook, follows `/resume` and `/clear` |
| `bin/claude-tabs-lock` | file lock for the state files (macOS has no `flock`) |
| `tmux.conf` | the two-row bar, mouse and keys |
| `claude-hub.desktop` | Linux app menu and login entry |
| `tests/smoke.sh` | installs into a throwaway HOME and restores tabs with a fake `claude`; CI runs it on Ubuntu and macOS |

State lives in `~/.local/state/claude-tabs/`: per project, one line per tab
(`tab-key`, `session-id`, `name`) in tab order, plus a `.path` file with the project
directory. Each tmux window carries its tab key in the window option `@tabkey`.
