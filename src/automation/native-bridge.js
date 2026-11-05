import { execFile as nodeExecFile } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { AutomationError } from './automation-error.js';
import { validateTextExportProof, validateTextExportReceipt } from './native-text-export.js';

const DEFAULT_SOURCE = fileURLToPath(new URL('./line-desktop-native.swift', import.meta.url));
const LIVE_READ_COMMANDS = new Set([
  'status',
  'processStatus',
  'accessibilityStatus',
  'activateLine',
  'listTabs',
  'listTabChats',
  'selectChat',
  'getHistory',
  'readHistoryPage',
  'probeReadChatTitles',
  'probeAXReadScope',
  'prepareTextExportScope',
  'exportChatText',
]);
const GLOBAL_LIVE_READ_COMMANDS = new Set([
  'status',
  'processStatus',
  'accessibilityStatus',
  'activateLine',
  'selectGlobalAll',
  'observeGlobalAll',
  'readGlobalHistoryPage',
]);
const LIVE_ALLOWED_ARGS = {
  status: [],
  processStatus: [],
  accessibilityStatus: [],
  activateLine: [],
  listTabs: ['maxPages'],
  listTabChats: ['tabName', 'limit', 'offset', 'expectedDigest'],
  selectChat: ['tabName', 'chatName'],
  getHistory: ['tabName', 'chatName', 'date', 'limit', 'pageUpTimes'],
  readHistoryPage: ['tabName', 'chatName', 'limit', 'identityKey', 'nativeState'],
  probeReadChatTitles: ['tabName', 'chatName'],
  probeAXReadScope: ['tabName', 'chatName'],
  prepareTextExportScope: ['tabName', 'chatName', 'identityKey', 'requestNonce'],
  exportChatText: [
    'tabName', 'chatName', 'identityKey', 'requestNonce', 'expectedProofDigest',
    'outputDirectory', 'outputFileName',
  ],
};
const GLOBAL_LIVE_ALLOWED_ARGS = {
  status: [],
  processStatus: [],
  accessibilityStatus: [],
  activateLine: [],
  selectGlobalAll: ['chatName', 'requestNonce', 'expectedWindow'],
  observeGlobalAll: ['chatName', 'requestNonce', 'expectedWindow'],
  readGlobalHistoryPage: ['chatName', 'resultIndex', 'limit', 'identityKey', 'nativeState'],
};

function isPlainObject(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function isSafeScopeName(value) {
  return typeof value === 'string' && value.length > 0 && value.length <= 200 &&
    !/\p{Cc}|[\u202a-\u202e\u2066-\u2069]/u.test(value);
}

function hasExactKeys(value, required, optional = []) {
  if (!isPlainObject(value)) return false;
  const keys = Object.keys(value);
  return required.every((key) => keys.includes(key)) &&
    keys.every((key) => required.includes(key) || optional.includes(key));
}

function validLiveWindow(value) {
  if (!hasExactKeys(value,
    ['pid', 'windowId', 'title', 'bounds', 'bundleIdentifier', 'executableURL'],
    ['signingIdentifier', 'teamIdentifier']) ||
    !Number.isInteger(value.pid) || value.pid <= 0 ||
    !Number.isInteger(value.windowId) || value.windowId <= 0 ||
    value.title !== 'LINE' || value.bundleIdentifier !== 'jp.naver.line.mac' ||
    typeof value.executableURL !== 'string' || value.executableURL.length === 0 ||
    value.executableURL.length > 2_000 ||
    !hasExactKeys(value.bounds, ['x', 'y', 'width', 'height']) ||
    !Object.values(value.bounds).every(Number.isFinite) ||
    value.bounds.width <= 0 || value.bounds.height <= 0) return false;
  return ['signingIdentifier', 'teamIdentifier'].every((key) => value[key] === undefined ||
    (typeof value[key] === 'string' && value[key].length > 0 && value[key].length <= 500));
}

function validCalendarDate(value) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value || '');
  if (!match) return false;
  const [year, month, day] = match.slice(1).map(Number);
  const parsed = new Date(0);
  parsed.setUTCHours(0, 0, 0, 0);
  parsed.setUTCFullYear(year, month - 1, day);
  return year >= 1 && parsed.getUTCFullYear() === year &&
    parsed.getUTCMonth() === month - 1 && parsed.getUTCDate() === day;
}

