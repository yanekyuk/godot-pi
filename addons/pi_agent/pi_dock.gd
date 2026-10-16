@tool
extends VBoxContainer
## Chat panel for Pi: toolbar, streaming transcript, tool cards, prompt input.

const PiSettings := preload("pi_settings.gd")
const PiFormat := preload("pi_format.gd")
const PiEditorContext := preload("pi_editor_context.gd")
const PiExtensionUI := preload("pi_extension_ui.gd")
const PiRpcClient := preload("pi_rpc_client.gd")
const PiSessions := preload("pi_sessions.gd")
const PiPromptEdit := preload("pi_prompt_edit.gd")
const PiTodoPanel := preload("pi_todo_panel.gd")

const EDIT_TOOLS := ["edit", "write", "bash", "multi_edit", "apply_patch"]
const MAX_OUTPUT_CHARS := 20000

var client: PiRpcClient
var ext_ui: PiExtensionUI

# --- UI ---
var _status_dot: Label
var _model_btn: OptionButton
var _thinking_btn: OptionButton
var _new_btn: Button
var _sessions_btn: Button
var _restart_btn: Button
var _widgets_above: VBoxContainer
var _widgets_below: VBoxContainer
var _scroll: ScrollContainer
var _transcript: VBoxContainer
var _queue_label: Label
var _prompt_edit: PiPromptEdit
var _todo_panel: PiTodoPanel
var _context_toggle: CheckBox
var _commands_btn: MenuButton
var _stats_label: Label
var _abort_btn: Button
var _send_btn: Button
var _ext_status_label: Label
var _fs_timer: Timer
var _sessions_dialog: ConfirmationDialog
var _sessions_filter: LineEdit
var _sessions_tree: Tree
var _sessions_info: Label
var _sessions_rename_btn: Button
var _sessions_delete_btn: Button
var _rename_dialog: ConfirmationDialog
var _rename_edit: LineEdit
var _delete_dialog: ConfirmationDialog

# --- theme ---
var _mono: Font
var _c_accent := Color(0.44, 0.73, 0.98)
var _c_error := Color(1, 0.47, 0.42)
var _c_warning := Color(1, 0.87, 0.4)
var _c_success := Color(0.45, 0.95, 0.5)
var _c_dim := Color(1, 1, 1, 0.55)
var _c_code := Color(0.8, 0.85, 0.95)
var _c_user_bg := Color(1, 1, 1, 0.06)
var _c_card_bg := Color(0, 0, 0, 0.18)

# --- state ---
var _busy := false
var _stick_bottom := true
var _models: Array = [] # [[provider, id], ...] by item index
var _asst_box: VBoxContainer
var _blocks := {} # contentIndex(int) -> {kind, text, label} or {kind:"tool", id}
var _dirty_blocks: Array = [] # block/card dicts flagged with `_dirty`
var _tool_cards := {} # toolCallId -> card dict
var _bash_cards := {} # request id -> card dict
var _statuses := {} # extension status key -> text
var _widgets := {} # widget key -> Label
var _fs_dirty_paths := {} # res path -> true
var _fs_dirty := false
var _session_file := "" # active session file reported by Pi
var _session_name := ""
var _sessions: Array = [] # last listing (PiSessions.list_sessions)
var _todo_revision := 0 # discard stale history responses after live updates
var _queued_drafts: Array = [] # {message, draft}, preserving images on clear_queue


func setup(p_client: PiRpcClient) -> void:
	client = p_client
	client.started.connect(_on_started)
	client.exited.connect(_on_exited)
	client.event_received.connect(_on_event)
	client.ui_request.connect(_on_ui_request)

	ext_ui = PiExtensionUI.new()
	ext_ui.name = "ExtensionUI"
	ext_ui.client = client
	ext_ui.notify_requested.connect(_on_ext_notify)
	ext_ui.status_changed.connect(_on_ext_status)
	ext_ui.widget_changed.connect(_on_ext_widget)
	ext_ui.title_changed.connect(_on_ext_title)
	ext_ui.editor_text_requested.connect(_on_ext_editor_text)
	add_child(ext_ui)

	_load_theme()
	_build_ui()
	_set_running(false)


# ------------------------------------------------------------------ lifecycle

## Starts Pi using the startup policy (Editor Settings > Pi Agent > Launch > Startup Session).
func start_agent() -> void:
	match int(PiSettings.get_value(PiSettings.STARTUP_SESSION)):
		PiSettings.StartupSession.RESUME_LAST:
			_launch(_existing(PiSessions.get_last_session()))
		PiSettings.StartupSession.CONTINUE_RECENT:
			_launch("", true)
		_:
			_launch("")


## Restarts Pi and keeps the current session (if it has been saved to disk).
func restart_agent() -> void:
	var path := _session_file if not _session_file.is_empty() else PiSessions.get_last_session()
	_launch(_existing(path))


func _existing(path: String) -> String:
	return path if not path.is_empty() and FileAccess.file_exists(path) else ""


## Spawns Pi. `session_path` resumes that file; `continue_recent` passes --continue.
## Neither is added when the user's extra_args already pick a session.
func _launch(session_path: String, continue_recent := false) -> void:
	if client == null:
		return
	var args := PiSettings.get_extra_args()
	if not PiSettings.extra_args_pick_session():
		if not session_path.is_empty():
			args.append_array(["--session", session_path])
		elif continue_recent:
			args.append("--continue")
	_session_file = ""
	_session_name = ""
	ext_ui.close_all()
	_clear_transcript()
	_reset_todos()
	_queued_drafts.clear()
	_statuses.clear()
	_refresh_ext_status()
	for k in _widgets.keys():
		_widgets[k].queue_free()
	_widgets.clear()
	var cmd := str(PiSettings.get_value(PiSettings.COMMAND)).strip_edges()
	if cmd.is_empty():
		cmd = "pi"
	var err: Error = client.start(PiEditorContext.project_dir(), cmd, args, bool(PiSettings.get_value(PiSettings.USE_LOGIN_SHELL)))
	if err != OK:
		_notice("Failed to start Pi (`%s`). Check Editor Settings > Pi Agent > Launch." % cmd, _c_error)


func _on_started() -> void:
	_set_running(true)
	_notice("Pi started in %s" % PiEditorContext.project_dir(), _c_dim)
	_refresh_all()


func _on_exited(code: int) -> void:
	_set_running(false)
	_set_busy(false)
	if code == -1:
		_notice("Pi stopped.", _c_dim)
		return
	var tail: String = client.get_stderr_tail().strip_edges()
	_notice("Pi exited (code %d).%s" % [code, ("\n" + tail) if not tail.is_empty() else ""], _c_error)


func _refresh_all() -> void:
	client.request({"type": "get_state"}, _on_state)
	client.request({"type": "get_available_models"}, _on_models)
	client.request({"type": "get_commands"}, _on_commands)
	client.request({"type": "get_messages"}, _on_messages)
	_refresh_thinking_levels()
	_refresh_stats()


func _process(_delta: float) -> void:
	if _dirty_blocks.is_empty():
		return
	var list := _dirty_blocks
	_dirty_blocks = []
	for b in list:
		b._dirty = false
		_render_block(b)


# ------------------------------------------------------------------ UI build

