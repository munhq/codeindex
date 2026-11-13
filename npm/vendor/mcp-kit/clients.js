import { join } from 'node:path';
import { DEFAULT_PORT, LOOPBACK } from '../loopback.js';
import { addServer, restartHost } from './registry.js';
const done = (client, changed, message) => ({ client, ok: true, changed, message });
const failed = (client, message) => ({ client, ok: false, changed: false, message });
const last = (text) => text.trim().split('\n').filter(Boolean).slice(-2).join(' / ');
const xdg = (h) => h.env.XDG_CONFIG_HOME || join(h.home, '.config');
/** Reads a JSON file, lets `edit` change it, and writes it when `edit` answers true. */
function editJson(h, path, edit) {
    const text = h.read(path);
    let doc = {};
    if (text !== undefined && text.trim() !== '') {
        try {
            doc = JSON.parse(text);
        }
        catch {
            return { error: `${path} is not JSON, so it was not changed` };
        }
    }
    if (!edit(doc))
        return { changed: false };
    h.write(path, `${JSON.stringify(doc, null, 2)}\n`);
    return { changed: true };
}
const obj = (d, key) => (d[key] ??= {});
/** Adds `value` under `d[section][name]` unless the entry is there already. */
function putEntry(h, client, label, path, section, name, value) {
    const r = editJson(h, path, (d) => {
        const entries = obj(d, section);
        if (JSON.stringify(entries[name]) === JSON.stringify(value))
            return false;
        entries[name] = value;
        return true;
    });
    if ('error' in r)
        return failed(client, r.error);
    return done(client, r.changed, r.changed ? `${label}: added ${name} to ${path}` : `${label}: ${name} is already in ${path}`);
}
/** The major version of OpenCode, or 0 when it does not answer. */
function openCodeMajor(h) {
    const r = h.run('opencode', ['--version']);
    const m = /(\d+)\.\d+\.\d+/.exec(`${r.stdout} ${r.stderr}`);
    return m ? Number(m[1]) : 0;
}
/**
 * The OpenCode 2 plugin that gives the provider `name` a fresh key on each request: its `model.request` hook runs
 * `command` (which prints `{"access_token", "expires_in"}`) and keeps the token until two minutes before its end; the command itself gives a token with ten minutes or more left.
 * OpenCode takes no key command in its config, and reads `{env:…}` only at start.
 */
export function openCodeKeyPlugin(name, command) {
    return `// Written by the login of ${name}: each request of the provider ${name} carries a fresh key.
import { execFile } from "node:child_process";
const COMMAND = ${JSON.stringify(command)};
let kept;
function mint() {
  return new Promise((resolve, reject) =>
    execFile("/bin/sh", ["-c", COMMAND], { timeout: 15000 }, (e, out, err) =>
      e ? reject(new Error(String(err).trim() || e.message)) : resolve(String(out))),
  );
}
async function key() {
  const now = Date.now() / 1000;
  if (kept && kept.exp - now > 120) return kept.token;
  const j = JSON.parse(await mint());
  kept = { token: j.access_token, exp: now + Number(j.expires_in) };
  return kept.token;
}
export default {
  id: ${JSON.stringify(`${name}-key`)},
  async setup(ctx) {
    await ctx.session.hook("model.request", async (event) => {
      event.headers.authorization = "Bearer " + (await key());
    }, { providerID: ${JSON.stringify(name)} });
  },
};
`;
}
/**
 * OpenCode 2 with a key command: the plugin in the product's own folder (`~/.config/<name>/opencode-plugin`), listed
 * in `plugins`, and the provider with no key. OpenCode loads a plugin from any folder that `plugins` lists.
 */
