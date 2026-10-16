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

	dock.queue_free()
	client.queue_free()
	# Let editor startup/import finish before shutdown (avoids aborting its scan).
	await get_tree().process_frame
	while EditorInterface.get_resource_filesystem().is_scanning():
		await get_tree().process_frame
	print("Editor integration tests: %d checks, %d failures" % [checks, failures])
	get_tree().quit(1 if failures else 0)
