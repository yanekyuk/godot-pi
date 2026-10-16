extends SceneTree
## Run: godot --headless --path . --script tests/test_features.gd
## No Pi process, provider credentials, or clipboard/display server required.

const Prompt := preload("res://addons/pi_agent/pi_prompt_edit.gd")
const Todos := preload("res://addons/pi_agent/pi_todo_panel.gd")
const Dock := preload("res://addons/pi_agent/pi_dock.gd")
const Rpc := preload("res://addons/pi_agent/pi_rpc_client.gd")
const Format := preload("res://addons/pi_agent/pi_format.gd")

var failures := 0
var checks := 0

class FakeClient extends Rpc:
	var requests: Array = []
	var callbacks: Array[Callable] = []

	func is_running() -> bool:
		return true

	func request(command: Dictionary, callback: Callable = Callable()) -> String:
		requests.append(command.duplicate(true))
		callbacks.append(callback)
		return "test-%d" % requests.size()


func _initialize() -> void:
	_run.call_deferred()


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)


func _run() -> void:
	_test_images()
	_test_todos()
	_test_branch_replay()
	_test_dock_events()
	await process_frame
	print("Feature tests: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func _image(color: Color) -> Image:
	var image := Image.create(4, 3, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return image


func _test_images() -> void:
	var prompt := Prompt.new()
	root.add_child(prompt)
	prompt.insert_text_at_caret("Look here: ")
	check(prompt.insert_image(_image(Color.RED)), "Accept clipboard image")
	check(prompt.text == "Look here: [image #1]", "Insert marker at caret")
	prompt.set_caret_column(5)
	prompt.insert_image(_image(Color.BLUE))
	check(prompt.text == "Look [image #2]here: [image #1]", "Insert second marker in the middle")
	var draft := prompt.get_prompt()
	check(draft.text == "Look [image #1]here: [image #2]", "RPC markers follow text order")
	check(draft.images.size() == 2 and draft.images[0].mimeType == "image/png", "RPC image content format")
	var decoded := Prompt.decode_image(draft.images[0])
	check(decoded != null and decoded.get_pixel(0, 0) == Color.BLUE, "Payload order matches marker order")
	prompt.select(0, 5, 0, 15)
	prompt.delete_selection()
	check(prompt.get_prompt().images.size() == 1, "Deleting a marker excludes its payload")
	prompt.undo()
	check(prompt.get_prompt().images.size() == 2, "Undo recovers marker and image")
	prompt.reset_draft()
	check(prompt.text.is_empty() and prompt.get_prompt().images.is_empty() and not prompt.has_undo(), "Reset clears payloads and undo history")
	prompt.insert_image(_image(Color.GREEN))
	prompt.restore_prompt(draft)
	var restored := prompt.get_prompt()
	check(restored.images.size() == 3, "Retry/abort restore preserves newer draft images")
	check(restored.text.contains("Look [image #2]here: [image #3]"), "Restore remaps colliding markers")
	prompt.reset_draft()
	prompt.insert_text_at_caret("[image #1]")
	check(prompt.get_prompt().images.is_empty(), "Literal marker does not invent an attachment")
	check(not prompt.insert_image(null), "Reject unreadable clipboard image")
	prompt.reset_draft()
	prompt.insert_text_at_caret("replace me")
	prompt.select(0, 0, 0, 10)
	prompt.insert_image(_image(Color.RED))
	check(prompt.text == "[image #1]", "Image paste replaces the selected text")
	# Optional Xvfb coverage for the actual TextEdit paste virtual and ordinary
	# text clipboard path, without touching the desktop clipboard.
	if DisplayServer.get_name() != "headless":
		if OS.get_cmdline_user_args().has("--image-clipboard"):
			prompt.reset_draft()
			check(DisplayServer.clipboard_has_image(), "Display server recognizes clipboard image")
			prompt.paste()
			check(prompt.text == "[image #1]" and prompt.get_prompt().images.size() == 1, "Native Paste action attaches clipboard image")
		prompt.reset_draft()
		prompt.insert_text_at_caret("replace me")
		prompt.select(0, 0, 0, 10)
		DisplayServer.clipboard_set("pasted text")
		prompt.paste()
		check(prompt.text == "pasted text", "Native text paste still replaces selection")
	check(Format.content_text([{"type": "text", "text": "hello"}, draft.images[0]], false) == "hello", "Extract message text without image placeholders")
	prompt.free()


func _tasks() -> Array:
	return [
		{"id": 1, "subject": "Plan", "status": "completed"},
		{"id": 2, "subject": "Build", "status": "in_progress", "activeForm": "Building UI", "description": "Full details", "owner": "agent"},
		{"id": 3, "subject": "Test", "status": "pending", "blockedBy": [1, 2]},
		{"id": 4, "subject": "Removed", "status": "deleted"},
	]


func _test_todos() -> void:
	var panel := Todos.new()
	root.add_child(panel)
	check(not panel.visible, "Empty TODO panel is hidden")
	check(panel.apply_snapshot({"tasks": _tasks()}), "Accept structured todo snapshot")
	check(panel.visible and panel._header.text.contains("1/3 done"), "Progress excludes tombstones")
	check(panel._header.text.contains("Building UI"), "Show active task form")
	check(panel._progress.value == 1 and panel._progress.max_value == 3, "Progress bar reflects completion")
	var first := panel._tree.get_root().get_first_child()
	check(first.get_text(1) == "#2 Build", "Active task is first")
	var pending := first.get_next()
	check(pending.get_tooltip_text(1).contains("Blocked by: #2") and not pending.get_tooltip_text(1).contains("#1"), "Only unfinished dependencies block")
	check(first.get_tooltip_text(1).contains("Full details") and first.get_tooltip_text(1).contains("Owner: agent"), "Task details in tooltip")
	panel._header.pressed.emit()
	check(not panel._body.visible, "TODO panel collapses")
	panel.apply_snapshot({"tasks": _tasks()})
	check(not panel._body.visible, "Live updates preserve collapsed state")
	check(not panel.apply_snapshot({"tasks": [{"id": 5, "status": "mystery"}]}), "Ignore malformed snapshot")
	check(panel._tasks.size() == 4, "Invalid snapshot preserves current state")
	check(panel.apply_snapshot({"tasks": []}) and not panel.visible, "Clear snapshot hides panel")
	panel.free()


func _test_branch_replay() -> void:
	var entries := [
		{"id": "a", "parentId": null, "type": "message", "message": {"role": "toolResult", "toolName": "todo", "details": {"tasks": _tasks()}}},
		{"id": "abandoned", "parentId": "a", "type": "custom", "customType": "rpiv-todo-state", "data": {"tasks": []}},
		{"id": "compact", "parentId": "a", "type": "compaction"},
		{"id": "leaf", "parentId": "compact", "type": "message", "message": {"role": "user", "content": "continue"}},
	]
	check(Todos.snapshot_from_entries(entries, "leaf").tasks.size() == 4, "Replay crosses compaction, ignores abandoned branch")
	check(Todos.snapshot_from_entries(entries, "abandoned").tasks.is_empty(), "Clear snapshot on selected branch wins")
	entries.append({"id": "nested", "parentId": "leaf", "type": "custom", "customType": "rpiv-todo-state", "data": {"tasks": [_tasks()[0]]}})
	check(Todos.snapshot_from_entries(entries, "nested").tasks.size() == 1, "Restore custom snapshot from nested todo calls")
	check(Todos.snapshot_from_entries(entries, null).tasks.is_empty(), "Empty session has no tasks")
	check(Todos.snapshot_from_entries([{"id": "cycle", "parentId": "cycle"}], "cycle").tasks.is_empty(), "Malformed branch cannot loop")


func _test_dock_events() -> void:
	# Construct only the event-facing controls; no EditorInterface or real agent.
	var dock := Dock.new()
	var client := FakeClient.new()
	dock.client = client
	dock._todo_panel = Todos.new()
	dock._transcript = VBoxContainer.new()
	dock._queue_label = Label.new()
	dock._prompt_edit = Prompt.new()
	for control in [dock._todo_panel, dock._transcript, dock._queue_label, dock._prompt_edit]:
		dock.add_child(control)
	root.add_child(dock)
	root.add_child(client)
	dock._on_event({"type": "tool_execution_end", "toolName": "todo", "toolCallId": "todo-1", "result": {"content": [], "details": {"tasks": _tasks()}}, "isError": false})
	check(dock._todo_panel._tasks.size() == 4, "Live tool result updates TODO panel")
	dock._on_event({"type": "entry_appended", "entry": {"type": "custom", "customType": "rpiv-todo-state", "data": {"tasks": []}}})
	check(not dock._todo_panel.visible, "Nested todo entry clears panel")
	dock._refresh_todos()
	var stale_callback: Callable = client.callbacks.back()
	dock._on_event({"type": "entry_appended", "entry": {"type": "custom", "customType": "rpiv-todo-state", "data": {"tasks": _tasks()}}})
	stale_callback.call({"success": true, "data": {"entries": [], "leafId": null}})
	check(dock._todo_panel._tasks.size() == 4, "Stale history response cannot overwrite live state")
	dock._prompt_edit.insert_image(_image(Color.RED))
	var draft := dock._prompt_edit.get_prompt()
	dock._queued_drafts.append({"message": "queued", "draft": draft})
	dock._prompt_edit.reset_draft()
	dock._on_abort()
	client.callbacks.back().call({"success": true, "data": {"steering": ["queued"], "followUp": []}})
	check(dock._prompt_edit.get_prompt().images.size() == 1, "Stop restores queued image payload")
	check(client.requests.back().type == "abort", "Clear queue is followed by abort")
	check(dock._queued_drafts.is_empty(), "Restored queue entry is consumed")
	dock._queued_drafts.append({"message": "look [image #1]", "draft": draft})
	dock._on_message_start({"role": "user", "content": [{"type": "text", "text": "look [image #1]"}, draft.images[0]]})
	check(dock._queued_drafts.is_empty(), "Delivered image message releases queued draft")
	var bubble := dock._transcript.get_child(dock._transcript.get_child_count() - 1)
	check(bubble.get_child(0).get_child_count() == 3, "User bubble has text, image label and preview")
	check(bubble.get_child(0).get_child(0).get_parsed_text() == "look [image #1]", "No duplicate MIME placeholders in bubble")
	dock._reset_todos()
	check(not dock._todo_panel.visible, "Session reset clears TODO panel")
	dock.free()
	client.free()