func _load_theme() -> void:
	var t := EditorInterface.get_editor_theme()
	if t == null:
		return
	_mono = t.get_font("source", "EditorFonts")
	if t.has_color("accent_color", "Editor"):
		_c_accent = t.get_color("accent_color", "Editor")
	if t.has_color("error_color", "Editor"):
		_c_error = t.get_color("error_color", "Editor")
	if t.has_color("warning_color", "Editor"):
		_c_warning = t.get_color("warning_color", "Editor")
	if t.has_color("success_color", "Editor"):
		_c_success = t.get_color("success_color", "Editor")
	if t.has_color("font_color", "Editor"):
		var f := t.get_color("font_color", "Editor")
		_c_dim = Color(f, 0.55)
		_c_user_bg = Color(f, 0.07)
	if t.has_color("dark_color_2", "Editor"):
		_c_card_bg = Color(t.get_color("dark_color_2", "Editor"), 0.6)


func _build_ui() -> void:
	size_flags_vertical = SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 4)
	custom_minimum_size = Vector2(240, 200)

	# Toolbar
	var bar := HBoxContainer.new()
	add_child(bar)
	_status_dot = Label.new()
	_status_dot.text = "●"
	_status_dot.mouse_filter = MOUSE_FILTER_PASS
	bar.add_child(_status_dot)

	_model_btn = OptionButton.new()
	_model_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	_model_btn.fit_to_longest_item = false
	_model_btn.clip_text = true
	_model_btn.tooltip_text = "Model"
	_model_btn.item_selected.connect(_on_model_selected)
	bar.add_child(_model_btn)

	_thinking_btn = OptionButton.new()
	_thinking_btn.tooltip_text = "Thinking level"
	_thinking_btn.item_selected.connect(_on_thinking_selected)
	bar.add_child(_thinking_btn)

	_new_btn = _icon_button("New", "New session")
	_new_btn.pressed.connect(_on_new_session)
	bar.add_child(_new_btn)

	_sessions_btn = _icon_button("History", "Sessions of this project")
	_sessions_btn.pressed.connect(open_sessions_dialog)
	bar.add_child(_sessions_btn)

	_restart_btn = _icon_button("Reload", "Restart Pi (keeps the current session)")
	_restart_btn.pressed.connect(restart_agent)
	bar.add_child(_restart_btn)

	_widgets_above = VBoxContainer.new()
	add_child(_widgets_above)

	# Transcript
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	_transcript = VBoxContainer.new()
	_transcript.size_flags_horizontal = SIZE_EXPAND_FILL
	_transcript.add_theme_constant_override("separation", 8)
	_scroll.add_child(_transcript)
	var vbar := _scroll.get_v_scroll_bar()
	vbar.changed.connect(_on_vbar_changed)
	vbar.value_changed.connect(_on_vbar_value_changed)

	_queue_label = _small_label()
	_queue_label.visible = false
	_queue_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_queue_label.add_theme_color_override("font_color", _c_warning)
	add_child(_queue_label)

	_widgets_below = VBoxContainer.new()
	add_child(_widgets_below)

	_todo_panel = PiTodoPanel.new()
	add_child(_todo_panel)

	# Input
	_prompt_edit = PiPromptEdit.new()
	_prompt_edit.image_paste_failed.connect(func(message: String) -> void: _notice(message, _c_error))
	_prompt_edit.custom_minimum_size.y = 72
	_prompt_edit.placeholder_text = "Ask Pi…  (Enter send · Shift+Enter newline · paste images · !cmd · /command)"
	_prompt_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_prompt_edit.scroll_fit_content_height = true
	_prompt_edit.gui_input.connect(_on_input_gui_input)
	add_child(_prompt_edit)

	var row := HBoxContainer.new()
	add_child(row)
	_context_toggle = CheckBox.new()
	_context_toggle.text = "Context"
	_context_toggle.tooltip_text = "Attach editor context: open scene, selected nodes, current script and code selection."
	_context_toggle.button_pressed = bool(PiSettings.get_value(PiSettings.ATTACH_CONTEXT))
	row.add_child(_context_toggle)

	_commands_btn = MenuButton.new()
	_commands_btn.text = "/"
	_commands_btn.tooltip_text = "Commands, prompt templates and skills"
	_commands_btn.flat = false
	_commands_btn.get_popup().id_pressed.connect(_on_command_picked)
	row.add_child(_commands_btn)

	_stats_label = _small_label()
	_stats_label.size_flags_horizontal = SIZE_EXPAND_FILL
	_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_stats_label.clip_text = true
	_stats_label.mouse_filter = MOUSE_FILTER_PASS
	row.add_child(_stats_label)

	_abort_btn = Button.new()
	_abort_btn.text = "Stop"
	_abort_btn.tooltip_text = "Abort the current run (clears queued messages back into the input)"
	_abort_btn.pressed.connect(_on_abort)
	row.add_child(_abort_btn)

	_send_btn = Button.new()
	_send_btn.text = "Send"
	_send_btn.pressed.connect(_submit.bind(false))
	row.add_child(_send_btn)

	_ext_status_label = _small_label()
	_ext_status_label.visible = false
	_ext_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_ext_status_label)

	_fs_timer = Timer.new()
	_fs_timer.one_shot = true
	_fs_timer.wait_time = 0.75
	_fs_timer.timeout.connect(_sync_filesystem)
	add_child(_fs_timer)


func _icon_button(icon_name: String, tooltip: String) -> Button:
	var b := Button.new()
	b.flat = true
	b.tooltip_text = tooltip
	var t := EditorInterface.get_editor_theme()
	if t and t.has_icon(icon_name, "EditorIcons"):
		b.icon = t.get_icon(icon_name, "EditorIcons")
	else:
		b.text = tooltip
	return b


func _small_label() -> Label:
	var l := Label.new()
	l.add_theme_color_override("font_color", _c_dim)
	l.add_theme_font_size_override("font_size", 12)
	return l


func _rich(selectable := true) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.selection_enabled = selectable
	r.context_menu_enabled = true
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.size_flags_horizontal = SIZE_EXPAND_FILL
	if _mono:
		r.add_theme_font_override("mono_font", _mono)
	r.meta_clicked.connect(_on_meta_clicked)
	return r


func _panel(bg: Color, margin := 6) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(margin)
	p.add_theme_stylebox_override("panel", sb)
	p.size_flags_horizontal = SIZE_EXPAND_FILL
	return p


# ------------------------------------------------------------------ state

func _set_running(running: bool) -> void:
	_status_dot.add_theme_color_override("font_color", _c_success if running else _c_dim)
	_status_dot.tooltip_text = "Pi is running" if running else "Pi is not running"
	_model_btn.disabled = not running
	_thinking_btn.disabled = not running
	_new_btn.disabled = not running
	_send_btn.disabled = not running
	_abort_btn.disabled = true


func _set_busy(busy: bool) -> void:
	_busy = busy
	var running: bool = client != null and client.is_running()
	_abort_btn.disabled = not (busy and running)
	_send_btn.text = "Steer" if busy else "Send"
	_send_btn.tooltip_text = "Queue a steering message (Alt+Enter: follow-up)" if busy else "Send prompt"
	if running:
		_status_dot.add_theme_color_override("font_color", _c_warning if busy else _c_success)
		_status_dot.tooltip_text = "Pi is working…" if busy else "Pi is idle"


func _on_state(res: Dictionary) -> void:
	if not res.get("success", false):
		return
	var d: Dictionary = res.get("data", {})
	var m = d.get("model")
	if m is Dictionary:
		_select_model(str(m.get("provider", "")), str(m.get("id", "")))
	_select_thinking(str(d.get("thinkingLevel", "")))
	_set_busy(bool(d.get("isStreaming", false)))
	var name_ = d.get("sessionName")
	_session_name = str(name_) if name_ != null else ""
	var file_ = d.get("sessionFile")
	_session_file = str(file_) if file_ != null else ""
	PiSessions.remember(_session_file)
	var label := _session_name if not _session_name.is_empty() else str(d.get("sessionId", "?"))
	_new_btn.tooltip_text = "New session (current: %s)" % label
	_sessions_btn.tooltip_text = "Sessions of this project (current: %s)" % label
	if _sessions_dialog and _sessions_dialog.visible:
		_reload_sessions()


