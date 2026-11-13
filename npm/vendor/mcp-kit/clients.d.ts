import type { Host } from './host.js';
/**
 * The AI clients that a product's MCP server and models can be added to, and how each one takes
 * them: the command or the file, and the sign-in that follows. Each recipe was run against the real
 * client. The writers change a client's own configuration only through its CLI or as JSON, so a
 * second run changes nothing, and a file that a writer replaces keeps a copy (`<file>.munhq-bak`).
 */
export type ClientId = 'claude' | 'codex' | 'opencode' | 'pi' | 'hermes' | 'gemini' | 'cursor';
/** The server on the local host of the machine: `http://127.0.0.1:<port>/<server>`. */
export interface LocalEntry {
    /** The name of the server in the path, such as `codeindex`. */
    server: string;
    /** The port of the local host. Default `7717`. */
    port?: number;
    /**
     * The program of the server, as the host starts it once for the machine. With it, the writer adds the server to the
     * file of the machine, so a host that runs serves it. Without it, the machine must already list the server.
     */
    command?: string;
    /** The arguments of the program. */
    args?: string[];
    /** The environment of the program: no key of a product, only what the server needs to find its files. */
    env?: Record<string, string>;
}
/** A remote MCP server (Streamable HTTP) that a person signs in to with a browser. */
export interface McpServer {
    name: string;
    url: string;
    /**
     * Hermes sends a client metadata document by default, and a server that checks its `client_uri`
     * refuses it. True makes Hermes register itself with the server instead.
     */
    registerClient?: boolean;
    /**
     * A shell command that prints the headers of a call as JSON, such as `proxium token --header`. A client that runs
     * it signs in with the product's own login and needs no OAuth sign-in in a browser.
     */
    headersHelper?: string;
}
/**
 * A server as a product gives it to the writers: the URL of a hosted server, or the entry of the local host of the
 * machine. `addMcpServer` reads the URL from the entry, so every client holds a URL and none holds a command.
 */
export type McpServerInput = Omit<McpServer, 'url'> & {
    url?: string;
    /**
     * The same server, run once for the machine by the local host (`startLocalHost`), for a server that needs
     * the files of the machine.
     */
    local?: LocalEntry;
};
/** An OpenAI-compatible endpoint that a client can choose as its model provider. */
export interface Provider {
    /** The provider id in the client, such as `proxium`. */
    name: string;
    label: string;
    /** The base URL with `/v1`. */
    baseUrl: string;
    /** The environment variable that holds the key. The configuration never holds the key. */
    keyEnv: string;
    /**
     * A command that prints a fresh key (`<product> token`). Pi runs it at each request (`apiKey: "!<command>"`),
     * so it replaces `keyEnv` there. OpenCode takes no command, and keeps `keyEnv`.
     */
    keyCommand?: string;
    /**
     * The same command with JSON output (`<product> token --json`). Hermes runs it as its `key_cmd`, and OpenCode 2
     * runs it in a plugin that sets the key of each request.
     */
    keyCommandJson?: string;
    /** Headers on every call, such as the app name. */
    headers?: Record<string, string>;
    models: {
        id: string;
        label?: string;
    }[];
    defaultModel: string;
}
export interface Outcome {
    client: ClientId;
    ok: boolean;
    changed: boolean;
    message: string;
}
/** What the person does next to sign in to a server in this client. */
export interface LoginStep {
    client: ClientId;
    /** A command that opens the browser, or none when the client signs in inside a session. */
    command?: string[];
    /** The folder to run the command in. */
    cwd?: string;
    instruction: string;
}
export interface ClientSpec {
    id: ClientId;
    name: string;
    bin: string;
    /** True when the recipe comes from the client's documentation and was not run against a real install. */
    untested?: boolean;
    addMcp(h: Host, s: McpServer): Outcome;
    mcpLogin(h: Host, s: McpServer): LoginStep;
    addProvider?(h: Host, p: Provider): Outcome;
    /** True when the client runs `keyCommand` or `keyCommandJson` for its key, so it needs no key of its own. */
    takesKeyCommand?(h: Host): boolean;
}
/**
 * The OpenCode 2 plugin that gives the provider `name` a fresh key on each request: its `model.request` hook runs
 * `command` (which prints `{"access_token", "expires_in"}`) and keeps the token until two minutes before its end; the command itself gives a token with ten minutes or more left.
 * OpenCode takes no key command in its config, and reads `{env:…}` only at start.
 */
export declare function openCodeKeyPlugin(name: string, command: string): string;
export declare const CLIENTS: Record<ClientId, ClientSpec>;
/** The clients of `only` (all when omitted) whose program is on the PATH. */
export declare function installedClients(h: Host, only?: ClientId[]): ClientSpec[];
/** Adds a remote MCP server to each client. A failure of one client does not stop the others. */
/** The URL that a client holds: the hosted URL, or the local host of the machine. */
export declare function serverUrl(s: McpServerInput): string;
export declare function addMcpServer(h: Host, clients: ClientSpec[], server: McpServerInput): {
    outcomes: Outcome[];
    logins: LoginStep[];
};
/** Adds a model provider to each client that can take one. */
export declare function addProvider(h: Host, clients: ClientSpec[], provider: Provider): Outcome[];
