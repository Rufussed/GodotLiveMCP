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
	add_control_to_bottom_panel(_assistant_panel, "AI Assistant")

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
