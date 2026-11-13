/** Runs a program and answers its exit code and text. */
export type Run = (bin: string, args: string[], opts?: {
    input?: string;
    cwd?: string;
    env?: NodeJS.ProcessEnv;
    timeoutMs?: number;
}) => {
    code: number;
    stdout: string;
    stderr: string;
};
/**
 * The machine that a client writer works on: the home folder, the programs it can run, and the
 * files it reads and writes. A test gives a writer a host of its own, so no test touches a real
 * home folder.
 */
export interface Host {
    home: string;
    env: NodeJS.ProcessEnv;
    run: Run;
    read(path: string): string | undefined;
    /**
     * Writes the file and makes its folders. With no `mode`, a file that it replaces keeps a copy named
     * `<file>.munhq-bak`. With a `mode` (a secret, a program) no copy is kept, and the file and its
     * folders get the modes given.
     */
    write(path: string, text: string, opts?: {
        mode?: number;
        dirMode?: number;
    }): void;
}
export declare function systemHost(env?: NodeJS.ProcessEnv): Host;
