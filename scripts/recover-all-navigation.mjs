#!/usr/bin/env node
import { pathToFileURL } from 'node:url';
import { assertSafeName } from '../src/automation/automation-error.js';
import { MacOSDesktopAutomation } from '../src/automation/desktop-automation.js';
import { NativeBridge } from '../src/automation/native-bridge.js';

export function parseRecoveryArgs(argv) {
  const options = { chatName: null, run: false };
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--run' && !options.run) options.run = true;
    else if (argv[index] === '--chat' && options.chatName === null) {
      options.chatName = assertSafeName(argv[++index], 'chatName');
    } else throw new Error('只接受一次 --chat <name> 與可選的 --run');
  }
  if (!options.chatName) throw new Error('必須指定 --chat <name>');
  return options;
}

export async function runRecoveryCli(argv, {
  makeDesktop = (chatName) => {
    const bridge = new NativeBridge({ liveScope: { kind: 'global', chatName } });
    return new MacOSDesktopAutomation({ bridge });
  },
  write = (value) => process.stdout.write(`${JSON.stringify(value)}\n`),
} = {}) {
  const options = parseRecoveryArgs(argv);
  const desktop = makeDesktop(options.chatName);
  const context = { transport: 'stdio', sessionId: 'owner-bound-all-recovery' };
  const preview = await desktop.previewGlobalAllNavigationRecovery(
    { chatName: options.chatName }, context
  );
  if (!options.run) {
    write(preview);
    return preview;
  }
  const result = await desktop.recoverGlobalAllNavigation({
    chatName: options.chatName,
    expectedOperationId: preview.expectedOperationId,
  }, context, { run: true });
  write(result);
  return result;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  runRecoveryCli(process.argv.slice(2)).catch((error) => {
    process.stderr.write(`${JSON.stringify({ error: { code: error?.code || 'RECOVERY_FAILED' } })}\n`);
    process.exitCode = 1;
  });
}
