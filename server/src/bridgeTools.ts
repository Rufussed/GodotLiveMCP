/**
 * MCP tool definitions and dispatch for tools that talk to the live
 * GodotLiveMCP runtime bridge addon (as opposed to the file/CLI-level
 * tools inherited from godot-mcp).
 */

import { BridgeClient } from './bridgeClient.js';

const NODE_PATH_PROPERTY = {
  node_path: {
    type: 'string',
    description: 'Path to the node, relative to the scene root (e.g. "Player/Sprite2D"), or "." for the root',
  },
};

const VALUE_ENCODING_NOTE =
  ' Values are Godot\'s var_to_str() string encoding (e.g. "5", "true", "\\"hello\\"", ' +
  '"Vector2(1, 2)", "Color(1, 0, 0, 1)") — not plain JSON.';

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
      'access to ProjectSettings, ClassDB, Engine, Input, OS, Time, Performance, AudioServer, and ' +
      '(in-editor) EditorInterface, e.g. "AudioServer.set_bus_volume_db(AudioServer.get_bus_index(\\"Music\\"), -6.0)". ' +
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
    description: 'Get all editor-visible properties of a live node and their current values.' + VALUE_ENCODING_NOTE,
    inputSchema: {
      type: 'object',
      properties: { ...NODE_PATH_PROPERTY },
      required: [],
    },
  },
  {
    name: 'set_property',
    description: 'Set an arbitrary property on a live node.' + VALUE_ENCODING_NOTE,
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
      'calls whenever configuring more than one property on the same node.' + VALUE_ENCODING_NOTE,
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
        rotation: { type: 'string', description: 'var_to_str()-encoded float (radians), e.g. "1.57"' },
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
      'Instantiate a Godot class (e.g. "Sprite2D", "RigidBody2D") and add it as a live child of ' +
      'parent_path. Distinct from godot-mcp\'s file-based add_node, which edits a .tscn on disk ' +
      'rather than the live tree.',
    inputSchema: {
      type: 'object',
      properties: {
        parent_path: { type: 'string', description: 'Path to the parent node, relative to the scene root, or "." for the root' },
        node_type: { type: 'string', description: 'Godot class name to instantiate, e.g. "Sprite2D"' },
        node_name: { type: 'string', description: 'Optional name for the new node' },
      },
      required: ['parent_path', 'node_type'],
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
    name: 'setup_collision',
    description:
      'Add a CollisionShape2D/3D child (with a new shape resource) to a live CollisionObject2D/3D ' +
      '(Area2D, StaticBody2D, RigidBody3D, ...). One call instead of instantiate-shape + set-props + ' +
      'instantiate-collision-node + assign + add_child.',
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
      'given properties, wrap it in a new MeshInstance3D, and add that as a live child.',
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
    description: 'Configure a live WorldEnvironment node\'s Environment resource (creating one if it has none).',
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
    description: 'Configure a live GeometryInstance3D\'s (e.g. MeshInstance3D) material_override as a StandardMaterial3D, reusing one if already set.',
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        material_params: {
          type: 'object',
          description: 'Properties to set on the StandardMaterial3D, var_to_str()-encoded, e.g. {"albedo_color": "Color(1, 0, 0, 1)"}',
        },
      },
      required: ['node_path', 'material_params'],
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
    description: 'Instantiate an AudioEffect (e.g. "AudioEffectReverb") with the given properties and add it to an existing bus.',
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
    description: 'List every audio bus with its volume/mute/solo/bypass/send settings and attached effect types.',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
];

let sharedClient: BridgeClient | null = null;
function getClient(): BridgeClient {
  if (!sharedClient) sharedClient = new BridgeClient();
  return sharedClient;
}

export async function handleBridgeTool(name: string, args: any): Promise<any> {
  const client = getClient();
  const params = args || {};

  switch (name) {
    case 'eval_expression':
      return textResult(await client.call('eval_expression', {
        node_path: params.node_path ?? '.',
        expression: params.expression,
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
        node_type: params.node_type,
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
    default:
      throw new Error(`Unknown bridge tool: ${name}`);
  }
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