func _on_models(res: Dictionary) -> void:
	if not res.get("success", false):
		return
	_model_btn.clear()
	_models.clear()
	var models = res.get("data", {}).get("models", [])
	if not (models is Array):
		return
	models.sort_custom(func(a, b): return str(a.get("provider", "")) + "/" + str(a.get("id", "")) < str(b.get("provider", "")) + "/" + str(b.get("id", "")))
	for m in models:
		var label := "%s/%s" % [m.get("provider", ""), m.get("id", "")]
		_model_btn.add_item(label)
		_model_btn.set_item_tooltip(_model_btn.item_count - 1, str(m.get("name", label)))
		_models.append([str(m.get("provider", "")), str(m.get("id", ""))])
	client.request({"type": "get_state"}, _on_state)


func _select_model(provider: String, id: String) -> void:
	for i in _models.size():
		if _models[i][0] == provider and _models[i][1] == id:
			_model_btn.select(i)
			_model_btn.tooltip_text = "%s/%s" % [provider, id]
			return
	if _models.is_empty() and not id.is_empty():
		_model_btn.clear()
		_model_btn.add_item("%s/%s" % [provider, id])
		_models.append([provider, id])
		_model_btn.select(0)


func _on_model_selected(index: int) -> void:
	if index < 0 or index >= _models.size():
		return
	var m: Array = _models[index]
	var cb := func(res: Dictionary) -> void:
		if not res.get("success", false):
			_notice("set_model failed: %s" % res.get("error", "?"), _c_error)
			client.request({"type": "get_state"}, _on_state)
		else:
			_refresh_thinking_levels()
			_refresh_stats()
	client.request({"type": "set_model", "provider": m[0], "modelId": m[1]}, cb)


func _refresh_thinking_levels() -> void:
	var cb := func(res: Dictionary) -> void:
		if not res.get("success", false):
			return
		var current := _thinking_btn.get_item_text(_thinking_btn.selected) if _thinking_btn.selected >= 0 else ""
		_thinking_btn.clear()
		for l in res.get("data", {}).get("levels", []):
			_thinking_btn.add_item(str(l))
		_select_thinking(current)
		client.request({"type": "get_state"}, _on_state)
	client.request({"type": "get_available_thinking_levels"}, cb)


func _select_thinking(level: String) -> void:
	for i in _thinking_btn.item_count:
		if _thinking_btn.get_item_text(i) == level:
			_thinking_btn.select(i)
			return


func _on_thinking_selected(index: int) -> void:
	client.request({"type": "set_thinking_level", "level": _thinking_btn.get_item_text(index)})


func _on_commands(res: Dictionary) -> void:
	if not res.get("success", false):
		return
	var popup := _commands_btn.get_popup()
	popup.clear()
	var cmds = res.get("data", {}).get("commands", [])
	if not (cmds is Array):
		return
	cmds.sort_custom(func(a, b): return str(a.get("name", "")) < str(b.get("name", "")))
	for c in cmds:
		var desc := str(c.get("description", ""))
		popup.add_item("/" + str(c.get("name", "")))
		var idx := popup.item_count - 1
		popup.set_item_metadata(idx, str(c.get("name", "")))
		popup.set_item_tooltip(idx, "%s\n[%s]" % [desc, c.get("source", "")])
	if popup.item_count == 0:
		popup.add_item("(no commands)")
		popup.set_item_disabled(0, true)


func _on_command_picked(id: int) -> void:
	var popup := _commands_btn.get_popup()
	var idx := popup.get_item_index(id)
	var name_ = popup.get_item_metadata(idx)
	if name_ == null:
		return
	_prompt_edit.reset_draft()
	_prompt_edit.text = "/%s " % name_
	_prompt_edit.set_caret_line(0)
	_prompt_edit.set_caret_column(_prompt_edit.text.length())
	_prompt_edit.grab_focus()


func _refresh_stats() -> void:
	var cb := func(res: Dictionary) -> void:
		if not res.get("success", false):
			return
		var d: Dictionary = res.get("data", {})
		var parts := PackedStringArray()
		var ctx = d.get("contextUsage")
		if ctx is Dictionary and ctx.get("percent") != null:
			parts.append("ctx %d%%" % int(ctx.get("percent")))
		var tokens = d.get("tokens", {})
		if tokens is Dictionary and float(tokens.get("total", 0)) > 0:
			parts.append(PiFormat.format_tokens(float(tokens.get("total", 0))) + " tok")
		var cost := float(d.get("cost", 0))
		if cost > 0:
			parts.append("$%.3f" % cost)
		_stats_label.text = " · ".join(parts)
		_stats_label.tooltip_text = JSON.stringify(tokens, "  ") if tokens is Dictionary else ""
	client.request({"type": "get_session_stats"}, cb)


# ------------------------------------------------------------------ input

func _on_input_gui_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER:
		if k.shift_pressed:
			return # newline
		_prompt_edit.accept_event()
		_submit(k.alt_pressed)
	elif k.keycode == KEY_ESCAPE and _busy:
		_prompt_edit.accept_event()
		_on_abort()


func _submit(follow_up: bool = false) -> void:
	if client == null or not client.is_running():
		_notice("Pi is not running. Press the restart button.", _c_error)
		return
	var draft := _prompt_edit.get_prompt()
	var text := str(draft.text).strip_edges()
	if text.is_empty():
		return
	if text.begins_with("!") and not draft.images.is_empty():
		_notice("Shell commands cannot include images. Remove the image markers or send a chat prompt.", _c_warning)
		return
	_prompt_edit.reset_draft()

	if text.begins_with("!"):
		var exclude := text.begins_with("!!")
		_run_bash(text.substr(2 if exclude else 1).strip_edges(), exclude)
		return

	if PiSettings.get_value(PiSettings.SAVE_BEFORE_PROMPT):
		var se := EditorInterface.get_script_editor()
		if se and se.has_method("save_all_scripts"):
			se.save_all_scripts()

	var message := text
	if _context_toggle.button_pressed and not text.begins_with("/"):
		message += "\n\n" + PiEditorContext.build()

	var cmd := {"type": "prompt", "message": message}
	if not draft.images.is_empty():
		cmd["images"] = draft.images
	var queued := {"message": message, "draft": draft}
	if _busy:
		cmd["streamingBehavior"] = "followUp" if follow_up else "steer"
		_queued_drafts.append(queued)
	var cb := func(res: Dictionary) -> void:
		if not res.get("success", false):
			_queued_drafts.erase(queued)
			_notice("Prompt rejected: %s" % res.get("error", "?"), _c_error)
			_prompt_edit.restore_prompt(draft)
		elif str(res.get("data", {}).get("disposition", "")) == "handled":
			_queued_drafts.erase(queued)
			_refresh_all_light()
	client.request(cmd, cb)
	_stick_bottom = true


## After an extension command, models/commands/session may have changed.
func _refresh_all_light() -> void:
	client.request({"type": "get_state"}, _on_state)
	_refresh_todos()
	_refresh_stats()


func _on_abort() -> void:
	var cb := func(res: Dictionary) -> void:
		if res.get("success", false):
			var d: Dictionary = res.get("data", {})
			for s in d.get("steering", []) + d.get("followUp", []):
				var draft := _take_queued_draft(str(s))
				_prompt_edit.restore_prompt(draft if not draft.is_empty() else {"text": str(s), "images": []})
		client.request({"type": "abort"})
	client.request({"type": "clear_queue"}, cb)


