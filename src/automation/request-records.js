import crypto from 'node:crypto';
import path from 'node:path';
import fs from 'node:fs/promises';
import { withOperation } from './request-control.js';
import { AutomationError } from './automation-error.js';
import { readPrivateJSON, writePrivateJSON, privateDirectory, syncDirectory } from './private-json.js';

const terminal = new Set(['succeeded', 'partial', 'cancelled', 'failed', 'user_reported_submitted', 'abandoned']);
const states = new Set([...terminal, 'started', 'uncertain']);
const allowedResult = new Set(['success', 'autoSent', 'chatVerified', 'selectedFileVerified',
  'sourceSha256', 'imageSha256', 'width', 'height', 'temporaryFileRetained', 'receipt',
  'localStorageWarning', 'phase', 'preparedCount', 'cancelled', 'completedCount', 'totalCount', 'items', 'partial', 'failedIndex', 'causeCode', 'fileSha256', 'byteCount']);

export function validateRequestId(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{16,128}$/.test(value)) {
    throw new AutomationError('INVALID_ARGUMENT', 'requestId須為16至128位英數字、底線或連字號');
  }
  return value;
}

export function sanitizeReceipt(result) {
  const selected = Object.fromEntries(Object.entries(result).filter(([key]) => allowedResult.has(key)));
  if (selected.receipt) selected.receipt = {
    status: selected.receipt.status, observedAt: selected.receipt.observedAt, deliveryConfirmed: false,
  };
  if (selected.items) selected.items = selected.items.map(sanitizeReceipt);
  return selected;
}

export class RequestReceipts {
  constructor(directory) { this.directory = directory; }

  file(requestId) {
    const key = crypto.createHash('sha256').update(validateRequestId(requestId)).digest('hex');
    return path.join(this.directory, `${key}.json`);
  }

  async read(requestId) {
    const loaded = await readPrivateJSON(this.file(requestId));
    if (!loaded) return null;
    const record = loaded.value;
    if (!record || typeof record !== 'object' || Array.isArray(record) || record.schemaVersion !== 1 || !states.has(record.state) ||
        !/^[a-f0-9]{64}$/.test(record.actionHash ?? '') ||
        !/^[a-f0-9-]{36}$/.test(record.operationId ?? '') ||
        !Number.isFinite(Date.parse(record.createdAt))) {
      throw new AutomationError('LOCAL_RECORD_INVALID', '請求紀錄結構不正確');
    }
    return record;
  }

  async status(requestId, journalPath) {
    const record = await this.read(requestId);
    if (!record) return { found: false };
    const journal = journalPath ? await readPrivateJSON(journalPath) : null;
    const ownJournalPending = journal?.value.operationId === record.operationId && journal?.value.actionHash === record.actionHash;
    return { found: true, operationId: record.operationId, state: record.state,
      terminal: terminal.has(record.state), needsRecovery: !terminal.has(record.state) || ownJournalPending,
      blockingJournal: journal !== null,
      ...(record.result ? { result: sanitizeReceipt(record.result) } : {}) };
  }

