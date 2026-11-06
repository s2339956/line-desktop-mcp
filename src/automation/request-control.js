import { AsyncLocalStorage } from 'node:async_hooks';
import { AutomationError } from './automation-error.js';

// 控制訊號屬於當次MCP呼叫，不可混入共用session、操作雜湊或持久化紀錄。
const requests = new AsyncLocalStorage();
export const withRequestControl = (control, work) => requests.run(control, work);
export const requestSignal = () => requests.getStore()?.signal;
const cancelled = () => new AutomationError('REQUEST_CANCELLED', '請求已停止，不會開始後續工作', { phase: 'pre_commit' });
export function throwIfCancelled() {
  if (requestSignal()?.aborted) throw cancelled();
}
export function waitForRequest(promise, milliseconds) {
  throwIfCancelled();
  const signal = requestSignal();
  return new Promise((resolve, reject) => {
    let timer;
    const finish = (handler, value) => {
      clearTimeout(timer); signal?.removeEventListener('abort', abort); handler(value);
    };
    const abort = () => finish(reject, cancelled());
    signal?.addEventListener('abort', abort, { once: true });
    if (milliseconds !== undefined) timer = setTimeout(() => finish(resolve, false), Math.max(0, milliseconds));
    promise.then(value => finish(resolve, value), error => finish(reject, error));
  });
}
export const requestPause = milliseconds => waitForRequest(new Promise(() => {}), milliseconds);

export const requestOperation = () => requests.getStore()?.operationId;
export const withOperation = (operationId, work) => withRequestControl({ ...requests.getStore(), operationId }, work);
export function progressReporter(token, send) {
  let previous = -1, unavailable = false;
  const enabled = typeof token === 'string' || (typeof token === 'number' && Number.isFinite(token));
  return async ({ progress, total, message }) => {
    if (!enabled || unavailable || progress <= previous) return;
    previous = progress;
    let timer;
    try {
      // 進度通知不是提交證據；client寫入卡住或離線不能改變可靠回條。
      await Promise.race([send({ method: 'notifications/progress', params: { progressToken: token, progress, total, message } }),
        new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('progress unavailable')), 500); })]);
    } catch { unavailable = true; }
    finally { clearTimeout(timer); }
  };
}
export const reportProgress = async value => {
  const control = requests.getStore();
  if (!control?.signal?.aborted) await control?.progress?.(value);
};

// 已提交後的回條與快照登錄必須完成；此範圍不允許啟動新的UI動作。
export const withFinalization = work => withRequestControl({ ...requests.getStore(), signal: undefined }, work);