func _on_new_session() -> void:
	var cb := func(res: Dictionary) -> void:
		if not res.get("success", false):
			_notice("new_session failed: %s" % res.get("error", "?"), _c_error)
			return
		if res.get("data", {}).get("cancelled", false):
			_notice("New session cancelled by an extension.", _c_warning)
			return
		_clear_transcript()
		_reset_todos()
		_queued_drafts.clear()
		_notice("New session.", _c_dim)
		_refresh_all_light()
	client.request({"type": "new_session"}, cb)


func _run_bash(command: String, exclude: bool) -> void:
	if command.is_empty():
		return
	var card := _make_tool_card("$", {"command": command}, _transcript)
	card.out_text = ""
	_set_card_status(card, "running")
	var cb := func(res: Dictionary) -> void:
		if not res.get("success", false):
			card.out_text += "\n" + str(res.get("error", "failed"))
			_set_card_status(card, "error")
		else:
			var d: Dictionary = res.get("data", {})
			var out := str(d.get("output", ""))
			if not out.is_empty():
				card.out_text = out
			if d.get("truncated", false):
				card.out_text += "\n…(truncated, full output: %s)" % d.get("fullOutputPath", "?")
			var code = d.get("exitCode")
			_set_card_status(card, "ok" if code != null and int(code) == 0 else "error")
			card.suffix = "  [exit %s]" % ("?" if code == null else str(int(code)))
		_mark_dirty(card)
		_fs_dirty = true
		_fs_timer.start()
	var id := client.request({"type": "bash", "command": command, "excludeFromContext": exclude}, cb)
	_bash_cards[id] = card
	_set_card_expanded(card, true)


# ------------------------------------------------------------------ sessions

## The active session, or the one the dock will resume when Pi is not running.
func _current_session_path() -> String:
	return _session_file if not _session_file.is_empty() else PiSessions.get_last_session()


func open_sessions_dialog() -> void:
	if _sessions_dialog == null:
		_build_sessions_dialog()
	_sessions_filter.text = ""
	_reload_sessions()
	var scale := EditorInterface.get_editor_scale()
	_sessions_dialog.popup_centered_clamped(Vector2i(Vector2(760, 460) * scale), 0.9)
	_sessions_filter.grab_focus.call_deferred()


func _build_sessions_dialog() -> void:
	_sessions_dialog = ConfirmationDialog.new()
	_sessions_dialog.title = "Pi Sessions"
	_sessions_dialog.ok_button_text = "Open"
	_sessions_dialog.cancel_button_text = "Close"
	_sessions_dialog.dialog_hide_on_ok = false
	_sessions_dialog.confirmed.connect(_open_selected_session)
	_sessions_dialog.custom_action.connect(_on_sessions_action)

	var box := VBoxContainer.new()
	_sessions_dialog.add_child(box)
	_sessions_filter = LineEdit.new()
	_sessions_filter.placeholder_text = "Filter by name, first prompt or id"
	_sessions_filter.clear_button_enabled = true
	_sessions_filter.text_changed.connect(func(_t: String) -> void: _populate_sessions())
	box.add_child(_sessions_filter)
	_sessions_dialog.register_text_enter(_sessions_filter)

	_sessions_tree = Tree.new()
	_sessions_tree.size_flags_vertical = SIZE_EXPAND_FILL
	_sessions_tree.hide_root = true
	_sessions_tree.columns = 3
	_sessions_tree.column_titles_visible = true
	_sessions_tree.set_column_title(0, "Session")
	_sessions_tree.set_column_title(1, "Updated")
	_sessions_tree.set_column_title(2, "Size")
	_sessions_tree.set_column_expand(0, true)
	for c in [1, 2]:
		_sessions_tree.set_column_expand(c, false)
		_sessions_tree.set_column_clip_content(c, false)
	_sessions_tree.select_mode = Tree.SELECT_ROW
	_sessions_tree.item_selected.connect(_update_session_buttons)
	_sessions_tree.item_activated.connect(_open_selected_session)
	box.add_child(_sessions_tree)

	_sessions_info = _small_label()
	_sessions_info.clip_text = true
	_sessions_info.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	box.add_child(_sessions_info)

	_sessions_rename_btn = _sessions_dialog.add_button("Rename…", false, "rename")
	_sessions_delete_btn = _sessions_dialog.add_button("Delete…", false, "delete")
	_sessions_dialog.add_button("Show in File Manager", false, "show")
	add_child(_sessions_dialog)

	_rename_dialog = ConfirmationDialog.new()
	_rename_dialog.title = "Rename Session"
	_rename_edit = LineEdit.new()
	_rename_edit.custom_minimum_size.x = 360 * EditorInterface.get_editor_scale()
	_rename_dialog.add_child(_rename_edit)
	_rename_dialog.register_text_enter(_rename_edit)
	_rename_dialog.confirmed.connect(_rename_current_session)
	add_child(_rename_dialog)

	_delete_dialog = ConfirmationDialog.new()
	_delete_dialog.title = "Delete Session"
	_delete_dialog.ok_button_text = "Move to Trash"
	_delete_dialog.confirmed.connect(_delete_selected_session)
	add_child(_delete_dialog)


## Re-reads the session directory.
func _reload_sessions() -> void:
	_sessions = PiSessions.list_sessions()
	_populate_sessions()


## Rebuilds the tree from `_sessions`, applying the filter.
func _populate_sessions() -> void:
	var keep := str(_selected_session().get("path", ""))
	var current := _current_session_path()
	var filter := _sessions_filter.text.strip_edges().to_lower()
	_sessions_tree.clear()
	var root := _sessions_tree.create_item()
	var rows: Array = _sessions.duplicate()
	# A new session is only written to disk after its first prompt; still show it.
	if not _session_file.is_empty() and not FileAccess.file_exists(_session_file):
		rows.push_front({"path": _session_file, "unsaved": true, "title": _session_name if not _session_name.is_empty() else "New session", "name": _session_name, "first_message": "", "id": "", "modified": 0, "size": 0})
	var shown := 0
	for s in rows:
		if not filter.is_empty():
			var hay := ("%s\n%s\n%s" % [s.title, s.first_message, s.id]).to_lower()
			if not hay.contains(filter):
				continue
		var it := _sessions_tree.create_item(root)
		var is_current: bool = s.path == current
		var title: String = s.title
		if s.get("unsaved", false):
			title += "  (not saved until the first prompt)"
		it.set_text(0, ("● " if is_current else "") + title)
		it.set_text(1, PiSessions.format_time(int(s.modified)))
		it.set_text(2, PiSessions.format_size(int(s.size)) if not s.get("unsaved", false) else "")
		it.set_text_alignment(2, HORIZONTAL_ALIGNMENT_RIGHT)
		var tip := str(s.first_message).left(600)
		if not str(s.name).is_empty():
			tip = "%s\n\n%s" % [s.name, tip]
		it.set_tooltip_text(0, (tip + "\n\n" if not tip.strip_edges().is_empty() else "") + str(s.path))
		if is_current:
			for c in 3:
				it.set_custom_color(c, _c_accent)
		it.set_metadata(0, s)
		if s.path == keep or (keep.is_empty() and shown == 0):
			it.select(0)
		shown += 1
	_sessions_info.text = "%d of %d sessions in %s" % [shown, rows.size(), PiSessions.get_session_dir()] if not rows.is_empty() else "No sessions yet in %s" % PiSessions.get_session_dir()
	_sessions_info.tooltip_text = PiSessions.get_session_dir()
	_update_session_buttons()


