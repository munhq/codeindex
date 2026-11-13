import { spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname } from 'node:path';
export function systemHost(env = process.env) {
    return {
        home: env.HOME ?? homedir(),
        env,
        run(bin, args, opts = {}) {
            const r = spawnSync(bin, args, {
                input: opts.input,
                cwd: opts.cwd,
                env: opts.env ?? env,
                timeout: opts.timeoutMs,
                encoding: 'utf8',
            });
            return { code: r.status ?? 1, stdout: r.stdout ?? '', stderr: r.stderr ?? (r.error ? String(r.error) : '') };
        },
        read(path) {
            try {
                return readFileSync(path, 'utf8');
            }
            catch {
                return undefined;
            }
        },
        write(path, text, opts = {}) {
            mkdirSync(dirname(path), { recursive: true, ...(opts.dirMode === undefined ? {} : { mode: opts.dirMode }) });
            if (opts.mode === undefined) {
                if (existsSync(path))
                    copyFileSync(path, `${path}.munhq-bak`);
                writeFileSync(path, text);
                return;
            }
            // Many agents read token.json while one of them renews it. The text goes to a file of this process and
            // a rename puts it in place, so a reader sees the old file or the new one, and never an empty one.
            const tmp = `${path}.${process.pid}.tmp`;
            writeFileSync(tmp, text, { mode: opts.mode });
            chmodSync(tmp, opts.mode);
            renameSync(tmp, path);
        },
    };
}
//# sourceMappingURL=host.js.map