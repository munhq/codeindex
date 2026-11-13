/**
 * The local host: one process runs every server that must stay on the machine,
 * and serves each of them over streamable HTTP on the loopback address.
 *
 * A client then holds one URL for a local server, and a session of that client
 * starts no copy of the server. The host starts each server once, and it answers
 * the requests of every session from that one child process. It keys the state
 * of a session by the MCP session id, so two sessions never share a transport.
 */
import { randomUUID } from "node:crypto";
import { createServer } from "node:http";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { Server as McpServer } from "@modelcontextprotocol/sdk/server/index.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { ResultSchema, } from "@modelcontextprotocol/sdk/types.js";
import { DEFAULT_PORT, LOOPBACK } from './loopback.js';
export { DEFAULT_PORT, LOOPBACK } from './loopback.js';
/** Start one child process for a server, and initialize it once for the machine. */
async function startChild(spec) {
    const client = new Client({ name: `mcp-kit-local-host`, version: "1.0.0" }, { capabilities: {} });
    await client.connect(new StdioClientTransport({
        command: spec.command,
        args: spec.args,
        env: spec.env,
        cwd: spec.cwd,
    }));
    return { spec, client };
}
/**
 * A server for one session. It reports the capabilities of the child, and it
 * forwards every request and every notification to the child, which answers the
 * requests of all sessions in turn.
 */
function sessionServer(child) {
    const capabilities = child.client.getServerCapabilities() ?? {};
    const name = child.client.getServerVersion()?.name ?? child.spec.name;
    const version = child.client.getServerVersion()?.version ?? "1.0.0";
    const server = new McpServer({ name, version }, {
        capabilities,
        instructions: `The tools of ${child.spec.name}, served by the local host of this machine.`,
    });
    server.fallbackRequestHandler = async (request) => (await child.client.request(request, ResultSchema));
    server.fallbackNotificationHandler = async (notification) => {
        await child.client.notification(notification);
    };
    return server;
}
function header(req, name) {
    const value = req.headers[name];
    return Array.isArray(value) ? value[0] : value;
}
function answer(res, code, body) {
    const text = JSON.stringify(body);
    res.writeHead(code, { "content-type": "application/json", "content-length": Buffer.byteLength(text) });
    res.end(text);
}
/**
 * Start the host. The caller registers the returned URLs in the clients, and
 * calls `close` when the process stops.
 */
export async function startLocalHost(options) {
    const host = options.host ?? LOOPBACK;
    const children = new Map();
    const sessions = new Map();
    for (const spec of options.servers) {
        if (children.has(spec.name))
            throw new Error(`the local host has two servers named ${spec.name}`);
        children.set(spec.name, await startChild(spec));
    }
    const openSession = async (path, child) => {
        const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: () => randomUUID() });
        const server = sessionServer(child);
        const session = { path, server, transport };
        transport.onclose = () => {
            const id = transport.sessionId;
            if (id)
                sessions.delete(id);
        };
        await server.connect(transport);
        return session;
    };
    const http = createServer((req, res) => {
        void (async () => {
            const path = new URL(req.url ?? "/", `http://${LOOPBACK}`).pathname.replace(/^\/+|\/+$/g, "");
            if (path === "" || path === "health") {
                answer(res, 200, { servers: [...children.keys()], sessions: sessions.size });
                return;
            }
            const child = children.get(path);
            if (!child) {
                answer(res, 404, { error: `the local host runs no server named ${path}` });
                return;
            }
            const id = header(req, "mcp-session-id");
            const known = id ? sessions.get(id) : undefined;
            if (known) {
                await known.transport.handleRequest(req, res);
                return;
            }
            if (id) {
                answer(res, 404, { error: `the local host has no session ${id}` });
                return;
            }
            if (req.method !== "POST") {
                answer(res, 400, { error: "a session starts with a POST of initialize" });
                return;
            }
            const session = await openSession(path, child);
            await session.transport.handleRequest(req, res);
            // The transport prints its session id while it answers `initialize`, so the
            // key of the session exists only after that answer.
            const opened = session.transport.sessionId;
            if (opened)
                sessions.set(opened, session);
        })().catch((error) => {
            if (res.headersSent) {
                res.end();
                return;
            }
            answer(res, 500, { error: error instanceof Error ? error.message : String(error) });
        });
    });
    await new Promise((resolve, reject) => {
        http.once("error", reject);
        http.listen(options.port ?? DEFAULT_PORT, host, () => {
            http.off("error", reject);
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
            for (const session of [...sessions.values()]) {
                sessions.delete(session.transport.sessionId ?? "");
                await session.transport.close();
                await session.server.close();
            }
            for (const child of children.values())
                await child.client.close();
            children.clear();
            await new Promise((resolve) => http.close(() => resolve()));
        },
    };
}
//# sourceMappingURL=local-host.js.map