@tool
extends Node
## Implements Pi's RPC extension UI subprotocol with editor dialogs.
## Dialog methods (select/confirm/input/editor) reply with `extension_ui_response`.
## Fire-and-forget methods are re-emitted as signals for the dock to display.

const PiFormat := preload("pi_format.gd")

signal notify_requested(message: String, kind: String)
## text == "" clears the status entry.
signal status_changed(key: String, text: String)
## lines empty clears the widget. placement: "aboveEditor" | "belowEditor".
signal widget_changed(key: String, lines: PackedStringArray, placement: String)
signal title_changed(title: String)
signal editor_text_requested(text: String)

var client: Node # PiRpcClient
var _open_dialogs := {} # request id -> Window


func handle(req: Dictionary) -> void:
	var method := str(req.get("method", ""))
	match method:
		"select":
			_select(req)
		"confirm":
			_confirm(req)
		"input":
			_input_dialog(req)
		"editor":
			_editor(req)
		"notify":
			notify_requested.emit(PiFormat.strip_ansi(str(req.get("message", ""))), str(req.get("notifyType", "info")))
		"setStatus":
			var t = req.get("statusText")
			status_changed.emit(str(req.get("statusKey", "")), PiFormat.strip_ansi(str(t)) if t != null else "")
		"setWidget":
			var lines := PackedStringArray()
			var raw = req.get("widgetLines")
			if raw is Array:
				for l in raw:
					lines.append(PiFormat.strip_ansi(str(l)))
			widget_changed.emit(str(req.get("widgetKey", "")), lines, str(req.get("widgetPlacement", "aboveEditor")))
		"setTitle":
			title_changed.emit(PiFormat.strip_ansi(str(req.get("title", ""))))
		"set_editor_text":
			editor_text_requested.emit(str(req.get("text", "")))
		_:
			# Unknown dialog-like method: cancel so the extension does not hang.
			if req.has("id"):
				_respond(str(req.id), {"cancelled": true})


## Closes all open dialogs (e.g. when Pi restarts).
func close_all() -> void:
	for id in _open_dialogs.keys():
		var w: Window = _open_dialogs[id]
		if is_instance_valid(w):
			w.queue_free()
	_open_dialogs.clear()


func _exit_tree() -> void:
	close_all()


func _respond(id: String, payload: Dictionary) -> void:
	var rec := {"type": "extension_ui_response", "id": id}
	rec.merge(payload)
	if client:
		client.send_raw(rec)


## Builds a dialog around `content`. `on_ok` returns the response payload (or null to keep the dialog open).
func _show(req: Dictionary, content: Control, on_ok: Callable, cancel_payload: Dictionary, min_size: Vector2i) -> ConfirmationDialog:
	var id := str(req.get("id", ""))
	var dlg := ConfirmationDialog.new()
	dlg.title = "Pi"
	dlg.ok_button_text = "OK"
	dlg.dialog_hide_on_ok = false

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	var title := str(req.get("title", ""))
	if not title.is_empty():
		var lbl := Label.new()
		lbl.text = PiFormat.strip_ansi(title)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.custom_minimum_size.x = 360
		box.add_child(lbl)
	if content:
		box.add_child(content)
	dlg.add_child(box)

	var state := {"done": false}
	var finish := func(payload: Dictionary) -> void:
		if state.done:
			return
		state.done = true
		_open_dialogs.erase(id)
		_respond(id, payload)
		if is_instance_valid(dlg):
			dlg.hide()
			dlg.queue_free()

	var on_confirmed := func() -> void:
		var payload = on_ok.call()
		if payload is Dictionary:
			finish.call(payload)
	var on_canceled := func() -> void:
		finish.call(cancel_payload)
	var on_timeout := func() -> void:
		# Pi resolves timed-out dialogs itself; just close ours.
		if state.done:
			return
		state.done = true
		_open_dialogs.erase(id)
		if is_instance_valid(dlg):
			dlg.queue_free()

	dlg.confirmed.connect(on_confirmed)
	dlg.canceled.connect(on_canceled)
	var timeout := float(req.get("timeout", 0))
	if timeout > 0:
		get_tree().create_timer(timeout / 1000.0).timeout.connect(on_timeout)

	_open_dialogs[id] = dlg
	EditorInterface.popup_dialog_centered(dlg, min_size)
	return dlg


func _select(req: Dictionary) -> void:
	var list := ItemList.new()
	list.custom_minimum_size = Vector2(360, 200)
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var options = req.get("options", [])
	if options is Array:
		for o in options:
			list.add_item(PiFormat.strip_ansi(str(o)))
	if list.item_count > 0:
		list.select(0)
	var on_ok := func():
		var sel := list.get_selected_items()
		if sel.is_empty():
			return null
		return {"value": str(options[sel[0]])}
	var dlg := _show(req, list, on_ok, {"cancelled": true}, Vector2i(420, 320))
	var ok_button := dlg.get_ok_button()
	list.item_activated.connect(func(_i: int) -> void: ok_button.pressed.emit())
	list.grab_focus.call_deferred()


func _confirm(req: Dictionary) -> void:
	var msg := Label.new()
	msg.text = PiFormat.strip_ansi(str(req.get("message", "")))
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.custom_minimum_size.x = 360
	var dlg := _show(req, msg, func(): return {"confirmed": true}, {"confirmed": false}, Vector2i(420, 140))
	dlg.ok_button_text = "Yes"
	dlg.cancel_button_text = "No"


func _input_dialog(req: Dictionary) -> void:
	var edit := LineEdit.new()
	edit.placeholder_text = str(req.get("placeholder", ""))
	edit.custom_minimum_size.x = 360
	var dlg := _show(req, edit, func(): return {"value": edit.text}, {"cancelled": true}, Vector2i(420, 120))
	var ok_button := dlg.get_ok_button()
	edit.text_submitted.connect(func(_t: String) -> void: ok_button.pressed.emit())
	edit.grab_focus.call_deferred()


func _editor(req: Dictionary) -> void:
	var edit := TextEdit.new()
	edit.text = str(req.get("prefill", ""))
	edit.custom_minimum_size = Vector2(600, 360)
	edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	var mono = EditorInterface.get_editor_theme().get_font("source", "EditorFonts")
	if mono:
		edit.add_theme_font_override("font", mono)
	_show(req, edit, func(): return {"value": edit.text}, {"cancelled": true}, Vector2i(680, 480))
	edit.grab_focus.call_deferred()
