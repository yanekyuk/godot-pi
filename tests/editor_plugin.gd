@tool
extends EditorPlugin
## Integration runner for tests/run_editor_tests.sh, in an isolated project.

const Dock := preload("res://addons/pi_agent/pi_dock.gd")
const Rpc := preload("res://addons/pi_agent/pi_rpc_client.gd")
const Settings := preload("res://addons/pi_agent/pi_settings.gd")

class FakeClient extends Rpc:
	var requests: Array = []
	var callbacks: Array[Callable] = []

	func is_running() -> bool:
		return true

	func request(command: Dictionary, callback: Callable = Callable()) -> String:
		requests.append(command.duplicate(true))
		callbacks.append(callback)
		return "editor-test-%d" % requests.size()

var failures := 0
var checks := 0


func _enter_tree() -> void:
	_run.call_deferred()


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)


func _run() -> void:
	Settings.register()
	EditorInterface.get_editor_settings().set_setting(Settings.SAVE_BEFORE_PROMPT, false)
	var client := FakeClient.new()
	add_child(client)
	var dock := Dock.new()
	add_child(dock)
	dock.setup(client)
	dock._context_toggle.button_pressed = false
	var image := Image.create(4, 3, false, Image.FORMAT_RGBA8)
	image.fill(Color.RED)
	dock._prompt_edit.insert_image(image)
	dock._submit()
	check(client.requests.back().type == "prompt", "Image-only draft sends prompt")
	check(client.requests.back().message == "[image #1]", "Marker stays in prompt text")
	check(client.requests.back().images.size() == 1, "Prompt includes RPC images array")
	check(dock._prompt_edit.text.is_empty(), "Submission clears draft")
	var rejected: Callable = client.callbacks.back()
	dock._prompt_edit.insert_image(image)
	rejected.call({"success": false, "error": "test rejection"})
	check(dock._prompt_edit.get_prompt().images.size() == 2, "Rejection restores images alongside new draft")
	dock._set_busy(true)
	dock._submit(true)
	check(client.requests.back().streamingBehavior == "followUp", "Alt+Enter queues image follow-up")
	check(client.requests.back().images.size() == 2, "Follow-up includes every surviving image")
	check(dock._queued_drafts.size() == 1, "Queued draft is retained for abort")
	dock._on_abort()
	client.callbacks.back().call({"success": true, "data": {"steering": [], "followUp": [dock._queued_drafts[0].message]}})
	check(dock._prompt_edit.get_prompt().images.size() == 2, "Abort restores submitted image follow-up")
	dock._submit()
	check(client.requests.back().streamingBehavior == "steer", "Enter steers with images while busy")
	dock._prompt_edit.insert_text_at_caret("!echo ")
	dock._prompt_edit.insert_image(image)
	var before := client.requests.size()
	dock._submit()
	check(client.requests.size() == before and dock._prompt_edit.get_prompt().images.size() == 1, "Shell cannot silently discard image")
	dock._prompt_edit.reset_draft()
	dock._prompt_edit.insert_text_at_caret("ordinary prompt")
	dock._submit()
	check(not client.requests.back().has("images"), "Ordinary prompts omit optional images")
	dock._on_messages({"success": true, "data": {"messages": [{"role": "toolResult", "toolName": "todo", "toolCallId": "old", "content": [], "details": {"tasks": [{"id": 1, "subject": "Old", "status": "pending"}]}}]}})
	check(client.requests.back().type == "get_entries", "History restoration requests full branch after rendering")
	client.callbacks.back().call({"success": true, "data": {"entries": [{"id": "snapshot", "type": "custom", "parentId": null, "customType": "rpiv-todo-state", "data": {"tasks": [{"id": 2, "subject": "Current", "status": "completed"}]}}], "leafId": "snapshot"}})
	check(dock._todo_panel._tasks[0].subject == "Current", "Full branch snapshot replaces compacted transcript state")
	dock._on_new_session()
	var new_session: Callable = client.callbacks.back()
	new_session.call({"success": true, "data": {"cancelled": true}})
	check(dock._todo_panel.visible, "Cancelled session change preserves TODOs")
	dock._on_new_session()
	new_session = client.callbacks.back()
	new_session.call({"success": true, "data": {"cancelled": false}})
	check(not dock._todo_panel.visible, "New session clears TODOs")
	check(dock._queued_drafts.is_empty(), "New session clears queued image cache")

	await _test_thinking(dock)
	dock.queue_free()
	client.queue_free()
	# Let editor startup/import finish before shutdown (avoids aborting its scan).
	await get_tree().process_frame
	while EditorInterface.get_resource_filesystem().is_scanning():
		await get_tree().process_frame
	print("Editor integration tests: %d checks, %d failures" % [checks, failures])
	get_tree().quit(1 if failures else 0)


