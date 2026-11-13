/**
 * The host that runs the servers of this machine, with no dependency other than Node.
 *
 * It reads the one file that the products write (`~/.config/mcp-kit/host.json`), starts every server as a child
 * process over stdio, and serves each of them over Streamable HTTP on the loopback address. A client then holds a
 * URL for a local server, and a session of that client starts no copy of the server: the host starts each server
 * once per machine and answers the sessions from that one child.
 *
 * The file imports only Node's own modules and the two files of this folder (`registry.js`, `host.js`), because a
 * product vendors the compiled folder instead of installing this package, which needs the MCP SDK.
 */
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { systemHost } from './host.js';
import { DEFAULT_PORT, LOOPBACK, configPath, hostArgv, hostStatus, installHost, readConfig, uninstallHost, } from './registry.js';
const MAX_BODY = 8 * 1024 * 1024;
const PROTOCOL = '2025-06-18';
export const USAGE = `mcp-kit-host runs the servers that need the files of this machine once, and serves them over HTTP on ${LOOPBACK}.

  mcp-kit-host [--config <file.json>]
  mcp-kit-host --server <name>=<command>[,<arg>...] [--server ...] [--port <n>] [--host <address>]
  mcp-kit-host install | status | uninstall

A config file is JSON: {"port": ${DEFAULT_PORT}, "servers": [{"name": "codeindex", "command": "codeindex"}]}
A client holds the URL of each server: http://${LOOPBACK}:<port>/<name>

A product adds its server to the config and then calls \`install\` once, or calls it again when a run of this
machine has not kept the host yet. \`install\` writes the unit of the service, loads it, and leaves the config
alone; \`uninstall\` stops the service and keeps the config.`;
function parseServer(text) {
    const at = text.indexOf('=');
    if (at < 1)
        throw new Error(`a server is name=command[,arg...], not ${text}`);
    const [bin, ...rest] = text.slice(at + 1).split(',');
    if (!bin)
        throw new Error(`a server needs a command: ${text}`);
    return { name: text.slice(0, at), command: bin, args: rest.length > 0 ? rest : undefined };
}
/** Reads `--server name=command[,arg...]`, `--port`, `--host` and `--config`. Throws on a bad value. */
export function parseHostArgs(argv, read = (p) => readFileSync(p, 'utf8')) {
    const command = { servers: [], port: DEFAULT_PORT, host: LOOPBACK };
    for (let i = 0; i < argv.length; i += 1) {
        const flag = argv[i];
        if (flag === '--server') {
            const text = argv[i + 1];
            i += 1;
            if (!text)
                throw new Error('--server needs a value, such as codeindex=codeindex');
            command.servers.push(parseServer(text));
        }
        else if (flag === '--port') {
            const text = argv[i + 1];
            i += 1;
            const port = Number(text);
            if (!Number.isInteger(port) || port < 0)
                throw new Error(`--port needs a number, not ${text}`);
            command.port = port;
        }
        else if (flag === '--host') {
            const text = argv[i + 1];
            i += 1;
            if (!text)
                throw new Error('--host needs an address');
            command.host = text;
        }
        else if (flag === '--config') {
            const path = argv[i + 1];
            i += 1;
            if (!path)
                throw new Error('--config needs a file');
            const file = JSON.parse(read(path));
            command.config = path;
            if (file.port !== undefined)
                command.port = file.port;
            if (file.host !== undefined)
                command.host = file.host;
            if (file.servers)
                command.servers.push(...file.servers.map((s) => ({ ...s })));
        }
        else {
            throw new Error(`unknown argument ${flag}`);
        }
    }
    if (command.servers.length === 0)
        throw new Error('give at least one --server, or a --config with servers');
    for (const spec of command.servers) {
        if (!spec.name || !spec.command)
            throw new Error(`a server needs a name and a command: ${JSON.stringify(spec)}`);
    }
    return command;
}
/** The default end of a run: a signal of the operating system. */
export function untilSignal() {
    return new Promise((resolve) => {
        const stop = () => {
            process.off('SIGINT', stop);
            process.off('SIGTERM', stop);
            resolve();
        };
        process.on('SIGINT', stop);
        process.on('SIGTERM', stop);
    });
}
/**
 * One server of this machine, as a child process that speaks JSON-RPC over stdio, one message to a line.
 *
 * The child starts once. Every request of every session goes to it with an id of our own, so two sessions that
 * happen to use the same id never collide, and each answer goes back to the session that asked.
 */