  async run(requestId, actionHash, work) {
    if (requestId === undefined) {
      const operationId = crypto.randomUUID();
      return withOperation(operationId, () => work({ operationId, commit: async () => {} }));
    }
    const old = await this.read(requestId);
    if (old) {
      if (old.actionHash !== actionHash) throw new AutomationError('REQUEST_CONFLICT', '相同requestId不可更換操作內容');
      if (['succeeded', 'partial', 'cancelled'].includes(old.state)) return { ...sanitizeReceipt(old.result), replayed: true };
      throw new AutomationError(terminal.has(old.state) ? 'REQUEST_FINISHED' : 'OPERATION_UNCERTAIN',
        '此請求已執行或停止；不會再次傳送，請先查詢操作狀態', {
          operationId: old.operationId, needsRecovery: !terminal.has(old.state),
        });
    }
    const record = { schemaVersion: 1, actionHash, operationId: crypto.randomUUID(),
      createdAt: new Date().toISOString(), state: 'started' };
    await writePrivateJSON(this.file(requestId), record);
    let committed = false, progress;
    try {
      const result = await withOperation(record.operationId, () => work({ operationId: record.operationId, checkpoint: async result => {
        progress = sanitizeReceipt(result);
        await writePrivateJSON(this.file(requestId), { ...record, result: progress });
      }, commit: async result => {
        await writePrivateJSON(this.file(requestId), { ...record,
          state: result.cancelled === true ? 'cancelled' : result.partial === true ? 'partial' : 'succeeded', result: sanitizeReceipt(result) });
        committed = true;
      } }));
      if (!committed) throw new AutomationError('OPERATION_UNCERTAIN', '操作未持久化完成回條');
      return result;
    } catch (error) {
      if (!committed) await writePrivateJSON(this.file(requestId), {
        ...record, state: error.code === 'OPERATION_UNCERTAIN' ? 'uncertain' : 'failed',
        ...(progress ? { result: progress } : {}),
      }).catch(() => {});
      throw error;
    }
  }

  async resolve({ requestId, operationId, outcome }, journalPath, observe) {
    if (!['submitted', 'abandoned'].includes(outcome)) throw new AutomationError('INVALID_ARGUMENT', 'outcome須為submitted或abandoned');
    const record = await this.read(requestId);
    if (!record || record.operationId !== operationId) throw new AutomationError('RECOVERY_RECORD_INVALID', '不是指定請求的操作');
    const resolvedState = outcome === 'submitted' ? 'user_reported_submitted' : 'abandoned';
    if (terminal.has(record.state) && record.state !== resolvedState && record.state !== 'succeeded' &&
        !(record.state === 'partial' && outcome === 'abandoned')) {
      throw new AutomationError('RECOVERY_RECORD_INVALID', '請求已以不同結果結案');
    }
    if (record.state === 'succeeded' && outcome !== 'submitted') throw new AutomationError('RECOVERY_RECORD_INVALID', '已驗證提交不能改為未提交');
    const journal = await readPrivateJSON(journalPath);
    if (journal && (journal.value.operationId !== operationId || journal.value.actionHash !== record.actionHash)) {
      throw new AutomationError('RECOVERY_RECORD_INVALID', '現有紀錄屬於其他操作，不會清除');
    }
    if (journal) {
      const first = await observe();
      const second = await observe();
      if (first.usable !== true || second.usable !== true ||
          JSON.stringify(first.mainWindow) !== JSON.stringify(second.mainWindow)) {
        throw new AutomationError('RECOVERY_WINDOW_UNVERIFIED', 'LINE視窗尚未穩定，不會清除紀錄');
      }
      const evidence = path.join(path.dirname(journalPath), 'recovery-evidence');
      await privateDirectory(evidence);
      const archive = await fs.open(path.join(evidence, `${operationId}-${crypto.randomUUID()}.json`), 'wx', 0o600);
      try { await archive.writeFile(journal.raw); await archive.sync(); } finally { await archive.close(); }
      await syncDirectory(evidence);
    }
    // 先使原requestId永久停止，再清除已核對的journal；不提供任何重送動作。
    const finalState = ['succeeded', 'partial'].includes(record.state) ? record.state : resolvedState;
    await writePrivateJSON(this.file(requestId), { ...record, state: finalState });
    if (journal) {
      const current = await readPrivateJSON(journalPath);
      if (!current || !current.raw.equals(journal.raw)) throw new AutomationError('LOCAL_RECORD_CHANGED', '操作紀錄已改變');
      await fs.unlink(journalPath);
      await syncDirectory(path.dirname(journalPath));
    }
    return { resolved: true, sendAttempted: false, outcomeSource: 'user_report',
      state: finalState };
  }
}
