export { DEFAULT_PORT, LOOPBACK } from './loopback.js';
/** One server that the host runs for the whole machine. */
export interface LocalServerSpec {
    /** The name a client uses in the path of the URL, for example `codeindex`. */
    name: string;
    /** The executable of the server. */
    command: string;
    args?: string[];
    env?: Record<string, string>;
    cwd?: string;
}
export interface LocalHostOptions {
    servers: LocalServerSpec[];
    /** The port of the host. Default `7717`. */
    port?: number;
    /** The address of the host. Default `127.0.0.1`. */
    host?: string;
}
export interface LocalHost {
    /** The base URL of the host, for example `http://127.0.0.1:7717`. */
    readonly url: string;
    /** The URL of one server, for example `http://127.0.0.1:7717/codeindex`. */
    urlOf(name: string): string;
    /** The number of live client sessions over all servers. */
    readonly sessions: number;
    /** The number of child server processes that run. */
    readonly children: number;
    /** Stop every session and every child, then stop the HTTP server. */
    close(): Promise<void>;
}
/**
 * Start the host. The caller registers the returned URLs in the clients, and
 * calls `close` when the process stops.
 */
export declare function startLocalHost(options: LocalHostOptions): Promise<LocalHost>;
