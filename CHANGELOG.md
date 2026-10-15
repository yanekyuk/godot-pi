# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [SemVer](https://semver.org/).

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

[0.1.0]: https://github.com/yanekyuk/godot-pi/releases/tag/v0.1.0
