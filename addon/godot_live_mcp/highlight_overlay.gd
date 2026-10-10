extends RefCounted

## Pulsing outlines (with optional captions) drawn over editor UI. Only the
## drawing: each owner decides when to clear. highlight_editor_control
## clears on the user's next action; a tour keeps its outlines until the
## step is done. Call update() every frame while not is_empty() so the
## outlines follow their controls as the editor re-lays out or scrolls.

var _layer: Control = null
var _items: Array = []  # {panel, control (WeakRef) | tree (WeakRef) + item_path}

func is_empty() -> bool:
	return _items.is_empty()

func size() -> int:
	return _items.size()

## Outlines a Control.
func add_control(control: Control, label: String) -> void:
	var panel := _make_panel(label)
	_ensure_layer().add_child(panel)
	_items.append({"panel": panel, "control": weakref(control)})

## Outlines a Tree row, found by its item texts from the root down
## (TreeItems aren't Controls, so the rect is looked up every frame).
func add_tree_item(tree: Tree, item_path: Array, label: String) -> void:
	var panel := _make_panel(label)
	_ensure_layer().add_child(panel)
	_items.append({"panel": panel, "tree": weakref(tree), "item_path": item_path})

## Removes every outline; returns how many there were.
func clear() -> int:
	var n := _items.size()
	if _layer != null and is_instance_valid(_layer):
		_layer.queue_free()
	_layer = null
	_items.clear()
	return n

## Keeps each outline on its target: follows the rect, hides it when the
## target is not visible, and clips to the scroll areas it sits in.
func update() -> void:
	if _layer == null or not is_instance_valid(_layer):
		return
	for item in _items:
		var panel: Panel = item.panel
		var rect := Rect2()
		var shown := false
		if item.has("control"):
			var c = item.control.get_ref()
			if c is Control and (c as Control).is_visible_in_tree():
				rect = (c as Control).get_global_rect()
				shown = true
				var anc: Node = c.get_parent()
				while anc != null:
					if anc is ScrollContainer or (anc is Control and (anc as Control).clip_contents):
						rect = rect.intersection((anc as Control).get_global_rect())
					anc = anc.get_parent()
		else:
			var tree = item.tree.get_ref()
			if tree is Tree and (tree as Tree).is_visible_in_tree():
				var ti: TreeItem = find_tree_item(tree, item.item_path)
				if ti != null:
					var local: Rect2 = (tree as Tree).get_item_area_rect(ti, -1)
					rect = Rect2((tree as Tree).get_global_rect().position + local.position, local.size).intersection((tree as Tree).get_global_rect())
					shown = true
		panel.visible = shown and rect.has_area()
		if panel.visible:
			panel.position = rect.position - _layer.global_position
			panel.size = rect.size

static func find_tree_item(tree: Tree, names: Array) -> TreeItem:
	var ti := tree.get_root()
	if ti == null or names.is_empty() or ti.get_text(0) != String(names[0]):
		return null
	for i in range(1, names.size()):
		var found: TreeItem = null
		for child in ti.get_children():
			if child.get_text(0) == String(names[i]):
				found = child
				break
		if found == null:
			return null
		ti = found
	return ti

func _ensure_layer() -> Control:
	if _layer == null or not is_instance_valid(_layer):
		_layer = Control.new()
		_layer.name = "GodotLiveMCPHighlights"
		_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_layer.z_index = 100
		EditorInterface.get_base_control().add_child(_layer)
	return _layer

func _make_panel(label: String) -> Panel:
	var panel := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.2, 0.9, 0.35, 0.12)
	sb.border_color = Color(0.25, 0.95, 0.4, 1.0)
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", sb)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.name = "Highlight"
	if label != "":
		var l := Label.new()
		l.text = label
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.add_theme_color_override("font_color", Color.WHITE)
		var lsb := StyleBoxFlat.new()
		lsb.bg_color = Color(0.1, 0.5, 0.2, 0.95)
		lsb.set_content_margin_all(4)
		lsb.set_corner_radius_all(3)
		l.add_theme_stylebox_override("normal", lsb)
		l.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
		l.grow_vertical = Control.GROW_DIRECTION_END
		l.grow_horizontal = Control.GROW_DIRECTION_END
		l.offset_top = 4
		panel.add_child(l)
	var tween := panel.create_tween().set_loops()
	tween.tween_property(panel, "modulate:a", 0.45, 0.6)
	tween.tween_property(panel, "modulate:a", 1.0, 0.6)
	return panel
