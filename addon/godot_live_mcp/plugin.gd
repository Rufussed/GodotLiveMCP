@tool
extends EditorPlugin

const BridgeScript = preload("res://addons/godot_live_mcp/bridge.gd")
const AssistantPanelScript = preload("res://addons/godot_live_mcp/assistant_panel.gd")

var _bridge: Node
var _assistant_panel: Control

func _enter_tree() -> void:
	_bridge = BridgeScript.new()
	_bridge.name = "GodotLiveMCPBridge"
	_bridge.set_editor_plugin(self)
	add_child(_bridge)

	_assistant_panel = AssistantPanelScript.new()
	_assistant_panel.name = "AIAssistantPanel"
	var tab_button := add_control_to_bottom_panel(_assistant_panel, "AI Assistant")
	_move_tab_first(tab_button)
	_bridge.activity.connect(_assistant_panel.on_bridge_activity)

## New bottom panels go last; the chat is the one used most, so make it the
## first tab. Newer Godot wraps the panel in a dock inside a TabContainer
## (tab order = child order); older versions return a tab button instead.
func _move_tab_first(tab_button: Control) -> void:
	var node: Node = _assistant_panel
	while node and not (node.get_parent() is TabContainer):
		node = node.get_parent()
	if node:
		var tabs: TabContainer = node.get_parent()
		var current := tabs.get_current_tab_control()
		tabs.move_child(node, 0)
		if current:
			tabs.current_tab = tabs.get_tab_idx_from_control(current)
	elif tab_button and tab_button.get_parent():
		tab_button.get_parent().move_child(tab_button, 0)

func _exit_tree() -> void:
	if _bridge:
		_bridge.stop()
		_bridge.queue_free()
		_bridge = null
	if _assistant_panel:
		_assistant_panel.shutdown()
		remove_control_from_bottom_panel(_assistant_panel)
		_assistant_panel.queue_free()
		_assistant_panel = null