function validLiveNativeState(value) {
  if (!hasExactKeys(value, [
    'version', 'expectedWindow', 'headerDigest', 'anchorHash', 'offset', 'pageNumber',
    'advance', 'seenIds', 'dateContext',
  ])) return false;
  let byteLength;
  try {
    byteLength = Buffer.byteLength(JSON.stringify(value), 'utf8');
  } catch {
    return false;
  }
  const hex64 = /^[a-f0-9]{64}$/;
  const dateContextValid = value.dateContext === null ||
    (hasExactKeys(value.dateContext, ['date', 'anchorHash']) &&
      validCalendarDate(value.dateContext.date) &&
      hex64.test(value.dateContext.anchorHash));
  return byteLength <= 64 * 1024 && value.version === 1 && validLiveWindow(value.expectedWindow) &&
    hex64.test(value.headerDigest) && hex64.test(value.anchorHash) &&
    Number.isInteger(value.offset) && value.offset >= 0 && value.offset <= 2_000 &&
    Number.isInteger(value.pageNumber) && value.pageNumber >= 0 && value.pageNumber <= 1_000 &&
    typeof value.advance === 'boolean' && Array.isArray(value.seenIds) && value.seenIds.length <= 2_000 &&
    value.seenIds.every((id) => typeof id === 'string' && hex64.test(id)) &&
    new Set(value.seenIds).size === value.seenIds.length && dateContextValid;
}

function validateLiveScope(scope) {
  if (scope === null) return null;
  if (!scope || typeof scope !== 'object' || Array.isArray(scope)) {
    throw new AutomationError('INVALID_LIVE_SCOPE', 'liveScope 必須是 null 或物件');
  }
  const keys = Object.keys(scope);
  if ((keys.length === 2 || keys.length === 3) && keys.includes('kind') && keys.includes('chatName') &&
      keys.every(key => ['kind', 'chatName', 'resultIndex'].includes(key))) {
    if (scope.kind !== 'global' || !isSafeScopeName(scope.chatName) ||
        (scope.resultIndex !== undefined && (!Number.isInteger(scope.resultIndex) ||
          scope.resultIndex < 1 || scope.resultIndex > 20))) {
      throw new AutomationError('INVALID_LIVE_SCOPE', 'global liveScope 格式不正確');
    }
    return Object.freeze({ kind: 'global', chatName: scope.chatName,
      ...(scope.resultIndex === undefined ? {} : { resultIndex: scope.resultIndex }) });
  }
  if (keys.length !== 2 || !keys.includes('tabName') || !keys.includes('chatName')) {
    throw new AutomationError('INVALID_LIVE_SCOPE', 'liveScope 只能包含 tabName 與 chatName，或 global kind 與 chatName');
  }
  for (const field of ['tabName', 'chatName']) {
    if (!isSafeScopeName(scope[field])) {
      throw new AutomationError('INVALID_LIVE_SCOPE', `liveScope.${field} 格式不正確`);
    }
  }
  return Object.freeze({ tabName: scope.tabName, chatName: scope.chatName });
}

function runExecFile(execFile, executable, args, options, input) {
  return new Promise((resolve, reject) => {
    const child = execFile(executable, args, options, (error, stdout, stderr) => {
      if (error) {
        error.stdout = stdout;
        error.stderr = stderr;
        reject(error);
        return;
      }
      resolve({ stdout, stderr });
    });
    child.stdin?.on('error', reject);
    child.stdin?.end(input);
  });
}

