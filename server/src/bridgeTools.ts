/**
 * MCP tool definitions and dispatch for tools that talk to the live
 * GodotLiveMCP runtime bridge addon (as opposed to the file/CLI-level
 * tools inherited from godot-mcp).
 */

import { BridgeClient } from './bridgeClient.js';
import { validateToolArgs } from './validateArgs.js';

const NODE_PATH_PROPERTY = {
  node_path: {
    type: 'string',
    description: 'Path to the node, relative to the scene root (e.g. "Player/Sprite2D"), or "." for the root',
  },
};

const VALUE_ENCODING_NOTE =
  ' Values are Godot\'s var_to_str() string encoding (e.g. "5", "true", "\\"hello\\"", ' +
  '"Vector2(1, 2)", "Color(1, 0, 0, 1)") — not plain JSON.';

const PROPERTY_VALIDATION_NOTE =
  ' Unknown property names fail loudly rather than silently no-oping, and the response includes a ' +
  'readback of every value actually applied — trust that over assuming success from ok:true alone.';

const LOAD_PREFIX_NOTE =
  ' A value of the form "load:res://path/to/file" is resolved via load() instead of var_to_str() ' +
  'decoding — use this to assign an existing texture or other resource file, e.g. ' +
  '{"albedo_texture": "load:res://icon.svg"}. Nested colon-path property names like ' +
  '"material_override:albedo_texture" are NOT supported here — use set_nested_property for those instead.';

export const bridgeToolNames = new Set([
  'eval_expression',
  'list_scene_tree',
  'get_node_properties',
  'set_property',
  'set_properties',
  'set_transform',
  'attach_script',
  'remove_node',
  'reparent_node',
  'duplicate_node',
  'add_node_live',
  'rename_node',
  'connect_signal',
  'disconnect_signal',
  'get_node_groups',
  'set_node_groups',
  'get_editor_selection',
  'select_nodes',
  'clear_editor_selection',
  'validate_script',
  'edit_script_text',
  'set_properties_multi',
  'set_animation_keys',
  'set_animation_track_path',
  'save_resource_file',
  'get_script_text',
  'setup_collision',
  'get_collision_info',
  'set_physics_layers',
  'get_physics_layers',
  'add_mesh_instance',
  'setup_environment',
  'set_material_3d',
  'create_animation',
  'add_animation_track',
  'get_animation_info',
  'add_audio_bus',
  'add_audio_bus_effect',
  'get_audio_bus_layout',
  'tilemap_fill_rect',
  'tilemap_get_info',
  'set_particle_material',
  'set_particle_color_gradient',
  'get_particle_info',
  'save_scene_live',
  'set_physics_material',
  'set_theme_stylebox_override',
  'set_shader_material',
  'get_shader_material_info',
  'set_nested_property',
  'set_resource_property',
  'reload_plugin',
  'restart_editor',
  'play_scene',
  'stop_scene',
  'is_playing_scene',
  'reload_project',
  'get_signals',
  'find_nodes',
  'batch_set_properties',
  'get_editor_screenshot',
  'get_output_log',
  'get_material_info',
  'add_animation_state',
  'add_animation_transition',
  'setup_navigation',
  'get_resource_dependencies',
  'set_anchors_preset',
  'get_node_bounds',
  'set_audio_bus_effect_params',
  'remove_audio_bus_effect',
  'run_script',
]);

export function isBridgeTool(name: string): boolean {
  return bridgeToolNames.has(name);
}

