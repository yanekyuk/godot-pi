# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [SemVer](https://semver.org/).

## [0.3.1] - 2026-10-16

### Fixed

- Hide empty, whitespace-only, and signature-only thinking blocks instead of displaying blank expandable cards. Readable thinking still streams normally; explicitly redacted content is labeled as unavailable from the provider.

## [0.3.0] - 2026-10-16

### Added

- Paste clipboard images into prompts as numbered `[image #1]` markers. Images are sent through RPC, shown as transcript previews, and retained when restoring rejected or aborted queued prompts.
- Collapsible, read-only TODO panel for the `rpiv-todo` Pi extension, with completion progress, task statuses, active forms and dependency details. Restores task state from the active session branch, including pre-compaction and nested-tool snapshots.
- Headless feature tests and isolated editor integration tests using a fake RPC client.

## [0.2.0] - 2026-10-15

### Added

- Per-project sessions. The dock remembers the session it used last in each project (in Godot's project metadata) and reopens it when Pi starts.
- **History** button with a session browser for the project. Filter, open/switch, rename the active session, delete (moves to trash), show in file manager.

### Changed

- Replaced `launch/continue_last_session` (bool) with `launch/startup_session`: Resume Last Dock Session (default), Continue Most Recent, New Session. If the old setting was on, it becomes Continue Most Recent.
- Restart keeps the current session instead of starting a new one.

## [0.1.0] - 2026-10-15

First experimental release.

### Added

- Pi dock (`EditorDock`) that runs `pi --mode rpc` as a child process with non-blocking pipes.
- Streaming transcript: Markdown text, collapsible thinking blocks, tool cards with live output, edit diffs and "open" links.
- Toolbar: model picker, thinking level picker, new session, restart, context/token/cost stats.
- Prompt input: Enter to send, steer or follow-up while Pi is running, Esc/Stop to abort, `!cmd` and `!!cmd` shell commands, `/` command menu.
- Context toggle that attaches the open scene, selected nodes, current script and code selection.
- Right-click "Add to Pi" entries in the code editor, FileSystem dock and Scene dock.
- Pi extension UI support: select/confirm/input/editor dialogs, notifications, status, widgets, editor text.
- Saves open scripts before prompts. Rescans the filesystem and reloads touched scripts and scenes after edits.
- Editor Settings under "Pi Agent".

[0.3.1]: https://github.com/yanekyuk/godot-pi/releases/tag/v0.3.1
[0.3.0]: https://github.com/yanekyuk/godot-pi/releases/tag/v0.3.0
[0.2.0]: https://github.com/yanekyuk/godot-pi/releases/tag/v0.2.0
[0.1.0]: https://github.com/yanekyuk/godot-pi/releases/tag/v0.1.0
