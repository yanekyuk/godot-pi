@tool
extends EditorContextMenuPlugin
## Right-click entries that push editor items into the Pi prompt.

enum Kind { CODE, FILES, NODES }

var kind: int = Kind.CODE
var panel_ref: WeakRef
var dock_ref: WeakRef


func _popup_menu(paths: PackedStringArray) -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists("res://addons/pi_agent/icon.svg"):
		icon = load("res://addons/pi_agent/icon.svg")
	match kind:
		Kind.CODE:
			add_context_menu_item("Add Selection to Pi", _on_code, icon)
		Kind.FILES:
			if not paths.is_empty():
				add_context_menu_item("Add to Pi Prompt", _on_files, icon)
		Kind.NODES:
			if not paths.is_empty():
				add_context_menu_item("Add to Pi Prompt", _on_nodes, icon)


func _panel() -> Object:
	var p = panel_ref.get_ref() if panel_ref else null
	var d = dock_ref.get_ref() if dock_ref else null
	if d:
		d.make_visible()
	return p


func _on_code(arg) -> void:
	var code_edit = arg[0] if arg is Array and not arg.is_empty() else arg
	if code_edit is NodePath or code_edit is String:
		code_edit = Engine.get_main_loop().root.get_node_or_null(code_edit)
	var p = _panel()
	if p and code_edit is CodeEdit:
		p.insert_code_reference(code_edit)


func _on_files(arg) -> void:
	var p = _panel()
	if p == null:
		return
	var paths: Array = []
	if arg is Array or arg is PackedStringArray:
		for x in arg:
			paths.append(str(x))
	else:
		paths.append(str(arg))
	p.insert_file_references(paths)


func _on_nodes(arg) -> void:
	var p = _panel()
	if p == null:
		return
	var nodes: Array = []
	if arg is Array:
		for x in arg:
			if x is Node:
				nodes.append(x)
	p.insert_node_references(nodes)