export const bridgeToolDefinitions = [
  {
    name: 'eval_expression',
    description:
      'Evaluate an arbitrary GDScript expression against a node in the live scene tree, running ' +
      'in the Godot editor, and return the result. Use this for anything the structured tools ' +
      "don't cover. The expression runs with the target node as `self`, and also has direct " +
      'access to ProjectSettings, ClassDB, Engine, Input, OS, Time, Performance, AudioServer, ResourceLoader (e.g. ResourceLoader.load("res://...") — plain load() is not available), ResourceSaver, and ' +
      '(in-editor) EditorInterface, e.g. "AudioServer.set_bus_volume_db(AudioServer.get_bus_index(\\"Music\\"), -6.0)". ' +
      'Also has KEY_* constants (e.g. "Input.is_key_pressed(KEY_A)") — these are ordinary GDScript ' +
      "globals elsewhere, but Expression doesn't resolve them unless explicitly bound like this. " +
      'Note: Expression syntax cannot parse assignment statements or loops — for those, use a ' +
      'structured tool.' + VALUE_ENCODING_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        expression: {
          type: 'string',
          description: 'GDScript expression to evaluate, e.g. "position.x" or "$Sprite2D.modulate"',
        },
      },
      required: ['expression'],
    },
  },
  {
    name: 'run_script',
    description:
      'Run multi-statement GDScript source against a node in the live scene tree, running in the ' +
      'Godot editor. Use this instead of eval_expression whenever the logic needs a `var` declaration, ' +
      'a loop, or more than one statement — Expression (what eval_expression uses) can only parse a ' +
      "single expression. `source` becomes the body of a compiled `func _run(node):`, so it can " +
      'reference the target node as `node` (not `self`) and MUST end with its own `return` statement — ' +
      'unlike eval_expression, there is no implicit return of a trailing expression. Also has access to ' +
      'ProjectSettings, ClassDB, Engine, Input, OS, Time, Performance, AudioServer, ResourceLoader (e.g. ResourceLoader.load("res://...") — plain load() is not available), ResourceSaver, and (in-editor) ' +
      'EditorInterface as bare identifiers. Note: a runtime error partway through the script (as opposed ' +
      'to a compile error) is not caught — you get back null; check get_debug_output for what actually ' +
      'went wrong.' + VALUE_ENCODING_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        source: {
          type: 'string',
          description:
            'GDScript statements forming a function body, e.g. ' +
            '"var root = EditorInterface.get_edited_scene_root()\\nvar total = 0\\nfor c in root.get_children():\\n\\ttotal += 1\\nreturn total"',
        },
      },
      required: ['source'],
    },
  },
  {
    name: 'list_scene_tree',
    description: 'List the live scene tree (name, type, path, children) starting at a node.',
    inputSchema: {
      type: 'object',
      properties: { ...NODE_PATH_PROPERTY },
      required: [],
    },
  },
  {
    name: 'get_node_properties',
    description:
      'Get all editor-visible properties of a live node and their current values. For a Node2D/Node3D, ' +
      'position/rotation/scale here are LOCAL (relative to the parent) — global_position/global_rotation/' +
      'global_transform (world-space, what matters most under nested parents) are also included even though ' +
      'Godot doesn\'t flag them editor-visible, since they\'re real settable properties too.' + VALUE_ENCODING_NOTE,
    inputSchema: {
      type: 'object',
      properties: { ...NODE_PATH_PROPERTY },
      required: [],
    },
  },
  {
    name: 'set_property',
    description: 'Set an arbitrary property on a live node.' + VALUE_ENCODING_NOTE + LOAD_PREFIX_NOTE + PROPERTY_VALIDATION_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        property_name: { type: 'string', description: 'Name of the property to set' },
        value: { type: 'string', description: 'New value, var_to_str()-encoded' },
      },
      required: ['property_name', 'value'],
    },
  },
  {
    name: 'set_properties',
    description:
      'Set multiple properties on a live node in one call. Prefer this over repeated set_property ' +
      'calls whenever configuring more than one property on the same node.' + VALUE_ENCODING_NOTE + LOAD_PREFIX_NOTE + PROPERTY_VALIDATION_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        properties: {
          type: 'object',
          description: 'Map of property_name -> var_to_str()-encoded value',
        },
      },
      required: ['properties'],
    },
  },
  {
    name: 'set_transform',
    description: 'Set position/rotation/scale on a live Node2D or Node3D. Any subset of the three may be given.' + VALUE_ENCODING_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        position: { type: 'string', description: 'var_to_str()-encoded Vector2/Vector3, e.g. "Vector2(10, 20)"' },
        rotation: { type: 'string', description: 'var_to_str()-encoded radians: a float for a Node2D (e.g. "1.57"), or a Vector3 for a Node3D (e.g. "Vector3(0, 1.57, 0)")' },
        scale: { type: 'string', description: 'var_to_str()-encoded Vector2/Vector3, e.g. "Vector2(2, 2)"' },
      },
      required: [],
    },
  },
  {
    name: 'attach_script',
    description: 'Attach an existing script (by res:// path) to a live node.',
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        script_path: { type: 'string', description: 'res:// path to an existing .gd script' },
      },
      required: ['script_path'],
    },
  },
  {
    name: 'remove_node',
    description: 'Remove and free a live node (cannot remove the scene root).',
    inputSchema: {
      type: 'object',
      properties: { ...NODE_PATH_PROPERTY },
      required: ['node_path'],
    },
  },
  {
    name: 'reparent_node',
    description: 'Move a live node to a new parent.',
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        new_parent_path: { type: 'string', description: 'Path to the new parent node' },
      },
      required: ['node_path', 'new_parent_path'],
    },
  },
  {
    name: 'duplicate_node',
    description: 'Duplicate a live node under the same parent and return the new node\'s path.',
    inputSchema: {
      type: 'object',
      properties: { ...NODE_PATH_PROPERTY },
      required: ['node_path'],
    },
  },
  {
    name: 'add_node_live',
    description:
      'Instantiate a Godot class (e.g. "Sprite2D", "RigidBody2D") — or, with scene_path, an ' +
      'instance of a saved .tscn — and add it as a live child of parent_path. If a game is running ' +
      'from the editor, the new node also appears in it (like adding it in the Scene dock). ' +
      'Distinct from godot-mcp\'s file-based add_node, which edits a .tscn on disk rather than the ' +
      'live tree.',
    inputSchema: {
      type: 'object',
      properties: {
        parent_path: { type: 'string', description: 'Path to the parent node, relative to the scene root, or "." for the root' },
        node_type: { type: 'string', description: 'Godot class name to instantiate, e.g. "Sprite2D" (not needed with scene_path)' },
        scene_path: { type: 'string', description: 'res:// path of a .tscn to add an instance of, instead of node_type' },
        node_name: { type: 'string', description: 'Optional name for the new node' },
      },
      required: ['parent_path'],
    },
  },
  {
    name: 'rename_node',
    description: 'Rename a live node.',
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        new_name: { type: 'string', description: 'New name for the node' },
      },
      required: ['node_path', 'new_name'],
    },
  },
  {
    name: 'connect_signal',
    description: 'Connect a live node\'s signal to a method on another live node.',
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        signal_name: { type: 'string', description: 'Name of the signal on node_path, e.g. "pressed"' },
        target_node_path: { type: 'string', description: 'Path to the node whose method should be called' },
        method_name: { type: 'string', description: 'Name of the method on the target node' },
      },
      required: ['node_path', 'signal_name', 'target_node_path', 'method_name'],
    },
  },
  {
    name: 'disconnect_signal',
    description: 'Disconnect a previously connected live signal.',
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        signal_name: { type: 'string', description: 'Name of the signal on node_path' },
        target_node_path: { type: 'string', description: 'Path to the connected target node' },
        method_name: { type: 'string', description: 'Name of the connected method' },
      },
      required: ['node_path', 'signal_name', 'target_node_path', 'method_name'],
    },
  },
  {
    name: 'get_node_groups',
    description: 'Get the groups a live node belongs to (internal editor groups are filtered out).',
    inputSchema: {
      type: 'object',
      properties: { ...NODE_PATH_PROPERTY },
      required: [],
    },
  },
  {
    name: 'set_node_groups',
    description: 'Replace a live node\'s group membership with the given list.',
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        groups: { type: 'array', items: { type: 'string' }, description: 'Full list of groups the node should belong to' },
      },
      required: ['groups'],
    },
  },
  {
    name: 'get_editor_selection',
    description: 'Get the paths of nodes currently selected in the editor.',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'select_nodes',
    description: 'Select the given live nodes in the editor (replaces the current selection).',
    inputSchema: {
      type: 'object',
      properties: {
        node_paths: { type: 'array', items: { type: 'string' }, description: 'Paths of nodes to select' },
      },
      required: ['node_paths'],
    },
  },
  {
    name: 'clear_editor_selection',
    description: 'Clear the editor\'s current node selection.',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'validate_script',
    description:
      'Check a GDScript file for parse errors by reloading it as a GDScript resource. On failure, ' +
      'only an error code is returned — check the editor\'s Output panel for the actual message.',
    inputSchema: {
      type: 'object',
      properties: { script_path: { type: 'string', description: 'res:// path to the script' } },
      required: ['script_path'],
    },
  },
  {
    name: 'set_animation_track_path',
    description:
      'Point an existing animation track at a different node/property, e.g. "LegLPivot:rotation" (relative to ' +
      'the AnimationPlayer\'s root node), as one undoable edit. Use instead of track_set_path via run_script.',
    inputSchema: {
      type: 'object',
      properties: {
        node_path: { type: 'string', description: 'AnimationPlayer path' },
        anim_name: { type: 'string' },
        library_name: { type: 'string', description: 'Default "" (the default library)' },
        track_index: { type: 'integer' },
        track_node_path: { type: 'string' },
      },
      required: ['node_path', 'anim_name', 'track_index', 'track_node_path'],
    },
  },
  {
    name: 'set_animation_keys',
    description:
      'Replace all keyframes of one animation track (and optionally the animation length) as ONE undoable ' +
      'edit. Use instead of eval_expression track_remove_key/track_insert_key calls, which can\'t be undone. ' +
      'Values use var_to_str() encoding, e.g. "Quaternion(0, 0, 0, 1)" or "Vector3(1, 2, 3)"; get_animation_info ' +
      'shows track indices and current keys.',
    inputSchema: {
      type: 'object',
      properties: {
        node_path: { type: 'string', description: 'AnimationPlayer path' },
        anim_name: { type: 'string' },
        library_name: { type: 'string', description: 'Default "" (the default library)' },
        track_index: { type: 'integer' },
        keys: {
          type: 'array',
          items: { type: 'object', properties: { time: { type: 'number' }, value: {}, transition: { type: 'number' } }, required: ['time', 'value'] },
        },
        length: { type: 'number', description: 'Optional new animation length in seconds' },
      },
      required: ['node_path', 'anim_name', 'track_index', 'keys'],
    },
  },
  {
    name: 'set_properties_multi',
    description:
      'Set different properties/values on many nodes as ONE undoable edit (one Ctrl+Z), live-synced to ' +
      'a running game. Everything is validated before anything changes. Use instead of run_script loops ' +
      'for edits like "space these 100 nodes out". Values use var_to_str() encoding ("Vector3(1, 2, 3)"), ' +
      'or "load:res://..." for files.',
    inputSchema: {
      type: 'object',
      properties: {
        edits: {
          type: 'array',
          description: 'List of {node_path, properties: {name: value}}',
          items: {
            type: 'object',
            properties: {
              node_path: { type: 'string' },
              properties: { type: 'object' },
            },
            required: ['node_path', 'properties'],
          },
        },
      },
      required: ['edits'],
    },
  },
  {
    name: 'save_resource_file',
    description:
      'Build an Image or Resource with a GDScript body (like run_script; must `return` it) and save it as a ' +
      'file: Image -> .png/.jpg/.webp, Resource (material, mesh, ...) -> .tres/.res. The file is registered ' +
      'with the editor. Then assign it with "load:<path>" (set_property / set_material_3d / ...) — unlike an ' +
      'in-memory resource, a file reaches a running game live. Use for generated textures etc.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'res:// path to save to' },
        source: { type: 'string', description: 'GDScript body returning an Image or Resource' },
      },
      required: ['path', 'source'],
    },
  },
  {
    name: 'edit_script_text',
    description:
      'Set the full text of a GDScript (.gd) or shader (.gdshader) file the way a person would: ' +
      'opens it in Godot\'s script/shader editor and replaces the text there as one undoable edit. ' +
      'The tab is left unsaved — it reaches disk on Ctrl+S or when the scene is played — so there ' +
      'is no "reload from disk?" prompt. Use this instead of writing .gd/.gdshader files directly ' +
      'while the editor is open. A path that doesn\'t exist yet is created on disk (like the ' +
      'editor\'s New Script dialog); attach it with attach_script / set_shader_material.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'res:// path to the .gd or .gdshader file' },
        text: { type: 'string', description: 'the complete new file contents' },
      },
      required: ['path', 'text'],
    },
  },
  {
    name: 'get_script_text',
    description:
      'Read a script\'s or shader\'s current text, including unsaved edits in an open editor tab ' +
      '(the file on disk can be older than what the editor shows). "source" says which was read.',
    inputSchema: {
      type: 'object',
      properties: { path: { type: 'string', description: 'res:// path to the .gd or .gdshader file' } },
      required: ['path'],
    },
  },
  {
    name: 'setup_collision',
    description:
      'Add a CollisionShape2D/3D child (with a new shape resource) to a live CollisionObject2D/3D ' +
      '(Area2D, StaticBody2D, RigidBody3D, ...). One call instead of instantiate-shape + set-props + ' +
      'instantiate-collision-node + assign + add_child.' + LOAD_PREFIX_NOTE + PROPERTY_VALIDATION_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        shape_type: {
          type: 'string',
          description: 'Shape class to create, e.g. "RectangleShape2D", "CircleShape2D", "BoxShape3D", "SphereShape3D"',
        },
        shape_params: {
          type: 'object',
          description: 'Properties to set on the shape, var_to_str()-encoded, e.g. {"size": "Vector2(32, 32)"} or {"radius": "16.0"}',
        },
      },
      required: ['node_path', 'shape_type'],
    },
  },
  {
    name: 'get_collision_info',
    description:
      'Read a live CollisionShape2D/3D\'s shape resource type and its own properties (radius, size, ...) ' +
      '- not reconstructable from get_node_properties, since var_to_str() doesn\'t round-trip in-memory resources.',
    inputSchema: {
      type: 'object',
      properties: { ...NODE_PATH_PROPERTY },
      required: ['node_path'],
    },
  },
  {
    name: 'set_physics_layers',
    description:
      'Set a live CollisionObject2D/3D\'s collision_layer/collision_mask using human layer numbers ' +
      '(1-32) instead of raw bitmasks. Either or both of layers/mask may be given.',
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        layers: { type: 'array', items: { type: 'integer' }, description: 'Layer numbers (1-32) this node occupies' },
        mask: { type: 'array', items: { type: 'integer' }, description: 'Layer numbers (1-32) this node detects' },
      },
      required: ['node_path'],
    },
  },
  {
    name: 'get_physics_layers',
    description: 'Get a live CollisionObject2D/3D\'s collision_layer/collision_mask as human layer numbers (1-32).',
    inputSchema: {
      type: 'object',
      properties: { ...NODE_PATH_PROPERTY },
      required: ['node_path'],
    },
  },
  {
    name: 'add_mesh_instance',
    description:
      'Instantiate a primitive Mesh (e.g. "BoxMesh", "SphereMesh", "CapsuleMesh", "PlaneMesh") with the ' +
      'given properties, wrap it in a new MeshInstance3D, and add that as a live child.' + LOAD_PREFIX_NOTE + PROPERTY_VALIDATION_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        parent_path: { type: 'string', description: 'Path to the parent node, relative to the scene root, or "." for the root' },
        mesh_type: { type: 'string', description: 'Mesh subclass to instantiate, e.g. "BoxMesh"' },
        mesh_params: { type: 'object', description: 'Properties to set on the mesh, var_to_str()-encoded, e.g. {"size": "Vector3(1, 1, 1)"}' },
        node_name: { type: 'string', description: 'Optional name for the new MeshInstance3D' },
      },
      required: ['parent_path', 'mesh_type'],
    },
  },
  {
    name: 'setup_environment',
    description: 'Configure a live WorldEnvironment node\'s Environment resource (creating one if it has none).' + LOAD_PREFIX_NOTE + PROPERTY_VALIDATION_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        environment_params: {
          type: 'object',
          description: 'Properties to set on the Environment resource, var_to_str()-encoded, e.g. {"background_mode": "2", "ambient_light_color": "Color(0.2, 0.2, 0.3, 1)"}',
        },
      },
      required: ['node_path', 'environment_params'],
    },
  },
  {
    name: 'set_material_3d',
    description: 'Configure a live GeometryInstance3D\'s (e.g. MeshInstance3D) material_override as a StandardMaterial3D, reusing one if already set. If a different material is already there (e.g. a ShaderMaterial), it refuses rather than replacing it, unless replace_existing is true. Pass surface_index to target one surface of a multi-surface MeshInstance3D (via set_surface_override_material) instead of the whole mesh.' + LOAD_PREFIX_NOTE + PROPERTY_VALIDATION_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        material_params: {
          type: 'object',
          description: 'Properties to set on the StandardMaterial3D, var_to_str()-encoded, e.g. {"albedo_color": "Color(1, 0, 0, 1)"}',
        },
        surface_index: { type: 'integer', description: 'Optional: target this surface (MeshInstance3D only) instead of the whole mesh\'s material_override' },
        replace_existing: { type: 'boolean', description: 'Replace a non-StandardMaterial3D material (e.g. a ShaderMaterial) that is already there. Only when the user wants it replaced. Default false.' },
      },
      required: ['node_path', 'material_params'],
    },
  },
  {
    name: 'get_material_info',
    description:
      'Read a live GeometryInstance3D\'s material_override (or one surface\'s override, via surface_index) ' +
      '— the counterpart to set_material_3d. Prefer this over eval_expression for reading material ' +
      'properties: a chained call like "get_surface_override_material(0).albedo_color" fails, since ' +
      'Expression can\'t see past the method\'s generic Object return type to know the real property exists; ' +
      'reading material_override directly via eval_expression works but dumps all ~90 StandardMaterial3D ' +
      'properties at once. This returns only editor-visible properties, same as get_node_properties.' + VALUE_ENCODING_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        surface_index: { type: 'integer', description: 'Optional: read this surface\'s override (MeshInstance3D only) instead of material_override' },
      },
      required: ['node_path'],
    },
  },
  {
    name: 'create_animation',
    description: 'Create a new Animation on a live AnimationPlayer (in the given animation library, default "").',
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        anim_name: { type: 'string', description: 'Name for the new animation' },
        length: { type: 'number', description: 'Animation length in seconds (default 1.0)' },
        library_name: { type: 'string', description: 'Animation library name (default "")' },
      },
      required: ['node_path', 'anim_name'],
    },
  },
  {
    name: 'add_animation_track',
    description:
      'Add a track to an existing animation and return its track_index (needed for follow-up ' +
      'eval_expression calls like get_animation(name).track_insert_key(track_index, time, value)).',
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        anim_name: { type: 'string', description: 'Name of the existing animation' },
        library_name: { type: 'string', description: 'Animation library name (default "")' },
        track_type: {
          type: 'string',
          enum: ['value', 'position_3d', 'rotation_3d', 'scale_3d', 'blend_shape', 'method', 'bezier', 'audio', 'animation'],
          description: 'Track type',
        },
        track_node_path: { type: 'string', description: 'NodePath the track targets, e.g. "Sprite2D:modulate"' },
      },
      required: ['node_path', 'anim_name', 'track_type', 'track_node_path'],
    },
  },
  {
    name: 'get_animation_info',
    description: 'Get an animation\'s length and all tracks with every keyframe (time + value).',
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        anim_name: { type: 'string', description: 'Name of the animation' },
        library_name: { type: 'string', description: 'Animation library name (default "")' },
      },
      required: ['node_path', 'anim_name'],
    },
  },
  {
    name: 'add_animation_state',
    description:
      'Add a state to a live AnimationTree\'s state machine (AnimationNodeStateMachine.add_node()) — a ' +
      'method call, unreachable through set_property/set_resource_property. tree_root must already be an ' +
      'AnimationNodeStateMachine (set it first via set_resource_property with property_name "tree_root", ' +
      'resource_type "AnimationNodeStateMachine").',
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        state_name: { type: 'string', description: 'Name for the new state' },
        animation_name: { type: 'string', description: 'Name of the animation this state plays (optional)' },
      },
      required: ['node_path', 'state_name'],
    },
  },
  {
    name: 'add_animation_transition',
    description:
      'Add a transition between two states in a live AnimationTree\'s state machine ' +
      '(AnimationNodeStateMachine.add_transition()) — a method call, unreachable through property tools.' +
      LOAD_PREFIX_NOTE + PROPERTY_VALIDATION_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        from_state: { type: 'string', description: 'Name of the source state (must already exist)' },
        to_state: { type: 'string', description: 'Name of the target state (must already exist)' },
        transition_params: {
          type: 'object',
          description: 'Properties to set on the AnimationNodeStateMachineTransition, var_to_str()-encoded, e.g. {"xfade_time": "0.2"}',
        },
      },
      required: ['node_path', 'from_state', 'to_state'],
    },
  },
  {
    name: 'add_audio_bus',
    description: 'Add a new audio bus (appended at the end) and name it. Returns its bus_index.',
    inputSchema: {
      type: 'object',
      properties: { bus_name: { type: 'string', description: 'Name for the new bus' } },
      required: ['bus_name'],
    },
  },
  {
    name: 'add_audio_bus_effect',
    description: 'Instantiate an AudioEffect (e.g. "AudioEffectReverb") with the given properties and add it to an existing bus.' + LOAD_PREFIX_NOTE + PROPERTY_VALIDATION_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        bus_name: { type: 'string', description: 'Name of the existing bus' },
        effect_type: { type: 'string', description: 'AudioEffect subclass to instantiate, e.g. "AudioEffectReverb"' },
        effect_params: { type: 'object', description: 'Properties to set on the effect, var_to_str()-encoded' },
      },
      required: ['bus_name', 'effect_type'],
    },
  },
  {
    name: 'get_audio_bus_layout',
    description: 'List every audio bus with its volume/mute/solo/bypass/send settings and each attached effect\'s index, type, and properties.',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'set_audio_bus_effect_params',
    description:
      'Adjust an existing audio bus effect\'s properties after creation — add_audio_bus_effect only covers ' +
      'setting properties at creation time. Find effect_index via get_audio_bus_layout.' +
      LOAD_PREFIX_NOTE + PROPERTY_VALIDATION_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        bus_name: { type: 'string', description: 'Name of the existing bus' },
        effect_index: { type: 'integer', description: 'Index of the effect on this bus, from get_audio_bus_layout' },
        effect_params: { type: 'object', description: 'Properties to set on the effect, var_to_str()-encoded' },
      },
      required: ['bus_name', 'effect_index', 'effect_params'],
    },
  },
  {
    name: 'remove_audio_bus_effect',
    description: 'Remove an audio bus effect by index (AudioServer.remove_bus_effect()) — a method call with no property-tool equivalent.',
    inputSchema: {
      type: 'object',
      properties: {
        bus_name: { type: 'string', description: 'Name of the existing bus' },
        effect_index: { type: 'integer', description: 'Index of the effect on this bus, from get_audio_bus_layout' },
      },
      required: ['bus_name', 'effect_index'],
    },
  },
  {
    name: 'tilemap_fill_rect',
    description: 'Fill a rectangular region of a live TileMapLayer with one tile, cell by cell.',
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        position: { type: 'string', description: 'var_to_str()-encoded Vector2i top-left cell, e.g. "Vector2i(0, 0)"' },
        size: { type: 'string', description: 'var_to_str()-encoded Vector2i cell count, e.g. "Vector2i(5, 3)"' },
        source_id: { type: 'integer', description: 'Tile set source id' },
        atlas_coords: { type: 'string', description: 'var_to_str()-encoded Vector2i atlas coordinates, e.g. "Vector2i(0, 0)"' },
        alternative_tile: { type: 'integer', description: 'Alternative tile id (default 0)' },
      },
      required: ['node_path', 'position', 'size', 'source_id', 'atlas_coords'],
    },
  },
  {
    name: 'tilemap_get_info',
    description: 'Get a live TileMapLayer\'s used rect, used cell count, and tile set source ids.',
    inputSchema: {
      type: 'object',
      properties: { ...NODE_PATH_PROPERTY },
      required: ['node_path'],
    },
  },
  {
    name: 'set_particle_material',
    description: 'Configure a live GPUParticles2D/3D\'s process_material as a ParticleProcessMaterial, reusing one if already set.' + LOAD_PREFIX_NOTE + PROPERTY_VALIDATION_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        material_params: { type: 'object', description: 'Properties to set on the ParticleProcessMaterial, var_to_str()-encoded' },
      },
      required: ['node_path', 'material_params'],
    },
  },
  {
    name: 'set_particle_color_gradient',
    description: 'Set a live GPUParticles2D/3D\'s color ramp from a list of gradient points.',
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        points: {
          type: 'array',
          description: 'Gradient points, e.g. [{"offset": 0, "color": "Color(1, 1, 0, 1)"}, {"offset": 1, "color": "Color(1, 0, 0, 0)"}]',
          items: {
            type: 'object',
            properties: {
              offset: { type: 'number', description: 'Position along the gradient, 0.0-1.0' },
              color: { type: 'string', description: 'var_to_str()-encoded Color' },
            },
          },
        },
      },
      required: ['node_path', 'points'],
    },
  },
  {
    name: 'get_particle_info',
    description: 'Get a live GPUParticles2D/3D\'s amount/lifetime/emitting and its process_material\'s own properties.',
    inputSchema: {
      type: 'object',
      properties: { ...NODE_PATH_PROPERTY },
      required: ['node_path'],
    },
  },
  {
    name: 'save_scene_live',
    description:
      'Save the currently edited scene to disk from the running editor, persisting every live change ' +
      'made through this bridge (eval_expression, set_property, add_node_live, ...). Distinct from ' +
      'godot-mcp\'s file-based save_scene tool, which resaves a scene FILE via a headless CLI process and ' +
      'has no knowledge of live in-memory changes — it will NOT persist bridge edits. Bridge edits only ' +
      'exist in the running editor\'s memory until this is called (or the user manually saves); closing ' +
      'or reloading the editor without saving discards them.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'Optional res:// path to "save as". Omit to save to the scene\'s current path.' },
      },
      required: [],
    },
  },
  {
    name: 'set_physics_material',
    description:
      'Configure a live PhysicsBody2D/3D\'s (RigidBody3D, StaticBody2D, ...) physics_material_override ' +
      '(bounce, friction, ...), creating one if it has none, reusing it if it already does.' + LOAD_PREFIX_NOTE + PROPERTY_VALIDATION_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        material_params: {
          type: 'object',
          description: 'Properties to set on the PhysicsMaterial, var_to_str()-encoded, e.g. {"bounce": "0.9", "friction": "0.5"}',
        },
      },
      required: ['node_path', 'material_params'],
    },
  },
  {
    name: 'set_theme_stylebox_override',
    description:
      'Set a live Control\'s per-instance theme stylebox override (e.g. "normal"/"hover"/"pressed" on a ' +
      'Button, or "panel" on a Panel), creating a new StyleBox resource (default "StyleBoxFlat") with the ' +
      'given properties. For a color/constant/font-size override instead, use eval_expression\'s ' +
      'add_theme_color_override/add_theme_constant_override/add_theme_font_size_override — those take plain ' +
      'values, not a resource, and are single method calls.' + LOAD_PREFIX_NOTE + PROPERTY_VALIDATION_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        override_name: { type: 'string', description: 'Theme override slot name, e.g. "normal", "panel"' },
        style_type: { type: 'string', description: 'StyleBox subclass to instantiate (default "StyleBoxFlat")' },
        style_params: {
          type: 'object',
          description: 'Properties to set on the StyleBox, var_to_str()-encoded, e.g. {"bg_color": "Color(0.2, 0.2, 0.2, 1)", "corner_radius_top_left": "8"}',
        },
      },
      required: ['node_path', 'override_name'],
    },
  },
  {
    name: 'set_anchors_preset',
    description:
      'Apply a layout preset to a live Control (Control.set_anchors_preset()) — the standard way to lay ' +
      'out UI (e.g. "make this fill its parent") without hand-computing four anchor values. A method call, ' +
      'unreachable through property tools.',
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        preset: { type: 'string', description: 'Control.LayoutPreset constant name, e.g. "PRESET_FULL_RECT", "PRESET_CENTER", "PRESET_TOP_WIDE"' },
        keep_offsets: { type: 'boolean', description: 'Keep the control\'s current offsets instead of resetting them (default false)' },
      },
      required: ['node_path', 'preset'],
    },
  },
  {
    name: 'get_node_bounds',
    description:
      'Get a node\'s bounding box — genuinely not reachable any other way. VisualInstance3D (MeshInstance3D, ' +
      'etc.) returns local and world-space AABB; Control returns local and global Rect2.',
    inputSchema: {
      type: 'object',
      properties: { ...NODE_PATH_PROPERTY },
      required: ['node_path'],
    },
  },
  {
    name: 'set_shader_material',
    description:
      'Assign/configure a live ShaderMaterial on a GeometryInstance3D\'s material_override or a ' +
      'CanvasItem\'s material, setting shader uniforms via set_shader_parameter() — a method call, not a ' +
      'property, so shader uniforms are unreachable through set_property/set_properties or ' +
      'get_node_properties. Reuses the node\'s existing ShaderMaterial if it already has one.' + LOAD_PREFIX_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        shader_path: { type: 'string', description: 'res:// path to a .gdshader file. Optional if the node already has a ShaderMaterial with a shader set.' },
        shader_params: {
          type: 'object',
          description: 'Map of uniform name -> var_to_str()-encoded value (or "load:res://..." for a sampler2D texture uniform)',
        },
      },
      required: ['node_path'],
    },
  },
  {
    name: 'get_shader_material_info',
    description: 'Read a live node\'s ShaderMaterial: shader path and every uniform\'s current value.',
    inputSchema: {
      type: 'object',
      properties: { ...NODE_PATH_PROPERTY },
      required: ['node_path'],
    },
  },
  {
    name: 'set_nested_property',
    description:
      'Set a property reached through a colon-separated path, e.g. "material_override:albedo_color" — ' +
      'the same path shape shown by the Godot inspector\'s own revert-arrow UI. set_property/set_properties ' +
      'treat a colon-path as one literal (unknown) property name, so use this instead whenever the target is ' +
      'a sub-property of a resource already assigned to the node (a material, a shape, a stylebox, ...). Every ' +
      'intermediate segment must already hold a non-null Resource/Object — this cannot create one along the ' +
      'way; use set_resource_property first if the intermediate resource does not exist yet.' +
      VALUE_ENCODING_NOTE +
      ' A value of the form "load:res://path/to/file" is resolved via load() instead of var_to_str() decoding.' +
      PROPERTY_VALIDATION_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        property_path: {
          type: 'string',
          description: 'Colon-separated property path, e.g. "material_override:albedo_color" or "shape:radius"',
        },
        value: { type: 'string', description: 'New value, var_to_str()-encoded (or "load:res://..." for a resource file)' },
      },
      required: ['property_path', 'value'],
    },
  },
  {
    name: 'set_resource_property',
    description:
      'Set a node property to a freshly-constructed Resource of any class (e.g. property_name ' +
      '"shape", resource_type "SphereShape3D"), applying resource_params to it first. This is the generic ' +
      'form of set_theme_stylebox_override/set_shader_material/set_physics_material/setup_environment — those ' +
      'exist as convenience wrappers for common cases, but this works for any Resource subclass, closing the ' +
      'gap where a resource-typed property needs a brand-new (unsaved, path-less) resource that ' +
      'str_to_var()/"load:" can\'t construct. Reuses the node\'s existing resource in place if it is already ' +
      'the requested type (set reuse_existing to false to always replace it).' + PROPERTY_VALIDATION_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        property_name: { type: 'string', description: 'Node property to assign the resource to, e.g. "shape", "material_override"' },
        resource_type: { type: 'string', description: 'Resource subclass to instantiate, e.g. "SphereShape3D", "StyleBoxFlat"' },
        resource_params: {
          type: 'object',
          description: 'Properties to set on the new resource, var_to_str()-encoded, e.g. {"radius": "1.5"}',
        },
        reuse_existing: {
          type: 'boolean',
          description: 'Reuse the node\'s existing resource if it\'s already resource_type, instead of replacing it (default true)',
        },
      },
      required: ['node_path', 'property_name', 'resource_type'],
    },
  },
  {
    name: 'reload_plugin',
    description:
      'Disable and re-enable the GodotLiveMCP editor plugin, the same effect as toggling it by hand in ' +
      'Project Settings > Plugins. Use this after any bridge.gd change so new/updated bridge commands take ' +
      'effect without manual intervention. The TCP connection drops as part of the reload — expect the next ' +
      'call to this server to reconnect automatically; a call issued immediately after this one may need a ' +
      'short retry if it lands before the new plugin instance is listening again.',
    inputSchema: {
      type: 'object',
      properties: {},
      required: [],
    },
  },
  {
    name: 'restart_editor',
    description:
      'Restart the WHOLE Godot editor process (closes and reopens the same project), the same effect as ' +
      'manually quitting and relaunching Godot. Distinct from reload_plugin (which only re-toggles this one ' +
      'plugin without restarting the engine) — use this when a change needs a real boot, e.g. a ' +
      'boot-only project setting like debug/file_logging/enable_file_logging, or to clear stubborn cached ' +
      'editor state that a plugin reload alone doesn\'t reset. The connection drops immediately and stays ' +
      'down for several seconds while the editor relaunches — retry the next call rather than assuming failure.',
    inputSchema: {
      type: 'object',
      properties: {
        save: { type: 'boolean', description: 'Save the project before restarting (default true)' },
      },
      required: [],
    },
  },
  {
    name: 'play_scene',
    description:
      'Start the project running via the editor\'s OWN Play mechanism (EditorInterface.play_main_scene()/' +
      'play_custom_scene()) — the same thing pressing the editor\'s Play button does. Prefer this over ' +
      'godot-mcp\'s run_project, which spawns a separate CLI process this MCP server owns directly; that path ' +
      'proved unreliable in practice (the process can vanish with no crash trace). After calling this, the ' +
      'runtime_bridge.gd autoload (if configured in the target project) becomes reachable on its own port for ' +
      'game_* tools once the game finishes booting (a few seconds).',
    inputSchema: {
      type: 'object',
      properties: {
        scene_path: { type: 'string', description: 'Optional res:// path to a specific scene to run instead of the project\'s main scene' },
      },
      required: [],
    },
  },
  {
    name: 'stop_scene',
    description: 'Stop the currently playing scene (EditorInterface.stop_playing_scene()) — the same as pressing the editor\'s Stop button.',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'is_playing_scene',
    description: 'Check whether a scene is currently playing, and which one.',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'reload_project',
    description:
      'Rescan the project filesystem (EditorFileSystem.scan()) so the editor notices externally-edited ' +
      'files, e.g. a script edited on disk outside the editor. Cheaper than restart_editor and doesn\'t drop ' +
      'the connection — try this first; escalate to restart_editor only if a change still isn\'t recognized ' +
      '(e.g. a boot-only project setting, or a change to bridge.gd itself, which needs reload_plugin instead).',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'get_signals',
    description:
      'List every signal a live node declares and every live connection on each (target + method). One call ' +
      'instead of get_signal_list() plus a get_signal_connection_list() call per signal via eval_expression, ' +
      'each returning a raw Dictionary that would need manual parsing.',
    inputSchema: {
      type: 'object',
      properties: { ...NODE_PATH_PROPERTY },
      required: [],
    },
  },
  {
    name: 'find_nodes',
    description:
      'Recursively find nodes under node_path matching a type and/or name pattern, returning just the ' +
      'matching paths — not the whole subtree like list_scene_tree, which matters once a scene has more than ' +
      'a handful of nodes. type uses inheritance-aware matching ("Control" matches a Button). name_pattern ' +
      'uses glob syntax ("*" and "?"). Either or both may be given.',
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        type: { type: 'string', description: 'Class name to match, inheritance-aware, e.g. "Button" or "Control"' },
        name_pattern: { type: 'string', description: 'Glob pattern for node name, e.g. "Enemy*"' },
      },
      required: [],
    },
  },
  {
    name: 'batch_set_properties',
    description:
      'Apply the same properties to every node matching a type/name_pattern filter (same matching as ' +
      'find_nodes) in one call — the alternative is a find_nodes round trip followed by one set_properties ' +
      'call per match, which doesn\'t scale as a scene grows. All matched nodes are batched into a single ' +
      'undo step, so one call is one Ctrl+Z regardless of how many nodes matched.' +
      VALUE_ENCODING_NOTE + LOAD_PREFIX_NOTE + PROPERTY_VALIDATION_NOTE +
      ' Unknown-property validation runs against every matched node before anything is applied, since ' +
      'matches under one type filter can be different concrete types with different property sets.',
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        type: { type: 'string', description: 'Class name to match, inheritance-aware, e.g. "Button" or "Control"' },
        name_pattern: { type: 'string', description: 'Glob pattern for node name, e.g. "Enemy*"' },
        properties: {
          type: 'object',
          description: 'Map of property_name -> var_to_str()-encoded value, applied to every matched node',
        },
      },
      required: ['properties'],
    },
  },
  {
    name: 'get_output_log',
    description:
      'Read what the user would see in Godot\'s Output and Debugger panels, to diagnose problems — especially ' +
      'after play_scene: the Output panel\'s last lines (includes the game\'s print() output), the Debugger\'s ' +
      'game errors/warnings with file:line and stack details, the stack the game is paused at after a script ' +
      'error (game_paused_at; stop_scene to end it), and the editor\'s own errors/warnings (tool scripts, plugins). ' +
      'Held in memory only. Pass editor_since=<editor_next_since from the last call> to get only newer editor errors.',
    inputSchema: {
      type: 'object',
      properties: {
        lines: { type: 'integer', description: 'How many of the Output panel\'s last lines to return (default 60)' },
        editor_since: { type: 'integer', description: 'Only editor errors newer than this (editor_next_since from a previous call)' },
      },
      required: [],
    },
  },
  {
    name: 'get_editor_screenshot',
    description:
      'Capture the live editor\'s 3D viewport as a PNG image — the only way to get visual state, since ' +
      'nothing else exposes rendered pixels through get_node_properties or eval_expression. Returned as an ' +
      'image content block, not JSON.',
    inputSchema: {
      type: 'object',
      properties: {
        max_dimension: { type: 'integer', description: 'Downscale so neither dimension exceeds this (default 800); pass 0 for full resolution' },
      },
      required: [],
    },
  },
  {
    name: 'setup_navigation',
    description:
      'Configure and bake a live NavigationRegion2D/3D\'s nav polygon/mesh in one call — creating the ' +
      'resource, applying properties, and baking are three separate steps otherwise, and baking specifically ' +
      'is a method call (bake_navigation_mesh()/bake_navigation_polygon()), unreachable through property ' +
      'tools. Bakes synchronously (blocks briefly) so the response reflects the finished result, rather than ' +
      'the default threaded bake this bridge has no way to await. Bakes from whatever geometry already ' +
      'exists under the region node in the scene, same as the editor\'s manual bake button.' +
      LOAD_PREFIX_NOTE + PROPERTY_VALIDATION_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        nav_params: {
          type: 'object',
          description: 'Properties to set on the NavigationMesh (3D) or NavigationPolygon (2D), var_to_str()-encoded, e.g. {"cell_size": "0.25"}',
        },
        bake: { type: 'boolean', description: 'Bake after configuring (default true)' },
      },
      required: ['node_path'],
    },
  },
  {
    name: 'get_resource_dependencies',
    description:
      'List a resource file\'s dependencies (other files it references) via ResourceLoader.get_dependencies() ' +
      '— a genuine capability gap, nothing else exposes a project\'s resource dependency graph. Useful before ' +
      'deleting or moving a file, to see what would break.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'res:// path to the resource file, e.g. "res://level1.tscn"' },
      },
      required: ['path'],
    },
  },
];

