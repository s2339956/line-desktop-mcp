import fs from 'node:fs/promises';
import { constants } from 'node:fs';
import crypto from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import { AutomationError, assertKnownKeys, assertSafeName } from './automation-error.js';
import { validateRequestId, sanitizeReceipt } from './request-records.js';

const MAX_ITEMS = 10;
const MAX_TOTAL_BYTES = 100 * 1024 * 1024;
const MAX_IMAGE_BYTES = 20 * 1024 * 1024;
const hash = value => crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
const codeOf = error => /^[A-Z0-9_]{1,64}$/.test(error.code ?? '') ? error.code : 'ATTACHMENT_FAILED';

export function validateBatch(args, kind) {
  if (!['image', 'file'].includes(kind)) throw new AutomationError('INVALID_ARGUMENT', '未知附件模式');
  const field = kind === 'image' ? 'images' : 'files';
  const pathKey = kind === 'image' ? 'imagePath' : 'filePath';
  const hashKey = kind === 'image' ? 'imageSha256' : 'fileSha256';
  assertKnownKeys(args, ['chatName', 'requestId', field]);
  const chatName = assertSafeName(args.chatName, 'chatName');
  validateRequestId(args.requestId);
  if (!Array.isArray(args[field]) || args[field].length < 1 || args[field].length > MAX_ITEMS) {
    throw new AutomationError('INVALID_ARGUMENT', '每批須為1至10個明確附件');
  }
  const items = args[field].map(item => {
    assertKnownKeys(item, [pathKey, hashKey]);
    if (typeof item[pathKey] !== 'string' || !path.isAbsolute(item[pathKey]) || item[pathKey].length > 4096 ||
        /\p{Cc}|[\u202a-\u202e\u2066-\u2069]/u.test(item[pathKey]) ||
        typeof item[hashKey] !== 'string' || !/^[a-f0-9]{64}$/.test(item[hashKey])) {
      throw new AutomationError('INVALID_ARGUMENT', '每個附件須提供安全絕對路徑與SHA256');
    }
    return { path: item[pathKey], sha256: item[hashKey] };
  });
  if (new Set(items.map(item => item.sha256)).size !== items.length) {
    throw new AutomationError('INVALID_ARGUMENT', '同一批不可重複選取相同內容');
  }
  const actionHash = hash({ action: `send_${kind}_batch`, chatName,
    items: items.map(item => ({ sha256: item.sha256,
      ...(kind === 'file' ? { nameHash: hash(path.basename(item.path).normalize('NFC')) } : {}),
    })) });
  return { chatName, items, actionHash, requestId: args.requestId };
}