function openCodeWithPlugin(h, p, command) {
    const dir = join(xdg(h), p.name, 'opencode-plugin');
    const config = join(xdg(h), 'opencode', 'opencode.json');
    const source = openCodeKeyPlugin(p.name, command);
    const pluginChanged = h.read(join(dir, 'index.js')) !== source;
    if (pluginChanged)
        h.write(join(dir, 'index.js'), source);
    const r = editJson(h, config, (d) => {
        let changed = false;
        const plugins = (Array.isArray(d.plugins) ? d.plugins : (d.plugins = []));
        if (!plugins.includes(dir)) {
            plugins.push(dir);
            changed = true;
        }
        const providers = obj(d, 'provider');
        const value = {
            npm: '@ai-sdk/openai-compatible',
            name: p.label,
            options: { baseURL: p.baseUrl, ...(p.headers ? { headers: p.headers } : {}) },
            models: Object.fromEntries(p.models.map((m) => [m.id, { name: m.label ?? m.id }])),
        };
        if (JSON.stringify(providers[p.name]) !== JSON.stringify(value)) {
            providers[p.name] = value;
            changed = true;
        }
        return changed;
    });
    if ('error' in r)
        return failed('opencode', r.error);
    const changed = r.changed || pluginChanged;
    return done('opencode', changed, changed ? `OpenCode: added ${p.name} to ${config}, with the plugin ${dir} that sets its key` : `OpenCode: ${p.name} is already in ${config}`);
}
/**
 * Registers the server in Claude Code at user scope with a `headersHelper`: Claude Code runs it for the headers of
 * each connection, so the server gets the product's login token and no OAuth step runs. Claude Code runs a helper only
 * from the user scope or a trusted workspace. An entry of an earlier login, with OAuth, is replaced.
 */
function claudeWithHelper(h, s, helper) {
    const want = { type: 'http', url: s.url, headersHelper: helper };
    const got = h.run('claude', ['mcp', 'get', s.name]);
    if (got.code === 0 && got.stdout.includes(helper) && got.stdout.includes(s.url)) {
        return done('claude', false, `Claude Code: ${s.name} is already registered with your login`);
    }
    if (got.code === 0)
        h.run('claude', ['mcp', 'remove', '--scope', 'user', s.name]);
    const r = h.run('claude', ['mcp', 'add-json', '--scope', 'user', s.name, JSON.stringify(want)]);
    if (r.code !== 0)
        return failed('claude', `Claude Code: claude mcp add-json failed: ${last(r.stderr || r.stdout)}`);
    return done('claude', true, `Claude Code: registered ${s.name} with your login, so it needs no sign-in`);
}
/** The sign-in step of a client that signs in with the product's own login: none. */
const viaLogin = (client, s) => ({ client, instruction: `${s.name} uses your login, so it needs no sign-in.` });
/**
 * Registers the server with a client CLI that has `mcp get`, `mcp remove` and `mcp add`. An entry that holds the same
 * URL stays; an entry of an earlier login, such as a local bridge command, is replaced by the URL entry.
 */
