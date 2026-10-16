@tool
extends VBoxContainer
## Read-only view of rpiv-todo's full details.tasks snapshots. No tool calls or
## filesystem polling are needed to update the view.

const STATE_ENTRY_TYPE := "rpiv-todo-state"
const STATUSES := ["pending", "in_progress", "completed", "deleted"]

var _header: Button
var _body: VBoxContainer
var _progress: ProgressBar
var _tree: Tree
var _tasks: Array = []
var _expanded := true


func _init() -> void:
	visible = false
	_header = Button.new()
	_header.flat = true
	_header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_header.clip_text = true
	_header.tooltip_text = "Tasks from Pi's todo extension (read-only). Click to collapse."
	_header.pressed.connect(func() -> void:
		_expanded = not _expanded
		_body.visible = _expanded
		_update_header()
	)
	add_child(_header)
	_body = VBoxContainer.new()
	add_child(_body)
	_progress = ProgressBar.new()
	_progress.custom_minimum_size.y = 6
	_progress.show_percentage = false
	_body.add_child(_progress)
	_tree = Tree.new()
	_tree.hide_root = true
	_tree.columns = 2
	_tree.set_column_expand(0, false)
	_tree.set_column_custom_minimum_width(0, 100)
	_tree.set_column_expand(1, true)
	_tree.custom_minimum_size.y = 150
	_tree.select_mode = Tree.SELECT_ROW
	_body.add_child(_tree)


func clear_tasks() -> void:
	_tasks.clear()
	_tree.clear()
	visible = false


## Ignore unrelated or malformed envelopes instead of destroying a valid view.
func apply_snapshot(details) -> bool:
	if not (details is Dictionary) or not (details.get("tasks") is Array):
		return false
	for task in details.tasks:
		if not (task is Dictionary) or not (task.get("id") is float or task.get("id") is int) or not (task.get("subject") is String) or not STATUSES.has(task.get("status")):
			return false
	_tasks = details.tasks.duplicate(true)
	_tree.clear()
	var root := _tree.create_item()
	var colors := {
		"pending": get_theme_color("font_color", "Label"),
		"in_progress": get_theme_color("accent_color", "Editor"),
		"completed": get_theme_color("success_color", "Editor"),
	}
	for status in ["in_progress", "pending", "completed"]:
		for task in _tasks:
			if task.status != status:
				continue
			var row := _tree.create_item(root)
			row.set_text(0, {"pending": "○ Pending", "in_progress": "◐ In progress", "completed": "✓ Done"}[status])
			row.set_custom_color(0, colors[status])
			row.set_text(1, "#%d %s" % [int(task.id), task.subject])
			var info := PackedStringArray()
			info.append("#%d %s" % [int(task.id), task.subject])
			if status == "in_progress" and not str(task.get("activeForm", "")).is_empty():
				info.append(str(task.activeForm))
			if not str(task.get("description", "")).is_empty():
				info.append(str(task.description))
			if not str(task.get("owner", "")).is_empty():
				info.append("Owner: " + str(task.owner))
			var dependencies := PackedStringArray()
			for id in task.get("blockedBy", []):
				# Completed and deleted prerequisites no longer block this task.
				for other in _tasks:
					if other.id == id and other.status in ["pending", "in_progress"]:
						dependencies.append("#%d" % int(id))
			if not dependencies.is_empty():
				info.append("Blocked by: " + ", ".join(dependencies))
				row.set_text(0, row.get_text(0) + " ⛓")
			for column in 2:
				row.set_tooltip_text(column, "\n".join(info))
	_update_header()
	return true


func _update_header() -> void:
	var total := 0
	var completed := 0
	var active := ""
	for task in _tasks:
		if task.status == "deleted":
			continue
		total += 1
		if task.status == "completed":
			completed += 1
		elif task.status == "in_progress":
			active = str(task.get("activeForm", task.subject))
	_header.text = "%s TODO · %d/%d done%s" % ["▾" if _expanded else "▸", completed, total, (" · " + active) if not active.is_empty() else ""]
	_progress.max_value = maxi(total, 1)
	_progress.value = completed
	visible = total > 0


## get_entries includes abandoned branches. Walk ONLY leaf -> parents, even
## across compaction, and pick the newest snapshot on that active branch.
static func snapshot_from_entries(entries: Array, leaf_id) -> Dictionary:
	var by_id := {}
	for entry in entries:
		if entry is Dictionary and entry.has("id"):
			by_id[str(entry.id)] = entry
	var cursor := str(leaf_id) if leaf_id != null else ""
	var seen := {}
	while by_id.has(cursor) and not seen.has(cursor):
		seen[cursor] = true
		var entry: Dictionary = by_id[cursor]
		var details = null
		if entry.get("type") == "custom" and entry.get("customType") == STATE_ENTRY_TYPE:
			details = entry.get("data")
		elif entry.get("type") == "message":
			var msg = entry.get("message")
			if msg is Dictionary and msg.get("role") == "toolResult" and msg.get("toolName") == "todo":
				details = msg.get("details")
		if details is Dictionary and details.get("tasks") is Array:
			return details
		var parent = entry.get("parentId")
		cursor = str(parent) if parent != null else ""
	return {"tasks": []}
