import { type Host } from './host.js';
import { type HostConfig, type ServerSpec } from './registry.js';
export declare const USAGE = "mcp-kit-host runs the servers that need the files of this machine once, and serves them over HTTP on 127.0.0.1.\n\n  mcp-kit-host [--config <file.json>]\n  mcp-kit-host --server <name>=<command>[,<arg>...] [--server ...] [--port <n>] [--host <address>]\n  mcp-kit-host install | status | uninstall\n\nA config file is JSON: {\"port\": 7717, \"servers\": [{\"name\": \"codeindex\", \"command\": \"codeindex\"}]}\nA client holds the URL of each server: http://127.0.0.1:<port>/<name>\n\nA product adds its server to the config and then calls `install` once, or calls it again when a run of this\nmachine has not kept the host yet. `install` writes the unit of the service, loads it, and leaves the config\nalone; `uninstall` stops the service and keeps the config.";
/** The options of a run of the command. */
export interface HostCommand {
    servers: ServerSpec[];
    port: number;
    host: string;
    config?: string;
}
/** Reads `--server name=command[,arg...]`, `--port`, `--host` and `--config`. Throws on a bad value. */
export declare function parseHostArgs(argv: string[], read?: (path: string) => string): HostCommand;
/** The default end of a run: a signal of the operating system. */
export declare function untilSignal(): Promise<void>;
export interface PlainHostOptions {
    config: Pick<HostConfig, 'servers' | 'port' | 'host'>;
    /** A line for each server started, and for each child that stops. */
    log?: (line: string) => void;
}
export interface PlainHost {
    /** The base URL of the host, for example `http://127.0.0.1:7717`. */
    readonly url: string;
    /** The URL of one server, for example `http://127.0.0.1:7717/codeindex`. */
    urlOf(name: string): string;
    readonly sessions: number;
    readonly children: number;
    close(): Promise<void>;
}
/**
 * Start the host. The caller registers the returned URLs in the clients, and calls `close` when the process stops.
 */
export declare function startPlainHost(options: PlainHostOptions): Promise<PlainHost>;
/** The parts of a run that a test replaces. */
export interface RunDeps {
    start?: typeof startPlainHost;
    /** The promise that ends the run. The default resolves on SIGINT or SIGTERM. */
    wait?: () => Promise<void>;
    say?: (line: string) => void;
    fail?: (line: string) => void;
    /** The machine: its home, its commands and its files. */
    host?: Host;
    platform?: NodeJS.Platform;
    /** The program of the host that the unit runs. The default is this file. */
    main?: string;
}
/**
 * `install`, `status` and `uninstall` of the one service per machine.
 *
 * `install` reads the config of the machine, writes the unit if its text changed, and loads it. What it prints a
 * person can paste: none of it is a token, and the config holds no token either.
 */
export declare function runService(command: 'install' | 'status' | 'uninstall', deps: RunDeps, say: (line: string) => void, fail: (line: string) => void): number;
/** Runs the command and returns its exit code. It serves until `wait` resolves, then closes the host. */
export declare function runHostCommand(argv: string[], deps?: RunDeps): Promise<number>;
/** The home of the person, for a run that names no file. */
export declare function homeOf(env?: NodeJS.ProcessEnv): string;
