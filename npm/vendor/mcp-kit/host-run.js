import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DEFAULT_PORT, LOOPBACK, startLocalHost } from '../local-host.js';
import { systemHost } from './host.js';
import { configPath, hostArgv, hostStatus, installHost, readConfig, uninstallHost } from './registry.js';
/**
 * `mcp-kit-host`: it runs the servers that need the files of this machine once, and serves each one
 * over Streamable HTTP on the loopback address, so every AI session of the machine reaches it
 * without a copy of its own. A product installs it as its own command (`<product> mcp host`).
 */
export const USAGE = `mcp-kit-host runs the servers that need the files of this machine once, and serves them over HTTP on ${LOOPBACK}.

  mcp-kit-host [--config <file.json>]
  mcp-kit-host --server <name>=<command>[,<arg>...] [--server ...] [--port <n>] [--host <address>]
  mcp-kit-host install | status | uninstall

A config file is JSON: {"port": ${DEFAULT_PORT}, "servers": [{"name": "codeindex", "command": "codeindex"}]}
A client holds the URL of each server: http://${LOOPBACK}:<port>/<name>

A product adds its server to the config and then calls \`install\` once, or calls it again when a run of this
machine has not kept the host yet. \`install\` writes the unit of the service, loads it, and leaves the config
alone; \`uninstall\` stops the service and keeps the config.`;
/** The text of an empty config: the service needs a file to read on a machine that has none. */
function emptyConfig() {
    return `${JSON.stringify({ port: DEFAULT_PORT, host: LOOPBACK, servers: [] }, null, 2)}\n`;
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
function parseServer(text) {
    const at = text.indexOf('=');
    if (at < 1)
        throw new Error(`a server is name=command[,arg...], not ${text}`);
    const [bin, ...rest] = text.slice(at + 1).split(',');
    if (!bin)
        throw new Error(`a server needs a command: ${text}`);
    return { name: text.slice(0, at), command: bin, args: rest.length > 0 ? rest : undefined };
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
 * `install`, `status` and `uninstall` of the one service per machine.
 *
 * `install` reads the config of the machine, writes the unit if its text changed, and loads it. What it prints a
 * person can paste: none of it is a token, and the config holds no token either.
 */
export function runService(command, deps, say, fail) {
    const h = deps.host ?? systemHost(process.env);
    const platform = deps.platform ?? process.platform;
    const main = deps.main ?? fileURLToPath(new URL('./host-main.js', import.meta.url));
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
export async function runLocalHostCommand(argv, deps = {}) {
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
    const start = deps.start ?? startLocalHost;
    let host;
    try {
        host = await start({ servers: command.servers, port: command.port, host: command.host });
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
//# sourceMappingURL=host-run.js.map