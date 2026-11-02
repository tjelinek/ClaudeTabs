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
- **Reorder projects:** drag a project along the top row, or Alt+Shift+↑ / Alt+Shift+↓. Also
  remembered; a project added later goes after the ordered ones.
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

## The desk (proof of concept)
`claude-desk [dir]` opens a web page for a project (also "Claude desk" in the app menu; without
a dir, the list of hub projects). The page renders the project's `DESK.md`: its report, notes
and buttons. On it you can:
- **Artifacts:** every artifact the project's tabs have published, newest first, read from
  the transcripts on disk (no API). The link opens it on claude.ai from any device; ↪ drafts
  "Update the artifact ..." in the message box for the tab to republish it in place.
- **⌨ terminal** (top right): the project's hub inside the page, through
  [ttyd](https://github.com/tsl0922/ttyd) on 127.0.0.1:7681. Same tabs as the kitty window
  with the two-row bar, mouse and keys, and the full Claude Code; each browser tab is its own
  tmux client (a grouped session, gone when the tab closes), so it can sit on a different tab
  than the kitty window. Put the static `ttyd` binary on your PATH.
- **Quote to tab:** select text, press the button, add your instruction, send. It is pasted
  into the chosen Claude tab of the hub, which edits the same `DESK.md`; the page re-renders
  within two seconds of any change. The side panel shows the tail of that tab's conversation.
- **Dictate** (any browser: Firefox, Safari, Chrome): the page records the microphone, cuts
  the audio into phrases at pauses, and the server transcribes each phrase locally with
  Whisper (`large-v3-turbo` via faster-whisper, GPU when there is one); the text lands in the
  message box, where you can fix it before "Send to tab". Audio never leaves the machine.
- **Buttons from the Markdown:** `[label](open:path)` opens a file or folder with the desktop's
  default application, `[label](<run:command>)` and fenced blocks tagged `run` execute in the
  project folder and show their output (for commands that finish), and
  `[label](<launch:command>)` starts a program and leaves it running (a viewer, e.g.
  `launch:~/anaconda3/envs/bikeslam/bin/rerun results/run.rrd`). The server runs or opens
  only what is written in the current `DESK.md`.

**Writing a `DESK.md`:** it is the project's presentation layer, a summary of now and not a log,
kept current by the project's own Claude tab as part of each piece of work and rendered to at most
2 A4 pages. A new project starts from this skeleton (the server writes it on first visit); the model
page is Housekeeping's:

```markdown
# Project

One line: what is running, finished or blocked right now.

## Now
- The question this project is answering this week, and where (sweep, probe, branch).
- Three to five bullets at most.

## State (date)
| item | value |
|---|---|
| latest result, read from the result file | number |

- [Open results](open:results)
- [Missing cells](<run:echo "run: waits for the command and shows its output">)
- [Viewer](<launch:xdg-open .>)

## Waiting on you
- Decisions only the user can make, with the size or cost of each.

## Buttons
- [Git status](<run:git status --short>)

```run
echo "fenced blocks tagged run get a play button"
```
```

**Keeping the page honest** (`bin/claude-desk-check`, a Stop hook `install.sh` registers in
`~/.claude/settings.json`): when a Claude tab finishes a turn in a folder with a `DESK.md`, the hook
asks it once per new commit to refresh the page if the commit predates it, and blocks the stop while
`DESK.md` rendered to A4 (Chrome headless, 11 pt) runs past 2 pages, so the desk stays a summary and
not a log. Folders without a `DESK.md` are left alone.

The server (`desk/desk.py`) runs in its own Python env, by default
`~/anaconda3/envs/desk` (override with `CLAUDE_DESK_PYTHON`):

```bash
conda create -n desk python=3.12
~/anaconda3/envs/desk/bin/pip install markdown numpy faster-whisper nvidia-cublas-cu12 nvidia-cudnn-cu12
```

(the two `nvidia-*` wheels only on a machine with an NVIDIA GPU). The first dictation
downloads the Whisper model (1.6 GB) into `~/.cache/huggingface`. The server listens on
127.0.0.1:7357 only, and every mutating request needs a custom header a foreign web page cannot send.

**Remote access** is through [Tailscale](https://tailscale.com) only, never a public port. Once
(as root): install Tailscale, `tailscale up`, `tailscale set --operator=$USER`, and enable MagicDNS
and HTTPS certificates in the admin console. Then `claude-desk --remote on` maps
`https://<machine>.<tailnet>.ts.net/` to the desk and port 7681 to the terminal with
`tailscale serve`; both stay bound to 127.0.0.1 and are reachable only from devices logged into
your tailnet (phone: the Tailscale app, then Firefox or Safari; HTTPS is what lets the microphone
work remotely). The desk adds its own lock: a proxied request is served only if Tailscale
identifies the caller as this node's user, so a Funnel (public) mapping or a node shared with
someone else gets 403. `claude-desk --remote off` removes the mapping. Mind that the terminal is a
real shell on this machine: a lost unlocked phone is a lost laptop, so keep remote off when you do
not need it and set short key expiry in Tailscale.

## Pieces
| File | Role |
|---|---|
| `bin/claude-hub` | the window: restores every project, then attaches; `add`, `remove` and `move` a project; `bar` redraws the top row |
| `bin/claude-tabs` | one project's tmux session, rebuilt from its state file when missing; `--sync` orders the state like the tabs, `--close` closes one for good |
| `bin/claude-tab` | one Claude session; records which conversation the tab shows; `fork` branches one |
| `bin/claude-tab-hook` | SessionStart hook, follows `/resume` and `/clear` |
| `bin/claude-tabs-lock` | file lock for the state files (macOS has no `flock`) |
| `tmux.conf` | the two-row bar, mouse and keys |
| `bin/claude-desk`, `desk/` | the desk: local web page per project rendered from its `DESK.md`, with chat bridge to the hub tab |
| `claude-hub.desktop` | Linux app menu and login entry |
| `tests/smoke.sh` | installs into a throwaway HOME and restores tabs with a fake `claude`; CI runs it on Ubuntu and macOS |

State lives in `~/.local/state/claude-tabs/`: per project, one line per tab
(`tab-key`, `session-id`, `name`) in tab order, plus a `.path` file with the project
directory, and `order`, the project directories in top-row order. Each tmux window carries its tab
key in the window option `@tabkey`.
