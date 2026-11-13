/**
 * The address and port of the local host of a machine.
 *
 * They live here, away from `local-host.ts`, because the client writers need them and
 * `local-host.ts` needs the MCP SDK. A product that vendors the CLI half of this package
 * must be able to read these two numbers without installing the SDK.
 */
/** The address the host listens on. A client on another machine cannot reach it. */
export const LOOPBACK = "127.0.0.1";
/** The port of the host of a machine. */
export const DEFAULT_PORT = 7717;
//# sourceMappingURL=loopback.js.map