func _test_thinking(dock: Dock) -> void:
	EditorInterface.get_editor_settings().set_setting(Settings.SHOW_THINKING, true)
	dock._clear_transcript()
	dock._on_event({"type": "message_start", "message": {"role": "assistant"}})
	dock._on_event({"type": "message_update", "assistantMessageEvent": {"type": "thinking_start", "contentIndex": 0}})
	var live: Dictionary = dock._blocks[0]
	check(not live.card.root.visible, "Thinking start must not create an empty visible card")
	dock._on_event({"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": "Inspect the scene tree first."}})
	dock._process(0)
	check(live.card.root.visible and live.label.get_parsed_text() == "Inspect the scene tree first.", "Readable thinking appears while streaming")
	dock._on_event({"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": "\nThen check the selected script."}})
	dock._process(0)
	check(live.label.get_parsed_text().contains("\nThen check"), "Thinking deltas append without losing text")
	dock._on_event({"type": "message_update", "assistantMessageEvent": {"type": "thinking_end", "contentIndex": 0, "content": "Authoritative readable summary."}})
	dock._process(0)
	check(live.label.get_parsed_text() == "Authoritative readable summary.", "Thinking end replaces deltas with authoritative text")
	dock._on_event({"type": "message_end", "message": {"role": "assistant", "content": [{"type": "thinking", "thinking": "", "thinkingSignature": "opaque-test-signature"}]}})
	dock._process(0)
	check(not live.card.root.visible, "Signature-only final content hides previously streamed card")

	dock._clear_transcript()
	dock._render_message({"role": "assistant", "content": [
		{"type": "thinking", "thinking": "", "thinkingSignature": "opaque-test-signature"},
		{"type": "thinking", "thinking": " \n\t"},
		{"type": "thinking", "thinking": "Inspect the scene tree, then check the selected script.\nOnly readable reasoning should appear in this panel."},
		{"type": "thinking", "thinking": "", "redacted": true},
		{"type": "text", "text": "**Ready.** Empty and signature-only thinking blocks are hidden."},
	]})
	var assistant: VBoxContainer = dock._transcript.get_child(dock._transcript.get_child_count() - 1)
	dock._process(0)
	check(not assistant.get_child(0).visible, "Reopened history hides signature-only thinking")
	check(not assistant.get_child(1).visible, "Reopened history hides whitespace-only thinking")
	check(assistant.get_child(2).visible, "Reopened history preserves readable thinking")
	check(assistant.get_child(3).visible, "Explicit redaction is displayed rather than silently hidden")
	for i in [2, 3]:
		var card_root := assistant.get_child(i)
		var header: Button = card_root.get_child(0).get_child(0)
		header.pressed.emit()
		check(card_root.get_child(1).visible, "Thinking header opens body")
		var label: RichTextLabel = card_root.get_child(1).get_child(0).get_child(0)
		check(not label.get_parsed_text().strip_edges().is_empty(), "Expanded thinking card has readable text")

	# Exercise the display preference through the same history rendering path.
	EditorInterface.get_editor_settings().set_setting(Settings.SHOW_THINKING, false)
	dock._render_message({"role": "assistant", "content": [{"type": "thinking", "thinking": "Hidden by preference."}]})
	dock._process(0)
	var hidden: VBoxContainer = dock._transcript.get_child(dock._transcript.get_child_count() - 1)
	check(not hidden.get_child(0).visible, "Show Thinking preference still hides readable thinking")
	EditorInterface.get_editor_settings().set_setting(Settings.SHOW_THINKING, true)

	var capture_dir := OS.get_environment("PI_TEST_CAPTURE_DIR")
	if capture_dir.is_empty():
		return
	dock._prompt_edit.reset_draft()
	dock._set_busy(false)
	dock._model_btn.add_item("Thinking display fixture")
	var window := Window.new()
	window.title = "Pi thinking display regression"
	window.size = Vector2i(720, 600)
	window.theme = EditorInterface.get_editor_theme()
	add_child(window)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 12)
	window.add_child(margin)
	dock.reparent(margin)
	window.popup_centered()
	for i in 5:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := window.get_texture().get_image()
	check(image.save_png(capture_dir.path_join("thinking-display.png")) == OK, "Save rendered thinking display fixture")
	print("Thinking display capture: " + capture_dir.path_join("thinking-display.png"))
	dock.reparent(self)
	window.queue_free()
