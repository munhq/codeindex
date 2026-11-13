import type { Host } from "./host.js";
/** One server of this machine, as the file holds it. The shape is plain JSON: the file outlives the code. */
export interface ServerSpec {
    name: string;
    command: string;
    args?: string[];
    env?: Record<string, string>;
    cwd?: string;
}
/** The address and the port that the file holds when no product names another. */
export declare const DEFAULT_PORT = 7717;
export declare const LOOPBACK = "127.0.0.1";
/** The file that lists the servers of this machine. */
export interface HostConfig {
    port: number;
    host: string;
    servers: ServerSpec[];
}
/** The name of the one service per machine, on Linux and on a Mac. */
export declare const HOST_UNIT = "mcp-kit-host";
export declare const HOST_LABEL = "com.munhq.mcp-kit-host";
/** The file of the config, under the home of the machine. */
export declare function configPath(home: string): string;
/** The config, or an empty one on a machine that has none. A file that is not JSON throws, so a person sees it. */
export declare function readConfig(home: string, read: Host["read"]): HostConfig;
/**
 * Add one server to the file of this machine.
 *
 * A server of the same name is replaced when its command, arguments or environment differ, and left alone
 * when they are the same, so that a second install writes nothing and restarts nothing.
 */
export declare function addServer(h: Host, spec: ServerSpec): {
    config: HostConfig;
    changed: boolean;
};
/** The files that keep the host loaded. A Mac uses LaunchAgents, Linux uses the user systemd. */
export interface HostPaths {
    file: string;
    log: string;
    unit: string;
    label: string;
}
export declare function hostPaths(home: string, platform?: NodeJS.Platform): HostPaths;
/** The command of the host: the Node that runs this code, the program of the host, and the file of the config. */
export declare function hostArgv(args: {
    node: string;
    main: string;
    config: string;
}): string[];
/** The text of the systemd user unit. It holds the command and the log, no token. */
export declare function unitText(argv: string[], log: string): string;
/** The text of the launchd plist. It holds the command and the log, no token. */
export declare function plistText(argv: string[], log: string, label?: string): string;
/** What the install did, so a caller can print one line. */
export interface InstallResult {
    /** The files written; empty when the machine was ready. */
    written: string[];
    /** The program that loads the service, and its arguments, or none on a platform this module does not know. */
    load?: string[];
}
/**
 * Keep the host loaded on this machine.
 *
 * A service that is already running is restarted only when the text of its unit changed, because a
 * restart drops the sessions of the clients of this machine for a moment.
 */
export declare function installHost(h: Host, args: {
    argv: string[];
    platform?: NodeJS.Platform;
}): InstallResult;
/** Is the host loaded on this machine? `disabled` means the unit is not there at all. */ export declare function hostStatus(h: Host, platform?: NodeJS.Platform): "running" | "stopped" | "disabled";
/**
 * Restart the host, so that a server that a product added a moment ago is up.
 *
 * Only a host that runs is restarted. A machine with no service keeps the new entry until `installHost` starts one,
 * and a client that calls the host before that gets the 404 that names the missing server.
 */
export declare function restartHost(h: Host, platform?: NodeJS.Platform): boolean;
/** Remove the host from this machine. The config stays, because it belongs to the products, not to the service. */ export declare function uninstallHost(h: Host, platform?: NodeJS.Platform): string[];
