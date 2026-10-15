@tool
extends RefCounted
## Editor settings for the Pi Agent plugin (Editor > Editor Settings > Pi Agent).

const COMMAND := "pi_agent/launch/command"
const EXTRA_ARGS := "pi_agent/launch/extra_args"
const USE_LOGIN_SHELL := "pi_agent/launch/use_login_shell"
const AUTO_START := "pi_agent/launch/auto_start"
const CONTINUE_LAST := "pi_agent/launch/continue_last_session"
const SAVE_BEFORE_PROMPT := "pi_agent/behavior/save_scripts_before_prompt"
const RELOAD_AFTER_EDITS := "pi_agent/behavior/reload_after_edits"
const ATTACH_CONTEXT := "pi_agent/behavior/attach_editor_context"
const SHOW_THINKING := "pi_agent/display/show_thinking"

const DEFS := [
	[COMMAND, "pi", TYPE_STRING, PROPERTY_HINT_NONE, "", "Command used to launch Pi. Can be an absolute path or e.g. 'node /path/to/cli.js'."],
	[EXTRA_ARGS, "", TYPE_STRING, PROPERTY_HINT_NONE, "", "Extra CLI arguments, space separated (e.g. '--provider anthropic --model claude-sonnet-4-5')."],
	[USE_LOGIN_SHELL, true, TYPE_BOOL, PROPERTY_HINT_NONE, "", "Launch through a login shell ($SHELL -lc) so PATH matches your terminal."],
	[AUTO_START, true, TYPE_BOOL, PROPERTY_HINT_NONE, "", "Start Pi when the plugin loads."],
	[CONTINUE_LAST, false, TYPE_BOOL, PROPERTY_HINT_NONE, "", "Pass --continue to resume the most recent session for this project."],
	[SAVE_BEFORE_PROMPT, true, TYPE_BOOL, PROPERTY_HINT_NONE, "", "Save all open scripts before sending a prompt, so Pi sees what you see."],
	[RELOAD_AFTER_EDITS, true, TYPE_BOOL, PROPERTY_HINT_NONE, "", "Rescan the filesystem and reload open scripts after Pi edits files."],
	[ATTACH_CONTEXT, true, TYPE_BOOL, PROPERTY_HINT_NONE, "", "Default state of the 'Context' toggle (attach open scene, selection, current script)."],
	[SHOW_THINKING, true, TYPE_BOOL, PROPERTY_HINT_NONE, "", "Show model thinking blocks in the transcript."],
]


static func register() -> void:
	var es := EditorInterface.get_editor_settings()
	for d in DEFS:
		var key: String = d[0]
		if not es.has_setting(key):
			es.set_setting(key, d[1])
		es.set_initial_value(key, d[1], false)
		es.add_property_info({"name": key, "type": d[2], "hint": d[3], "hint_string": d[4]})


static func get_value(key: String) -> Variant:
	var es := EditorInterface.get_editor_settings()
	if es.has_setting(key):
		return es.get_setting(key)
	for d in DEFS:
		if d[0] == key:
			return d[1]
	return null


static func get_extra_args() -> PackedStringArray:
	var out := PackedStringArray()
	for part in str(get_value(EXTRA_ARGS)).split(" ", false):
		out.append(part)
	if get_value(CONTINUE_LAST) and not out.has("--continue") and not out.has("-c"):
		out.append("--continue")
	return out