class ChildServer {
    log;
    spec;
    /** The answer of `initialize`, which every session receives when it starts. */
    init;
    proc;
    buffer = '';
    nextId = 0;
    pending = new Map();
    gone;
    constructor(spec, log) {
        this.log = log;
        this.spec = spec;
        this.proc = spawn(spec.command, spec.args ?? [], {
            cwd: spec.cwd,
            env: { ...process.env, ...spec.env },
            stdio: ['pipe', 'pipe', 'pipe'],
        });
        this.proc.stdout?.setEncoding('utf8');
        this.proc.stderr?.setEncoding('utf8');
        this.proc.stdout?.on('data', (text) => this.read(text));
        this.proc.stderr?.on('data', (text) => this.log(`${spec.name}: ${text.trimEnd()}`));
        this.proc.on('exit', (code, signal) => {
            this.gone = `the server ${spec.name} stopped (${signal ?? `exit ${code}`})`;
            for (const [, resolve] of this.pending)
                resolve({ jsonrpc: '2.0', error: { code: -32000, message: this.gone } });
            this.pending.clear();
        });
    }
    /** Start the child and initialize it for the whole machine. */
    async start() {
        this.write({
            jsonrpc: '2.0',
            id: this.take(),
            method: 'initialize',
            params: { protocolVersion: PROTOCOL, capabilities: {}, clientInfo: { name: 'mcp-kit-host', version: VERSION } },
        });
        const answer = await this.request('initialize', undefined, true);
        if (answer.error)
            throw new Error(`${this.spec.name}: ${JSON.stringify(answer.error)}`);
        this.init = answer;
        this.write({ jsonrpc: '2.0', method: 'notifications/initialized' });
    }
    /** Is the child alive? The message says why not, when it is not. */
    stopped() {
        return this.gone;
    }
    /** Send a request and wait for its answer. The id of the caller is never used. */
    request(method, params, preallocated = false) {
        const id = preallocated ? this.nextId : this.take();
        if (!preallocated) {
            this.write({ jsonrpc: '2.0', id, method, params });
        }
        return new Promise((resolve) => {
            this.pending.set(id, resolve);
        });
    }
    /** Send a notification. It has no answer. */
    notify(method, params) {
        this.write({ jsonrpc: '2.0', method, params });
    }
    async close() {
        if (this.proc.exitCode !== null || this.proc.signalCode !== null)
            return;
        const ended = new Promise((resolve) => this.proc.once('exit', () => resolve()));
        this.proc.kill('SIGTERM');
        const timer = setTimeout(() => this.proc.kill('SIGKILL'), 3000);
        await ended;
        clearTimeout(timer);
    }
    take() {
        this.nextId += 1;
        return this.nextId;
    }
    write(message) {
        if (this.gone)
            return;
        this.proc.stdin?.write(`${JSON.stringify(message)}\n`);
    }
    read(text) {
        this.buffer += text;
        let at = this.buffer.indexOf('\n');
        while (at >= 0) {
            const line = this.buffer.slice(0, at).trim();
            this.buffer = this.buffer.slice(at + 1);
            at = this.buffer.indexOf('\n');
            if (line === '')
                continue;
            let message;
            try {
                message = JSON.parse(line);
            }
            catch {
                this.log(`${this.spec.name}: not JSON: ${line.slice(0, 200)}`);
                continue;
            }
            const id = typeof message.id === 'number' ? message.id : undefined;
            const resolve = id === undefined ? undefined : this.pending.get(id);
            if (id !== undefined && resolve) {
                this.pending.delete(id);
                resolve(message);
                continue;
            }
            if (typeof message.method === 'string' && message.id !== undefined) {
                // A request from the server to its client: this host holds no tools of its own, so it refuses it.
                this.write({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'the local host answers no request of a server' } });
                continue;
            }
            if (typeof message.method === 'string')
                this.log(`${this.spec.name}: ${message.method}`);
        }
    }
}
const VERSION = '1.0.0';
function header(req, name) {
    const value = req.headers[name];
    return Array.isArray(value) ? value[0] : value;
}
function json(res, code, body, extra = {}) {
    const text = JSON.stringify(body);
    res.writeHead(code, {
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(text),
        ...extra,
    });
    res.end(text);
}
function empty(res, code, extra = {}) {
    res.writeHead(code, extra);
    res.end();
}
function body(req) {
    return new Promise((resolve, reject) => {
        let size = 0;
        const chunks = [];
        req.on('data', (chunk) => {
            size += chunk.length;
            if (size > MAX_BODY) {
                reject(new Error('the request is too large'));
                req.destroy();
                return;
            }
            chunks.push(chunk);
        });
        req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
        req.on('error', reject);
    });
}
/** Is the request from this machine? The host serves the loopback address only. */
function local(req) {
    const name = (header(req, 'host') ?? '').split(':')[0];
    return name === '127.0.0.1' || name === 'localhost' || name === '[::1]';
}
/**
 * Start the host. The caller registers the returned URLs in the clients, and calls `close` when the process stops.
 */
