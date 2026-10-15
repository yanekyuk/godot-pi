@tool
extends EditorPlugin
## Entry point: registers settings, the Pi dock, and context menu entries.

const PiSettings := preload("pi_settings.gd")
const PiRpcClient := preload("pi_rpc_client.gd")
const PiDock := preload("pi_dock.gd")
const PiContextMenu := preload("pi_context_menu.gd")

var client: PiRpcClient
var dock: EditorDock
var panel: PiDock
var _menus: Array[EditorContextMenuPlugin] = []


func _enter_tree() -> void:
	PiSettings.register()

	client = PiRpcClient.new()
	client.name = "PiRpcClient"
	add_child(client)

	panel = PiDock.new()
	panel.name = "PiPanel"
	panel.setup(client)

	dock = EditorDock.new()
	dock.name = "Pi"
	dock.title = "Pi"
	dock.layout_key = "pi_agent"
	dock.default_slot = EditorDock.DOCK_SLOT_RIGHT_UL
	dock.available_layouts = EditorDock.DOCK_LAYOUT_ALL
	var icon_path := "res://addons/pi_agent/icon.svg"
	if ResourceLoader.exists(icon_path):
		dock.dock_icon = load(icon_path)
	dock.add_child(panel)
	add_dock(dock)

	_add_menu(EditorContextMenuPlugin.CONTEXT_SLOT_SCRIPT_EDITOR_CODE, PiContextMenu.Kind.CODE)
	_add_menu(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, PiContextMenu.Kind.FILES)
	_add_menu(EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TREE, PiContextMenu.Kind.NODES)

	add_tool_menu_item("Pi: Restart Agent", _restart)

	if PiSettings.get_value(PiSettings.AUTO_START):
		# Defer so the editor finishes loading before we spawn a process.
		panel.call_deferred("start_agent")


func _exit_tree() -> void:
	remove_tool_menu_item("Pi: Restart Agent")
	for m in _menus:
		remove_context_menu_plugin(m)
	_menus.clear()
	if client:
		client.stop()
	if dock:
		remove_dock(dock)
		dock.queue_free()
		dock = null
	if client:
		client.queue_free()
		client = null
	panel = null


func _add_menu(slot: int, kind: int) -> void:
	var m := PiContextMenu.new()
	m.kind = kind
	m.panel_ref = weakref(panel)
	m.dock_ref = weakref(dock)
	add_context_menu_plugin(slot, m)
	_menus.append(m)


func _restart() -> void:
	if panel:
		panel.start_agent()
		dock.make_visible()