function urlByCommand(h, client, label, bin, s, before = [], after = ['--url']) {
    const got = h.run(bin, ['mcp', 'get', s.name]);
    if (got.code === 0 && got.stdout.includes(s.url))
        return done(client, false, `${label}: ${s.name} is already registered`);
    if (got.code === 0)
        h.run(bin, ['mcp', 'remove', ...(before.includes('--scope') ? ['--scope', 'user'] : []), s.name]);
    const r = h.run(bin, ['mcp', 'add', ...before, s.name, ...after, s.url]);
    if (r.code !== 0)
        return failed(client, `${label}: ${bin} mcp add failed: ${last(r.stderr || r.stdout)}`);
    return done(client, true, `${label}: registered ${s.name}`);
}
/** The transport of an entry of `pi mcp list --json`, or undefined when Pi has no entry with that name. */
function piTransport(h, name) {
    try {
        const d = JSON.parse(h.run('pi', ['mcp', 'list', '--json']).stdout);
        const found = (d.servers ?? []).find((s) => s.name === name);
        return typeof found?.transport === 'string' ? found.transport : undefined;
    }
    catch {
        return undefined;
    }
}
export const CLIENTS = {
    claude: {
        id: 'claude',
        name: 'Claude Code',
        bin: 'claude',
        addMcp: (h, s) => (s.headersHelper ? claudeWithHelper(h, s, s.headersHelper) : urlByCommand(h, 'claude', 'Claude Code', 'claude', s, ['--scope', 'user', '--transport', 'http'], [])),
        // With a headers helper Claude Code signs in with the login itself. Claude Code 2.1 has `claude mcp login <name>`;
        // an older one signs in from /mcp inside a session.
        mcpLogin: (h, s) => s.headersHelper
            ? viaLogin('claude', s)
            : h.run('claude', ['mcp', 'login', '--help']).code === 0
                ? { client: 'claude', command: ['claude', 'mcp', 'login', s.name], instruction: `Run claude mcp login ${s.name}.` }
                : { client: 'claude', instruction: `Start a new session, run /mcp, select ${s.name}, and sign in.` },
    },
    codex: {
        id: 'codex',
        untested: true,
        name: 'Codex',
        bin: 'codex',
        addMcp: (h, s) => urlByCommand(h, 'codex', 'Codex', 'codex', s),
        mcpLogin: (_h, s) => ({ client: 'codex', command: ['codex', 'mcp', 'login', s.name], instruction: `Run codex mcp login ${s.name}.` }),
    },
    opencode: {
        id: 'opencode',
        name: 'OpenCode',
        bin: 'opencode',
        addMcp: (h, s) => putEntry(h, 'opencode', 'OpenCode', join(xdg(h), 'opencode', 'opencode.json'), 'mcp', s.name, { type: 'remote', url: s.url, enabled: true }),
        // `opencode mcp auth` needs the home folder as its working folder: in a project folder its plugins do not finish activating.
        mcpLogin: (h, s) => ({ client: 'opencode', command: ['opencode', 'mcp', 'auth', s.name], cwd: h.home, instruction: `Run opencode mcp auth ${s.name} in your home folder.` }),
        takesKeyCommand: (h) => openCodeMajor(h) >= 2,
        addProvider: (h, p) => p.keyCommandJson && openCodeMajor(h) >= 2
            ? openCodeWithPlugin(h, p, p.keyCommandJson)
            : putEntry(h, 'opencode', 'OpenCode', join(xdg(h), 'opencode', 'opencode.json'), 'provider', p.name, {
                npm: '@ai-sdk/openai-compatible',
                name: p.label,
                env: [p.keyEnv],
                options: { baseURL: p.baseUrl, apiKey: `{env:${p.keyEnv}}`, ...(p.headers ? { headers: p.headers } : {}) },
                models: Object.fromEntries(p.models.map((m) => [m.id, { name: m.label ?? m.id }])),
            }),
    },
    pi: {
        id: 'pi',
        name: 'Pi',
        bin: 'pi',
        // `pi mcp list --json` exits 1 when any server fails, such as one that waits for a sign-in, so the transport of the entry decides.
        addMcp: (h, s) => {
            if (piTransport(h, s.name) === s.url)
                return done('pi', false, `Pi: ${s.name} is already registered`);
            // `pi mcp add` adds or replaces, so an entry of an earlier login becomes the URL entry.
            const r = h.run('pi', ['mcp', 'add', s.name, '--url', s.url]);
            return r.code === 0 ? done('pi', true, `Pi: registered ${s.name}`) : failed('pi', `Pi: pi mcp add failed: ${last(r.stderr || r.stdout)}`);
        },
        mcpLogin: (_h, s) => ({ client: 'pi', command: ['pi', 'mcp', 'login', s.name], instruction: `Run pi mcp login ${s.name}.` }),
        takesKeyCommand: () => true,
        addProvider: (h, p) => putEntry(h, 'pi', 'Pi', join(h.home, '.pi', 'agent', 'models.json'), 'providers', p.name, {
            baseUrl: p.baseUrl,
            api: 'openai-completions',
            apiKey: p.keyCommand ? `!${p.keyCommand}` : `$${p.keyEnv}`,
            ...(p.headers ? { headers: p.headers } : {}),
            models: p.models.map((m) => ({ id: m.id })),
        }),
    },
    hermes: {
        id: 'hermes',
        name: 'Hermes',
        bin: 'hermes',
        addMcp: (h, s) => hermesSet(h, 'mcp_servers', s.name, { url: s.url, auth: 'oauth', ...(s.registerClient ? { oauth: { cimd: false } } : {}) }),
        mcpLogin: (_h, s) => ({ client: 'hermes', command: ['hermes', 'mcp', 'login', s.name], instruction: `Run hermes mcp login ${s.name}.` }),
        takesKeyCommand: () => true,
        addProvider: (h, p) => hermesSet(h, 'providers', p.name, {
            api: p.baseUrl,
            ...(p.keyCommandJson ? { key_cmd: p.keyCommandJson } : { key_env: p.keyEnv }),
            default_model: p.defaultModel,
            ...(p.headers ? { extra_headers: p.headers } : {}),
        }),
    },
    gemini: {
        id: 'gemini',
        untested: true,
        name: 'Gemini CLI',
        bin: 'gemini',
        addMcp: (h, s) => putEntry(h, 'gemini', 'Gemini CLI', join(h.home, '.gemini', 'settings.json'), 'mcpServers', s.name, { httpUrl: s.url }),
        mcpLogin: (_h, s) => ({ client: 'gemini', instruction: `Start gemini, run /mcp auth ${s.name}, and sign in.` }),
    },
    cursor: {
        id: 'cursor',
        untested: true,
        name: 'Cursor',
        bin: 'cursor',
        addMcp: (h, s) => putEntry(h, 'cursor', 'Cursor', join(h.home, '.cursor', 'mcp.json'), 'mcpServers', s.name, { url: s.url }),
        mcpLogin: (_h, s) => ({ client: 'cursor', instruction: `Open Cursor, and sign in to ${s.name} when it asks.` }),
    },
};
/** Hermes keeps its configuration in YAML. Its own CLI reads and writes the entry, so the kit has no YAML parser. */
function hermesSet(h, section, name, value) {
    const key = `${section}.${name}`;
    const have = h.run('hermes', ['config', 'get', '--json', key]);
    if (have.code === 0) {
        try {
            if (JSON.stringify(JSON.parse(have.stdout)) === JSON.stringify(value))
                return done('hermes', false, `Hermes: ${name} is already in ${section}`);
        }
        catch {
            // not JSON: set it again
        }
    }
    const r = h.run('hermes', ['config', 'set', key, JSON.stringify(value)]);
    if (r.code !== 0)
        return failed('hermes', `Hermes: hermes config set ${key} failed: ${last(r.stderr || r.stdout)}`);
    return done('hermes', true, `Hermes: set ${key}`);
}
/** The clients of `only` (all when omitted) whose program is on the PATH. */
export function installedClients(h, only) {
    return Object.values(CLIENTS).filter((c) => (!only || only.includes(c.id)) && h.run('sh', ['-c', `command -v ${c.bin}`]).code === 0);
}
/** Adds a remote MCP server to each client. A failure of one client does not stop the others. */
/** The URL that a client holds: the hosted URL, or the local host of the machine. */
export function serverUrl(s) {
    if (s.local)
        return `http://${LOOPBACK}:${s.local.port ?? DEFAULT_PORT}/${s.local.server}`;
    if (s.url)
        return s.url;
    throw new Error(`the server ${s.name} has neither a url nor a local entry`);
}
export function addMcpServer(h, clients, server) {
    const target = { ...server, url: serverUrl(server) };
    // A server that needs the files of the machine goes into the file of the machine first, so the URL below names a
    // server that the host serves. A host that runs restarts once and picks up the new entry.
    const local = server.local;
    if (local?.command) {
        const added = addServer(h, { name: local.server, command: local.command, args: local.args, env: local.env });
        if (added.changed)
            restartHost(h);
    }
    const outcomes = [];
    const logins = [];
    for (const c of clients) {
        const o = c.addMcp(h, target);
        outcomes.push(o);
        if (o.ok)
            logins.push(c.mcpLogin(h, target));
    }
    return { outcomes, logins };
}
/** Adds a model provider to each client that can take one. */
export function addProvider(h, clients, provider) {
    return clients.flatMap((c) => (c.addProvider ? [c.addProvider(h, provider)] : []));
}
//# sourceMappingURL=clients.js.map