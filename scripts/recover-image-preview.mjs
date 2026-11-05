import { MacOSDesktopAutomation } from '../src/automation/desktop-automation.js';
// 只恢復明確綁定 autoSend:false 的歷史紀錄；預設僅核對，不封存或清除。
const values = {};
let run = false;
for (let i = 2; i < process.argv.length; i += 1) {
  const flag = process.argv[i];
  if (flag === '--run' && !run) { run = true; continue; }
  if (!['--operation-id', '--chat', '--sha256'].includes(flag) || values[flag] !== undefined ||
      !process.argv[i + 1] || process.argv[i + 1].startsWith('--')) throw new Error('恢復參數不完整或重複');
  values[flag] = process.argv[++i];
}
const args = { operationId: values['--operation-id'], chatName: values['--chat'], imageSha256: values['--sha256'] };
if (!/^[a-f0-9-]{36}$/i.test(args.operationId ?? '') || !args.chatName || !/^[a-f0-9]{64}$/.test(args.imageSha256 ?? '')) {
  throw new Error('必須提供確切 --operation-id、--chat 與 --sha256；執行恢復時另加 --run');
}
const desktop = new MacOSDesktopAutomation();
const result = run
  ? await desktop.recoverImagePreview(args, { transport: 'stdio', sessionId: 'image-preview-recovery-cli' })
  : await desktop.lock.withLock(async () => {
      await desktop.readImagePreviewRecoveryRecord(args);
      return { eligible: true, inputAttempted: false, sendAttempted: false, cleared: false };
    });
console.log(JSON.stringify(result));