func _selected_session() -> Dictionary:
	if _sessions_tree == null:
		return {}
	var it := _sessions_tree.get_selected()
	if it == null:
		return {}
	var m = it.get_metadata(0)
	return m if m is Dictionary else {}


func _update_session_buttons() -> void:
	var s := _selected_session()
	var running := client != null and client.is_running()
	var is_current: bool = not s.is_empty() and s.path == _current_session_path()
	var is_active: bool = running and not s.is_empty() and s.path == _session_file
	_sessions_dialog.get_ok_button().disabled = s.is_empty() or is_active
	_sessions_dialog.get_ok_button().tooltip_text = "This is the active session." if is_active else ("Switch Pi to this session." if running else "Start Pi with this session.")
	_sessions_rename_btn.disabled = not is_active
	_sessions_rename_btn.tooltip_text = "Rename the active session." if is_active else "Only the active session can be renamed. Open it first."
	_sessions_delete_btn.disabled = s.is_empty() or is_current or s.get("unsaved", false)
	_sessions_delete_btn.tooltip_text = "Switch to another session before deleting this one." if is_current else "Move the session file to the trash."


func _on_sessions_action(action: StringName) -> void:
	var s := _selected_session()
	match str(action):
		"rename":
			_rename_edit.text = _session_name
			_rename_dialog.popup_centered()
			_rename_edit.grab_focus.call_deferred()
			_rename_edit.select_all.call_deferred()
		"delete":
			if s.is_empty():
				return
			_delete_dialog.dialog_text = "Move this session to the trash?\n\n%s\n\n%s" % [str(s.title).left(120), s.path]
			_delete_dialog.popup_centered()
		"show":
			var target := str(s.get("path", ""))
			if target.is_empty() or not FileAccess.file_exists(target):
				target = PiSessions.get_session_dir()
			OS.shell_show_in_file_manager(target)


func _open_selected_session() -> void:
	var s := _selected_session()
	if s.is_empty():
		return
	var path := str(s.path)
	if client == null or not client.is_running():
		_sessions_dialog.hide()
		_launch(_existing(path))
		return
	if path == _session_file:
		_sessions_dialog.hide()
		return
	if _busy:
		_sessions_info.text = "Pi is working. Stop it before switching sessions."
		return
	var title := str(s.title)
	var cb := func(res: Dictionary) -> void:
		if not res.get("success", false):
			_notice("switch_session failed: %s" % res.get("error", "?"), _c_error)
			return
		if res.get("data", {}).get("cancelled", false):
			_notice("Session switch cancelled by an extension.", _c_warning)
			return
		ext_ui.close_all()
		_clear_transcript()
		_reset_todos()
		_queued_drafts.clear()
		_notice("Switched to session: %s" % title.left(120), _c_dim)
		client.request({"type": "get_messages"}, _on_messages)
		_refresh_all_light()
		_refresh_thinking_levels()
	_sessions_dialog.hide()
	client.request({"type": "switch_session", "sessionPath": path}, cb)


func _rename_current_session() -> void:
	var name_ := _rename_edit.text.strip_edges()
	if name_.is_empty() or client == null or not client.is_running():
		return
	var cb := func(res: Dictionary) -> void:
		if not res.get("success", false):
			_notice("set_session_name failed: %s" % res.get("error", "?"), _c_error)
			return
		client.request({"type": "get_state"}, _on_state)
	client.request({"type": "set_session_name", "name": name_}, cb)


func _delete_selected_session() -> void:
	var s := _selected_session()
	if s.is_empty() or s.path == _current_session_path():
		return
	var err := PiSessions.trash(str(s.path))
	if err != OK:
		_sessions_info.text = "Could not move the session to the trash (%s)." % error_string(err)
		return
	_reload_sessions()


# ------------------------------------------------------------------ events

func _on_event(ev: Dictionary) -> void:
	match str(ev.get("type", "")):
		"agent_start":
			_set_busy(true)
		"agent_settled":
			_set_busy(false)
			_refresh_stats()
			if _fs_dirty:
				_sync_filesystem()
			if ev.get("aborted", false):
				_notice("Aborted.", _c_warning)
		"message_start":
			_on_message_start(ev.get("message", {}))
		"message_update":
			_on_message_update(ev.get("assistantMessageEvent", {}))
		"message_end":
			_on_message_end(ev.get("message", {}))
		"tool_execution_start":
			var card := _tool_card_for(str(ev.get("toolCallId", "")), str(ev.get("toolName", "")), ev.get("args"))
			_set_card_status(card, "running")
		"tool_execution_update":
			var card := _tool_card_for(str(ev.get("toolCallId", "")), str(ev.get("toolName", "")), ev.get("args"))
			_set_card_result(card, ev.get("partialResult"), false, true)
		"tool_execution_end":
			var card := _tool_card_for(str(ev.get("toolCallId", "")), str(ev.get("toolName", "")), null)
			_set_card_result(card, ev.get("result"), bool(ev.get("isError", false)), false)
			var ms = ev.get("durationMs")
			if ms != null:
				card.header.tooltip_text = "%.1fs" % (float(ms) / 1000.0)
			_on_tool_finished(str(ev.get("toolName", "")), card.args)
		"bash_execution_update":
			var id := str(ev.get("id", ""))
			if _bash_cards.has(id):
				var card: Dictionary = _bash_cards[id]
				card.out_text += str(ev.get("delta", ""))
				_mark_dirty(card)
		"entry_appended":
			var entry = ev.get("entry")
			if entry is Dictionary and entry.get("type") == "custom" and entry.get("customType") == PiTodoPanel.STATE_ENTRY_TYPE:
				_apply_todos(entry.get("data"))
		"queue_update":
			_on_queue_update(ev)
		"compaction_start":
			_notice("Compacting context (%s)…" % ev.get("reason", ""), _c_dim)
		"compaction_end":
			if ev.get("aborted", false):
				_notice("Compaction aborted.", _c_warning)
			elif ev.has("errorMessage"):
				_notice("Compaction failed: %s" % ev.get("errorMessage"), _c_error)
			else:
				_notice("Context compacted.", _c_dim)
			_refresh_stats()
		"auto_retry_start":
			_notice("Retrying (%d/%d) in %.1fs: %s" % [int(ev.get("attempt", 0)), int(ev.get("maxAttempts", 0)), float(ev.get("delayMs", 0)) / 1000.0, ev.get("errorMessage", "")], _c_warning)
		"auto_retry_end":
			if not ev.get("success", true):
				_notice("Retry failed: %s" % ev.get("finalError", ""), _c_error)
		"extension_error":
			_notice("Extension error (%s, %s): %s" % [str(ev.get("extensionPath", "")).get_file(), ev.get("event", ""), ev.get("error", "")], _c_error)
		"thinking_level_changed":
			_select_thinking(str(ev.get("level", "")))
		"session_info_changed":
			client.request({"type": "get_state"}, _on_state)


func _on_queue_update(ev: Dictionary) -> void:
	var lines := PackedStringArray()
	for s in ev.get("steering", []):
		lines.append("↳ steer: " + str(s).get_slice("\n", 0))
	for s in ev.get("followUp", []):
		lines.append("⏭ follow-up: " + str(s).get_slice("\n", 0))
	_queue_label.text = "\n".join(lines)
	_queue_label.visible = not lines.is_empty()


func _on_message_start(msg) -> void:
	if not (msg is Dictionary):
		return
	match str(msg.get("role", "")):
		"user":
			_take_queued_draft(PiFormat.content_text(msg.get("content", ""), false))
			_add_user_bubble(msg.get("content", ""))
		"assistant":
			_begin_assistant()


