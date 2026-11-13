/**
 * The servers of one machine, and the one host that serves them.
 *
 * A product does not start its own host. It adds its server to the file this module keeps, installs the
 * service once when the machine has none, and writes its client entries as `http://127.0.0.1:<port>/<name>`.
 * The host then starts each server once and gives every session its own streamable-HTTP transport.
 *
 * The file holds no token. The command of a server may read its own secret at start, and that is the whole
 * of its environment: nothing from the caller of `installHost` reaches the host process.
 */
import { dirname, join } from "node:path";
/** The address and the port that the file holds when no product names another. */
export const DEFAULT_PORT = 7717;
export const LOOPBACK = "127.0.0.1";
/** The name of the one service per machine, on Linux and on a Mac. */
export const HOST_UNIT = "mcp-kit-host";
export const HOST_LABEL = "com.munhq.mcp-kit-host";
/** The file of the config, under the home of the machine. */
export function configPath(home) {
    return join(home, ".config", "mcp-kit", "host.json");
}
/** The config, or an empty one on a machine that has none. A file that is not JSON throws, so a person sees it. */
export function readConfig(home, read) {
    const text = read(configPath(home));
    if (text === undefined || text.trim() === "")
        return { port: DEFAULT_PORT, host: LOOPBACK, servers: [] };
    const parsed = JSON.parse(text);
    return {
        port: typeof parsed.port === "number" && parsed.port >= 0 ? parsed.port : DEFAULT_PORT,
        host: typeof parsed.host === "string" && parsed.host !== "" ? parsed.host : LOOPBACK,
        servers: Array.isArray(parsed.servers) ? parsed.servers.filter(usable) : [],
    };
}
function usable(spec) {
    return typeof spec?.name === "string" && spec.name !== "" && typeof spec.command === "string" && spec.command !== "";
}
/**
 * Add one server to the file of this machine.
 *
 * A server of the same name is replaced when its command, arguments or environment differ, and left alone
 * when they are the same, so that a second install writes nothing and restarts nothing.
 */
export function addServer(h, spec) {
    if (!usable(spec))
        throw new Error(`a server needs a name and a command: ${JSON.stringify(spec)}`);
    const config = readConfig(h.home, h.read);
    const at = config.servers.findIndex((s) => s.name === spec.name);
    const same = at >= 0 && JSON.stringify(config.servers[at]) === JSON.stringify(spec);
    if (same)
        return { config, changed: false };
    const servers = at >= 0 ? config.servers.map((s, i) => (i === at ? spec : s)) : [...config.servers, spec];
    const next = { ...config, servers };
    h.write(configPath(h.home), `${JSON.stringify(next, null, 2)}\n`, { mode: 0o600, dirMode: 0o700 });
    return { config: next, changed: true };
}
export function hostPaths(home, platform = process.platform) {
    if (platform === "darwin") {
        return {
            file: join(home, "Library", "LaunchAgents", `${HOST_LABEL}.plist`),
            log: join(home, "Library", "Logs", `${HOST_UNIT}.log`),
            unit: HOST_UNIT,
            label: HOST_LABEL,
        };
    }
    return {
        file: join(home, ".config", "systemd", "user", `${HOST_UNIT}.service`),
        log: join(home, ".local", "state", HOST_UNIT, "host.log"),
        unit: HOST_UNIT,
        label: HOST_LABEL,
    };
}
/** The command of the host: the Node that runs this code, the program of the host, and the file of the config. */
export function hostArgv(args) {
    return [args.node, args.main, "--config", args.config];
}
function unitQuote(value) {
    return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\$/g, "$$$$").replace(/%/g, "%%")}"`;
}
function xml(value) {
    return value
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&apos;");
}
/** The text of the systemd user unit. It holds the command and the log, no token. */
export function unitText(argv, log) {
    return [
        "[Unit]",
        "Description=MCP host: the local servers of this machine on the loopback address",
        "After=network.target",
        "",
        "[Service]",
        `ExecStart=${argv.map(unitQuote).join(" ")}`,
        "Restart=always",
        "RestartSec=2",
        `StandardOutput=append:${log}`,
        `StandardError=append:${log}`,
        "",
        "[Install]",
        "WantedBy=default.target",
        "",
    ].join("\n");
}
/** The text of the launchd plist. It holds the command and the log, no token. */
export function plistText(argv, log, label = HOST_LABEL) {
    return [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
        '<plist version="1.0">',
        "<dict>",
        `  <key>Label</key><string>${xml(label)}</string>`,
        "  <key>ProgramArguments</key>",
        "  <array>",
        ...argv.map((a) => `    <string>${xml(a)}</string>`),
        "  </array>",
        "  <key>RunAtLoad</key><true/>",
        "  <key>KeepAlive</key><true/>",
        `  <key>StandardOutPath</key><string>${xml(log)}</string>`,
        `  <key>StandardErrorPath</key><string>${xml(log)}</string>`,
        "</dict>",
        "</plist>",
        "",
    ].join("\n");
}
/**
 * Keep the host loaded on this machine.
 *
 * A service that is already running is restarted only when the text of its unit changed, because a
 * restart drops the sessions of the clients of this machine for a moment.
 */
