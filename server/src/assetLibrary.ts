/**
 * The official Godot Asset Library (https://godotengine.org/asset-library):
 * search it, and install an asset into the open project.
 *
 * Search uses the library's public JSON API. Install fetches the asset's
 * details (which carry the download link, taken from the API and nowhere
 * else), downloads the zip here, and hands it to the editor addon, which
 * extracts it into the project with path-safety checks. Nothing is ever
 * enabled automatically: installing an addon only copies files; enabling a
 * plugin (which runs its code in the editor) is the user's decision.
 */

import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { BridgeClient } from './bridgeClient.js';

const API = 'https://godotengine.org/asset-library/api';
const SITE = 'https://godotengine.org/asset-library/asset';
const ALLOWED_HOSTS = ['github.com', 'codeload.github.com', 'gitlab.com', 'bitbucket.org'];
const MAX_ZIP_BYTES = 100 * 1024 * 1024;

async function getJson(url: string): Promise<any> {
  const res = await fetch(url, { signal: AbortSignal.timeout(20000), headers: { 'User-Agent': 'godot-live-mcp' } });
  if (!res.ok) throw new Error(`Asset Library request failed (${res.status}) for ${url}`);
  return res.json();
}

/** "4.7" from the open editor, so results fit the engine version; undefined if no editor. */
async function editorVersion(client: BridgeClient): Promise<string | undefined> {
  try {
    const r = await client.call('eval_expression', {
      expression: 'str(Engine.get_version_info().major) + "." + str(Engine.get_version_info().minor)',
    });
    const v = String(r?.value ?? '').replace(/"/g, '');
    return /^\d+\.\d+$/.test(v) ? v : undefined;
  } catch {
    return undefined;
  }
}

let categoryCache: { id: string; name: string }[] | null = null;
async function categoryId(name: string): Promise<string | undefined> {
  if (/^\d+$/.test(name)) return name;
  if (!categoryCache) {
    try {
      categoryCache = (await getJson(`${API}/configure?type=addon`)).categories ?? [];
    } catch {
      categoryCache = [];
    }
  }
  return categoryCache!.find(c => c.name.toLowerCase() === name.toLowerCase())?.id;
}

export async function searchAssets(args: any, client: BridgeClient) {
  const query = String(args.query ?? '').trim();
  const max = Math.min(Math.max(Number(args.max_results ?? 8), 1), 20);
  const params = new URLSearchParams({ filter: query, max_results: String(max), type: String(args.type ?? 'addon') });
  const version = String(args.godot_version ?? '') || (await editorVersion(client));
  if (version) params.set('godot_version', version);
  if (args.sort) params.set('sort', String(args.sort));
  if (args.page) params.set('page', String(args.page));
  const notes: string[] = [];
  if (args.category) {
    const id = await categoryId(String(args.category));
    if (id) params.set('category', id);
    else notes.push(`unknown category "${args.category}" — not filtered`);
  }
  const data = await getJson(`${API}/asset?${params}`);
  let results: any[] = data.result ?? [];
  if (args.support) results = results.filter(a => a.support_level === args.support);
  return {
    query,
    godot_version: version ?? 'any',
    total_matches: data.total_items,
    page: data.page,
    pages: data.pages,
    results: results.map(a => ({
      asset_id: a.asset_id,
      title: a.title,
      author: a.author,
      category: a.category,
      license: a.cost, // the API's "cost" field holds the licence
      support_level: a.support_level,
      godot_version: a.godot_version,
      version: a.version_string,
      rating: a.rating,
      updated: a.modify_date,
      page_url: `${SITE}/${a.asset_id}`,
    })),
    notes: [
      ...notes,
      'Before installing, tell the user the title, author, license and support level, and ask them to confirm unless they already named this asset.',
      'Install with install_asset {asset_id}. Installing only copies files; it does not enable the plugin.',
    ],
  };
}

export async function installAsset(args: any, client: BridgeClient) {
  const id = String(args.asset_id ?? '').trim();
  if (!/^\d+$/.test(id)) throw new Error('asset_id must be the number from search_assets');
  const a = await getJson(`${API}/asset/${id}`);
  if (!a.download_url) throw new Error(`asset ${id} has no download link`);
  const url = new URL(a.download_url);
  if (url.protocol !== 'https:' || !ALLOWED_HOSTS.includes(url.hostname)) {
    throw new Error(`refusing to download from ${url.hostname}: only ${ALLOWED_HOSTS.join(', ')} are allowed`);
  }
  const res = await fetch(url, { signal: AbortSignal.timeout(60000), headers: { 'User-Agent': 'godot-live-mcp' }, redirect: 'follow' });
  if (!res.ok) throw new Error(`download failed (${res.status}) from ${url.hostname}`);
  const declared = Number(res.headers.get('content-length') ?? 0);
  if (declared > MAX_ZIP_BYTES) throw new Error(`the download is ${Math.round(declared / 1e6)} MB, over the ${MAX_ZIP_BYTES / 1e6} MB limit`);
  const bytes = Buffer.from(await res.arrayBuffer());
  if (bytes.length > MAX_ZIP_BYTES) throw new Error(`the download is over the ${MAX_ZIP_BYTES / 1e6} MB limit`);
  if (a.download_hash) {
    const got = createHash('sha256').update(bytes).digest('hex');
    if (got !== String(a.download_hash).toLowerCase()) throw new Error('the download does not match the library\'s checksum — refusing to install');
  }

  const dir = await mkdtemp(join(tmpdir(), 'godot-asset-'));
  const zip = join(dir, `${id}.zip`);
  try {
    await writeFile(zip, bytes);
    const installed = await client.call('install_asset_zip', {
      zip_path: zip,
      name: a.title,
      include: args.include ?? 'addons',
      overwrite: args.overwrite ?? false,
    });
    return {
      asset: {
        asset_id: a.asset_id,
        title: a.title,
        author: a.author,
        license: a.cost,
        support_level: a.support_level,
        version: a.version_string,
        godot_version: a.godot_version,
        repo: a.browse_url,
        issues: a.issues_url,
        downloaded_from: `${url.hostname}${url.pathname}`,
        checksum_verified: Boolean(a.download_hash),
        size_mb: Math.round((bytes.length / 1e6) * 10) / 10,
      },
      ...installed,
      next: 'Installed but NOT enabled. Tell the user what was installed (title, author, license), and only when they agree enable the plugin in Project > Project Settings > Plugins.',
    };
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}
