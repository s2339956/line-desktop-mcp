#!/usr/bin/env node
import { LocalMaintenance } from '../src/automation/local-maintenance.js';
import { AutomationError } from '../src/automation/automation-error.js';
import { publicError } from '../src/automation/mcp-result.js';
// 明確維護命令；不接收任意檔案路徑，不開LINE或觸發輸入事件。
const args = process.argv.slice(2);
let request;
if (!args.length || (args.length === 1 && args[0] === 'status')) request = { action: 'status' };
else if (args.length === 1 && args[0] === 'cleanup') request = { action: 'cleanup' };
else if (args.length === 2 && args[0] === 'recover-lock') request = { action: 'recover_lock', target: args[1] };
try {
  if (!request) throw new AutomationError('INVALID_ARGUMENT', '用法：maintenance.mjs status | cleanup | recover-lock ui|index|assets');
  console.log(JSON.stringify(await new LocalMaintenance().call(request)));
} catch (error) { console.error(JSON.stringify({ error: publicError(error) })); process.exitCode = 1; }
