#!/usr/bin/env node
import { runHostCommand } from './host-plain.js';
process.exitCode = await runHostCommand(process.argv.slice(2));
//# sourceMappingURL=host-main.js.map