# Dev mode

`agentic dev` gives each project one long-running container, `agentic-<project>-dev`, with a
tmux session named `main`. Your project folder is mounted at `/work`, and every new window
starts there. Run as many agents in it as you like, each in its own tmux window, then leave and
come back later. Everything keeps running while you are away.

## Commands

| Command | What it does |
|---|---|
| `agentic dev` | Starts the container if needed, then attaches to the session `main` (creating it if it is gone). |
| `agentic dev status` | `running=true/false`, and `outdated` when the image was rebuilt since the container started. |
| `agentic dev stop` | Stops the container. The next `agentic dev` starts it again. |
| `agentic dev recreate` | Removes the container, starts a new one from the current image and attaches. Use it after `agentic build`; `agentic add ... --yes` does it for you. |
| `agentic dev --host-profile wsl\|none` | Forces the WSL host conveniences on or off (see below). |
| `agentic shell [CMD...]` | A separate throwaway container, removed on exit. It is not part of the dev session. |

The container restarts with Docker (`--restart unless-stopped`). What survives:

| Survives | Detach, terminal closed | `stop` / Docker restart | `recreate` |
|---|---|---|---|
| Files in `/work` (your project on the host) | yes | yes | yes |
| Logins and Claude/Copilot history (`~/.claude`, `~/.copilot`, mounted from the host) | yes | yes | yes |
| Running agents and tmux windows | yes | no | no |
| Other changes inside the container (`~/.tmux.conf`, ad-hoc installs) | yes | yes | no |

After a stop or recreate, `claude --continue` (or `claude --resume` to pick one) brings back a
conversation, because the history lives on the host.

## tmux in five minutes

Every tmux key starts with the prefix **`Ctrl-b`**: press it, release, then press the key.

| Keys | Action |
|---|---|
| `Ctrl-b c` | New window in `/work`. Type `claude` (or `copilot`) to start another agent. |
| `Ctrl-b w` | Tree of all windows with a live preview. Arrows to choose, `Enter` to open. |
| `Ctrl-b 0` … `9` | Go to window 0 … 9. |
| `Ctrl-b n` / `p` | Next / previous window. |
| `Ctrl-b l` | Back to the last window you used. |
| `Ctrl-b ,` | Rename the current window. |
| `Ctrl-b d` | Detach. Everything keeps running, and `agentic dev` re-attaches. |
| `Ctrl-b [` | Scroll mode: arrows or `PgUp`/`PgDn`, `q` to leave. |
| `Ctrl-b %` / `"` | Split the window side by side / top and bottom. `Ctrl-b o` or arrows move between panes. |
| `Ctrl-b x` / `&` | Close the current pane / window (asks first). |

### Reading the status bar

```text
[main] 0:claude- 1:bash  2:claude*
```

`[main]` is the session. Each entry is `index:name`. `*` marks the window you are in and `-` the
one you were in before (`Ctrl-b l`). tmux names a window after the program running in it.

`Ctrl-b w` shows more. Claude Code sets each window's title to its current task, so the tree
reads like a task list:

```text
(0) - main: 3 windows (attached)
(1) ├─> 0: claude-: "✳ Project tech stack"
(2) ├─> 1: bash
(3) └─> 2: claude*: "✳ Backend architecture diagram from docs wiki"
```

## A typical day

1. `agentic dev`. Window `0` opens in `/work`. Start `claude`.
2. `Ctrl-b c`, then `claude` again for a second, independent task. Repeat as needed.
3. Keep one plain `bash` window for git, tests and looking around (`Ctrl-b c`, no agent).
4. `Ctrl-b w` to see which agent is doing what, and jump to the one that needs you.
5. `Ctrl-b d` when you leave. Later, `agentic dev` brings you back to the same windows.
6. After `agentic build`, `agentic dev status` says `outdated`. When the agents are idle, run
   `agentic dev recreate`.

You can attach from several terminals at once (run `agentic dev` in each). They all show the
same session, so typing in one appears in the others.

## Parallel agents and git

All windows share one checkout in `/work`. Two agents that change code at the same time will step
on each other's edits and commits. Give each parallel task its own git worktree inside `/work`:

```bash
git worktree add .worktrees/login-fix -b login-fix
cd .worktrees/login-fix && claude
```

Add `.worktrees/` to `.gitignore`, and remove the worktree when its branch is merged
(`git worktree remove .worktrees/login-fix`). Agents that only read, answer questions or review
can share `/work` without worktrees.

## Copy, paste and scrolling

- The mouse is off in tmux, so the terminal's own selection, copy and right-click paste keep
  working. Scroll with `Ctrl-b [`.
- To scroll with the wheel instead, add `set -g mouse on` to `~/.tmux.conf` in the container and
  run `tmux source ~/.tmux.conf`. Hold `Shift` to select or paste with the mouse. A recreate
  loses that file. To keep it, put it in `.agentic/files/tmux.conf` and add
  `agentic copy .agentic/files/tmux.conf /home/dev/.tmux.conf`.
- Text copied in tmux scroll mode reaches the system clipboard through OSC 52, where the terminal
  supports it.
- On WSL with WSLg, the container gets the display, the Wayland clipboard and the host `/tmp`, so
  pasting an image into Claude Code works. This is detected automatically. `--host-profile none`
  (or `AGENTIC_HOST_PROFILE=none`) turns it off, and `--host-profile wsl` forces it on.

## When something is off

- `agentic dev status` reports `running=false`: run `agentic dev` and it starts again.
- You typed `exit` in the last window: the tmux session ended, but the container still runs.
  `agentic dev` opens a new session.
- An agent says it is not logged in: run `agentic doctor` on the host, then `agentic login`.
- A tool or config change is missing: rebuild with `agentic build`, then `agentic dev recreate`.