export function installHost(h, args) {
    const platform = args.platform ?? process.platform;
    if (platform !== "linux" && platform !== "darwin")
        return { written: [] };
    const paths = hostPaths(h.home, platform);
    // systemd makes the log file, but not its folder: a missing folder stops the service with 209/STDOUT before the host
    // starts, and the service then restarts for ever. Make the folder first, so the first install runs on the first try.
    h.run("mkdir", ["-p", dirname(paths.log)]);
    const text = platform === "darwin" ? plistText(args.argv, paths.log, paths.label) : unitText(args.argv, paths.log);
    const written = [];
    if (h.read(paths.file) !== text) {
        h.write(paths.file, text);
        written.push(paths.file);
    }
    if (platform === "darwin") {
        h.run("launchctl", ["unload", paths.file]);
        h.run("launchctl", ["load", "-w", paths.file]);
        return { written, load: ["launchctl", "load", "-w", paths.file] };
    }
    if (written.length > 0)
        h.run("systemctl", ["--user", "daemon-reload"]);
    const enabled = h.run("systemctl", ["--user", "enable", "--now", `${paths.unit}.service`]);
    return { written, load: enabled.code === 0 ? undefined : ["systemctl", "--user", "enable", "--now", `${paths.unit}.service`] };
}
/** Is the host loaded on this machine? `disabled` means the unit is not there at all. */ export function hostStatus(h, platform = process.platform) {
    if (platform !== "linux" && platform !== "darwin")
        return "disabled";
    const paths = hostPaths(h.home, platform);
    if (h.read(paths.file) === undefined)
        return "disabled";
    const got = platform === "darwin" ? h.run("launchctl", ["list", paths.label]) : h.run("systemctl", ["--user", "is-active", `${paths.unit}.service`]);
    return got.code === 0 ? "running" : "stopped";
}
/**
 * Restart the host, so that a server that a product added a moment ago is up.
 *
 * Only a host that runs is restarted. A machine with no service keeps the new entry until `installHost` starts one,
 * and a client that calls the host before that gets the 404 that names the missing server.
 */
export function restartHost(h, platform = process.platform) {
    if (hostStatus(h, platform) !== "running")
        return false;
    const paths = hostPaths(h.home, platform);
    if (platform === "darwin") {
        h.run("launchctl", ["unload", paths.file]);
        return h.run("launchctl", ["load", "-w", paths.file]).code === 0;
    }
    return h.run("systemctl", ["--user", "restart", `${paths.unit}.service`]).code === 0;
}
/** Remove the host from this machine. The config stays, because it belongs to the products, not to the service. */ export function uninstallHost(h, platform = process.platform) {
    if (platform !== "linux" && platform !== "darwin")
        return [];
    const paths = hostPaths(h.home, platform);
    if (h.read(paths.file) === undefined)
        return [];
    if (platform === "darwin")
        h.run("launchctl", ["unload", paths.file]);
    else
        h.run("systemctl", ["--user", "disable", "--now", `${paths.unit}.service`]);
    h.write(paths.file, "");
    return [paths.file];
}
//# sourceMappingURL=registry.js.map