func _on_message_update(ame) -> void:
	if not (ame is Dictionary):
		return
	if _asst_box == null:
		_begin_assistant()
	var t := str(ame.get("type", ""))
	var idx := int(ame.get("contentIndex", -1))
	match t:
		"text_start":
			_block(idx, "text")
		"text_delta":
			var b := _block(idx, "text")
			b.text += str(ame.get("delta", ""))
			_mark_dirty(b)
		"text_end":
			var b := _block(idx, "text")
			b.text = str(ame.get("content", b.text))
			_mark_dirty(b)
		"thinking_start":
			_block(idx, "thinking")
		"thinking_delta":
			var b := _block(idx, "thinking")
			b.text += str(ame.get("delta", ""))
			_mark_dirty(b)
		"thinking_end":
			var b := _block(idx, "thinking")
			b.text = str(ame.get("content", b.text))
			_mark_dirty(b)
		"toolcall_start":
			var card := _tool_card_for(str(ame.get("id", "")), str(ame.get("toolName", "")), null)
			card.args_text = ""
			_blocks[idx] = {"kind": "tool", "id": str(ame.get("id", ""))}
		"toolcall_delta":
			var ref = _blocks.get(idx)
			if ref is Dictionary and ref.kind == "tool" and _tool_cards.has(ref.id):
				var card: Dictionary = _tool_cards[ref.id]
				card.args_text += str(ame.get("delta", ""))
				_mark_dirty(card)
		"toolcall_end":
			var tc = ame.get("toolCall")
			if tc is Dictionary:
				var card := _tool_card_for(str(tc.get("id", "")), str(tc.get("name", "")), tc.get("arguments"))
				_blocks[idx] = {"kind": "tool", "id": str(tc.get("id", ""))}
				_mark_dirty(card)


func _on_message_end(msg) -> void:
	if not (msg is Dictionary):
		return
	match str(msg.get("role", "")):
		"assistant":
			if _asst_box == null:
				_begin_assistant()
			_finalize_assistant(msg)
			_asst_box = null
			_blocks = {}
		"toolResult":
			var card := _tool_card_for(str(msg.get("toolCallId", "")), str(msg.get("toolName", "")), null)
			_set_card_result(card, msg, bool(msg.get("isError", false)), false)
		"custom":
			if msg.get("display", false):
				_add_custom_message(msg)


## Renders a full message (used for history).
func _render_message(msg) -> void:
	if not (msg is Dictionary):
		return
	match str(msg.get("role", "")):
		"user":
			_add_user_bubble(msg.get("content", ""))
		"assistant":
			_begin_assistant()
			_finalize_assistant(msg)
			_asst_box = null
			_blocks = {}
		"toolResult":
			var card := _tool_card_for(str(msg.get("toolCallId", "")), str(msg.get("toolName", "")), null)
			_set_card_result(card, msg, bool(msg.get("isError", false)), false)
		"bashExecution":
			var card := _make_tool_card("$", {"command": msg.get("command", "")}, _transcript)
			card.out_text = str(msg.get("output", ""))
			var code = msg.get("exitCode")
			_set_card_status(card, "ok" if code != null and int(code) == 0 else "error")
			_mark_dirty(card)
		"custom":
			if msg.get("display", false):
				_add_custom_message(msg)
		"compactionSummary":
			_notice("Earlier conversation was compacted (%s tokens summarized)." % PiFormat.format_tokens(float(msg.get("tokensBefore", 0))), _c_dim)
		"branchSummary":
			_notice("Branch summary: " + str(msg.get("summary", "")).left(300), _c_dim)


func _on_messages(res: Dictionary) -> void:
	if not res.get("success", false):
		return
	var msgs = res.get("data", {}).get("messages", [])
	if not (msgs is Array):
		return
	if msgs.is_empty():
		_refresh_todos()
		return
	_clear_transcript()
	var count := 0
	for m in msgs:
		_render_message(m)
		if m is Dictionary and str(m.get("role", "")) != "system":
			count += 1
	_notice("Loaded %d messages from session." % count, _c_dim)
	_stick_bottom = true
	# Replay may only include post-compaction messages. Restore from the full
	# active branch after rendering, so history cards cannot overwrite it.
	_refresh_todos()


# ------------------------------------------------------------------ transcript pieces

func _clear_transcript() -> void:
	for c in _transcript.get_children():
		c.queue_free()
	_asst_box = null
	_blocks = {}
	_tool_cards.clear()
	_bash_cards.clear()
	_dirty_blocks.clear()
	_queue_label.visible = false


func _notice(text: String, color: Color) -> void:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", 12)
	_transcript.add_child(l)


func _add_user_bubble(content) -> void:
	var stripped := PiEditorContext.strip(PiFormat.content_text(content, false))
	var p := _panel(_c_user_bg, 8)
	var box := VBoxContainer.new()
	p.add_child(box)
	var r := _rich()
	r.add_text(stripped[0])
	box.add_child(r)
	if content is Array:
		var index := 0
		for block in content:
			if not (block is Dictionary) or block.get("type") != "image":
				continue
			index += 1
			var label := _small_label()
			label.text = "[image #%d]" % index
			box.add_child(label)
			var image := PiPromptEdit.decode_image(block)
			if image != null:
				# Keep GPU previews small even when the original screenshot is large.
				var scale_ := minf(1.0, 480.0 / maxf(image.get_width(), image.get_height()))
				image.resize(maxi(1, int(image.get_width() * scale_)), maxi(1, int(image.get_height() * scale_)))
				var preview := TextureRect.new()
				preview.texture = ImageTexture.create_from_image(image)
				preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				preview.custom_minimum_size.y = minf(image.get_height(), 180)
				preview.tooltip_text = label.text
				box.add_child(preview)
			else:
				label.text += " (preview unavailable: %s)" % block.get("mimeType", "unknown format")
	if stripped[1]:
		var l := _small_label()
		l.text = "+ editor context"
		box.add_child(l)
	_transcript.add_child(p)


func _add_custom_message(msg: Dictionary) -> void:
	var p := _panel(_c_card_bg, 6)
	var r := _rich()
	r.push_color(_c_accent)
	r.add_text("[%s] " % msg.get("customType", "custom"))
	r.pop()
	r.add_text(PiFormat.content_text(msg.get("content", "")))
	p.add_child(r)
	_transcript.add_child(p)


func _begin_assistant() -> void:
	_asst_box = VBoxContainer.new()
	_asst_box.add_theme_constant_override("separation", 6)
	_asst_box.size_flags_horizontal = SIZE_EXPAND_FILL
	_transcript.add_child(_asst_box)
	_blocks = {}


## Gets or creates a text/thinking block for content index `idx` in the current assistant message.
func _block(idx: int, kind: String) -> Dictionary:
	if _blocks.has(idx) and _blocks[idx].kind == kind:
		return _blocks[idx]
	var b := {"kind": kind, "text": ""}
	if kind == "thinking":
		var card := _make_collapsible("Thinking", _asst_box)
		card.header.add_theme_color_override("font_color", _c_dim)
		var r := _rich()
		r.add_theme_color_override("default_color", _c_dim)
		card.body.add_child(r)
		b.label = r
		b.card = card
		card.root.visible = bool(PiSettings.get_value(PiSettings.SHOW_THINKING))
	else:
		var r := _rich()
		_asst_box.add_child(r)
		b.label = r
	_blocks[idx] = b
	return b