export class NativeBridge {
  constructor(options = {}) {
    const {
      execFile,
      sourcePath = DEFAULT_SOURCE,
      cacheDir = path.join(os.homedir(), 'Library', 'Caches', 'line-desktop-mcp', 'native'),
      compilerPath = '/usr/bin/swiftc',
      // 冷啟動 Vision、雙快照與原生文字選單共用一個預算，避免中途終止而來不及還原剪貼簿。
      timeoutMs = 30_000,
      // 冷機首次載入Swift SDK可能超過兩分鐘；只延長編譯，不延長LINE操作。
      compileTimeoutMs = 300_000,
      maxBuffer = 2 * 1024 * 1024,
      liveScope = null,
    } = options;
    this.execFileInjected = typeof execFile === 'function';
    this.execFile = this.execFileInjected ? execFile : nodeExecFile;
    this.sourcePath = sourcePath;
    this.cacheDir = cacheDir;
    this.compilerPath = compilerPath;
    this.timeoutMs = timeoutMs;
    this.compileTimeoutMs = compileTimeoutMs;
    this.maxBuffer = maxBuffer;
    this.liveScope = validateLiveScope(liveScope);
    this.binaryPromise = null;
  }

  async call(name, args = {}) {
    // live scope 必須在停用檢查與編譯前完成，錯誤 scope 不得接觸 native 執行路徑。
    const request = this.prepareRequest(name, args);
    if (process.env.LINE_MCP_DISABLE_NATIVE === '1' && !this.execFileInjected) {
      throw new AutomationError('NATIVE_DISABLED', '目前環境已停用 LINE native helper');
    }
    const binaryPath = await this.ensureBinary();
    let output;
    try {
      output = await runExecFile(
        this.execFile,
        binaryPath,
        [],
        {
          encoding: 'utf8',
          timeout: this.timeoutMs,
          maxBuffer: this.maxBuffer,
          windowsHide: true,
        },
        JSON.stringify(request)
      );
    } catch (error) {
      const timedOut = error?.killed || error?.signal === 'SIGTERM' || error?.code === 'ETIMEDOUT';
      throw new AutomationError(timedOut ? 'NATIVE_TIMEOUT' : 'NATIVE_FAILURE', 'LINE native helper 執行失敗', {
        phase: 'unknown',
        timedOut,
      });
    }

    let response;
    try {
      response = JSON.parse(output.stdout);
    } catch {
      throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'LINE native helper 回傳無效 JSON');
    }
    if (!response || typeof response !== 'object' || Array.isArray(response)) {
      throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'LINE native helper 回傳格式不正確');
    }
    if (response.ok === false) {
      const nativeError = response.error || {};
      if (
        typeof nativeError.code !== 'string' ||
        !/^[A-Z0-9_]{1,64}$/.test(nativeError.code) ||
        typeof nativeError.message !== 'string' ||
        nativeError.message.length > 1_000 ||
        (nativeError.details !== undefined &&
          (!nativeError.details || typeof nativeError.details !== 'object' || Array.isArray(nativeError.details)))
      ) {
        throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'LINE native helper error 格式不正確');
      }
      throw new AutomationError(
        nativeError.code,
        nativeError.message,
        nativeError.details || {}
      );
    }
    if (
      response.ok !== true ||
      !response.result ||
      typeof response.result !== 'object' ||
      Array.isArray(response.result)
    ) {
      throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'LINE native helper 缺少結構化結果');
    }
    return response.result;
  }

  async exportChatText(args) {
    const proof = await this.call('prepareTextExportScope', {
      tabName: args.tabName,
      chatName: args.chatName,
      identityKey: args.identityKey,
      requestNonce: args.requestNonce,
    });
    validateTextExportProof(proof, args, args.identityKey, 'prepareTextExportScope result');
    const receipt = await this.call('exportChatText', {
      tabName: args.tabName,
      chatName: args.chatName,
      identityKey: args.identityKey,
      requestNonce: args.requestNonce,
      expectedProofDigest: proof.proofDigest,
      outputDirectory: args.outputDirectory,
      outputFileName: args.outputFileName,
    });
    validateTextExportReceipt(receipt, args, args.identityKey);
    if (receipt.preActionProof.proofDigest !== proof.proofDigest) {
      throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'export receipt 與 prepare proof 不一致');
    }
    return receipt;
  }

  prepareRequest(name, args) {
    if (!this.liveScope) {
      if (name === 'probeReadChatTitles' || name === 'probeAXReadScope') {
        throw new AutomationError('LIVE_SCOPE_DENIED', '名稱探針必須綁定核准範圍');
      }
      return { name, args };
    }
    this.assertLiveScope(name, args);
    if (this.liveScope.kind === 'global') {
      return { name, args: { ...args }, liveScope: this.liveScope };
    }
    const scopedArgs = { ...args };
    if (name === 'selectChat' || name === 'getHistory' || name === 'readHistoryPage' ||
        name === 'probeReadChatTitles' || name === 'prepareTextExportScope' ||
        name === 'exportChatText') {
      if (scopedArgs.tabName !== undefined && scopedArgs.tabName !== this.liveScope.tabName) {
        throw new AutomationError('LIVE_SCOPE_DENIED', 'LIVE harness 聊天讀取必須綁定核准分頁');
      }
      // tabName 只來自程式內 scope；MCP client 不能省略後繞過 native 的分頁重驗。
      scopedArgs.tabName = this.liveScope.tabName;
    }
    this.assertLiveScope(name, scopedArgs);
    return { name, args: scopedArgs, liveScope: this.liveScope };
  }

  assertLiveScope(name, args) {
    if (!this.liveScope) return;
    if (this.liveScope.kind === 'global') {
      this.assertGlobalLiveScope(name, args);
      return;
    }
    if (!LIVE_READ_COMMANDS.has(name)) {
      throw new AutomationError('LIVE_SCOPE_DENIED', 'LIVE harness 不允許此 native command');
    }
    if (!args || typeof args !== 'object' || Array.isArray(args)) {
      throw new AutomationError('LIVE_SCOPE_DENIED', 'LIVE harness command 缺少結構化參數');
    }
    if (Object.keys(args).some((key) => !LIVE_ALLOWED_ARGS[name].includes(key))) {
      throw new AutomationError('LIVE_SCOPE_DENIED', 'LIVE harness command 含有未核准參數');
    }
    // 被動探針必須由呼叫端明確提供兩個目標，不能沿用舊讀取命令的自動補分頁行為。
    if ((name === 'probeReadChatTitles' || name === 'probeAXReadScope') &&
        (args.tabName !== this.liveScope.tabName || args.chatName !== this.liveScope.chatName)) {
      throw new AutomationError('LIVE_SCOPE_DENIED', '探針必須明確綁定 exact 核准範圍');
    }
    if (name === 'selectChat' || name === 'getHistory' || name === 'readHistoryPage' ||
        name === 'probeReadChatTitles' || name === 'probeAXReadScope' ||
        name === 'prepareTextExportScope' ||
        name === 'exportChatText') {
      if (args.chatName !== this.liveScope.chatName) {
        throw new AutomationError('LIVE_SCOPE_DENIED', 'LIVE harness 僅能開啟核准聊天室');
      }
      if (args.tabName !== undefined && args.tabName !== this.liveScope.tabName) {
        throw new AutomationError('LIVE_SCOPE_DENIED', 'LIVE harness 聊天讀取必須綁定核准分頁');
      }
    }
    if (name === 'listTabChats') {
      if (args.tabName !== this.liveScope.tabName) {
        throw new AutomationError('LIVE_SCOPE_DENIED', 'LIVE harness 只能盤點核准分頁');
      }
      if (!Number.isInteger(args.limit) || args.limit < 1 || args.limit > 100 ||
          !Number.isInteger(args.offset) || args.offset < 0 || args.offset > 1000 ||
          (args.expectedDigest !== undefined && !/^[a-f0-9]{64}$/.test(args.expectedDigest))) {
        throw new AutomationError('LIVE_SCOPE_DENIED', 'LIVE harness 分頁盤點 metadata 格式不正確');
      }
    }
  }

  assertGlobalLiveScope(name, args) {
    if (!GLOBAL_LIVE_READ_COMMANDS.has(name)) {
      throw new AutomationError('LIVE_SCOPE_DENIED', 'global LIVE harness 不允許此 native command');
    }
    if (!isPlainObject(args) ||
        Object.keys(args).some((key) => !GLOBAL_LIVE_ALLOWED_ARGS[name].includes(key))) {
      throw new AutomationError('LIVE_SCOPE_DENIED', 'global LIVE harness command 參數不正確');
    }
    if (name === 'selectGlobalAll' || name === 'observeGlobalAll') {
      if (args.chatName !== this.liveScope.chatName ||
          typeof args.requestNonce !== 'string' || !/^[a-f0-9]{64}$/.test(args.requestNonce) ||
          !validLiveWindow(args.expectedWindow)) {
        throw new AutomationError('LIVE_SCOPE_DENIED', 'global LIVE harness 只能選取 exact 核准 All 範圍');
      }
      return;
    }
    if (name !== 'readGlobalHistoryPage') return;
    // 所有目標與 continuation 狀態都在編譯、執行 native 前驗證。
    if (args.chatName !== this.liveScope.chatName ||
        args.resultIndex !== this.liveScope.resultIndex ||
        !Number.isInteger(args.limit) || args.limit < 1 || args.limit > 100 ||
        typeof args.identityKey !== 'string' || !/^[a-f0-9]{64}$/.test(args.identityKey) ||
        (args.nativeState !== undefined && !validLiveNativeState(args.nativeState))) {
      throw new AutomationError('LIVE_SCOPE_DENIED', 'global LIVE harness 只能讀取 exact 核准聊天室');
    }
  }

  async selectedSourceDigest() {
    // 注入 fake 未選取真正 binary；只有已經由真 bridge 選定的 cache path 才能聲稱已驗證。
    if (!this.binaryPromise || this.execFileInjected) return { sourceDigest: null, sourceDigestVerified: false };
    const binaryPath = await this.binaryPromise;
    const match = /^line-desktop-native-([a-f0-9]{64})$/.exec(path.basename(binaryPath));
    if (!match) throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'native helper cache path 缺少有效 source digest');
    await fs.access(binaryPath);
    return { sourceDigest: match[1], sourceDigestVerified: true };
  }

  async journalSourceDigest() {
    const source = await fs.readFile(this.sourcePath);
    return crypto.createHash('sha256').update(source).digest('hex');
  }

  async ensureBinary() {
    if (!this.binaryPromise) this.binaryPromise = this.compileIfNeeded();
    try {
      return await this.binaryPromise;
    } catch (error) {
      this.binaryPromise = null;
      throw error;
    }
  }

  async compileIfNeeded() {
    const source = await fs.readFile(this.sourcePath);
    const digest = crypto.createHash('sha256').update(source).digest('hex');
    const binaryPath = path.join(this.cacheDir, `line-desktop-native-${digest}`);
    try {
      await fs.access(binaryPath);
      return binaryPath;
    } catch {
      // 首次實際桌面呼叫才建立快取與編譯，import/list tools 不碰 UI 或安裝內容。
    }
    await fs.mkdir(this.cacheDir, { recursive: true, mode: 0o700 });
    await fs.chmod(this.cacheDir, 0o700);
    const nonce = `${process.pid}.${crypto.randomUUID()}`;
    const pinnedSourcePath = path.join(this.cacheDir, `source-${nonce}.swift`);
    const temporaryPath = `${binaryPath}.${nonce}.tmp`;
    try {
      // 編譯器只讀取與 digest 同一批 bytes，避免長任務並行修改原始 Swift 造成 cache 錯配。
      await fs.writeFile(pinnedSourcePath, source, { mode: 0o600, flag: 'wx' });
      await runExecFile(
        this.execFile,
        this.compilerPath,
        [pinnedSourcePath, '-O', '-o', temporaryPath],
        { encoding: 'utf8', timeout: this.compileTimeoutMs, maxBuffer: this.maxBuffer },
        undefined
      );
      await fs.chmod(temporaryPath, 0o700);
      await fs.rename(temporaryPath, binaryPath);
      return binaryPath;
    } catch (error) {
      throw new AutomationError('NATIVE_BUILD_FAILED', '無法編譯隨套件提供的 LINE native helper', {
        compilerPath: this.compilerPath,
      });
    } finally {
      await fs.rm(pinnedSourcePath, { force: true });
      await fs.rm(temporaryPath, { force: true });
    }
  }
}
