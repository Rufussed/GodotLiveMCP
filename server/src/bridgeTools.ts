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
  'set_transform',
  'attach_script',
  'remove_node',
  'reparent_node',
  'duplicate_node',
  'get_project_setting',
  'set_project_setting',
  'add_node_live',
  'rename_node',
  'connect_signal',
  'disconnect_signal',
  'get_node_groups',
  'set_node_groups',
  'get_editor_selection',
  'select_nodes',
  'clear_editor_selection',
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
      "don't cover. The expression runs with the target node as `self`." + VALUE_ENCODING_NOTE,
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
    name: 'get_project_setting',
    description: 'Read a live project setting by key (e.g. "physics/2d/default_gravity").' + VALUE_ENCODING_NOTE,
    inputSchema: {
      type: 'object',
      properties: { key: { type: 'string', description: 'Project setting key' } },
      required: ['key'],
    },
  },
  {
    name: 'set_project_setting',
    description: 'Set a live project setting by key.' + VALUE_ENCODING_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        key: { type: 'string', description: 'Project setting key' },
        value: { type: 'string', description: 'New value, var_to_str()-encoded' },
      },
      required: ['key', 'value'],
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
    case 'get_project_setting':
      return textResult(await client.call('get_project_setting', {
        key: params.key,
      }));
    case 'set_project_setting':
      return textResult(await client.call('set_project_setting', {
        key: params.key,
        value: params.value,
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