func _finalize_assistant(msg: Dictionary) -> void:
	var content = msg.get("content", [])
	if content is Array:
		for i in content.size():
			var c = content[i]
			if not (c is Dictionary):
				continue
			match str(c.get("type", "")):
				"text":
					var b := _block(i, "text")
					b.text = str(c.get("text", ""))
					_mark_dirty(b)
				"thinking":
					var b := _block(i, "thinking")
					b.text = str(c.get("thinking", ""))
					if b.text.is_empty() and c.get("redacted", false):
						b.text = "(redacted)"
					_mark_dirty(b)
				"toolCall":
					var card := _tool_card_for(str(c.get("id", "")), str(c.get("name", "")), c.get("arguments"))
					_mark_dirty(card)
	var stop := str(msg.get("stopReason", ""))
	if stop == "error":
		_notice("Error: %s" % msg.get("errorMessage", "unknown error"), _c_error)
	elif stop == "aborted":
		_notice("Response aborted.", _c_warning)
	elif stop == "length":
		_notice("Response hit the output token limit.", _c_warning)


func _mark_dirty(b: Dictionary) -> void:
	if b.get("_dirty", false):
		return
	b._dirty = true
	_dirty_blocks.append(b)


func _render_block(b: Dictionary) -> void:
	match str(b.get("kind", "")):
		"text":
			var r: RichTextLabel = b.label
			if not is_instance_valid(r):
				return
			r.clear()
			r.append_text(PiFormat.markdown_to_bbcode(b.text, _c_code))
		"thinking":
			var r: RichTextLabel = b.label
			if not is_instance_valid(r):
				return
			r.clear()
			r.add_text(b.text)
			var first := str(b.text).strip_edges().get_slice("\n", 0)
			b.card.header.text = "%s Thinking  %s" % [_arrow(b.card), first.left(80)]
		"tool_card":
			_render_tool_card(b)


# ------------------------------------------------------------------ tool cards

func _make_collapsible(title: String, parent: Control) -> Dictionary:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 2)
	root.size_flags_horizontal = SIZE_EXPAND_FILL
	var head_row := HBoxContainer.new()
	root.add_child(head_row)
	var header := Button.new()
	header.flat = true
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.clip_text = true
	header.size_flags_horizontal = SIZE_EXPAND_FILL
	header.text = "▸ " + title
	head_row.add_child(header)
	var body_panel := _panel(_c_card_bg, 6)
	var body := VBoxContainer.new()
	body_panel.add_child(body)
	body_panel.visible = false
	root.add_child(body_panel)
	parent.add_child(root)
	var card := {"root": root, "head_row": head_row, "header": header, "body_panel": body_panel, "body": body, "expanded": false}
	header.pressed.connect(func() -> void: _set_card_expanded(card, not card.expanded))
	return card


func _arrow(card: Dictionary) -> String:
	return "▾" if card.expanded else "▸"


func _set_card_expanded(card: Dictionary, expanded: bool) -> void:
	card.expanded = expanded
	card.body_panel.visible = expanded
	var t: String = card.header.text
	if t.length() > 1 and (t.begins_with("▸") or t.begins_with("▾")):
		card.header.text = _arrow(card) + t.substr(1)


func _make_tool_card(tool_name: String, args, parent: Control) -> Dictionary:
	var card := _make_collapsible(tool_name, parent)
	card.kind = "tool_card"
	card.name = tool_name
	card.args = args if args is Dictionary else {}
	card.args_text = ""
	card.out_text = ""
	card.out_is_error = false
	card.diff = ""
	card.status = "pending"
	card.suffix = ""
	var args_label := _rich()
	if _mono:
		args_label.add_theme_font_override("normal_font", _mono)
	args_label.add_theme_color_override("default_color", _c_dim)
	card.body.add_child(args_label)
	card.args_label = args_label
	var out_label := _rich()
	if _mono:
		out_label.add_theme_font_override("normal_font", _mono)
	card.body.add_child(out_label)
	card.out_label = out_label
	_add_open_link(card)
	_mark_dirty(card)
	return card


## Finds the card for a tool call id or creates one in the current assistant box.
func _tool_card_for(id: String, tool_name: String, args) -> Dictionary:
	if _tool_cards.has(id):
		var card: Dictionary = _tool_cards[id]
		if args is Dictionary and not args.is_empty() and (card.args as Dictionary).is_empty():
			card.args = args
			_add_open_link(card)
		elif args is Dictionary and not args.is_empty():
			card.args = args
		_mark_dirty(card)
		return card
	var parent: Control = _asst_box if _asst_box != null else _transcript
	var card := _make_tool_card(tool_name if not tool_name.is_empty() else "tool", args, parent)
	_tool_cards[id] = card
	return card


func _add_open_link(card: Dictionary) -> void:
	var res_path := PiEditorContext.to_res(str(card.args.get("path", card.args.get("file_path", ""))))
	if res_path.is_empty():
		return
	for c in card.head_row.get_children():
		if c is LinkButton:
			return
	var open := LinkButton.new()
	open.text = "open"
	open.tooltip_text = res_path
	open.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
	open.pressed.connect(func() -> void: _open_res_path(res_path))
	card.head_row.add_child(open)


func _set_card_status(card: Dictionary, status: String) -> void:
	card.status = status
	var c := _c_dim
	match status:
		"running":
			c = _c_warning
		"ok":
			c = _c_success
		"error":
			c = _c_error
	card.header.add_theme_color_override("font_color", c)
	card.header.add_theme_color_override("font_hover_color", c.lightened(0.2))
	_mark_dirty(card)


func _set_card_result(card: Dictionary, result, is_error: bool, partial: bool) -> void:
	if card.name == "todo" and not partial and not is_error and result is Dictionary:
		_apply_todos(result.get("details"))
	if result is Dictionary:
		card.out_text = PiFormat.content_text(result.get("content", ""))
		var details = result.get("details")
		if details is Dictionary and details.get("diff") is String:
			card.diff = details.get("diff")
	if not partial:
		_set_card_status(card, "error" if is_error else "ok")
		if is_error:
			_set_card_expanded(card, true)
	_mark_dirty(card)


func _render_tool_card(card: Dictionary) -> void:
	if not is_instance_valid(card.header):
		return
	var summary := PiFormat.tool_summary(card.name, card.args)
	if summary.is_empty() and not str(card.args_text).is_empty():
		summary = str(card.args_text).left(80)
	card.header.text = "%s %s  %s%s" % [_arrow(card), card.name, summary, card.suffix]

	var args_label: RichTextLabel = card.args_label
	args_label.clear()
	if not (card.args as Dictionary).is_empty():
		args_label.add_text(_format_args(card.name, card.args))
	elif not str(card.args_text).is_empty():
		args_label.add_text(str(card.args_text))
	args_label.visible = args_label.get_total_character_count() > 0

	var out_label: RichTextLabel = card.out_label
	out_label.clear()
	if not str(card.diff).is_empty():
		_append_diff(out_label, card.diff)
	else:
		var out := str(card.out_text)
		if out.length() > MAX_OUTPUT_CHARS:
			out = "…(%d chars hidden)\n" % (out.length() - MAX_OUTPUT_CHARS) + out.right(MAX_OUTPUT_CHARS)
		if card.status == "error":
			out_label.push_color(_c_error)
			out_label.add_text(out)
			out_label.pop()
		else:
			out_label.add_text(out)
	out_label.visible = out_label.get_total_character_count() > 0


func _format_args(tool_name: String, args: Dictionary) -> String:
	match tool_name:
		"bash", "$":
			return "$ " + str(args.get("command", ""))
		"write":
			return "%s\n%s" % [args.get("path", ""), str(args.get("content", "")).left(4000)]
		"edit":
			var s := str(args.get("path", ""))
			var edits = args.get("edits")
			if edits is Array:
				s += "  (%d edits)" % edits.size()
			return s
	return JSON.stringify(args, "  ")


