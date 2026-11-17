@tool
extends EditorPlugin

const BridgeScript = preload("res://addons/godot_live_mcp/bridge.gd")
const McpEndpointScript = preload("res://addons/godot_live_mcp/mcp_endpoint.gd")
const AssistantPanelScript = preload("res://addons/godot_live_mcp/assistant_panel.gd")

var _bridge: Node
var _mcp_endpoint: Node
var _assistant_panel: Control

const TOURS_MENU_ITEM := "Guided Tours…"

## Plays saved .tour.json files, no agent needed.
func _open_tours() -> void:
	if _bridge:
		_bridge.open_tour_picker()

func _enter_tree() -> void:
	_bridge = BridgeScript.new()
	_bridge.name = "GodotLiveMCPBridge"
	_bridge.set_editor_plugin(self)
	add_child(_bridge)

	_mcp_endpoint = McpEndpointScript.new()
	_mcp_endpoint.name = "GodotLiveMCPEndpoint"
	add_child(_mcp_endpoint)
	_mcp_endpoint.start(_bridge)

	_assistant_panel = AssistantPanelScript.new()
	_assistant_panel.name = "AIAssistantPanel"
	var tab_button := add_control_to_bottom_panel(_assistant_panel, "Agentic Tutor")
	_move_tab_first(tab_button)
	_bridge.activity.connect(_assistant_panel.on_bridge_activity)
	_assistant_panel.set_bridge(_bridge)
	_assistant_panel.set_endpoint(_mcp_endpoint)
	add_tool_menu_item(TOURS_MENU_ITEM, _open_tours)

## New bottom panels go last; the chat is the one used most, so make it the
## first tab and the one shown when the editor opens. Newer Godot wraps the
## panel in a dock inside a TabContainer (tab order = child order); older
## versions return a tab button instead. The editor can reorder or reselect
## tabs while it finishes loading (saved layout, other plugins), so this
## runs again shortly afterwards.
func _move_tab_first(tab_button: Control) -> void:
	_place_tab(tab_button)
	for delay in [0.5, 2.0]:
		get_tree().create_timer(delay).timeout.connect(_place_tab.bind(tab_button))

func _place_tab(tab_button: Control) -> void:
	if _assistant_panel == null or not is_instance_valid(_assistant_panel):
		return
	var node: Node = _assistant_panel
	while node and not (node.get_parent() is TabContainer):
		node = node.get_parent()
	if node:
		var tabs: TabContainer = node.get_parent()
		tabs.move_child(node, 0)
		tabs.current_tab = tabs.get_tab_idx_from_control(node)
	elif tab_button and is_instance_valid(tab_button) and tab_button.get_parent():
		tab_button.get_parent().move_child(tab_button, 0)
		if tab_button is Button:
			tab_button.button_pressed = true

func _exit_tree() -> void:
	remove_tool_menu_item(TOURS_MENU_ITEM)
	if _mcp_endpoint:
		_mcp_endpoint.stop()
		_mcp_endpoint.queue_free()
		_mcp_endpoint = null
	if _bridge:
		_bridge.stop()
		_bridge.queue_free()
		_bridge = null
	if _assistant_panel:
		_assistant_panel.shutdown()
		remove_control_from_bottom_panel(_assistant_panel)
		_assistant_panel.queue_free()
		_assistant_panel = null
