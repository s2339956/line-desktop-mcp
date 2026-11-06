import { AutomationError } from './automation-error.js';

// JSON text保留舊client相容性；structuredContent提供agent不必再解析文字的穩定物件。
export function toolResult(value) {
  return { content: [{ type: 'text', text: JSON.stringify(value) }], structuredContent: value,
    ...((value?.partial === true || value?.cancelled === true) && value.success === false ? { isError: true } : {}) };
}
export function publicError(error) {
  if (!error || typeof error !== 'object') error = {};
  const details = {};
  if (typeof error.details?.operationId === 'string' && /^[a-f0-9-]{36}$/i.test(error.details.operationId)) details.operationId = error.details.operationId;
  if (error.details?.needsRecovery === true) details.needsRecovery = true;
  if (/^[A-Z0-9_]{1,64}$/.test(error.details?.causeCode ?? '')) details.causeCode = error.details.causeCode;
  for (const key of ['completedCount', 'totalCount', 'failedIndex']) {
    if (Number.isInteger(error.details?.[key]) && error.details[key] >= 0 && error.details[key] <= 10) details[key] = error.details[key];
  }
  // 僅受控AutomationError可公開語意訊息；原生FS/程序錯誤常含私人路徑、參數或內容。
  const safe = error instanceof AutomationError && !error.path && !error.syscall && !error.spawnargs;
  const code = /^[A-Z0-9_]{1,64}$/.test(error.code ?? '') ? error.code : 'DESKTOP_OPERATION_FAILED';
  return { code, message: safe ? error.message : '本機操作未完成，請檢查狀態與檔案權限後再繼續。',
    ...(Object.keys(details).length ? { details } : {}) };
}