export async function stageAttachment(item, maximumBytes) {
  let input, output, directory;
  try {
    input = await fs.open(item.path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const before = await input.stat();
    if (!before.isFile() || before.nlink !== 1 || before.size <= 0 || before.size > maximumBytes) {
      throw new AutomationError('ATTACHMENT_FILE_UNSAFE', '附件須為一般單連結檔案，且未超過批次大小限制');
    }
    directory = await fs.mkdtemp(path.join(os.tmpdir(), `line-mcp-attachment-${item.sha256}-`));
    await fs.chmod(directory, 0o700);
    const file = path.join(directory, path.basename(item.path).normalize('NFC'));
    output = await fs.open(file, 'wx', 0o600);
    const digest = crypto.createHash('sha256');
    const buffer = Buffer.alloc(64 * 1024);
    let copied = 0;
    while (true) {
      const { bytesRead } = await input.read(buffer, 0, buffer.length, null);
      if (!bytesRead) break;
      copied += bytesRead;
      if (copied > maximumBytes || copied > before.size) throw new AutomationError('ATTACHMENT_FILE_CHANGED', '附件讀取期間大小改變');
      digest.update(buffer.subarray(0, bytesRead));
      // FileHandle.write不保證一次寫滿；只把完整快照交給LINE。
      let written = 0;
      while (written < bytesRead) {
        const next = await output.write(buffer, written, bytesRead - written, null);
        if (!next.bytesWritten) throw new AutomationError('ATTACHMENT_COPY_FAILED', '附件快照寫入未完成');
        written += next.bytesWritten;
      }
    }
    const after = await input.stat();
    if (copied !== before.size || before.size !== after.size || before.mtimeMs !== after.mtimeMs ||
        before.ctimeMs !== after.ctimeMs || digest.digest('hex') !== item.sha256) {
      throw new AutomationError('ATTACHMENT_HASH_MISMATCH', '附件內容與指定SHA256不符或讀取期間改變');
    }
    await output.sync();
    return { file, directory, sha256: item.sha256, byteCount: copied };
  } catch (error) {
    if (directory) await fs.rm(directory, { recursive: true, force: true });
    if (error instanceof AutomationError) throw error;
    throw new AutomationError('ATTACHMENT_FILE_UNSAFE', '無法建立安全附件快照');
  } finally { await input?.close(); await output?.close(); }
}

function verifiedReceipt(result, item, kind) {
  if (result?.success !== true || result.autoSent !== true || result.chatVerified !== true ||
      result.selectedFileVerified !== true || result.sourceSha256 !== item.sha256 ||
      result.receipt?.status !== 'UI_SUBMITTED' || result.receipt.deliveryConfirmed !== false ||
      (kind === 'file' && (result.fileSha256 !== item.sha256 || result.byteCount !== item.byteCount)) ||
      (kind === 'image' && !/^[a-f0-9]{64}$/.test(result.imageSha256 ?? ''))) {
    throw new AutomationError('SEND_UNVERIFIED', '附件回條與本次檔案不符');
  }
  return sanitizeReceipt(result);
}

export async function sendAttachmentBatch({ args, kind, bridge, lock, records, journal,
  settle = () => new Promise(resolve => setTimeout(resolve, 2100)) }) {
  const request = validateBatch(args, kind);
  return lock.withLock(() => records.run(request.requestId, request.actionHash,
    async ({ operationId, commit, checkpoint }) => {
      await journal.assertEmpty();
      const staged = [], completed = [];
      let retainFiles = false;
      const clearJournal = async () => {
        try { await journal.clear(); }
        catch { throw new AutomationError('OPERATION_UNCERTAIN', '回條已保留，但操作紀錄尚未清除；不會重送', {
          operationId, needsRecovery: true, causeCode: 'JOURNAL_CLEAR_FAILED',
        }); }
      };
      const summary = (success, extra = {}) => ({ success, completedCount: completed.length,
        totalCount: request.items.length, items: completed, ...extra });
      try {
        let total = 0;
        // 全部先驗檔與解碼，再執行第一個UI操作；不讓後面的壞檔造成可避免的部分提交。
        for (const item of request.items) {
          const copy = await stageAttachment(item, Math.min(MAX_TOTAL_BYTES - total,
            kind === 'image' ? MAX_IMAGE_BYTES : MAX_TOTAL_BYTES));
          staged.push(copy); total += copy.byteCount;
          if (kind === 'image') {
            const inspected = await bridge.call('inspectImage', { imagePath: copy.file, imageSha256: copy.sha256 });
            if (inspected.sourceSha256 !== copy.sha256 || inspected.uiAccessed !== false ||
                !Number.isInteger(inspected.width) || !Number.isInteger(inspected.height) ||
                inspected.width < 1 || inspected.height < 1 || inspected.width > 8192 || inspected.height > 8192 ||
                inspected.width * inspected.height > 16_000_000) {
              throw new AutomationError('IMAGE_INVALID', '圖片解碼檢查未提供有效證據');
            }
          }
        }
        await journal.write({ operationId, actionHash: request.actionHash, createdAt: new Date().toISOString() });
        for (let index = 0; index < staged.length; index++) {
          const item = staged[index];
          try {
            retainFiles = true;
            const result = kind === 'image'
              ? await bridge.call('sendImage', { chatName: request.chatName, imagePath: item.file, imageSha256: item.sha256, autoSend: true })
              : await bridge.call('sendFile', { chatName: request.chatName, filePath: item.file, fileSha256: item.sha256 });
            completed.push(verifiedReceipt(result, item, kind));
            await checkpoint(summary(false));
            // 讓本次合成鍵鼠事件離開2秒idle窗口；下一項仍完整核對硬體活動，不自動重試。
            if (index + 1 < staged.length) await settle();
          } catch (error) {
            if (error.details?.phase === 'pre_commit') {
              if (!completed.length) { retainFiles = false; await clearJournal(); throw error; }
              const partial = summary(false, { partial: true, failedIndex: index, causeCode: codeOf(error) });
              await commit(partial); await clearJournal(); return partial;
            }
            throw new AutomationError('OPERATION_UNCERTAIN', '附件批次在本項停止；不會重送或繼續後面的檔案', {
              operationId, needsRecovery: true, causeCode: codeOf(error),
              completedCount: completed.length, totalCount: staged.length, failedIndex: index,
            });
          }
        }
        const result = summary(true, { receipt: { status: 'UI_SUBMITTED', deliveryConfirmed: false, observedAt: new Date().toISOString() } });
        await commit(result); await clearJournal(); return result;
      } finally {
        // 任何可能已提交的快照都保留，避免LINE延後讀檔失敗。
        if (!retainFiles) for (const item of staged) await fs.rm(item.directory, { recursive: true, force: true });
      }
    }));
}