export async function startPlainHost(options) {
    const log = options.log ?? (() => undefined);
    const host = options.config.host ?? LOOPBACK;
    const children = new Map();
    const sessions = new Map();
    try {
        for (const spec of options.config.servers) {
            if (children.has(spec.name))
                throw new Error(`the local host has two servers named ${spec.name}`);
            const child = new ChildServer(spec, log);
            await child.start();
            children.set(spec.name, child);
        }
    }
    catch (error) {
        for (const child of children.values())
            await child.close();
        throw error;
    }
    /** Forward one message of a client to the child, and answer with the message that goes back. */
    const forward = async (child, message) => {
        const method = typeof message.method === 'string' ? message.method : undefined;
        if (method === undefined)
            return undefined;
        if (message.id === undefined) {
            child.notify(method, message.params);
            return undefined;
        }
        if (method === 'initialize' && child.init) {
            return { jsonrpc: '2.0', id: message.id, result: child.init.result };
        }
        const answer = await child.request(method, message.params);
        return { ...answer, id: message.id };
    };
    const http = createServer((req, res) => {
        void (async () => {
            if (!local(req)) {
                json(res, 400, { error: 'the local host serves 127.0.0.1 only' });
                return;
            }
            const path = new URL(req.url ?? '/', `http://${LOOPBACK}`).pathname.replace(/^\/+|\/+$/g, '');
            if (path === '' || path === 'health') {
                json(res, 200, {
                    servers: [...children.keys()],
                    sessions: sessions.size,
                    stopped: [...children.entries()].filter(([, c]) => c.stopped()).map(([name, c]) => ({ name, why: c.stopped() })),
                });
                return;
            }
            const child = children.get(path);
            if (!child) {
                json(res, 404, { error: `the local host runs no server named ${path}` });
                return;
            }
            if (child.stopped()) {
                json(res, 503, { error: child.stopped() });
                return;
            }
            const id = header(req, 'mcp-session-id');
            if (req.method === 'DELETE') {
                if (id === undefined || !sessions.has(id)) {
                    json(res, 404, { error: `the local host has no session ${id ?? ''}` });
                    return;
                }
                sessions.delete(id);
                empty(res, 204);
                return;
            }
            if (req.method !== 'POST') {
                json(res, 405, { error: 'the local host answers POST and DELETE; it sends no stream of its own' }, { allow: 'POST, DELETE' });
                return;
            }
            const text = await body(req);
            let parsed;
            try {
                parsed = JSON.parse(text);
            }
            catch {
                json(res, 400, { error: 'the request is not JSON' });
                return;
            }
            const messages = Array.isArray(parsed) ? parsed : [parsed];
            const starts = messages.some((m) => m.method === 'initialize');
            let session = id === undefined ? undefined : sessions.get(id);
            if (session === undefined) {
                if (id !== undefined) {
                    json(res, 404, { error: `the local host has no session ${id}` });
                    return;
                }
                if (!starts) {
                    json(res, 400, { error: 'a session starts with a POST of initialize' });
                    return;
                }
                session = { server: path, protocol: header(req, 'mcp-protocol-version') ?? PROTOCOL };
                sessions.set(randomUUID(), session);
            }
            const sessionId = [...sessions.entries()].find(([, s]) => s === session)?.[0];
            const extra = sessionId ? { 'mcp-session-id': sessionId, 'mcp-protocol-version': session.protocol } : {};
            const answers = [];
            for (const message of messages) {
                const answer = await forward(child, message);
                if (answer)
                    answers.push(answer);
            }
            if (answers.length === 0)
                empty(res, 202, extra);
            else
                json(res, 200, Array.isArray(parsed) ? answers : answers[0], extra);
        })().catch((error) => {
            if (res.headersSent) {
                res.end();
                return;
            }
            json(res, 500, { error: error instanceof Error ? error.message : String(error) });
        });
    });
    await new Promise((resolve, reject) => {
        http.once('error', reject);
        http.listen(options.config.port ?? DEFAULT_PORT, host, () => {
            http.off('error', reject);
            resolve();
        });
    });
    const port = http.address().port;
    const url = `http://${host}:${port}`;
    return {
        url,
        urlOf: (name) => `${url}/${name}`,
        get sessions() {
            return sessions.size;
        },
        get children() {
            return children.size;
        },
        async close() {
            sessions.clear();
            for (const child of children.values())
                await child.close();
            children.clear();
            await new Promise((resolve) => http.close(() => resolve()));
        },
    };
}
/** The text of an empty config: the service needs a file to read on a machine that has none. */
function emptyConfig() {
    return `${JSON.stringify({ port: DEFAULT_PORT, host: LOOPBACK, servers: [] }, null, 2)}\n`;
}
/**
 * `install`, `status` and `uninstall` of the one service per machine.
 *
 * `install` reads the config of the machine, writes the unit if its text changed, and loads it. What it prints a
 * person can paste: none of it is a token, and the config holds no token either.
 */
