# ClaudeTabs: all Claude Code sessions in one window

One kitty window, the **Claude hub**, holds the [Claude Code](https://claude.com/claude-code)
sessions of every project as clickable tabs. Each project is a tmux session, so sessions keep
running when the window closes, and after a reboot every tab comes back resumed from its last
message. Nothing asks questions.

## Install

Needs Linux with an XDG desktop (GNOME tested), `tmux` 3.4+, `kitty`, `claude`, `jq`,
`uuidgen` and `flock`.

```bash
git clone https://github.com/tjelinek/ClaudeTabs.git && ClaudeTabs/install.sh
claude-hub add ~/path/to/project
claude-hub
```

`install.sh` symlinks the scripts into `~/.local/bin`, the tmux profile into
`~/.config/claude-tabs/`, the "Claude hub" entry into the app menu and autostart, and adds a
SessionStart hook to `~/.claude/settings.json`. Your own `~/.tmux.conf` is not touched.

**Claude flags.** Tabs start plain `claude`. To give every tab extra flags, put them on one
line in `~/.config/claude-tabs/claude-flags`, for example:

```bash
echo --dangerously-skip-permissions > ~/.config/claude-tabs/claude-flags
```

## The bar at the bottom
- **Top row, projects:** click one to switch to it. (Keys: Alt+↑ / Alt+↓)
- **Bottom row, that project's tabs:** click one to switch. (Keys: Alt+← / Alt+→)
- **+ new** (bottom right, or Alt+N): a new session in the selected project. It asks for a
  name, or press Enter for the default ("myproject 2"); type `r` to reopen a past chat instead.
  The name shows on the tab, in the `/resume` list and in the mobile app. Rename later inside
  Claude with `/rename <name>`.
- **Close a tab for good:** right-click it and press `y`, or quit Claude in it (Ctrl+C
  twice). A project whose last tab you close disappears from the top row.
- `/resume` or `/clear` inside a tab is fine: the tab remembers whatever conversation it
  shows now, and that is what comes back after a reboot.

## Everyday
- **Switch off the computer:** just do it. After the next login the hub rebuilds every
  project's tabs.
- **Closed the kitty window?** Sessions keep running. Open "Claude hub" from the app menu
  (or type `claude-hub` in any terminal) to see them again.
- **One project's tabs in another terminal** (an IDE's, say): run `claude-tabs` in the
  project directory. It shows the same live sessions as the hub.

## Pieces
| File | Role |
|---|---|
| `bin/claude-hub` | the window: restores every project, then attaches; `claude-hub add <dir>` |
| `bin/claude-tabs` | one project's tmux session, rebuilt from its state file when missing |
| `bin/claude-tab` | one Claude session; records which conversation the tab shows |
| `bin/claude-tab-hook` | SessionStart hook, follows `/resume` and `/clear` |
| `tmux.conf` | the two-row bar, mouse and keys |
| `claude-hub.desktop` | app menu and login entry |

State lives in `~/.local/state/claude-tabs/`: per project, one line per tab
(`tab-key`, `session-id`, `name`) plus a `.path` file with the project directory.