let sharedClient: BridgeClient | null = null;
function getClient(): BridgeClient {
  if (!sharedClient) sharedClient = new BridgeClient();
  return sharedClient;
}

export async function handleBridgeTool(name: string, args: any): Promise<any> {
  validateToolArgs(bridgeToolDefinitions, name, args);
  const client = getClient();
  const params = args || {};

  switch (name) {
    case 'eval_expression':
      return textResult(await client.call('eval_expression', {
        node_path: params.node_path ?? '.',
        expression: params.expression,
      }));
    case 'run_script':
      return textResult(await client.call('run_script', {
        node_path: params.node_path ?? '.',
        source: params.source,
      }));
    case 'list_scene_tree':
      return textResult(await client.call('list_scene_tree', {
        node_path: params.node_path ?? '.',
      }));
    case 'get_node_properties':
      return textResult(await client.call('get_node_properties', {
        node_path: params.node_path ?? '.',
      }));
    case 'set_property':
      return textResult(await client.call('set_property', {
        node_path: params.node_path ?? '.',
        property_name: params.property_name,
        value: params.value,
      }));
    case 'set_properties':
      return textResult(await client.call('set_properties', {
        node_path: params.node_path ?? '.',
        properties: params.properties ?? {},
      }));
    case 'set_transform':
      return textResult(await client.call('set_transform', {
        node_path: params.node_path ?? '.',
        position: params.position,
        rotation: params.rotation,
        scale: params.scale,
      }));
    case 'attach_script':
      return textResult(await client.call('attach_script', {
        node_path: params.node_path ?? '.',
        script_path: params.script_path,
      }));
    case 'remove_node':
      return textResult(await client.call('remove_node', {
        node_path: params.node_path,
      }));
    case 'reparent_node':
      return textResult(await client.call('reparent_node', {
        node_path: params.node_path,
        new_parent_path: params.new_parent_path,
      }));
    case 'duplicate_node':
      return textResult(await client.call('duplicate_node', {
        node_path: params.node_path,
      }));
    case 'add_node_live':
      return textResult(await client.call('add_node_live', {
        parent_path: params.parent_path ?? '.',
        node_type: params.node_type ?? '',
        scene_path: params.scene_path ?? '',
        node_name: params.node_name ?? '',
      }));
    case 'rename_node':
      return textResult(await client.call('rename_node', {
        node_path: params.node_path ?? '.',
        new_name: params.new_name,
      }));
    case 'connect_signal':
      return textResult(await client.call('connect_signal', {
        node_path: params.node_path ?? '.',
        signal_name: params.signal_name,
        target_node_path: params.target_node_path,
        method_name: params.method_name,
      }));
    case 'disconnect_signal':
      return textResult(await client.call('disconnect_signal', {
        node_path: params.node_path ?? '.',
        signal_name: params.signal_name,
        target_node_path: params.target_node_path,
        method_name: params.method_name,
      }));
    case 'get_node_groups':
      return textResult(await client.call('get_node_groups', {
        node_path: params.node_path ?? '.',
      }));
    case 'set_node_groups':
      return textResult(await client.call('set_node_groups', {
        node_path: params.node_path ?? '.',
        groups: params.groups ?? [],
      }));
    case 'get_editor_selection':
      return textResult(await client.call('get_editor_selection', {}));
    case 'select_nodes':
      return textResult(await client.call('select_nodes', {
        node_paths: params.node_paths ?? [],
      }));
    case 'clear_editor_selection':
      return textResult(await client.call('clear_editor_selection', {}));
    case 'validate_script':
      return textResult(await client.call('validate_script', {
        script_path: params.script_path,
      }));
    case 'set_animation_track_path':
      return textResult(await client.call('set_animation_track_path', {
        node_path: params.node_path ?? '.',
        anim_name: params.anim_name,
        library_name: params.library_name ?? '',
        track_index: params.track_index,
        track_node_path: params.track_node_path,
      }));
    case 'set_animation_keys':
      return textResult(await client.call('set_animation_keys', {
        node_path: params.node_path ?? '.',
        anim_name: params.anim_name,
        library_name: params.library_name ?? '',
        track_index: params.track_index,
        keys: params.keys ?? [],
        ...(params.length !== undefined ? { length: params.length } : {}),
      }));
    case 'set_properties_multi':
      return textResult(await client.call('set_properties_multi', { edits: params.edits ?? [] }));
    case 'save_resource_file':
      return textResult(await client.call('save_resource_file', { path: params.path, source: params.source }));
    case 'edit_script_text':
      return textResult(await client.call('edit_script_text', {
        path: params.path,
        text: params.text,
      }));
    case 'get_script_text':
      return textResult(await client.call('get_script_text', { path: params.path }));
    case 'setup_collision':
      return textResult(await client.call('setup_collision', {
        node_path: params.node_path ?? '.',
        shape_type: params.shape_type,
        shape_params: params.shape_params ?? {},
      }));
    case 'get_collision_info':
      return textResult(await client.call('get_collision_info', {
        node_path: params.node_path ?? '.',
      }));
    case 'set_physics_layers':
      return textResult(await client.call('set_physics_layers', {
        node_path: params.node_path ?? '.',
        layers: params.layers,
        mask: params.mask,
      }));
    case 'get_physics_layers':
      return textResult(await client.call('get_physics_layers', {
        node_path: params.node_path ?? '.',
      }));
    case 'add_mesh_instance':
      return textResult(await client.call('add_mesh_instance', {
        parent_path: params.parent_path ?? '.',
        mesh_type: params.mesh_type,
        mesh_params: params.mesh_params ?? {},
        node_name: params.node_name ?? '',
      }));
    case 'setup_environment':
      return textResult(await client.call('setup_environment', {
        node_path: params.node_path ?? '.',
        environment_params: params.environment_params ?? {},
      }));
    case 'set_material_3d':
      return textResult(await client.call('set_material_3d', {
        node_path: params.node_path ?? '.',
        material_params: params.material_params ?? {},
        surface_index: params.surface_index,
        replace_existing: params.replace_existing ?? false,
      }));
    case 'create_animation':
      return textResult(await client.call('create_animation', {
        node_path: params.node_path ?? '.',
        anim_name: params.anim_name,
        length: params.length ?? 1.0,
        library_name: params.library_name ?? '',
      }));
    case 'add_animation_track':
      return textResult(await client.call('add_animation_track', {
        node_path: params.node_path ?? '.',
        anim_name: params.anim_name,
        library_name: params.library_name ?? '',
        track_type: params.track_type,
        track_node_path: params.track_node_path,
      }));
    case 'get_animation_info':
      return textResult(await client.call('get_animation_info', {
        node_path: params.node_path ?? '.',
        anim_name: params.anim_name,
        library_name: params.library_name ?? '',
      }));
    case 'add_audio_bus':
      return textResult(await client.call('add_audio_bus', {
        bus_name: params.bus_name,
      }));
    case 'add_audio_bus_effect':
      return textResult(await client.call('add_audio_bus_effect', {
        bus_name: params.bus_name,
        effect_type: params.effect_type,
        effect_params: params.effect_params ?? {},
      }));
    case 'get_audio_bus_layout':
      return textResult(await client.call('get_audio_bus_layout', {}));
    case 'set_audio_bus_effect_params':
      return textResult(await client.call('set_audio_bus_effect_params', {
        bus_name: params.bus_name,
        effect_index: params.effect_index,
        effect_params: params.effect_params ?? {},
      }));
    case 'remove_audio_bus_effect':
      return textResult(await client.call('remove_audio_bus_effect', {
        bus_name: params.bus_name,
        effect_index: params.effect_index,
      }));
    case 'tilemap_fill_rect':
      return textResult(await client.call('tilemap_fill_rect', {
        node_path: params.node_path ?? '.',
        position: params.position,
        size: params.size,
        source_id: params.source_id,
        atlas_coords: params.atlas_coords,
        alternative_tile: params.alternative_tile ?? 0,
      }));
    case 'tilemap_get_info':
      return textResult(await client.call('tilemap_get_info', {
        node_path: params.node_path ?? '.',
      }));
    case 'set_particle_material':
      return textResult(await client.call('set_particle_material', {
        node_path: params.node_path ?? '.',
        material_params: params.material_params ?? {},
      }));
    case 'set_particle_color_gradient':
      return textResult(await client.call('set_particle_color_gradient', {
        node_path: params.node_path ?? '.',
        points: params.points ?? [],
      }));
    case 'get_particle_info':
      return textResult(await client.call('get_particle_info', {
        node_path: params.node_path ?? '.',
      }));
    case 'save_scene_live':
      return textResult(await client.call('save_scene_live', {
        path: params.path ?? '',
      }));
    case 'set_physics_material':
      return textResult(await client.call('set_physics_material', {
        node_path: params.node_path ?? '.',
        material_params: params.material_params ?? {},
      }));
    case 'set_theme_stylebox_override':
      return textResult(await client.call('set_theme_stylebox_override', {
        node_path: params.node_path ?? '.',
        override_name: params.override_name,
        style_type: params.style_type ?? 'StyleBoxFlat',
        style_params: params.style_params ?? {},
      }));
    case 'set_anchors_preset':
      return textResult(await client.call('set_anchors_preset', {
        node_path: params.node_path ?? '.',
        preset: params.preset,
        keep_offsets: params.keep_offsets ?? false,
      }));
    case 'get_node_bounds':
      return textResult(await client.call('get_node_bounds', {
        node_path: params.node_path ?? '.',
      }));
    case 'set_shader_material':
      return textResult(await client.call('set_shader_material', {
        node_path: params.node_path ?? '.',
        shader_path: params.shader_path ?? '',
        shader_params: params.shader_params ?? {},
      }));
    case 'get_shader_material_info':
      return textResult(await client.call('get_shader_material_info', {
        node_path: params.node_path ?? '.',
      }));
    case 'set_nested_property':
      return textResult(await client.call('set_nested_property', {
        node_path: params.node_path ?? '.',
        property_path: params.property_path,
        value: params.value,
      }));
    case 'set_resource_property':
      return textResult(await client.call('set_resource_property', {
        node_path: params.node_path ?? '.',
        property_name: params.property_name,
        resource_type: params.resource_type,
        resource_params: params.resource_params ?? {},
        reuse_existing: params.reuse_existing ?? true,
      }));
    case 'reload_plugin':
      return textResult(await client.call('reload_plugin', {}));
    case 'restart_editor':
      return textResult(await client.call('restart_editor', {
        save: params.save ?? true,
      }));
    case 'play_scene':
      return textResult(await client.call('play_scene', {
        scene_path: params.scene_path ?? '',
      }));
    case 'stop_scene':
      return textResult(await client.call('stop_scene', {}));
    case 'is_playing_scene':
      return textResult(await client.call('is_playing_scene', {}));
    case 'reload_project':
      return textResult(await client.call('reload_project', {}));
    case 'get_signals':
      return textResult(await client.call('get_signals', {
        node_path: params.node_path ?? '.',
      }));
    case 'find_nodes':
      return textResult(await client.call('find_nodes', {
        node_path: params.node_path ?? '.',
        type: params.type ?? '',
        name_pattern: params.name_pattern ?? '',
      }));
    case 'batch_set_properties':
      return textResult(await client.call('batch_set_properties', {
        node_path: params.node_path ?? '.',
        type: params.type ?? '',
        name_pattern: params.name_pattern ?? '',
        properties: params.properties ?? {},
      }));
    case 'get_output_log':
      return textResult(await client.call('get_output_log', {
        lines: params.lines ?? 60,
        editor_since: params.editor_since ?? 0,
      }));
    case 'get_editor_screenshot':
      return imageResult(await client.call('get_editor_screenshot', {
        max_dimension: params.max_dimension ?? 800,
      }));
    case 'get_material_info':
      return textResult(await client.call('get_material_info', {
        node_path: params.node_path ?? '.',
        surface_index: params.surface_index,
      }));
    case 'add_animation_state':
      return textResult(await client.call('add_animation_state', {
        node_path: params.node_path ?? '.',
        state_name: params.state_name,
        animation_name: params.animation_name ?? '',
      }));
    case 'add_animation_transition':
      return textResult(await client.call('add_animation_transition', {
        node_path: params.node_path ?? '.',
        from_state: params.from_state,
        to_state: params.to_state,
        transition_params: params.transition_params ?? {},
      }));
    case 'setup_navigation':
      return textResult(await client.call('setup_navigation', {
        node_path: params.node_path ?? '.',
        nav_params: params.nav_params ?? {},
        bake: params.bake ?? true,
      }));
    case 'get_resource_dependencies':
      return textResult(await client.call('get_resource_dependencies', {
        path: params.path,
      }));
    default:
      throw new Error(`Unknown bridge tool: ${name}`);
  }
}

function imageResult(result: { base64: string; format: string }) {
  return {
    content: [
      {
        type: 'image',
        data: result.base64,
        mimeType: `image/${result.format}`,
      },
    ],
  };
}

function textResult(result: any) {
  return {
    content: [
      {
        type: 'text',
        text: typeof result === 'string' ? result : JSON.stringify(result, null, 2),
      },
    ],
  };
}
