@tool
extends EditorPlugin

const BridgeScript = preload("res://addons/godot_live_mcp/bridge.gd")

var _bridge: Node

func _enter_tree() -> void:
	_bridge = BridgeScript.new()
	_bridge.name = "GodotLiveMCPBridge"
	_bridge.set_editor_plugin(self)
	add_child(_bridge)

func _exit_tree() -> void:
	if _bridge:
		_bridge.stop()
		_bridge.queue_free()
		_bridge = null
