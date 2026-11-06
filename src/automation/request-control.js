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