func _append_diff(r: RichTextLabel, diff: String) -> void:
	for line in diff.split("\n"):
		var c := Color(0, 0, 0, 0)
		if line.begins_with("+") and not line.begins_with("+++"):
			c = _c_success
		elif line.begins_with("-") and not line.begins_with("---"):
			c = _c_error
		elif line.begins_with("@@"):
			c = _c_accent
		if c.a > 0:
			r.push_color(c)
			r.add_text(line + "\n")
			r.pop()
		else:
			r.add_text(line + "\n")


# ------------------------------------------------------------------ editor integration

func _on_tool_finished(tool_name: String, args) -> void:
	if not EDIT_TOOLS.has(tool_name):
		return
	if not PiSettings.get_value(PiSettings.RELOAD_AFTER_EDITS):
		return
	if args is Dictionary:
		var res_path := PiEditorContext.to_res(str(args.get("path", args.get("file_path", ""))))
		if not res_path.is_empty():
			_fs_dirty_paths[res_path] = true
	_fs_dirty = true
	_fs_timer.start()


func _sync_filesystem() -> void:
	if not _fs_dirty:
		return
	_fs_dirty = false
	var fs := EditorInterface.get_resource_filesystem()
	for p in _fs_dirty_paths.keys():
		if FileAccess.file_exists(p):
			fs.update_file(p)
	if not fs.is_scanning():
		fs.scan()
	# Only reload open scripts when Pi touched one of them (reloading is not free).
	var se := EditorInterface.get_script_editor()
	if se:
		for s in se.get_open_scripts():
			if s and _fs_dirty_paths.has(s.resource_path):
				se.reload_open_files()
				break
	# Reload open scenes Pi touched, unless they have unsaved changes.
	var open_scenes := EditorInterface.get_open_scenes()
	var unsaved := EditorInterface.get_unsaved_scenes() if EditorInterface.has_method("get_unsaved_scenes") else PackedStringArray()
	for p in _fs_dirty_paths.keys():
		if open_scenes.has(p) and not unsaved.has(p):
			EditorInterface.reload_scene_from_path(p)
	_fs_dirty_paths.clear()


func _open_res_path(res_path: String) -> void:
	if not FileAccess.file_exists(res_path) and not DirAccess.dir_exists_absolute(res_path):
		_notice("File not found: %s" % res_path, _c_warning)
		return
	var ext := res_path.get_extension().to_lower()
	if ext in ["tscn", "scn"]:
		EditorInterface.open_scene_from_path(res_path)
		return
	if ResourceLoader.exists(res_path):
		var res := load(res_path)
		if res is Script:
			EditorInterface.edit_script(res as Script)
			EditorInterface.set_main_screen_editor("Script")
			return
		if res:
			EditorInterface.edit_resource(res)
			return
	EditorInterface.select_file(res_path)


func _on_meta_clicked(meta) -> void:
	var s := str(meta)
	if s.begins_with("http://") or s.begins_with("https://"):
		OS.shell_open(s)
	else:
		_open_res_path(PiEditorContext.to_res(s))


## Called from context menus.
func insert_code_reference(code_edit: CodeEdit) -> void:
	_insert_text(PiEditorContext.code_reference(code_edit))


func insert_file_references(paths: Array) -> void:
	var refs := PackedStringArray()
	for p in paths:
		refs.append("`%s`" % PiEditorContext.rel(str(p)))
	_insert_text(", ".join(refs) + " ")


func insert_node_references(nodes: Array) -> void:
	var refs := PackedStringArray()
	for n in nodes:
		refs.append(PiEditorContext.node_reference(n))
	_insert_text("; ".join(refs) + " ")


func _insert_text(s: String) -> void:
	if not _prompt_edit.text.is_empty() and not _prompt_edit.text.ends_with("\n") and not _prompt_edit.text.ends_with(" "):
		_prompt_edit.insert_text_at_caret(" ")
	_prompt_edit.insert_text_at_caret(s)
	_prompt_edit.grab_focus.call_deferred()


# ------------------------------------------------------------------ TODO state and queued drafts

func _reset_todos() -> void:
	_todo_revision += 1
	_todo_panel.clear_tasks()


func _apply_todos(details) -> void:
	if _todo_panel.apply_snapshot(details):
		_todo_revision += 1


func _refresh_todos() -> void:
	var revision := _todo_revision
	var cb := func(res: Dictionary) -> void:
		if revision != _todo_revision or not res.get("success", false):
			return
		var data: Dictionary = res.get("data", {})
		var entries = data.get("entries")
		if entries is Array:
			_apply_todos(PiTodoPanel.snapshot_from_entries(entries, data.get("leafId")))
	client.request({"type": "get_entries"}, cb)


func _take_queued_draft(message: String) -> Dictionary:
	for i in _queued_drafts.size():
		if _queued_drafts[i].message == message:
			var draft: Dictionary = _queued_drafts[i].draft
			_queued_drafts.remove_at(i)
			return draft
	return {}


# ------------------------------------------------------------------ extension UI

func _on_ui_request(req: Dictionary) -> void:
	ext_ui.handle(req)


func _on_ext_notify(message: String, kind: String) -> void:
	var color := _c_dim
	var severity := EditorToaster.SEVERITY_INFO
	match kind:
		"warning":
			color = _c_warning
			severity = EditorToaster.SEVERITY_WARNING
		"error":
			color = _c_error
			severity = EditorToaster.SEVERITY_ERROR
	_notice(message, color)
	var toaster := EditorInterface.get_editor_toaster()
	if toaster:
		toaster.push_toast("Pi: " + message, severity)


func _on_ext_status(key: String, text: String) -> void:
	if text.is_empty():
		_statuses.erase(key)
	else:
		_statuses[key] = text
	_refresh_ext_status()


func _refresh_ext_status() -> void:
	var parts := PackedStringArray()
	for k in _statuses:
		parts.append(str(_statuses[k]))
	_ext_status_label.text = "  ·  ".join(parts)
	_ext_status_label.visible = not parts.is_empty()


func _on_ext_widget(key: String, lines: PackedStringArray, placement: String) -> void:
	if _widgets.has(key):
		_widgets[key].queue_free()
		_widgets.erase(key)
	if lines.is_empty():
		return
	var l := _small_label()
	if _mono:
		l.add_theme_font_override("font", _mono)
	l.text = "\n".join(lines)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	(_widgets_below if placement == "belowEditor" else _widgets_above).add_child(l)
	_widgets[key] = l


func _on_ext_title(title: String) -> void:
	_status_dot.tooltip_text = title
	var dock := get_parent()
	if dock is EditorDock and not title.is_empty():
		dock.tooltip_text = title


func _on_ext_editor_text(text: String) -> void:
	_prompt_edit.reset_draft()
	_prompt_edit.text = text
	_prompt_edit.set_caret_line(_prompt_edit.get_line_count() - 1)
	_prompt_edit.set_caret_column(_prompt_edit.get_line(_prompt_edit.get_line_count() - 1).length())
	_prompt_edit.grab_focus()


# ------------------------------------------------------------------ scrolling

func _on_vbar_changed() -> void:
	if _stick_bottom:
		var vbar := _scroll.get_v_scroll_bar()
		_scroll.scroll_vertical = int(vbar.max_value)


func _on_vbar_value_changed(value: float) -> void:
	var vbar := _scroll.get_v_scroll_bar()
	_stick_bottom = value + vbar.page >= vbar.max_value - 16