export function runService(command, deps, say, fail) {
    const h = deps.host ?? systemHost(process.env);
    const platform = deps.platform ?? process.platform;
    const main = deps.main ?? fileURLToPath(import.meta.url);
    try {
        if (command === 'install') {
            if (h.read(configPath(h.home)) === undefined)
                h.write(configPath(h.home), emptyConfig(), { mode: 0o600, dirMode: 0o700 });
            const config = readConfig(h.home, h.read);
            const r = installHost(h, { argv: hostArgv({ node: process.execPath, main, config: configPath(h.home) }), platform });
            for (const file of r.written)
                say(`mcp-kit-host: wrote ${file}`);
            if (r.load) {
                fail(`mcp-kit-host: the service manager did not load the service. Run: ${r.load.join(' ')}`);
                return 1;
            }
            const names = config.servers.map((s) => s.name).join(', ') || 'no server yet';
            say(`mcp-kit-host: the service runs, with ${names} on http://${LOOPBACK}:${config.port}`);
            return 0;
        }
        if (command === 'status') {
            const config = readConfig(h.home, h.read);
            say(`mcp-kit-host: ${hostStatus(h, platform)} on http://${LOOPBACK}:${config.port}`);
            for (const spec of config.servers)
                say(`mcp-kit-host: ${spec.name} http://${LOOPBACK}:${config.port}/${spec.name} runs ${spec.command}`);
            return 0;
        }
        const removed = uninstallHost(h, platform);
        say(removed.length > 0 ? `mcp-kit-host: stopped, and cleared ${removed.join(', ')}. The config stays.` : 'mcp-kit-host: no service on this machine');
        return 0;
    }
    catch (error) {
        fail(`mcp-kit-host: ${error.message}`);
        return 1;
    }
}
/** Runs the command and returns its exit code. It serves until `wait` resolves, then closes the host. */
export async function runHostCommand(argv, deps = {}) {
    const say = deps.say ?? ((line) => console.log(line));
    const fail = deps.fail ?? ((line) => console.error(line));
    if (argv.includes('--help') || argv.includes('-h')) {
        say(USAGE);
        return 0;
    }
    if (argv[0] === 'install' || argv[0] === 'status' || argv[0] === 'uninstall') {
        return runService(argv[0], deps, say, fail);
    }
    let command;
    try {
        command = parseHostArgs(argv);
    }
    catch (error) {
        fail(`mcp-kit-host: ${error.message}\n\n${USAGE}`);
        return 2;
    }
    const start = deps.start ?? startPlainHost;
    let host;
    try {
        host = await start({ config: command, log: (line) => fail(line) });
    }
    catch (error) {
        fail(`mcp-kit-host: ${error.message}`);
        return 1;
    }
    for (const spec of command.servers)
        say(`mcp-kit-host: ${spec.name} ${host.urlOf(spec.name)}`);
    say(`mcp-kit-host: listening on ${host.url}`);
    try {
        await (deps.wait ?? untilSignal)();
    }
    finally {
        await host.close();
    }
    say('mcp-kit-host: closed');
    return 0;
}
/** The home of the person, for a run that names no file. */
export function homeOf(env = process.env) {
    return env.HOME ?? homedir();
}
//# sourceMappingURL=host-plain.js.map