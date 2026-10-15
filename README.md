# Pi Agent for Godot

[![Release](https://img.shields.io/github/v/release/yanekyuk/godot-pi?include_prereleases&label=release)](https://github.com/yanekyuk/godot-pi/releases)
[![Godot 4.6+](https://img.shields.io/badge/Godot-4.6%2B-478cbf?logo=godotengine&logoColor=white)](https://godotengine.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

A Godot editor plugin that puts the [Pi Coding Agent](https://github.com/earendil-works/pi) in a dock.
It runs `pi --mode rpc` in your project folder and streams the conversation, tool calls and file edits into the editor.

> [!WARNING]
> **Experimental (v0.x).** Developed and tried on macOS with Godot 4.7. Linux should work. Windows is untested.
> Pi edits files in your project, so use version control.

<!-- ![Pi dock in the Godot editor](docs/screenshot.png) -->

## Features

- **Chat dock** with streaming replies, collapsible thinking blocks, and tool cards that show live output and diffs.
- **Editor-aware prompts.** The **Context** toggle attaches the open scene, the selected nodes, the current script
  and the code you selected.
- **Right-click → Add to Pi** in the code editor, the FileSystem dock and the Scene dock.
- **Live reload.** Open scripts are saved before each prompt. After Pi edits files, the plugin rescans the
  filesystem and reloads the scripts and scenes that Pi touched.
- **Model and thinking-level pickers**, new session, restart, and context/token/cost stats.
- **Per-project sessions.** The dock reopens the session it used last in this project. The **History** button lists
  this project's sessions so you can switch, rename or delete them.
- **Steer or queue** messages while Pi is working. **Esc** aborts.
- **Shell commands:** `!cmd` runs a command and adds its output to Pi's context. `!!cmd` runs it without adding the output.
- **Pi extensions work:** their dialogs open as editor dialogs, and their notifications, status lines and widgets
  show in the dock.

## Requirements

- **Godot 4.6 or newer.** The plugin uses the `EditorDock` API added in 4.6.
- **Pi**, installed and logged in to a model provider:
  ```bash
  npm install -g --ignore-scripts @earendil-works/pi-coding-agent
  pi            # run once in a terminal to log in / choose a model
  ```
  Check that `pi --version` works in your terminal before you continue.

## Installation

The plugin is installed per project. Godot does not support editor-wide plugins.

### From a GitHub Release (recommended)

1. Download `godot-pi-vX.Y.Z.zip` from the [latest release](https://github.com/yanekyuk/godot-pi/releases).
2. Extract it into your **project root**, the folder that contains `project.godot`. The zip holds
   `addons/pi_agent/`, so you end up with:
   ```
   your-project/
   ├── project.godot
   └── addons/
       └── pi_agent/
           ├── plugin.cfg
           └── ...
   ```
3. Open the project in Godot and enable **Project → Project Settings → Plugins → Pi Agent**.
4. The **Pi** dock appears on the right side. A green dot means Pi is running.

From a terminal, the same install looks like this:

```bash
cd /path/to/your-project
VERSION=v0.2.0
curl -fL -o /tmp/godot-pi.zip \
  "https://github.com/yanekyuk/godot-pi/releases/download/$VERSION/godot-pi-$VERSION.zip"
unzip -o /tmp/godot-pi.zip -d .
```

Then enable the plugin as in step 3.

### Updating

Close the Godot editor first. Delete `addons/pi_agent/` so that no removed files stay behind,
extract the new zip the same way, then reopen the project.

### Uninstalling

Disable the plugin in **Project Settings → Plugins**, then delete `addons/pi_agent/`.
Its editor settings (under **Pi Agent**) are stored per user and do nothing once the plugin is gone.

## Configuration

**Editor → Editor Settings → Pi Agent**. After you change a launch setting, use the dock's restart button or
**Project → Tools → Pi: Restart Agent**.

| Setting | Default | Description |
|---|---|---|
| `launch/command` | `pi` | Command used to start Pi. Can be an absolute path or e.g. `node /path/to/dist/cli.js`. |
| `launch/extra_args` | *(empty)* | Extra CLI arguments, space separated, e.g. `--provider anthropic --model claude-sonnet-4-5`. |
| `launch/use_login_shell` | on | Start Pi through `$SHELL -lc` so that `PATH` matches your terminal. |
| `launch/auto_start` | on | Start Pi when the plugin loads. |
| `launch/startup_session` | Resume Last Dock Session | Session Pi opens on startup. **Resume Last Dock Session** reopens the session the dock used last in this project. **Continue Most Recent** passes `--continue`, which also picks up sessions started from a terminal. **New Session** always starts fresh. |
| `behavior/save_scripts_before_prompt` | on | Save open scripts before each prompt, so Pi sees what you see. |
| `behavior/reload_after_edits` | on | Rescan the filesystem and reload touched scripts and scenes after Pi edits. |
| `behavior/attach_editor_context` | on | Whether the **Context** toggle starts on. |
| `display/show_thinking` | on | Show model thinking blocks. |

If `launch/extra_args` already contains a session flag (`--session`, `--continue`, `--resume`, `--no-session`, `--fork`, `--session-id`),
the plugin adds none of its own.

Pi always runs in the project root, so `res://player.gd` is `./player.gd` for Pi. Pi's own settings, models,
skills and extensions (`~/.pi`, `.pi/` in the project) apply as usual.

## Usage

| Action | How |
|---|---|
| Send a prompt | **Enter** (**Shift+Enter** for a newline) |
| Steer a running agent | **Enter** while Pi is working |
| Queue a follow-up | **Alt+Enter** while Pi is working |
| Abort | **Esc** in the input box, or **Stop**. Queued messages go back into the input box. |
| Run a shell command | `!git status` (output goes into Pi's context) · `!!ls` (output does not) |
| Commands, prompt templates, skills | the **/** button, or type `/name` |
| Reference code | select code → right-click → **Add Selection to Pi** |
| Reference files or nodes | right-click in the FileSystem or Scene dock → **Add to Pi Prompt** |
| Open a file Pi touched | the **open** link on a tool card |
| Switch, rename or delete sessions | the **History** button. Double-click a session to open it. |
| Keep the session across restarts | the **restart** button or **Project → Tools → Pi: Restart Agent** |

## Sessions

Pi saves every conversation as a session file. By default it stores them in `~/.pi/agent/sessions/--<project path>--/`.
The dock tracks sessions per project:

- The session the dock used last is stored in the editor's project metadata (`.godot/editor/project_metadata.cfg`).
  That file is per user and is not committed. The next time the editor starts, Pi reopens that session.
- **History** lists every session of this project, including sessions you started from a terminal. It shows the
  session name (or the first prompt), the last update time and the file size. The active session is marked with ●.
- **Open** switches Pi to the selected session. If Pi is not running, Open starts Pi with that session.
- **Rename…** names the active session. To rename a different session, open it first.
- **Delete…** moves a session file to the trash. You can't delete the active session.
- Pi writes a new session to disk only after its first prompt. Until then, History shows it as *not saved*.

Pi finds its session folder from `get_state`, so `--session-dir`, `PI_CODING_AGENT_SESSION_DIR` and the
`sessionDir` setting are respected.

## Troubleshooting

**The dock says "Pi exited" right away, or the dot stays grey.**
Godot could not start `pi`. The error message includes Pi's last stderr lines. Common fixes:
- Godot was opened from Finder or a launcher, and your login shell doesn't put `node` or `pi` on `PATH`.
  Set `launch/command` to an absolute path (run `which pi` to find it). If `node` itself isn't found,
  use something like `/path/to/node /path/to/pi`.
- Your shell profile prints text when it starts. The plugin ignores those lines, but if your profile
  stops or prompts for input, turn off `launch/use_login_shell` and use absolute paths.

**No models in the picker.** Run `pi` once in a terminal and log in to a provider.

**An edited script doesn't refresh.** Turn on
**Editor Settings → Text Editor → Behavior → Files → Auto Reload Scripts on External Change**.

## How it works

The plugin is pure GDScript and needs no native code. It starts
`$SHELL -lc "cd <project> && exec pi --mode rpc"` with `OS.execute_with_pipe(..., blocking = false)`
and polls the pipes every frame. It sends [Pi's RPC commands](https://github.com/earendil-works/pi) as JSON lines
and builds the dock from the event stream. When the plugin is disabled or the editor closes, Pi's stdin is
closed so it shuts down cleanly.

| File | Role |
|---|---|
| `plugin.gd` | Registers the dock, the context menus and the Tools menu item |
| `pi_rpc_client.gd` | Process and JSON-lines transport: non-blocking reads, atomic chunked writes, request IDs |
| `pi_dock.gd` | Chat UI and event handling |
| `pi_extension_ui.gd` | Pi extension UI subprotocol |
| `pi_editor_context.gd` | Editor context for prompts and `res://` path mapping |
| `pi_context_menu.gd` | Right-click menu entries |
| `pi_format.gd` | Markdown to BBCode and ANSI stripping |
| `pi_sessions.gd` | Per-project session memory and the session list |
| `pi_settings.gd` | Editor settings |

## Known limitations

- Image attachments are not supported yet.
- Pi's TUI-only features (`/settings`, custom footers or editors, `ctx.ui.custom()`) do not exist in RPC mode.
  Use the dock's toolbar instead.
- When the Godot window is not focused, the editor's main loop runs slower, so streaming updates less often.
  No data is lost.
- The plugin does not watch Pi's edits in real time. It reloads files after each edit tool finishes.

## Development

This repository is also a demo project. `sample/` contains a small scene, and the plugin is already enabled.

```bash
git clone https://github.com/yanekyuk/godot-pi.git
godot -e --path godot-pi
```

To try Pi's extension UI, set `launch/extra_args` to `-e <path to pi>/examples/extensions/rpc-demo.ts`
and restart Pi.

### Releasing

1. Update `version` in `addons/pi_agent/plugin.cfg` and add an entry to `CHANGELOG.md`.
2. Commit, then tag and push: `git tag v0.2.0 && git push origin v0.2.0`.
3. The [Release workflow](.github/workflows/release.yml) checks that the tag matches `plugin.cfg`, builds
   `godot-pi-v0.2.0.zip` from `addons/pi_agent/`, and publishes a GitHub Release. `v0.x` releases are marked
   as pre-releases.

## License

[MIT](LICENSE) © Yanek Yuk. Pi is a separate project under its own [license](https://github.com/earendil-works/pi).
