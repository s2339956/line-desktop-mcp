import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import { constants as fsConstants } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  AutomationError,
  assertKnownKeys,
  assertPlainObject,
  assertSafeName,
  optionalInteger,
} from './automation-error.js';
import { NativeBridge } from './native-bridge.js';
import { NativeTextExportReader } from './native-text-export.js';
import { OperationLock } from './operation-lock.js';
import { doctor } from './doctor.js';
import { RequestReceipts, validateRequestId } from './request-records.js';
import { sendAttachmentBatch } from './attachment-batch.js';

const TOKEN_TTL_MS = 120_000;
const MAX_STORED_TOKENS = 100;
const MAX_JOURNAL_BYTES = 64 * 1024;
const QUERY_NORMALIZATION_VERSION = 'nfkc-js-lower-v1';
const HEX_64 = /^[a-f0-9]{64}$/;
const REASON_CODE = /^[A-Z][A-Z0-9_]{0,63}$/;
const LEGACY_GLOBAL_ALL_SOURCE = 'f847245dffaacdb7429614ec6dcb87528aa55a723116f7367ffbd5da769b01a8';
const GLOBAL_ALL_OPERATION_PREFIX = 'global-all-navigation:';

function stable(value) {
  if (Array.isArray(value)) return value.map(stable);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, stable(value[key])]));
  }
  return value;
}

function digest(value) {
  return crypto.createHash('sha256').update(JSON.stringify(stable(value))).digest('hex');
}

function keyedDigest(key, value) {
  return crypto.createHmac('sha256', key).update(JSON.stringify(stable(value))).digest('hex');
}

function isPlainObject(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function cloneJson(value, label = 'native result') {
  const visit = (item) => {
    if (item === null || typeof item === 'string' || typeof item === 'boolean') return item;
    if (typeof item === 'number' && Number.isFinite(item)) return item;
    if (Array.isArray(item)) return item.map(visit);
    if (isPlainObject(item)) {
      return Object.fromEntries(Object.entries(item).map(([key, nested]) => [key, visit(nested)]));
    }
    throw new AutomationError('NATIVE_PROTOCOL_ERROR', `${label} 含有非 JSON 資料`);
  };
  return visit(value);
}

function deepFreeze(value) {
  if (value && typeof value === 'object' && !Object.isFrozen(value)) {
    Object.freeze(value);
    for (const nested of Object.values(value)) deepFreeze(nested);
  }
  return value;
}

function validDigest(value) {
  return typeof value === 'string' && value.length > 0 && value.length <= 256;
}

function calendarDate(value, field) {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'string') {
    throw new AutomationError('INVALID_ARGUMENT', `${field} 必須是 YYYY-MM-DD`, { field });
  }
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) throw new AutomationError('INVALID_ARGUMENT', `${field} 必須是 YYYY-MM-DD`, { field });
  const [year, month, day] = match.slice(1).map(Number);
  const parsed = new Date(0);
  parsed.setUTCHours(0, 0, 0, 0);
  parsed.setUTCFullYear(year, month - 1, day);
  if (
    year < 1 || parsed.getUTCFullYear() !== year ||
    parsed.getUTCMonth() !== month - 1 || parsed.getUTCDate() !== day
  ) {
    throw new AutomationError('INVALID_ARGUMENT', `${field} 不是有效的 Gregorian 日曆日期`, { field });
  }
  return value;
}

function dateRange(args) {
  const startDate = calendarDate(args.startDate, 'startDate');
  const endDate = calendarDate(args.endDate, 'endDate');
  if (startDate && endDate && startDate > endDate) {
    throw new AutomationError('INVALID_ARGUMENT', 'startDate 不可晚於 endDate');
  }
  return { startDate, endDate };
}

function normalizeQuery(value) {
  if (typeof value !== 'string' || [...value].length > 1_000 || Buffer.byteLength(value, 'utf8') > 4_000) {
    throw new AutomationError('INVALID_ARGUMENT', 'query 最多 1000 個 code points 且 4000 bytes', { field: 'query' });
  }
  if (/\p{Cc}|[\u202a-\u202e\u2066-\u2069]/u.test(value)) {
    throw new AutomationError('INVALID_ARGUMENT', 'query 含有不允許的控制或雙向覆寫字元', { field: 'query' });
  }
  const normalized = value.normalize('NFKC').toLowerCase();
  const terms = [...new Set(normalized.split(/\p{White_Space}+/u).filter(Boolean))];
  if (terms.length === 0) {
    throw new AutomationError('INVALID_ARGUMENT', 'query 正規化後不可為空白', { field: 'query' });
  }
  if (terms.length > 16) {
    throw new AutomationError('INVALID_ARGUMENT', 'query 最多包含 16 個不重複詞彙', { field: 'query' });
  }
  return { raw: value, terms, version: QUERY_NORMALIZATION_VERSION };
}

function nativeShape(value, allowed, label) {
  if (!isPlainObject(value) || Object.keys(value).length !== allowed.length ||
      Object.keys(value).some((key) => !allowed.includes(key))) {
    throw new AutomationError('NATIVE_PROTOCOL_ERROR', `${label} 格式或欄位不正確`);
  }
}

function validateReasonList(value, label = 'reasons') {
  if (!Array.isArray(value) || value.length > 32 ||
      value.some((reason) => typeof reason !== 'string' || !REASON_CODE.test(reason)) ||
      new Set(value).size !== value.length) {
    throw new AutomationError('NATIVE_PROTOCOL_ERROR', `native helper 的 ${label} 格式不正確`);
  }
  return value;
}

function validIso8601(value) {
  if (typeof value !== 'string' || value.length > 100) return false;
  const match = /^(\d{4}-\d{2}-\d{2})T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,9})?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$/.exec(value);
  if (!match || !Number.isFinite(Date.parse(value))) return false;
  try {
    calendarDate(match[1], 'observedAt');
    return true;
  } catch {
    return false;
  }
}

function validateWindowIdentity(value) {
  nativeShape(value,
    Object.prototype.hasOwnProperty.call(value || {}, 'signingIdentifier') ||
      Object.prototype.hasOwnProperty.call(value || {}, 'teamIdentifier')
      ? ['pid', 'windowId', 'title', 'bounds', 'bundleIdentifier', 'executableURL',
        ...('signingIdentifier' in value ? ['signingIdentifier'] : []),
        ...('teamIdentifier' in value ? ['teamIdentifier'] : [])]
      : ['pid', 'windowId', 'title', 'bounds', 'bundleIdentifier', 'executableURL'],
    'nextState.expectedWindow');
  if (!Number.isInteger(value.pid) || value.pid <= 0 || !Number.isInteger(value.windowId) || value.windowId <= 0 ||
      value.title !== 'LINE' || value.bundleIdentifier !== 'jp.naver.line.mac' ||
      typeof value.executableURL !== 'string' || value.executableURL.length === 0 || value.executableURL.length > 2_000) {
    throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'nextState.expectedWindow 身分不正確');
  }
  nativeShape(value.bounds, ['x', 'y', 'width', 'height'], 'nextState.expectedWindow.bounds');
  if (!Object.values(value.bounds).every(Number.isFinite) || value.bounds.width <= 0 || value.bounds.height <= 0) {
    throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'nextState.expectedWindow 幾何不正確');
  }
  for (const key of ['signingIdentifier', 'teamIdentifier']) {
    if (value[key] !== undefined && (typeof value[key] !== 'string' || value[key].length === 0 || value[key].length > 500)) {
      throw new AutomationError('NATIVE_PROTOCOL_ERROR', `nextState.expectedWindow.${key} 格式不正確`);
    }
  }
}

function sameWindowIdentity(left, right) {
  return digest(left) === digest(right);
}

function validateGlobalNavigationReceipt(raw, request, requireVerified) {
  nativeShape(raw, [
    'route', 'requestNonce', 'scope', 'expectedWindow', 'mainWindow', 'allSelected',
    'inputAttempted', 'eventCounts', 'systemEventsInvocations', 'phase', 'identityVerified',
  ], 'selectGlobalAll result');
  nativeShape(raw.scope, ['kind', 'chatName'], 'selectGlobalAll scope');
  nativeShape(raw.eventCounts, ['move', 'down', 'up'], 'selectGlobalAll eventCounts');
  validateWindowIdentity(raw.expectedWindow);
  const counts = raw.eventCounts;
  const countsZero = counts.move === 0 && counts.down === 0 && counts.up === 0;
  const countsOne = counts.move === 1 && counts.down === 1 && counts.up === 1;
  const countsOrdered = counts.up <= counts.down && counts.down <= counts.move;
  const anyDirectInput = Object.values(counts).some((count) => count > 0);
  if (raw.route !== 'line-hid-all-v1' || raw.requestNonce !== request.requestNonce ||
      raw.scope.kind !== 'all-navigation' || raw.scope.chatName !== request.chatName ||
      !sameWindowIdentity(raw.expectedWindow, request.expectedWindow) ||
      typeof raw.allSelected !== 'boolean' || typeof raw.inputAttempted !== 'boolean' ||
      typeof raw.identityVerified !== 'boolean' ||
      raw.systemEventsInvocations !== 0 ||
      !['verified', 'pre_input', 'post_input'].includes(raw.phase) ||
      !Object.values(counts).every((count) => Number.isInteger(count) && count >= 0 && count <= 1) ||
      !countsOrdered || raw.inputAttempted !== anyDirectInput ||
      (raw.phase === 'pre_input' && !countsZero) ||
      (raw.phase === 'post_input' && !anyDirectInput) ||
      (raw.phase === 'verified' && !countsZero && !countsOne)) {
    throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'selectGlobalAll receipt 與本次要求不一致');
  }
  if (raw.mainWindow !== null) validateWindowIdentity(raw.mainWindow);
  if (requireVerified) {
    if (raw.phase !== 'verified' || raw.allSelected !== true || raw.identityVerified !== true ||
        raw.mainWindow === null || !sameWindowIdentity(raw.mainWindow, request.expectedWindow) ||
        raw.systemEventsInvocations !== 0) {
      throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'selectGlobalAll 未提供可結案的 strict All 證明');
    }
  }
  return deepFreeze(cloneJson(raw, 'selectGlobalAll result'));
}

function trustedZeroEventNavigation(raw, request) {
  try {
    const receipt = validateGlobalNavigationReceipt(raw, request, false);
    return receipt.phase === 'pre_input' && receipt.inputAttempted === false &&
      receipt.systemEventsInvocations === 0 &&
      Object.values(receipt.eventCounts).every((count) => count === 0) ? receipt : null;
  } catch {
    return null;
  }
}

function validateGlobalNavigationStatus(raw) {
  if (!isPlainObject(raw) ||
      !['running', 'accessibilityTrusted', 'foreground', 'usable'].every(
        (key) => typeof raw[key] === 'boolean'
      ) || !Object.prototype.hasOwnProperty.call(raw, 'mainWindow')) {
    throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'status 缺少 global All 導航所需欄位');
  }
  if (!raw.running || !raw.accessibilityTrusted || !raw.foreground || !raw.usable) {
    throw new AutomationError('LINE_NOT_READY', 'LINE 必須執行中、已授權、位於前景且主窗可用');
  }
  validateWindowIdentity(raw.mainWindow);
  return deepFreeze(cloneJson(raw.mainWindow, 'status.mainWindow'));
}

function canonicalNavigationStart(navigation, route) {
  const start = {
    version: 1,
    route,
    requestNonce: navigation.requestNonce,
    sourceDigest: navigation.sourceDigest,
    pid: navigation.pid,
    expectedWindow: navigation.expectedWindow,
    scopeHmac: navigation.scopeHmac,
    phase: 'pre_input',
    eventCounts: { move: 0, down: 0, up: 0 },
  };
  if (route === 'line-system-events-all-v1' || route === 'line-hid-all-v1') {
    start.systemEventsInvocations = 0;
  }
  return start;
}

function validateOwnedNavigationRecord(record, expectedOperationId) {
  if (!isPlainObject(record) || record.schemaVersion !== 2 ||
      !isPlainObject(record.navigation) ||
      !['line-pid-mouse-v1', 'line-system-events-all-v1', 'line-hid-all-v1']
        .includes(record.navigation.route) ||
      typeof expectedOperationId !== 'string' || record.operationId !== expectedOperationId ||
      record.operationId !== `${GLOBAL_ALL_OPERATION_PREFIX}${record.navigation.requestNonce}` ||
      record.navigation.version !== 1 ||
      !HEX_64.test(record.navigation.requestNonce) || !HEX_64.test(record.navigation.sourceDigest) ||
      record.planHash !== record.navigation.scopeHmac || !HEX_64.test(record.navigation.scopeHmac) ||
      record.itemCount !== 1 || record.currentIndex !== 0 ||
      !Array.isArray(record.itemHashes) || record.itemHashes.length !== 1 ||
      record.navigation.pid !== record.navigation.expectedWindow?.pid) {
    throw new AutomationError('RECOVERY_RECORD_INVALID', 'pending journal 不屬於可復原的 All 導航');
  }
  validateWindowIdentity(record.navigation.expectedWindow);
  const window = record.navigation.expectedWindow;
  if (window.executableURL !== '/Applications/LINE.app/Contents/MacOS/LINE' ||
      window.signingIdentifier !== 'jp.naver.line.mac' || window.teamIdentifier !== 'VUTU7AKEUR' ||
      record.itemHashes[0] !== digest(canonicalNavigationStart(record.navigation, record.navigation.route))) {
    throw new AutomationError('RECOVERY_RECORD_INVALID', 'pending journal 的 LINE owner 或 immutable hash 不符');
  }
  const countsAre = (expected) => isPlainObject(record.navigation.eventCounts) &&
    Object.keys(record.navigation.eventCounts).length === 3 &&
    ['move', 'down', 'up'].every((key) => record.navigation.eventCounts[key] === expected);
  let passiveReconcileValid = false;
  if (record.reconciledCurrentView !== undefined) {
    const marker = record.reconciledCurrentView;
    const markerHid = marker?.route === 'line-hid-all-v1';
    passiveReconcileValid = isPlainObject(marker) && marker.version === 1 &&
      ['line-system-events-all-v1', 'line-hid-all-v1'].includes(marker.route) &&
      HEX_64.test(marker.requestNonce) &&
      marker.requestNonce === (record.recoveryAttempt?.requestNonce || record.navigation.requestNonce) &&
      marker.phase === 'verified' && marker.systemEventsInvocations === 0 &&
      isPlainObject(marker.expectedWindow) &&
      (markerHid
        ? isPlainObject(marker.eventCounts) && Object.keys(marker.eventCounts).length === 3 &&
          ['move', 'down', 'up'].every((key) => marker.eventCounts[key] === 0)
        : !Object.prototype.hasOwnProperty.call(marker, 'eventCounts'));
    if (passiveReconcileValid) {
      validateWindowIdentity(marker.expectedWindow);
      passiveReconcileValid = marker.expectedWindow.pid === window.pid &&
        marker.expectedWindow.windowId === window.windowId &&
        marker.expectedWindow.executableURL === window.executableURL &&
        marker.expectedWindow.signingIdentifier === window.signingIdentifier &&
        marker.expectedWindow.teamIdentifier === window.teamIdentifier;
    }
    if (!passiveReconcileValid) {
      throw new AutomationError('RECOVERY_RECORD_INVALID', 'passive reconcile marker 不正確');
    }
  }
  if (record.recoveryAttempt !== undefined) {
    const attempt = record.recoveryAttempt;
    if (!isPlainObject(attempt) || attempt.version !== 1 || attempt.attempt !== 1 ||
      !['line-system-events-all-v1', 'line-hid-all-v1'].includes(attempt.route) ||
        !HEX_64.test(attempt.requestNonce) ||
        attempt.requestNonce === record.navigation.requestNonce || !HEX_64.test(attempt.sourceDigest) ||
        !['prepared', 'uncertain', 'verified'].includes(attempt.phase) ||
        (attempt.expectedWindow === null && attempt.phase !== 'prepared')) {
      throw new AutomationError('RECOVERY_RECORD_INVALID', 'recoveryAttempt canonical shape 不正確');
    }
    if (attempt.expectedWindow !== null) {
      validateWindowIdentity(attempt.expectedWindow);
      if (attempt.expectedWindow.pid !== window.pid || attempt.expectedWindow.windowId !== window.windowId ||
          attempt.expectedWindow.executableURL !== window.executableURL ||
          attempt.expectedWindow.signingIdentifier !== window.signingIdentifier ||
          attempt.expectedWindow.teamIdentifier !== window.teamIdentifier) {
        throw new AutomationError('RECOVERY_RECORD_INVALID', 'recoveryAttempt window owner 不一致');
      }
    }
    if (attempt.phase === 'verified') {
      const hidCounts = isPlainObject(attempt.eventCounts) &&
        Object.keys(attempt.eventCounts).length === 3 &&
        ['move', 'down', 'up'].every((key) => [0, 1].includes(attempt.eventCounts[key]));
      if (attempt.route === 'line-system-events-all-v1'
        ? (!Number.isInteger(attempt.systemEventsInvocations) ||
          attempt.systemEventsInvocations < 0 || attempt.systemEventsInvocations > 1)
        : (attempt.systemEventsInvocations !== 0 || !hidCounts ||
          !((attempt.eventCounts.move === 0 && attempt.eventCounts.down === 0 && attempt.eventCounts.up === 0) ||
            (attempt.eventCounts.move === 1 && attempt.eventCounts.down === 1 && attempt.eventCounts.up === 1)))) {
        throw new AutomationError('RECOVERY_RECORD_INVALID', 'recoveryAttempt verified receipt 不完整');
      }
    } else if (attempt.route === 'line-hid-all-v1') {
      const expectedCounts = attempt.phase === 'prepared' ? 0 : null;
      if (attempt.systemEventsInvocations !== 0 || !isPlainObject(attempt.eventCounts) ||
          Object.keys(attempt.eventCounts).length !== 3 ||
          !['move', 'down', 'up'].every((key) => attempt.eventCounts[key] === expectedCounts)) {
        throw new AutomationError('RECOVERY_RECORD_INVALID', 'HID recoveryAttempt counter 不正確');
      }
    }
  }
  if (record.navigation.route === 'line-pid-mouse-v1') {
    const uncertain = record.phase === 'uncertain' && record.verifiedThrough === -1;
    const verified = record.phase === 'verified' && record.verifiedThrough === 0 &&
      record.recoveredCurrentView === true &&
      (record.recoveryAttempt?.phase === 'verified' || passiveReconcileValid);
    const validPhase = uncertain ||
      verified;
    if (record.navigation.sourceDigest !== LEGACY_GLOBAL_ALL_SOURCE || !validPhase ||
        record.navigation.phase !== 'post_input' || !countsAre(null) ||
        Object.prototype.hasOwnProperty.call(record.navigation, 'systemEventsInvocations')) {
      throw new AutomationError('RECOVERY_RECORD_INVALID', 'legacy All pending canonical 關係不正確');
    }
  } else {
    if (record.recoveryAttempt !== undefined) {
      throw new AutomationError('RECOVERY_RECORD_INVALID', 'V4/HID canonical record 不可帶 legacy recoveryAttempt');
    }
    const hid = record.navigation.route === 'line-hid-all-v1';
    const uncertain = record.phase === 'uncertain' && record.verifiedThrough === -1 &&
      record.navigation.phase === 'post_input' && countsAre(null) &&
      record.navigation.systemEventsInvocations === (hid ? 0 : null);
    const selectorVerified = record.phase === 'verified' && record.verifiedThrough === 0 &&
      record.navigation.phase === 'verified' &&
      (hid
        ? record.navigation.systemEventsInvocations === 0 &&
          (countsAre(0) || countsAre(1))
        : countsAre(0) && Number.isInteger(record.navigation.systemEventsInvocations) &&
          record.navigation.systemEventsInvocations >= 0 && record.navigation.systemEventsInvocations <= 1);
    const reconcileVerified = record.phase === 'verified' && record.verifiedThrough === 0 &&
      record.recoveredCurrentView === true && record.navigation.phase === 'post_input' &&
      countsAre(null) && record.navigation.systemEventsInvocations === (hid ? 0 : null) &&
      passiveReconcileValid;
    if (!uncertain && !selectorVerified && !reconcileVerified) {
      throw new AutomationError('RECOVERY_RECORD_INVALID', 'V4/HID All pending canonical 關係不正確');
    }
  }
  return record;
}

function validateNativeState(value) {
  if (value === null) return null;
  nativeShape(value, [
    'version', 'expectedWindow', 'headerDigest', 'anchorHash', 'offset', 'pageNumber',
    'advance', 'seenIds', 'dateContext',
  ], 'nextState');
  if (Buffer.byteLength(JSON.stringify(value), 'utf8') > 64 * 1024 || value.version !== 1 ||
      !HEX_64.test(value.headerDigest) || !HEX_64.test(value.anchorHash) ||
      !Number.isInteger(value.offset) || value.offset < 0 || value.offset > 2_000 ||
      !Number.isInteger(value.pageNumber) || value.pageNumber < 0 || value.pageNumber > 1_000 ||
      typeof value.advance !== 'boolean' || !Array.isArray(value.seenIds) || value.seenIds.length > 2_000 ||
      value.seenIds.some((id) => typeof id !== 'string' || !HEX_64.test(id)) ||
      new Set(value.seenIds).size !== value.seenIds.length) {
    throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'native helper 的 nextState 超量或格式不正確');
  }
  validateWindowIdentity(value.expectedWindow);
  if (value.dateContext !== null) {
    nativeShape(value.dateContext, ['date', 'anchorHash'], 'nextState.dateContext');
    try {
      if (calendarDate(value.dateContext.date, 'nextState.dateContext.date') === null) throw new Error('missing date');
    } catch {
      throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'nextState.dateContext.date 不是有效日期');
    }
    if (!HEX_64.test(value.dateContext.anchorHash)) {
      throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'nextState.dateContext.anchorHash 格式不正確');
    }
  }
  return deepFreeze(cloneJson(value, 'nextState'));
}

function validateHistoryEnvelope(raw, tabName, chatName, limit) {
  nativeShape(raw, [
    'scope', 'observations', 'observedAt', 'snapshotDigest', 'nextState', 'complete',
    'reasons', 'syncState', 'truncated', 'possibleDuplicates',
  ], 'readHistoryPage result');
  nativeShape(raw.scope, ['tabName', 'chatName', 'verified'], 'readHistoryPage scope');
  // scope 必須先於 body 驗證，避免 native 混入其他聊天室內容後被回傳。
  if (raw.scope.tabName !== tabName || raw.scope.chatName !== chatName || raw.scope.verified !== true) {
    throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'readHistoryPage scope 與要求範圍不符');
  }
  const envelope = validateHistoryEnvelopeBody(raw, limit, 'readHistoryPage', true);
  if (envelope.observations.some(item => item.provenance.source === 'VISIBLE_CHAT_VIEWPORT_OCR')) {
    throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'tab history 不接受 indexed viewport provider');
  }
  return envelope;
}

function validateGlobalHistoryEnvelope(raw, chatName, limit, resultIndex = null) {
  nativeShape(raw, [
    'scope', 'observations', 'observedAt', 'snapshotDigest', 'nextState', 'complete',
    'reasons', 'syncState', 'truncated', 'possibleDuplicates',
  ], 'readGlobalHistoryPage result');
  nativeShape(raw.scope, resultIndex === null
    ? ['kind', 'chatName', 'verified']
    : ['kind', 'chatName', 'resultIndex', 'verified'], 'readGlobalHistoryPage scope');
  const scopeValid = resultIndex === null
    ? raw.scope.kind === 'chat'
    : raw.scope.kind === 'search_result' && raw.scope.resultIndex === resultIndex;
  if (!scopeValid || raw.scope.chatName !== chatName || raw.scope.verified !== true) {
    throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'readGlobalHistoryPage scope 與要求範圍不符');
  }
  const envelope = validateHistoryEnvelopeBody(raw, limit, 'readGlobalHistoryPage', false);
  const viewportSource = 'VISIBLE_CHAT_VIEWPORT_OCR';
  if (resultIndex === null) {
    if (envelope.observations.some(item => item.provenance.source === viewportSource)) {
      throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'no-index global 不接受 indexed viewport provider');
    }
    return envelope;
  }
  const fixedReasons = [
    'VISIBLE_VIEWPORT_ONLY', 'DATE_CONTEXT_UNKNOWN', 'STABLE_MESSAGE_ID_UNAVAILABLE',
    'LATEST_BOUNDARY_UNVERIFIED',
  ];
  if (envelope.complete || envelope.nextState !== null || !envelope.possibleDuplicates ||
      envelope.syncState !== 'unknown' || envelope.truncated ||
      envelope.reasons.length !== fixedReasons.length ||
      fixedReasons.some(reason => !envelope.reasons.includes(reason)) ||
      envelope.observations.some(item => item.unit !== 'text_block' || item.date !== null ||
        item.dateVerified || item.identityVerified || item.provenance.source !== viewportSource ||
        item.provenance.complete)) {
    throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'indexed viewport truthfulness 組合不正確');
  }
  return envelope;
}

function validateHistoryEnvelopeBody(raw, limit, commandName, allowNativeTextExport) {
  if (!Array.isArray(raw.observations) || raw.observations.length > limit) {
    throw new AutomationError('NATIVE_PROTOCOL_ERROR', `${commandName} observations 超過有界頁面`);
  }
  let textUnits = 0;
  const observedIds = new Set();
  for (const observation of raw.observations) {
    nativeShape(observation, [
      'observedId', 'text', 'date', 'dateVerified', 'unit', 'provenance', 'identityVerified',
    ], 'observation');
    nativeShape(observation.provenance, ['source', 'complete'], 'observation.provenance');
    if (!HEX_64.test(observation.observedId) || typeof observation.text !== 'string' ||
        typeof observation.dateVerified !== 'boolean' ||
        !['message', 'text_block'].includes(observation.unit) ||
        !['AX_ROW_VALUE', 'AX_STATIC_TEXT', 'VISIBLE_VERIFIED_ROW_OCR', 'VISIBLE_CHAT_VIEWPORT_OCR',
          ...(allowNativeTextExport ? ['NATIVE_TEXT_EXPORT'] : [])]
          .includes(observation.provenance.source) ||
        typeof observation.provenance.complete !== 'boolean' || typeof observation.identityVerified !== 'boolean') {
      throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'observation 欄位格式不正確');
    }
    if (observation.dateVerified) {
      try {
        if (calendarDate(observation.date, 'observation.date') === null) throw new Error('missing date');
      } catch {
        throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'observation.date 不是有效日期');
      }
    } else if (observation.date !== null) {
      throw new AutomationError('NATIVE_PROTOCOL_ERROR', '未驗證日期必須回 null');
    }
    if (observedIds.has(observation.observedId)) {
      throw new AutomationError('NATIVE_PROTOCOL_ERROR', '同一 raw page 不可重複 observedId');
    }
    observedIds.add(observation.observedId);
    textUnits += observation.text.length;
  }
  if (textUnits > 50_000 || !validIso8601(raw.observedAt) ||
      !HEX_64.test(raw.snapshotDigest) || typeof raw.complete !== 'boolean' ||
      !['complete', 'syncing', 'unknown'].includes(raw.syncState) ||
      typeof raw.truncated !== 'boolean' || typeof raw.possibleDuplicates !== 'boolean') {
    throw new AutomationError('NATIVE_PROTOCOL_ERROR', `${commandName} 結果格式不正確`);
  }
  const reasons = validateReasonList(raw.reasons);
  const nextState = validateNativeState(raw.nextState);
  const hasUnverifiedIdentity = raw.observations.some((item) => !item.identityVerified);
  if (hasUnverifiedIdentity && !raw.possibleDuplicates) {
    throw new AutomationError('NATIVE_PROTOCOL_ERROR', '無穩定列身分時必須標示 possibleDuplicates');
  }
  if (raw.complete && (
    nextState !== null || raw.syncState !== 'complete' || raw.truncated || raw.possibleDuplicates ||
    reasons.length > 0 || raw.observations.some((item) => !item.dateVerified || !item.provenance.complete)
  )) {
    throw new AutomationError('NATIVE_PROTOCOL_ERROR', `${commandName} complete 與限制證據矛盾`);
  }
  if (!raw.complete && nextState === null && reasons.length === 0) {
    throw new AutomationError('NATIVE_PROTOCOL_ERROR', '未完成且無 nextState 時必須提供 terminal limitation reason');
  }
  return deepFreeze({ ...cloneJson(raw, `${commandName} result`), nextState });
}

function mergeReasons(...lists) {
  return [...new Set(lists.flat().filter(Boolean))].slice(0, 32);
}

function aggregateSyncState(previous, current) {
  if (previous === 'syncing' || current === 'syncing') return 'syncing';
  if (previous === 'unknown' || current === 'unknown') return 'unknown';
  return 'complete';
}

function validateProviderState(value) {
  if (value === null) return null;
  nativeShape(value, ['provider', 'state'], 'providerState');
  if (value.provider === 'native') {
    return deepFreeze({ provider: 'native', state: validateNativeState(value.state) });
  }
  if (value.provider === 'export') {
    nativeShape(value.state, ['snapshotId', 'snapshotDigest', 'offset'], 'exportState');
    if (!HEX_64.test(value.state.snapshotId) || !HEX_64.test(value.state.snapshotDigest) ||
        !Number.isInteger(value.state.offset) || value.state.offset < 0) {
      throw new AutomationError('CURSOR_INVALID', 'export provider state 格式不正確');
    }
    return deepFreeze(cloneJson(value, 'providerState'));
  }
  throw new AutomationError('CURSOR_INVALID', 'providerState provider 不正確');
}

function filterObservations(observations, range) {
  const strict = range.startDate !== null || range.endDate !== null;
  let excludedUnknownDateCount = 0;
  const filtered = observations.filter((item) => {
    if (!item.dateVerified) {
      if (strict) excludedUnknownDateCount += 1;
      return !strict;
    }
    return (!range.startDate || item.date >= range.startDate) && (!range.endDate || item.date <= range.endDate);
  });
  const unknownCount = observations.filter((item) => !item.dateVerified).length;
  return { filtered, excludedUnknownDateCount, unknownCount };
}

function validateTabChanges(args) {
  assertKnownKeys(args, ['changes']);
  if (!Array.isArray(args.changes) || args.changes.length < 1 || args.changes.length > 20) {
    throw new AutomationError('INVALID_ARGUMENT', 'changes 必須包含 1 到 20 筆異動', { field: 'changes' });
  }

  const changes = args.changes.map((raw, index) => {
    assertPlainObject(raw, `changes[${index}]`);
    if (typeof raw.action !== 'string') {
      throw new AutomationError('INVALID_ARGUMENT', 'action 必須是支援的字串', { index });
    }
    switch (raw.action) {
      case 'create_tab':
        assertKnownKeys(raw, ['action', 'name'], `changes[${index}]`);
        return { action: raw.action, name: assertSafeName(raw.name, `changes[${index}].name`) };
      case 'rename_tab': {
        assertKnownKeys(raw, ['action', 'tabName', 'newName'], `changes[${index}]`);
        const tabName = assertSafeName(raw.tabName, `changes[${index}].tabName`);
        const newName = assertSafeName(raw.newName, `changes[${index}].newName`);
        if (tabName === newName) {
          throw new AutomationError('INVALID_ARGUMENT', '改名前後名稱不可相同', { index });
        }
        return { action: raw.action, tabName, newName };
      }
      case 'move_chat': {
        assertKnownKeys(raw, ['action', 'sourceTab', 'destinationTab', 'chatName'], `changes[${index}]`);
        const sourceTab = assertSafeName(raw.sourceTab, `changes[${index}].sourceTab`);
        const destinationTab = assertSafeName(raw.destinationTab, `changes[${index}].destinationTab`);
        const chatName = assertSafeName(raw.chatName, `changes[${index}].chatName`);
        if (sourceTab === destinationTab) {
          throw new AutomationError('INVALID_ARGUMENT', '來源與目的分頁不可相同', { index });
        }
        return { action: raw.action, sourceTab, destinationTab, chatName };
      }
      case 'remove_chat':
        assertKnownKeys(raw, ['action', 'sourceTab', 'chatName'], `changes[${index}]`);
        return {
          action: raw.action,
          sourceTab: assertSafeName(raw.sourceTab, `changes[${index}].sourceTab`),
          chatName: assertSafeName(raw.chatName, `changes[${index}].chatName`),
        };
      default:
        throw new AutomationError('INVALID_ARGUMENT', '不支援的分類異動 action', { index });
    }
  });

  const action = changes[0].action;
  if ((action === 'create_tab' || action === 'rename_tab') && changes.length !== 1) {
    throw new AutomationError('INVALID_ARGUMENT', '建立或改名每個計畫只能有一筆異動');
  }
  if (changes.some((change) => change.action !== action)) {
    throw new AutomationError('INVALID_ARGUMENT', '同一計畫不可混合不同 action 或建立批次依賴鏈');
  }
  if (action === 'move_chat' || action === 'remove_chat') {
    const sourceTab = changes[0].sourceTab;
    if (changes.some((change) => change.sourceTab !== sourceTab)) {
      throw new AutomationError('INVALID_ARGUMENT', '批次異動必須使用相同來源分頁');
    }
    const chats = changes.map((change) => change.chatName);
    if (new Set(chats).size !== chats.length) {
      throw new AutomationError('INVALID_ARGUMENT', '同一計畫不可重複處理聊天室');
    }
  }
  return deepFreeze(changes);
}

function validateContext(context) {
  assertKnownKeys(context, ['transport', 'sessionId'], 'context');
  if (context.transport !== 'stdio') {
    throw new AutomationError('TRANSPORT_NOT_ALLOWED', '桌面工具只允許透過 stdio 使用');
  }
  if (
    typeof context.sessionId !== 'string' ||
    context.sessionId.length === 0 ||
    context.sessionId.length > 256 ||
    /\p{Cc}/u.test(context.sessionId)
  ) {
    throw new AutomationError('INVALID_CONTEXT', '缺少有效的 stdio sessionId');
  }
  return context;
}

function validateNameList(result, field, maximum) {
  if (!result || typeof result !== 'object' || !Array.isArray(result[field]) || result[field].length > maximum) {
    throw new AutomationError('NATIVE_PROTOCOL_ERROR', `native helper 的 ${field} 格式不正確`);
  }
  for (const value of result[field]) {
    if (
      typeof value !== 'string' || value.length === 0 || value.length > 200 ||
      /\p{Cc}|[\u202a-\u202e\u2066-\u2069]/u.test(value)
    ) {
      throw new AutomationError('NATIVE_PROTOCOL_ERROR', `native helper 的 ${field} 含有無效名稱`);
    }
  }
  return result;
}

export class UnsupportedDesktopAutomation {
  async call(_name, _args, context) {
    validateContext(context);
    throw new AutomationError('UNSUPPORTED_PLATFORM', '此平台尚未支援 LINE 桌面新工具');
  }
}

export class MacOSDesktopAutomation {
  constructor({
    bridge = new NativeBridge(),
    lock = new OperationLock(),
    now = () => Date.now(),
    randomBytes = crypto.randomBytes,
    bootNonce = crypto.randomBytes(24).toString('base64url'),
    fileSystem = fs,
    exportReader,
    journalPath = path.join(
      os.homedir(),
      'Library',
      'Application Support',
      'line-desktop-mcp',
      'pending-operation.json'
    ),
    recoveryEvidenceDirectory,
    requests,
    attachmentSettle,
  } = {}) {
    this.bridge = bridge;
    this.lock = lock;
    this.now = now;
    this.randomBytes = randomBytes;
    this.bootNonce = bootNonce;
    this.fs = fileSystem;
    this.exportReader = exportReader === undefined && typeof bridge.exportChatText === 'function'
      ? new NativeTextExportReader({
        capture: (request) => bridge.exportChatText(request),
        now,
        randomBytes,
        fileSystem,
      })
      : exportReader || null;
    this.journalPath = journalPath;
    this.recoveryEvidenceDirectory = recoveryEvidenceDirectory ||
      path.join(path.dirname(journalPath), 'recovery-evidence');
    this.requests = requests || new RequestReceipts(path.join(path.dirname(journalPath), 'requests'));
    this.attachmentSettle = attachmentSettle;
    this.recoveryLatch = null;
    this.plans = new Map();
    this.cursors = new Map();
  }

  async call(name, args = {}, context = {}) {
    validateContext(context);
    assertPlainObject(args);
    this.pruneStores();
    switch (name) {
      case 'line_send_images':
        return this.sendAttachments(args, 'image');
      case 'line_send_files':
        return this.sendAttachments(args, 'file');
      case 'line_doctor':
        assertKnownKeys(args, ['probeNative']);
        return doctor({ bridge: this.bridge, probeNative: args.probeNative ?? false });
      case 'line_operation_status':
        assertKnownKeys(args, ['requestId']);
        return this.requests.status(validateRequestId(args.requestId), this.journalPath);
      case 'line_resolve_operation':
        assertKnownKeys(args, ['requestId', 'operationId', 'outcome']);
        validateRequestId(args.requestId);
        return this.lock.withLock(() => this.requests.resolve(args, this.journalPath, () => this.bridge.call('status')));
      case 'line_send_image':
        return this.sendImage(args);
      case 'line_desktop_status':
        assertKnownKeys(args, []);
        return this.lock.withLock(async () => {
          const recovery = await this.recoveryStatus();
          return {
            ...(await this.bridge.call('status')),
            needsRecovery: recovery !== null,
            ...(recovery ? { recovery } : {}),
          };
        });
      case 'line_list_tabs':
        return this.listTabs(args);
      case 'line_list_tab_chats':
        return this.listTabChats(args, context);
      case 'line_get_chat_history_page':
        return this.getChatHistoryPage(args, context);
      case 'line_get_chat_history_global':
        return this.getGlobalChatHistoryPage(args, context);
      case 'line_search_tab_messages':
        return this.searchTabMessages(args, context);
      case 'line_mark_tab_read':
        return this.previewMarkTabRead(args, context);
      case 'line_plan_tab_changes':
        return this.previewTabChanges(args, context);
      case 'line_execute_plan':
        return this.executePlan(args, context);
      default:
        throw new AutomationError('UNKNOWN_TOOL', `不支援的桌面工具：${name}`);
    }
  }

  async listTabs(args) {
    assertKnownKeys(args, ['maxPages']);
    const maxPages = optionalInteger(args.maxPages, 'maxPages', 1, 20, 5);
    return this.lock.withLock(async () => {
      const result = validateNameList(await this.bridge.call('listTabs', { maxPages }), 'tabs', 1_000);
      if (result.tabs.length === 0) {
        throw new AutomationError('SEMANTIC_UNRELIABLE', 'native helper 未提供可辨識的分頁，不回傳假空清單');
      }
      return result;
    });
  }

  async listTabChats(args, context) {
    assertKnownKeys(args, ['tabName', 'limit', 'cursor']);
    const tabName = assertSafeName(args.tabName, 'tabName');
    const limit = optionalInteger(args.limit, 'limit', 1, 100, 50);
    let offset = 0;
    let expectedDigest;
    if (args.cursor !== undefined) {
      if (typeof args.cursor !== 'string') {
        throw new AutomationError('INVALID_ARGUMENT', 'cursor 必須是字串', { field: 'cursor' });
      }
      const cursor = this.cursors.get(args.cursor);
      if (
        !cursor ||
        cursor.expiresAt <= this.now() ||
        cursor.kind !== 'tabChats' ||
        cursor.bootNonce !== this.bootNonce ||
        cursor.sessionId !== context.sessionId ||
        cursor.tabName !== tabName
      ) {
        throw new AutomationError('CURSOR_INVALID', 'cursor 已失效或不屬於目前 session');
      }
      this.cursors.delete(args.cursor);
      offset = cursor.offset;
      expectedDigest = cursor.snapshotDigest;
    }

    const result = await this.lock.withLock(() =>
      this.bridge.call('listTabChats', { tabName, limit, offset, expectedDigest })
    );
    validateNameList(result, 'chats', limit);
    if (typeof result.snapshotDigest !== 'string' || result.snapshotDigest.length === 0 || result.snapshotDigest.length > 256) {
      throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'native helper 缺少有效 snapshotDigest');
    }
    if (
      result.nextOffset !== undefined &&
      (!Number.isInteger(result.nextOffset) || result.nextOffset <= offset || result.nextOffset > 100_000)
    ) {
      throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'native helper 回傳無效 nextOffset');
    }
    if (expectedDigest && result.snapshotDigest !== expectedDigest) {
      throw new AutomationError('CURSOR_INVALID', '分頁內容已變更，舊 cursor 不再有效');
    }
    if (Number.isInteger(result.nextOffset)) {
      result.cursor = this.storeCursor({
        kind: 'tabChats',
        sessionId: context.sessionId,
        tabName,
        offset: result.nextOffset,
        snapshotDigest: result.snapshotDigest,
      });
    } else {
      result.cursor = null;
    }
    delete result.nextOffset;
    return result;
  }

  async inventoryTabChatsHeld(tabName) {
    const chats = [];
    const ambiguous = new Set();
    const reasons = [];
    let offset = 0;
    let snapshotDigest;
    let complete = true;
    let exhausted = false;
    for (let page = 0; page < 10; page += 1) {
      const result = await this.bridge.call('listTabChats', {
        tabName, limit: 100, offset, ...(snapshotDigest ? { expectedDigest: snapshotDigest } : {}),
      });
      validateNameList(result, 'chats', 100);
      if (result.tabName !== undefined && result.tabName !== tabName) {
        throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'inventory 回傳了不同分頁');
      }
      if (!HEX_64.test(result.snapshotDigest) ||
          (snapshotDigest !== undefined && snapshotDigest !== result.snapshotDigest)) {
        throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'inventory snapshotDigest 格式或分頁間一致性不正確');
      }
      snapshotDigest = result.snapshotDigest;
      if (typeof result.complete !== 'boolean' || typeof result.partial !== 'boolean' ||
          result.complete === result.partial) {
        throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'inventory 完整性旗標不正確');
      }
      complete = complete && result.complete;
      if (result.partial) reasons.push('INVENTORY_PARTIAL');
      for (const reason of validateReasonList(result.reasons || [], 'inventory reasons')) reasons.push(reason);
      if (!Array.isArray(result.ambiguousNames) || result.ambiguousNames.length > 1_000) {
        throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'inventory ambiguousNames 格式不正確');
      }
      validateNameList({ ambiguousNames: result.ambiguousNames }, 'ambiguousNames', 1_000);
      for (const name of result.ambiguousNames) {
        ambiguous.add(name);
      }
      chats.push(...result.chats);
      if (result.nextOffset === undefined) {
        exhausted = true;
        break;
      }
      if (!Number.isInteger(result.nextOffset) || result.nextOffset <= offset || result.nextOffset > 1_000) {
        throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'inventory nextOffset 格式不正確');
      }
      if (result.nextOffset !== offset + result.chats.length) {
        throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'inventory nextOffset 會跳過未盤點成員');
      }
      offset = result.nextOffset;
    }
    if (!exhausted) {
      complete = false;
      reasons.push('INVENTORY_BUDGET');
    }
    const counts = new Map();
    for (const chat of chats) counts.set(chat, (counts.get(chat) || 0) + 1);
    for (const [chat, count] of counts) if (count > 1) ambiguous.add(chat);
    if (ambiguous.size > 0) reasons.push('INVENTORY_AMBIGUOUS');
    const members = [...counts.keys()].filter((chat) => !ambiguous.has(chat));
    const normalizedReasons = mergeReasons(reasons);
    return deepFreeze({
      chats: [...chats],
      members,
      ambiguousNames: [...ambiguous],
      complete: complete && ambiguous.size === 0,
      reasons: normalizedReasons,
      snapshotDigest,
      inventoryDigest: digest({
        tabName, chats, snapshotDigest, ambiguousNames: [...ambiguous].sort(), complete, reasons: normalizedReasons,
      }),
    });
  }

  consumeCursor(rawToken, expected) {
    if (rawToken === undefined) return null;
    if (typeof rawToken !== 'string') {
      throw new AutomationError('INVALID_ARGUMENT', 'cursor 必須是字串', { field: 'cursor' });
    }
    const cursor = this.cursors.get(rawToken);
    const valid = cursor && cursor.expiresAt > this.now() && cursor.bootNonce === this.bootNonce &&
      cursor.kind === expected.kind && cursor.sessionId === expected.sessionId &&
      cursor.tabName === expected.tabName && cursor.chatName === expected.chatName &&
      cursor.query === expected.query && cursor.startDate === expected.startDate &&
      cursor.endDate === expected.endDate && cursor.limit === expected.limit &&
      cursor.normalizationVersion === expected.normalizationVersion;
    if (!valid) throw new AutomationError('CURSOR_INVALID', 'cursor 已失效或不符合原始查詢條件');
    this.cursors.delete(rawToken);
    return cursor;
  }

  identityKey(context, tabName, chatName) {
    return keyedDigest(this.bootNonce, {
      purpose: 'history-row-identity-v1', sessionId: context.sessionId, tabName, chatName,
    });
  }

  globalIdentityKey(context, chatName, resultIndex = null) {
    return keyedDigest(this.bootNonce, resultIndex === null
      ? { purpose: 'global-history-identity-v1', sessionId: context.sessionId, chatName }
      : { purpose: 'global-history-identity-v1', sessionId: context.sessionId, chatName, resultIndex });
  }

  async readProviderPage({ tabName, chatName, limit, identityKey, providerState, allowExport }) {
    const state = validateProviderState(providerState);
    if (state?.provider === 'export') {
      if (!this.exportReader) throw new AutomationError('CURSOR_INVALID', 'export provider 已不可用');
      const page = await this.exportReader.readPage({
        tabName, chatName, limit, identityKey, state: state.state,
      });
      if (!page) throw new AutomationError('CURSOR_INVALID', 'export continuation 不得切換 provider');
      return {
        envelope: validateHistoryEnvelope(page.envelope, tabName, chatName, limit),
        providerState: page.exportState ? { provider: 'export', state: page.exportState } : null,
      };
    }
    if (state?.provider === 'native') {
      const envelope = validateHistoryEnvelope(await this.bridge.call('readHistoryPage', {
        tabName, chatName, limit, identityKey, nativeState: state.state,
      }), tabName, chatName, limit);
      return {
        envelope,
        providerState: envelope.nextState ? { provider: 'native', state: envelope.nextState } : null,
      };
    }
    if (allowExport && this.exportReader) {
      const page = await this.exportReader.readPage({ tabName, chatName, limit, identityKey });
      if (page) {
        return {
          envelope: validateHistoryEnvelope(page.envelope, tabName, chatName, limit),
          providerState: page.exportState ? { provider: 'export', state: page.exportState } : null,
        };
      }
    }
    const envelope = validateHistoryEnvelope(await this.bridge.call('readHistoryPage', {
      tabName, chatName, limit, identityKey,
    }), tabName, chatName, limit);
    return {
      envelope,
      providerState: envelope.nextState ? { provider: 'native', state: envelope.nextState } : null,
    };
  }

  async getChatHistoryPage(args, context) {
    assertKnownKeys(args, ['tabName', 'chatName', 'startDate', 'endDate', 'limit', 'cursor']);
    const tabName = assertSafeName(args.tabName, 'tabName');
    const chatName = assertSafeName(args.chatName, 'chatName');
    const range = dateRange(args);
    const limit = optionalInteger(args.limit, 'limit', 1, 100, 50);
    return this.lock.withLock(async () => {
      const cursor = this.consumeCursor(args.cursor, {
        kind: 'historyPage', sessionId: context.sessionId, tabName, chatName,
        query: null, ...range, limit, normalizationVersion: QUERY_NORMALIZATION_VERSION,
      });
      const inventory = await this.inventoryTabChatsHeld(tabName);
      if (cursor && cursor.inventoryDigest !== inventory.inventoryDigest) {
        throw new AutomationError('CURSOR_INVALID', '分頁成員盤點已變更，舊 cursor 不再有效');
      }
      if (inventory.ambiguousNames.includes(chatName)) {
        throw new AutomationError('SCOPE_AMBIGUOUS', '分頁內有同名聊天室，拒絕讀取訊息 body');
      }
      if (!inventory.members.includes(chatName)) {
        throw new AutomationError('SCOPE_NOT_VERIFIED', '無法證明聊天室屬於指定分頁，拒絕讀取訊息 body');
      }
      const read = await this.readProviderPage({
        tabName, chatName, limit,
        identityKey: this.identityKey(context, tabName, chatName),
        providerState: cursor?.providerState || null,
        allowExport: range.startDate === null && range.endDate === null,
      });
      const envelope = read.envelope;
      const filtered = filterObservations(envelope.observations, range);
      const previousEvidence = cursor?.historyEvidence || {
        reasons: [], excludedUnknownDateCount: 0, truncated: false,
        possibleDuplicates: false, syncState: 'complete',
      };
      const truncated = previousEvidence.truncated || envelope.truncated;
      const possibleDuplicates = previousEvidence.possibleDuplicates || envelope.possibleDuplicates;
      const syncState = aggregateSyncState(previousEvidence.syncState, envelope.syncState);
      const excludedUnknownDateCount =
        previousEvidence.excludedUnknownDateCount + filtered.excludedUnknownDateCount;
      const reasons = mergeReasons(
        previousEvidence.reasons,
        inventory.reasons,
        envelope.reasons,
        truncated ? ['TRUNCATED'] : [],
        possibleDuplicates ? ['POSSIBLE_DUPLICATES'] : [],
        syncState !== 'complete' ? ['SYNC_INCOMPLETE'] : [],
        filtered.unknownCount > 0
          ? [range.startDate || range.endDate ? 'UNKNOWN_DATE_EXCLUDED' : 'UNKNOWN_DATE']
          : []
      );
      const nextCursor = read.providerState ? this.storeCursor({
        kind: 'historyPage', sessionId: context.sessionId, tabName, chatName,
        query: null, ...range, limit, normalizationVersion: QUERY_NORMALIZATION_VERSION,
        inventoryDigest: inventory.inventoryDigest, providerState: read.providerState,
        historyEvidence: { reasons, excludedUnknownDateCount, truncated, possibleDuplicates, syncState },
      }) : null;
      return {
        scope: envelope.scope,
        observations: filtered.filtered,
        observedAt: envelope.observedAt,
        snapshotDigest: envelope.snapshotDigest,
        cursor: nextCursor,
        complete: envelope.complete && inventory.complete && reasons.length === 0,
        reasons,
        syncState,
        truncated,
        possibleDuplicates,
        excludedUnknownDateCount,
        limitUnit: 'observations',
        mayAffectReadState: true,
      };
    });
  }

  async getGlobalChatHistoryPage(args, context) {
    assertKnownKeys(args, ['chatName', 'resultIndex', 'startDate', 'endDate', 'limit', 'cursor']);
    const chatName = assertSafeName(args.chatName, 'chatName');
    const resultIndex = optionalInteger(args.resultIndex, 'resultIndex', 1, 20, null);
    if (resultIndex !== null && args.cursor !== undefined) {
      throw new AutomationError('INVALID_ARGUMENT', 'resultIndex 模式不支援 cursor');
    }
    const range = dateRange(args);
    const limit = optionalInteger(args.limit, 'limit', 1, 100, 50);
    return this.lock.withLock(async () => {
      // 任何未完成的 UI 異動都優先停止全域讀取，且不消耗 cursor。
      await this.assertNoPendingJournal();
      const cursor = this.consumeCursor(args.cursor, {
        kind: 'globalHistoryPage', sessionId: context.sessionId, tabName: null, chatName,
        query: null, ...range, limit, normalizationVersion: QUERY_NORMALIZATION_VERSION,
      });
      let nativeState = null;
      if (cursor?.nativeState !== undefined) {
        try {
          nativeState = validateNativeState(cursor.nativeState);
        } catch {
          throw new AutomationError('CURSOR_INVALID', 'global cursor 的 native state 不正確');
        }
      }
      const expectedWindow = validateGlobalNavigationStatus(await this.bridge.call('status'));
      if (nativeState && !sameWindowIdentity(nativeState.expectedWindow, expectedWindow)) {
        throw new AutomationError('CURSOR_INVALID', 'global cursor 的視窗身分已漂移');
      }
      const requestNonce = this.randomBytes(32).toString('hex');
      if (!HEX_64.test(requestNonce)) {
        throw new AutomationError('TOKEN_GENERATION_FAILED', '無法產生 global All 導航 nonce');
      }
      let sourceDigest = null;
      if (typeof this.bridge.selectedSourceDigest === 'function') {
        const selected = await this.bridge.selectedSourceDigest();
        if (selected?.sourceDigestVerified === true && HEX_64.test(selected.sourceDigest)) {
          sourceDigest = selected.sourceDigest;
        }
      }
      const selectorRequest = { chatName, requestNonce, expectedWindow };
      const scopeHmac = keyedDigest(this.bootNonce, {
        route: 'line-hid-all-v1', requestNonce, chatName, expectedWindow,
      });
      const navigation = {
        version: 1,
        route: 'line-hid-all-v1',
        requestNonce,
        sourceDigest,
        pid: expectedWindow.pid,
        expectedWindow,
        scopeHmac,
        phase: 'pre_input',
        eventCounts: { move: 0, down: 0, up: 0 },
        systemEventsInvocations: 0,
      };
      const journal = {
        schemaVersion: 2,
        operationId: `global-all-navigation:${requestNonce}`,
        planHash: scopeHmac,
        itemHashes: [digest(navigation)],
        itemCount: 1,
        currentIndex: 0,
        verifiedThrough: -1,
        phase: 'prepared',
        navigation,
      };
      // create 與 atomic checkpoint 都完成後才允許 native 第一次移動滑鼠。
      await this.createJournalV2(journal);
      await this.checkpointJournalV2(journal);

      let selectorReceipt;
      try {
        selectorReceipt = validateGlobalNavigationReceipt(
          await this.bridge.call('selectGlobalAll', selectorRequest), selectorRequest, true
        );
      } catch (error) {
        const zeroEvent = trustedZeroEventNavigation(error?.details?.allNavigation, selectorRequest);
        if (zeroEvent) {
          const closed = {
            ...journal,
            phase: 'terminal_known_partial',
            navigation: { ...navigation, phase: zeroEvent.phase, eventCounts: zeroEvent.eventCounts },
          };
          try {
            await this.checkpointJournalV2(closed);
            await this.clearJournalV2();
          } catch (clearError) {
            this.recoveryLatch = closed;
            throw new AutomationError('OPERATION_UNCERTAIN', 'global All 零事件記錄無法安全結案', {
              needsRecovery: true,
              causeCode: clearError?.code || 'JOURNAL_FAILURE',
            });
          }
          throw error;
        }
        const pending = {
          ...journal,
          phase: 'uncertain',
          navigation: {
            ...navigation,
            phase: 'post_input',
            eventCounts: { move: null, down: null, up: null },
            systemEventsInvocations: 0,
          },
        };
        this.recoveryLatch = pending;
        await this.checkpointJournalV2(pending).catch(() => {});
        throw new AutomationError('OPERATION_UNCERTAIN', 'global All 導航結果不明，已停止正文讀取', {
          needsRecovery: true,
          causeCode: error?.code || 'NATIVE_FAILURE',
        });
      }

      const verified = {
        ...journal,
        phase: 'verified',
        verifiedThrough: 0,
        navigation: {
          ...navigation,
          phase: selectorReceipt.phase,
          eventCounts: selectorReceipt.eventCounts,
          systemEventsInvocations: selectorReceipt.systemEventsInvocations,
        },
      };
      try {
        await this.checkpointJournalV2(verified);
        await this.clearJournalV2();
      } catch (error) {
        this.recoveryLatch = verified;
        await this.createJournalV2(verified).catch(() => {});
        throw new AutomationError('OPERATION_UNCERTAIN', 'global All 已驗證但 journal 無法安全結案', {
          needsRecovery: true,
          causeCode: error?.code || 'JOURNAL_FAILURE',
        });
      }
      const request = {
        chatName,
        limit,
        identityKey: this.globalIdentityKey(context, chatName, resultIndex),
        ...(resultIndex === null ? {} : { resultIndex }),
        ...(nativeState ? { nativeState } : {}),
      };
      const envelope = validateGlobalHistoryEnvelope(
        await this.bridge.call('readGlobalHistoryPage', request), chatName, limit, resultIndex
      );
      const filtered = filterObservations(envelope.observations, range);
      const previousEvidence = cursor?.historyEvidence || {
        reasons: [], excludedUnknownDateCount: 0, truncated: false,
        possibleDuplicates: false, syncState: 'complete',
      };
      const truncated = previousEvidence.truncated || envelope.truncated;
      const possibleDuplicates = previousEvidence.possibleDuplicates || envelope.possibleDuplicates;
      const syncState = aggregateSyncState(previousEvidence.syncState, envelope.syncState);
      const excludedUnknownDateCount =
        previousEvidence.excludedUnknownDateCount + filtered.excludedUnknownDateCount;
      const reasons = mergeReasons(
        previousEvidence.reasons,
        envelope.reasons,
        truncated ? ['TRUNCATED'] : [],
        possibleDuplicates ? ['POSSIBLE_DUPLICATES'] : [],
        syncState !== 'complete' ? ['SYNC_INCOMPLETE'] : [],
        filtered.unknownCount > 0
          ? [range.startDate || range.endDate ? 'UNKNOWN_DATE_EXCLUDED' : 'UNKNOWN_DATE']
          : []
      );
      const nextCursor = resultIndex === null && envelope.nextState ? this.storeCursor({
        kind: 'globalHistoryPage', sessionId: context.sessionId, tabName: null, chatName,
        query: null, ...range, limit, normalizationVersion: QUERY_NORMALIZATION_VERSION,
        nativeState: envelope.nextState,
        historyEvidence: { reasons, excludedUnknownDateCount, truncated, possibleDuplicates, syncState },
      }) : null;
      return {
        scope: envelope.scope,
        observations: filtered.filtered,
        observedAt: envelope.observedAt,
        snapshotDigest: envelope.snapshotDigest,
        cursor: nextCursor,
        complete: envelope.complete && reasons.length === 0,
        reasons,
        syncState,
        truncated,
        possibleDuplicates,
        excludedUnknownDateCount,
        limitUnit: 'observations',
        mayAffectReadState: true,
      };
    });
  }

  async searchTabMessages(args, context) {
    assertKnownKeys(args, ['tabName', 'query', 'startDate', 'endDate', 'limit', 'cursor']);
    const tabName = assertSafeName(args.tabName, 'tabName');
    const query = normalizeQuery(args.query);
    const range = dateRange(args);
    const limit = optionalInteger(args.limit, 'limit', 1, 100, 50);
    return this.lock.withLock(async () => {
      const cursor = this.consumeCursor(args.cursor, {
        kind: 'tabSearch', sessionId: context.sessionId, tabName, chatName: null,
        query: query.raw, ...range, limit, normalizationVersion: query.version,
      });
      const inventory = await this.inventoryTabChatsHeld(tabName);
      if (cursor && cursor.inventoryDigest !== inventory.inventoryDigest) {
        throw new AutomationError('CURSOR_INVALID', '分頁成員盤點已變更，舊 cursor 不再有效');
      }
      const state = cursor?.searchState || {
        memberIndex: 0, providerState: null, reasons: inventory.reasons,
        scannedObservationCount: 0, returnedMatchCount: 0, excludedUnknownDateCount: 0,
        truncated: false, possibleDuplicates: false, syncState: 'complete',
      };
      if (state.memberIndex < 0 || state.memberIndex >= inventory.members.length) {
        const completeEmptyInventory = inventory.chats.length === 0 && inventory.complete &&
          inventory.reasons.length === 0;
        return {
          matches: [], cursor: null, complete: completeEmptyInventory,
          reasons: completeEmptyInventory ? [] : mergeReasons(state.reasons, ['NO_UNIQUE_MEMBERS']),
          progress: {
            inventoryObserved: inventory.chats.length,
            totalIfKnown: inventory.complete ? inventory.chats.length : null,
            currentChat: null,
            scannedObservationCount: state.scannedObservationCount,
            returnedMatchCount: state.returnedMatchCount,
          },
          excludedUnknownDateCount: state.excludedUnknownDateCount,
          syncState: completeEmptyInventory ? 'complete' : 'unknown',
          truncated: state.truncated,
          possibleDuplicates: state.possibleDuplicates,
          limitUnit: 'observations',
          mayAffectReadState: true,
        };
      }
      const chatName = inventory.members[state.memberIndex];
      const read = await this.readProviderPage({
        tabName, chatName, limit,
        identityKey: this.identityKey(context, tabName, chatName),
        providerState: state.providerState,
        allowExport: range.startDate === null && range.endDate === null,
      });
      const envelope = read.envelope;
      const filtered = filterObservations(envelope.observations, range);
      const matches = filtered.filtered.filter((item) => {
        const text = item.text.normalize('NFKC').toLowerCase();
        return query.terms.every((term) => text.includes(term));
      }).map((item) => ({ chatName, ...item }));
      const truncated = state.truncated || envelope.truncated;
      const possibleDuplicates = state.possibleDuplicates || envelope.possibleDuplicates;
      const syncState = aggregateSyncState(state.syncState, envelope.syncState);
      const accumulatedReasons = mergeReasons(
        state.reasons,
        envelope.reasons,
        truncated ? ['TRUNCATED'] : [],
        possibleDuplicates ? ['POSSIBLE_DUPLICATES'] : [],
        syncState !== 'complete' ? ['SYNC_INCOMPLETE'] : [],
        filtered.unknownCount > 0
          ? [range.startDate || range.endDate ? 'UNKNOWN_DATE_EXCLUDED' : 'UNKNOWN_DATE']
          : []
      );
      const scannedObservationCount = state.scannedObservationCount + envelope.observations.length;
      const returnedMatchCount = state.returnedMatchCount + matches.length;
      const excludedUnknownDateCount = state.excludedUnknownDateCount + filtered.excludedUnknownDateCount;
      let memberIndex = state.memberIndex;
      let providerState = read.providerState;
      if (!providerState) memberIndex += 1;
      const hasNext = providerState !== null || memberIndex < inventory.members.length;
      const nextCursor = hasNext ? this.storeCursor({
        kind: 'tabSearch', sessionId: context.sessionId, tabName, chatName: null,
        query: query.raw, ...range, limit, normalizationVersion: query.version,
        inventoryDigest: inventory.inventoryDigest,
        searchState: {
          memberIndex, providerState, reasons: accumulatedReasons,
          scannedObservationCount, returnedMatchCount, excludedUnknownDateCount,
          truncated, possibleDuplicates, syncState,
        },
      }) : null;
      return {
        matches,
        cursor: nextCursor,
        complete: !hasNext && envelope.complete && inventory.complete && accumulatedReasons.length === 0,
        reasons: accumulatedReasons,
        progress: {
          inventoryObserved: inventory.chats.length,
          totalIfKnown: inventory.complete ? inventory.chats.length : null,
          currentChat: chatName,
          scannedObservationCount,
          returnedMatchCount,
        },
        excludedUnknownDateCount,
        syncState,
        truncated,
        possibleDuplicates,
        limitUnit: 'observations',
        mayAffectReadState: true,
      };
    });
  }

  async previewMarkTabRead(args, context) {
    assertKnownKeys(args, ['tabName']);
    const tabName = assertSafeName(args.tabName, 'tabName');
    return this.lock.withLock(async () => {
      await this.assertNoPendingJournal();
      const preview = await this.bridge.call('previewMarkTabRead', { tabName });
      if (
        typeof preview.snapshotDigest !== 'string' ||
        preview.snapshotDigest.length === 0 ||
        preview.snapshotDigest.length > 256 ||
        !preview.expectedWindow ||
        typeof preview.expectedWindow !== 'object' ||
        Array.isArray(preview.expectedWindow) ||
        !preview.preview ||
        typeof preview.preview !== 'object' ||
        Array.isArray(preview.preview)
      ) {
        throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'preview 缺少視窗或結構快照');
      }
      const issuedAt = this.now();
      const token = this.uniqueToken(this.plans, 32);
      const plan = {
        action: 'markTabRead',
        args: { tabName },
        bootNonce: this.bootNonce,
        sessionId: context.sessionId,
        transport: context.transport,
        snapshotDigest: preview.snapshotDigest,
        expectedWindow: preview.expectedWindow,
        structureDigest: digest({ tabName, preview }),
        issuedAt,
        expiresAt: issuedAt + TOKEN_TTL_MS,
      };
      this.storeBounded(this.plans, token, plan);
      return {
        action: 'markTabRead',
        tabName,
        preview: preview.preview,
        planToken: token,
        expiresAt: new Date(plan.expiresAt).toISOString(),
      };
    });
  }

  async previewTabChanges(args, context) {
    const changes = validateTabChanges(args);
    return this.lock.withLock(async () => {
      await this.assertNoPendingJournal();
      const nativePreview = await this.bridge.call('previewTabChanges', { changes });
      if (!isPlainObject(nativePreview) || !isPlainObject(nativePreview.preview)) {
        throw new AutomationError('NATIVE_PROTOCOL_ERROR', '分類異動 preview 格式不正確');
      }
      const unknown = Object.keys(nativePreview).filter((key) =>
        !['preview', 'snapshotDigest', 'expectedWindow', 'itemFingerprints', 'canExecute', 'blocked'].includes(key));
      if (unknown.length > 0) {
        throw new AutomationError('NATIVE_PROTOCOL_ERROR', '分類異動 preview 含未知欄位');
      }
      const preview = cloneJson(nativePreview.preview, 'preview');
      if (nativePreview.canExecute !== undefined && typeof nativePreview.canExecute !== 'boolean') {
        throw new AutomationError('NATIVE_PROTOCOL_ERROR', '分類異動 canExecute 格式不正確');
      }
      if (nativePreview.blocked !== undefined && typeof nativePreview.blocked !== 'boolean') {
        throw new AutomationError('NATIVE_PROTOCOL_ERROR', '分類異動 blocked 格式不正確');
      }
      if (nativePreview.expectedWindow !== undefined && nativePreview.expectedWindow !== null &&
          !isPlainObject(nativePreview.expectedWindow)) {
        throw new AutomationError('NATIVE_PROTOCOL_ERROR', '分類異動 expectedWindow 格式不正確');
      }
      const expectedWindowValid = isPlainObject(nativePreview.expectedWindow);
      const fingerprintsValid =
        Array.isArray(nativePreview.itemFingerprints) &&
        nativePreview.itemFingerprints.length === changes.length &&
        nativePreview.itemFingerprints.every((value) =>
          typeof value === 'string' && value.length > 0 && value.length <= 512) &&
        new Set(nativePreview.itemFingerprints).size === changes.length;
      const canExecute =
        nativePreview.canExecute === true &&
        nativePreview.blocked !== true &&
        validDigest(nativePreview.snapshotDigest) &&
        expectedWindowValid &&
        fingerprintsValid;
      const response = {
        action: 'tabChanges',
        changes: cloneJson(changes, 'changes'),
        preview,
        mayAffectReadState: true,
        canExecute,
        blocked: !canExecute,
      };
      if (!canExecute) return response;

      const issuedAt = this.now();
      const token = this.uniqueToken(this.plans, 32);
      const plan = deepFreeze({
        action: 'tabChanges',
        changes,
        bootNonce: this.bootNonce,
        sessionId: context.sessionId,
        transport: context.transport,
        snapshotDigest: nativePreview.snapshotDigest,
        expectedWindow: cloneJson(nativePreview.expectedWindow, 'expectedWindow'),
        itemFingerprints: [...nativePreview.itemFingerprints],
        issuedAt,
        expiresAt: issuedAt + TOKEN_TTL_MS,
      });
      this.storeBounded(this.plans, token, plan);
      return {
        ...response,
        planToken: token,
        expiresAt: new Date(plan.expiresAt).toISOString(),
      };
    });
  }

  async executePlan(args, context) {
    assertKnownKeys(args, ['planToken']);
    if (typeof args.planToken !== 'string' || args.planToken.length < 20 || args.planToken.length > 200) {
      throw new AutomationError('INVALID_ARGUMENT', 'planToken 格式不正確', { field: 'planToken' });
    }
    return this.lock.withLock(async () => {
      await this.assertNoPendingJournal();
      const plan = this.plans.get(args.planToken);
      if (!plan) throw new AutomationError('PLAN_INVALID', 'planToken 不存在或已使用');
      if (plan.expiresAt <= this.now() || plan.bootNonce !== this.bootNonce) {
        this.plans.delete(args.planToken);
        throw new AutomationError('PLAN_INVALID', 'planToken 已過期或不屬於目前 server boot');
      }
      if (plan.sessionId !== context.sessionId || plan.transport !== context.transport) {
        throw new AutomationError('PLAN_INVALID', 'planToken 不屬於目前 session');
      }

      if (plan.action === 'tabChanges') {
        return this.executeTabChanges(args.planToken, plan);
      }

      let current;
      try {
        current = await this.bridge.call('snapshotMarkTabRead', {
          tabName: plan.args.tabName,
          expectedWindow: plan.expectedWindow,
        });
      } catch (error) {
        this.plans.delete(args.planToken);
        throw error;
      }
      if (
        typeof current.snapshotDigest !== 'string' ||
        current.snapshotDigest.length === 0 ||
        current.snapshotDigest.length > 256
      ) {
        this.plans.delete(args.planToken);
        throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'native helper 缺少有效 snapshotDigest');
      }
      if (current.snapshotDigest !== plan.snapshotDigest) {
        this.plans.delete(args.planToken);
        throw new AutomationError('SNAPSHOT_CHANGED', 'LINE 視窗或分頁結構已變更，請重新預覽');
      }

      // 重驗完成後、第一個不可逆事件前消耗 token；不論結果都不可重播。
      this.plans.delete(args.planToken);
      const operationId = crypto.randomUUID();
      await this.writeJournal({
        operationId,
        actionHash: digest({ action: plan.action, structureDigest: plan.structureDigest }),
        createdAt: new Date(this.now()).toISOString(),
      });
      try {
        const result = await this.bridge.call('executeMarkTabRead', {
          operationId,
          tabName: plan.args.tabName,
          expectedWindow: plan.expectedWindow,
          snapshotDigest: plan.snapshotDigest,
        });
        if (result.success !== true || result.readback?.allReadObserved !== true) {
          throw new AutomationError('READBACK_UNVERIFIED', 'native helper 未提供可驗證的提交回讀', {
            phase: 'post_commit',
          });
        }
        await this.clearJournal();
        return result;
      } catch (error) {
        if (error?.details?.phase === 'pre_commit') {
          try {
            await this.clearJournal();
          } catch {
            throw new AutomationError('OPERATION_UNCERTAIN', '清除全部已讀 journal 失敗，已停止後續異動', {
              operationId,
              needsRecovery: true,
              causeCode: 'JOURNAL_CLEAR_FAILED',
            });
          }
          throw error;
        }
        throw new AutomationError('OPERATION_UNCERTAIN', '全部已讀可能已提交，已停止後續異動', {
          operationId,
          needsRecovery: true,
          causeCode: error?.code || 'NATIVE_FAILURE',
        });
      }
    });
  }

  async executeTabChanges(planToken, plan) {
    let current;
    try {
      current = await this.bridge.call('snapshotTabChanges', {
        changes: plan.changes,
        expectedWindow: plan.expectedWindow,
        itemFingerprints: plan.itemFingerprints,
      });
    } catch (error) {
      this.plans.delete(planToken);
      throw error;
    }
    if (!isPlainObject(current) || Object.keys(current).some((key) => key !== 'snapshotDigest') ||
        !validDigest(current.snapshotDigest)) {
      this.plans.delete(planToken);
      throw new AutomationError('NATIVE_PROTOCOL_ERROR', 'native helper 缺少有效的分類 snapshotDigest');
    }
    if (current.snapshotDigest !== plan.snapshotDigest) {
      this.plans.delete(planToken);
      throw new AutomationError('SNAPSHOT_CHANGED', 'LINE 視窗或分類結構已變更，請重新預覽');
    }
    if (plan.expiresAt <= this.now() || plan.bootNonce !== this.bootNonce ||
        this.plans.get(planToken) !== plan) {
      this.plans.delete(planToken);
      throw new AutomationError('PLAN_INVALID', 'planToken 在提交前已過期或失效');
    }

    // 重驗完成後才消耗 token；batch 後續由同一把跨程序鎖保護。
    this.plans.delete(planToken);
    const operationId = crypto.randomUUID();
    const record = {
      schemaVersion: 2,
      operationId,
      planHash: keyedDigest(this.bootNonce, {
        changes: plan.changes,
        sessionId: plan.sessionId,
        snapshotDigest: plan.snapshotDigest,
        expectedWindow: plan.expectedWindow,
        itemFingerprints: plan.itemFingerprints,
      }),
      itemHashes: plan.changes.map((change, index) => keyedDigest(this.bootNonce, {
        index,
        change,
        itemFingerprint: plan.itemFingerprints[index],
      })),
      itemCount: plan.changes.length,
      currentIndex: 0,
      verifiedThrough: -1,
      phase: 'prepared',
    };
    const results = plan.changes.map((change, index) => ({
      index,
      change: cloneJson(change, 'change'),
      status: 'not_attempted',
    }));

    try {
      await this.createJournalV2(record);
    } catch (error) {
      return this.uncertainBatch(operationId, record, results, 0, error);
    }

    for (let index = 0; index < plan.changes.length; index += 1) {
      record.currentIndex = index;
      record.phase = 'committed_unverified';
      try {
        await this.checkpointJournalV2(record);
      } catch (error) {
        return this.uncertainBatch(operationId, record, results, index, error);
      }

      try {
        const result = await this.bridge.call('executeTabChange', {
          change: plan.changes[index],
          index,
          expectedWindow: plan.expectedWindow,
          itemFingerprint: plan.itemFingerprints[index],
        });
        if (!isPlainObject(result) || result.success !== true || !isPlainObject(result.readback) ||
            result.readback.verified !== true) {
          throw new AutomationError('READBACK_UNVERIFIED', 'native helper 未提供可驗證的分類異動回讀', {
            phase: 'post_commit',
          });
        }
        record.verifiedThrough = index;
        record.phase = 'verified';
        try {
          await this.checkpointJournalV2(record);
        } catch (error) {
          return this.uncertainBatch(operationId, record, results, index, error);
        }
        results[index].status = 'verified';
      } catch (error) {
        if (error?.details?.phase !== 'pre_commit') {
          return this.uncertainBatch(operationId, record, results, index, error);
        }
        results[index].status = 'failed_before_commit';
        record.phase = 'terminal_known_partial';
        try {
          await this.checkpointJournalV2(record);
          await this.clearJournalV2();
        } catch (checkpointError) {
          if (record.phase === 'terminal_known_partial') {
            await this.preserveUncertainJournal(record, index);
          }
          return this.uncertainBatch(operationId, record, results, index, checkpointError);
        }
        return { complete: false, operationId, results };
      }
    }

    try {
      await this.clearJournalV2();
    } catch (error) {
      await this.preserveUncertainJournal(record, results.length - 1);
      return this.uncertainBatch(operationId, record, results, results.length - 1, error);
    }
    return { complete: true, operationId, results };
  }

  uncertainBatch(operationId, record, results, index, error) {
    results[index].status = 'uncertain';
    for (let remaining = index + 1; remaining < results.length; remaining += 1) {
      results[remaining].status = 'not_attempted';
    }
    this.recoveryLatch = {
      ...record,
      operationId,
      currentIndex: index,
      verifiedThrough: Math.min(record.verifiedThrough, index - 1),
      phase: 'uncertain',
    };
    return {
      complete: false,
      operationId,
      needsRecovery: true,
      causeCode: error?.code || 'CHECKPOINT_FAILED',
      results,
    };
  }

  async preserveUncertainJournal(record, index) {
    const recovery = {
      ...record,
      currentIndex: index,
      verifiedThrough: Math.min(record.verifiedThrough, index - 1),
      phase: 'uncertain',
    };
    try {
      await this.fs.access(this.journalPath);
      await this.checkpointJournalV2(recovery);
    } catch (error) {
      if (error?.code !== 'ENOENT') return;
      await this.createJournalV2(recovery).catch(() => {});
    }
  }

  async legacySelectChat(chatName) {
    assertSafeName(chatName, 'chatName');
    return this.lock.withLock(() => this.bridge.call('selectChat', { chatName }));
  }

  async legacyHistory(chatName, date, messageLimit, pageUpTimes) {
    assertSafeName(chatName, 'chatName');
    const limit = optionalInteger(messageLimit, 'messageLimit', 1, 10_000, 100);
    const pages = optionalInteger(pageUpTimes, 'pageUpTimes', 0, 100, 10);
    const validatedDate = calendarDate(date, 'date');
    return this.lock.withLock(() =>
      this.bridge.call('getHistory', { chatName, date: validatedDate, limit, pageUpTimes: pages })
    );
  }

  async legacySend(chatName, message, autoSend, requestId) {
    assertSafeName(chatName, 'chatName');
    if (typeof message !== 'string' || message.length === 0 || message.length > 50_000) {
      throw new AutomationError('INVALID_ARGUMENT', 'message 必須是 1 到 50000 字元的字串');
    }
    if (requestId !== undefined) validateRequestId(requestId);
    const shouldSend = Boolean(autoSend);
    const actionHash = digest({ action: shouldSend ? 'legacySend' : 'legacyDraft', chatName,
      ...(requestId === undefined ? {} : { messageSha256: digest(message) }) });
    return this.lock.withLock(() => this.requests.run(requestId, actionHash, async ({ operationId, commit }) => {
      await this.assertNoPendingJournal();
      await this.writeJournal({
        operationId,
        actionHash,
        createdAt: new Date(this.now()).toISOString(),
      });
      try {
        const result = await this.bridge.call('sendMessage', { chatName, message, autoSend: shouldSend });
        // UI_SUBMITTED 只證明介面已提交，不能視為伺服器已確認送達。
        const receiptValid = shouldSend
          ? result.success === true &&
            result.autoSent === true &&
            result.receipt?.status === 'UI_SUBMITTED' &&
            result.receipt.deliveryConfirmed === false
          : result.success === true && result.autoSent === false;
        if (!receiptValid) {
          throw new AutomationError('SEND_UNVERIFIED', 'native helper 未提供可驗證的草稿／送出回執', {
            phase: 'post_commit',
          });
        }
        await commit(result);
        await this.clearJournal();
        return result;
      } catch (error) {
        if (error?.details?.phase === 'pre_commit') {
          try {
            await this.clearJournal();
          } catch {
            throw new AutomationError('OPERATION_UNCERTAIN', '清除送訊 journal 失敗，已停止後續異動', {
              operationId,
              needsRecovery: true,
              causeCode: 'JOURNAL_CLEAR_FAILED',
            });
          }
          throw error;
        }
        throw new AutomationError('OPERATION_UNCERTAIN', '訊息草稿或送出狀態不明，已停止後續異動', {
          operationId,
          needsRecovery: true,
          causeCode: error?.code || 'NATIVE_FAILURE',
        });
      }
    }));
  }

  async sendImage(args) {
    assertKnownKeys(args, ['chatName', 'imagePath', 'imageSha256', 'autoSend', 'requestId']);
    const chatName = assertSafeName(args.chatName, 'chatName');
    if (typeof args.imagePath !== 'string' || args.imagePath.length > 4096 ||
        !path.isAbsolute(args.imagePath) || /\p{Cc}/u.test(args.imagePath) ||
        typeof args.imageSha256 !== 'string' || !HEX_64.test(args.imageSha256) ||
        (args.autoSend !== undefined && typeof args.autoSend !== 'boolean')) {
      throw new AutomationError('INVALID_ARGUMENT', '圖片需要絕對路徑、SHA256 與 boolean autoSend');
    }
    const autoSend = args.autoSend ?? false;
    if (args.requestId !== undefined) validateRequestId(args.requestId);
    const actionHash = digest({ action: 'sendImage', chatName, imageSha256: args.imageSha256, autoSend });
    return this.lock.withLock(() => this.requests.run(args.requestId, actionHash, async ({ operationId, commit }) => {
      await this.assertNoPendingJournal();
      await this.writeJournal({ operationId,
        actionHash,
        createdAt: new Date(this.now()).toISOString() });
      try {
        const result = await this.bridge.call('sendImage', { chatName, imagePath: args.imagePath, imageSha256: args.imageSha256, autoSend });
        // 僅接受本次圖片、收件者與模式均核對的回條；選入圖片不等於已送出。
        if (result?.success !== true || result.autoSent !== autoSend ||
            result.sourceSha256 !== args.imageSha256 || !HEX_64.test(result.imageSha256 ?? '') ||
            result.chatVerified !== true || result.selectedFileVerified !== true ||
            result.receipt?.status !== (autoSend ? 'UI_SUBMITTED' : 'IMAGE_SELECTED_NOT_SENT') ||
            result.receipt.deliveryConfirmed !== false) {
          throw new AutomationError('SEND_UNVERIFIED', '圖片回條與本次請求不符');
        }
        await commit(result);
        await this.clearJournal();
        return result;
      } catch (error) {
        if (error?.details?.phase === 'pre_commit') {
          try { await this.clearJournal(); }
          catch {
            throw new AutomationError('OPERATION_UNCERTAIN', '圖片操作紀錄未能清除，已停止', {
              operationId, needsRecovery: true, causeCode: 'JOURNAL_CLEAR_FAILED' });
          }
          throw error;
        }
        throw new AutomationError('OPERATION_UNCERTAIN', '圖片選入或提交狀態不明，禁止自動重試', {
          operationId, needsRecovery: true, causeCode: error?.code || 'NATIVE_FAILURE' });
      }
    }));
  }

  async sendAttachments(args, kind) {
    return sendAttachmentBatch({ args, kind, bridge: this.bridge, lock: this.lock, records: this.requests,
      settle: this.attachmentSettle,
      journal: {
        assertEmpty: () => this.assertNoPendingJournal(),
        write: record => this.writeJournal(record),
        clear: () => this.clearJournal(),
      },
    });
  }

  async readImagePreviewRecoveryRecord(args) {
    const handle = await this.fs.open(this.journalPath, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
    try {
      const stat = await handle.stat();
      const uid = typeof process.getuid === 'function' ? process.getuid() : stat.uid;
      if (!stat.isFile() || stat.nlink !== 1 || stat.uid !== uid ||
          (stat.mode & 0o777) !== 0o600 || stat.size < 1 || stat.size > MAX_JOURNAL_BYTES) {
        throw new AutomationError('RECOVERY_RECORD_INVALID', '圖片預覽紀錄 owner、型態或大小不符');
      }
      const buffer = Buffer.alloc(stat.size + 1);
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
      if (bytesRead !== stat.size) throw new AutomationError('RECOVERY_RECORD_INVALID', '圖片紀錄讀取期間變更');
      const raw = buffer.subarray(0, bytesRead);
      let record;
      try { record = JSON.parse(raw.toString('utf8')); }
      catch { throw new AutomationError('RECOVERY_RECORD_INVALID', '圖片紀錄不是 JSON'); }
      // 僅恢復 autoSend:false 的確切操作；真正傳送、其他操作與未知格式一律拒絕。
      if (!isPlainObject(record) || Object.keys(record).sort().join(',') !== 'actionHash,createdAt,operationId' ||
          record.operationId !== args.operationId || !validIso8601(record.createdAt) ||
          record.actionHash !== digest({ action: 'sendImage', chatName: args.chatName,
            imageSha256: args.imageSha256, autoSend: false })) {
        throw new AutomationError('RECOVERY_RECORD_INVALID', '不是本次指定的不發送圖片預覽紀錄');
      }
      return { raw, record, rawSha256: crypto.createHash('sha256').update(raw).digest('hex') };
    } finally { await handle.close(); }
  }

  async recoverImagePreview(args, context) {
    validateContext(context);
    assertPlainObject(args);
    assertKnownKeys(args, ['operationId', 'chatName', 'imageSha256']);
    assertSafeName(args.chatName, 'chatName');
    if (!/^[a-f0-9-]{36}$/i.test(args.operationId ?? '') || !HEX_64.test(args.imageSha256 ?? '')) {
      throw new AutomationError('INVALID_ARGUMENT', '恢復需要確切 operationId、聊天室及圖片 SHA256');
    }
    return this.lock.withLock(async () => {
      if (this.recoveryLatch || this.exportReader?.recoveryLatch) {
        throw new AutomationError('NEEDS_RECOVERY', '另有未確認操作，不恢復圖片預覽');
      }
      const owned = await this.readImagePreviewRecoveryRecord(args);
      const observe = async () => {
        const status = await this.bridge.call('status');
        if (status.running !== true || status.accessibilityTrusted !== true || status.usable !== true) {
          throw new AutomationError('NEEDS_RECOVERY', '未證明 LINE 主視窗正常且沒有殘留 modal');
        }
        validateWindowIdentity(status.mainWindow);
        const window = status.mainWindow;
        if (window.executableURL !== '/Applications/LINE.app/Contents/MacOS/LINE' ||
            window.signingIdentifier !== 'jp.naver.line.mac' || window.teamIdentifier !== 'VUTU7AKEUR') {
          throw new AutomationError('NEEDS_RECOVERY', '圖片恢復的 LINE 主視窗身分不符');
        }
        return window;
      };
      const before = await observe();
      await this.archiveOwnedNavigation(owned.raw, owned.rawSha256);
      const after = await observe();
      const current = await this.readImagePreviewRecoveryRecord(args);
      if (!sameWindowIdentity(before, after) || current.rawSha256 !== owned.rawSha256) {
        throw new AutomationError('NEEDS_RECOVERY', '恢復期間視窗或圖片紀錄漂移，保留 pending');
      }
      try {
        await this.clearJournal();
        const directory = await this.fs.open(path.dirname(this.journalPath), 'r');
        try { await directory.sync(); } finally { await directory.close(); }
      } catch {
        this.recoveryLatch = owned.record;
        // 清除耐久性無法確認時盡可能補回原紀錄，不能把此狀態當成已恢復。
        try {
          const handle = await this.fs.open(this.journalPath, 'wx', 0o600);
          try { await handle.writeFile(owned.raw); await handle.sync(); } finally { await handle.close(); }
        } catch {}
        throw new AutomationError('OPERATION_UNCERTAIN', '圖片恢復結案寫入不明，停止後續操作', {
          operationId: args.operationId, needsRecovery: true });
      }
      return { recovered: true, archived: true, inputAttempted: false, sendAttempted: false };
    });
  }

  async readOwnedGlobalNavigationRecord(expectedOperationId = null) {
    const stat = await (typeof this.fs.lstat === 'function'
      ? this.fs.lstat(this.journalPath)
      : this.fs.stat(this.journalPath));
    const uid = typeof process.getuid === 'function' ? process.getuid() : stat.uid;
    if (!stat.isFile?.() || stat.isSymbolicLink?.() || stat.uid !== uid ||
        (stat.mode & 0o777) !== 0o600 || stat.size <= 0 || stat.size > MAX_JOURNAL_BYTES) {
      throw new AutomationError('RECOVERY_RECORD_INVALID', 'pending journal owner、mode 或檔案型態不正確');
    }
    const raw = await this.fs.readFile(this.journalPath);
    let record;
    try { record = JSON.parse(raw.toString('utf8')); }
    catch { throw new AutomationError('RECOVERY_RECORD_INVALID', 'pending journal 不是有效 JSON'); }
    const operationId = expectedOperationId || record?.operationId;
    return {
      record: validateOwnedNavigationRecord(record, operationId),
      operationId,
      raw,
      rawSha256: crypto.createHash('sha256').update(raw).digest('hex'),
    };
  }

  recoverySummary(owned, mode) {
    const summary = {
      mode,
      eligible: true,
      route: owned.record.navigation.route,
      phase: owned.record.phase,
      inputAttempted: false,
    };
    Object.defineProperty(summary, 'expectedOperationId', {
      value: owned.operationId,
      enumerable: false,
    });
    return summary;
  }

  async previewGlobalAllNavigationRecovery(args, context) {
    validateContext(context);
    assertPlainObject(args);
    assertKnownKeys(args, ['chatName']);
    assertSafeName(args.chatName, 'chatName');
    return this.lock.withLock(async () =>
      this.recoverySummary(await this.readOwnedGlobalNavigationRecord(), 'preview'));
  }

  async archiveOwnedNavigation(raw, rawSha256) {
    await this.fs.mkdir(this.recoveryEvidenceDirectory, { recursive: true, mode: 0o700 });
    const uid = typeof process.getuid === 'function' ? process.getuid() : 0;
    const directoryStat = await this.fs.lstat(this.recoveryEvidenceDirectory);
    if (!directoryStat.isDirectory?.() || directoryStat.isSymbolicLink?.() ||
        directoryStat.uid !== uid || (directoryStat.mode & 0o777) !== 0o700) {
      throw new AutomationError('RECOVERY_ARCHIVE_INVALID', 'recovery-evidence 目錄不安全');
    }
    const archivePath = path.join(this.recoveryEvidenceDirectory, `${rawSha256}.json`);
    let handle;
    try {
      handle = await this.fs.open(archivePath, 'wx', 0o600);
    } catch (error) {
      if (error?.code !== 'EEXIST') throw error;
      const existingStat = await this.fs.lstat(archivePath);
      const existing = await this.fs.readFile(archivePath);
      if (!existingStat.isFile?.() || existingStat.isSymbolicLink?.() ||
          existingStat.uid !== uid || (existingStat.mode & 0o777) !== 0o600 ||
          !existing.equals(raw)) {
        throw new AutomationError('RECOVERY_ARCHIVE_INVALID', '既有 recovery evidence 不屬於本次 raw journal');
      }
      const existingDirectory = await this.fs.open(this.recoveryEvidenceDirectory, 'r');
      try { await existingDirectory.sync(); } finally { await existingDirectory.close(); }
      return;
    }
    try {
      await handle.writeFile(raw);
      await handle.sync();
    } finally {
      await handle.close();
    }
    const directory = await this.fs.open(this.recoveryEvidenceDirectory, 'r');
    try { await directory.sync(); } finally { await directory.close(); }
  }

  sameRecoveryWindowOwner(left, right) {
    return left.pid === right.pid && left.windowId === right.windowId &&
      left.executableURL === right.executableURL &&
      left.signingIdentifier === right.signingIdentifier &&
      left.teamIdentifier === right.teamIdentifier;
  }

  async reconcileOwnedNavigation(owned, chatName) {
    const record = owned.record;
    if (record.recoveryAttempt) {
      const currentSourceDigest = typeof this.bridge.journalSourceDigest === 'function'
        ? await this.bridge.journalSourceDigest()
        : (await this.bridge.selectedSourceDigest?.())?.sourceDigest;
      if (currentSourceDigest !== record.recoveryAttempt.sourceDigest) {
        this.recoveryLatch = record;
        throw new AutomationError('OPERATION_UNCERTAIN', '被動 reconcile source digest 不一致', {
          needsRecovery: true,
        });
      }
    }
    const expectedWindow = record.recoveryAttempt?.expectedWindow || record.navigation.expectedWindow;
    const requestNonce = record.recoveryAttempt?.requestNonce || record.navigation.requestNonce;
    const request = { chatName, requestNonce, expectedWindow };
    let receipt;
    try {
      receipt = validateGlobalNavigationReceipt(
        await this.bridge.call('observeGlobalAll', request), request, true
      );
    } catch (error) {
      this.recoveryLatch = record;
      throw new AutomationError('OPERATION_UNCERTAIN', '被動 All reconcile 未取得正面證明', {
        needsRecovery: true,
        causeCode: error?.code || 'NATIVE_FAILURE',
      });
    }
    if (receipt.systemEventsInvocations !== 0 || receipt.inputAttempted !== false) {
      this.recoveryLatch = record;
      throw new AutomationError('OPERATION_UNCERTAIN', '被動 All reconcile receipt 含有輸入', {
        needsRecovery: true,
      });
    }
    const unchanged = await this.readOwnedGlobalNavigationRecord(record.operationId);
    if (unchanged.rawSha256 !== owned.rawSha256) {
      this.recoveryLatch = record;
      throw new AutomationError('OPERATION_UNCERTAIN', '被動 reconcile 期間 journal 發生漂移', {
        needsRecovery: true,
      });
    }
    const verified = {
      ...record,
      phase: 'verified',
      verifiedThrough: 0,
      recoveredCurrentView: true,
      reconciledCurrentView: {
        version: 1,
        route: 'line-hid-all-v1',
        requestNonce,
        expectedWindow,
        phase: 'verified',
        systemEventsInvocations: 0,
        eventCounts: { move: 0, down: 0, up: 0 },
      },
    };
    await this.checkpointJournalV2(verified);
    try {
      await this.clearJournalV2();
    } catch (error) {
      this.recoveryLatch = verified;
      await this.createJournalV2(verified).catch(() => {});
      throw new AutomationError('OPERATION_UNCERTAIN', '被動 All reconcile 已驗證但 journal 未安全清除', {
        needsRecovery: true,
        causeCode: error?.code || 'JOURNAL_FAILURE',
      });
    }
    this.recoveryLatch = null;
    return {
      mode: 'reconciled', complete: true, recoveredCurrentView: true,
      inputAttempted: false, systemEventsInvocations: 0, allSelected: true,
    };
  }

  async recoverGlobalAllNavigation(args, context, { run = false } = {}) {
    validateContext(context);
    assertPlainObject(args);
    assertKnownKeys(args, ['chatName', 'expectedOperationId']);
    const chatName = assertSafeName(args.chatName, 'chatName');
    if (typeof args.expectedOperationId !== 'string' ||
        !args.expectedOperationId.startsWith(GLOBAL_ALL_OPERATION_PREFIX)) {
      throw new AutomationError('INVALID_ARGUMENT', 'expectedOperationId 格式不正確');
    }
    if (typeof run !== 'boolean') throw new AutomationError('INVALID_ARGUMENT', 'run 必須是 boolean');
    return this.lock.withLock(async () => {
      const owned = await this.readOwnedGlobalNavigationRecord(args.expectedOperationId);
      if (!run) return this.recoverySummary(owned, 'preview');
      const record = owned.record;
      if (['line-system-events-all-v1', 'line-hid-all-v1'].includes(record.navigation.route) ||
          record.recoveryAttempt) {
        return this.reconcileOwnedNavigation(owned, chatName);
      }

      const plannedSourceDigest = typeof this.bridge.journalSourceDigest === 'function'
        ? await this.bridge.journalSourceDigest()
        : (await this.bridge.selectedSourceDigest?.())?.sourceDigest;
      if (!HEX_64.test(plannedSourceDigest)) {
        throw new AutomationError('RECOVERY_SOURCE_UNAVAILABLE', 'HID recovery source digest 無法在輸入前固定');
      }
      await this.archiveOwnedNavigation(owned.raw, owned.rawSha256);
      const requestNonce = this.randomBytes(32).toString('hex');
      if (!HEX_64.test(requestNonce)) throw new AutomationError('TOKEN_GENERATION_FAILED', 'recovery nonce 無效');
      let attempted = {
        ...record,
        recoveryAttempt: {
          version: 1,
          attempt: 1,
          route: 'line-hid-all-v1',
          requestNonce,
          sourceDigest: plannedSourceDigest,
          phase: 'prepared',
          expectedWindow: null,
          systemEventsInvocations: 0,
          eventCounts: { move: 0, down: 0, up: 0 },
        },
      };
      await this.checkpointJournalV2(attempted);
      const activation = await this.bridge.call('activateLine');
      if (activation?.success !== true) {
        this.recoveryLatch = attempted;
        throw new AutomationError('OPERATION_UNCERTAIN', 'LINE focus recovery 未完成', { needsRecovery: true });
      }
      const expectedWindow = validateGlobalNavigationStatus(await this.bridge.call('status'));
      if (!this.sameRecoveryWindowOwner(record.navigation.expectedWindow, expectedWindow)) {
        this.recoveryLatch = attempted;
        throw new AutomationError('OPERATION_UNCERTAIN', 'LINE recovery window owner 已漂移', { needsRecovery: true });
      }
      const selected = typeof this.bridge.selectedSourceDigest === 'function'
        ? await this.bridge.selectedSourceDigest()
        : null;
      if (selected?.sourceDigestVerified !== true || !HEX_64.test(selected.sourceDigest)) {
        this.recoveryLatch = attempted;
        throw new AutomationError('OPERATION_UNCERTAIN', 'HID recovery source digest 未驗證', { needsRecovery: true });
      }
      if (selected.sourceDigest !== plannedSourceDigest) {
        this.recoveryLatch = attempted;
        throw new AutomationError('OPERATION_UNCERTAIN', 'HID recovery source 在 focus 後漂移', {
          needsRecovery: true,
        });
      }
      attempted = {
        ...attempted,
        recoveryAttempt: {
          ...attempted.recoveryAttempt,
          sourceDigest: selected.sourceDigest,
          expectedWindow,
        },
      };
      await this.checkpointJournalV2(attempted);
      const checkpoint = await this.readOwnedGlobalNavigationRecord(record.operationId);
      const request = { chatName, requestNonce, expectedWindow };
      let receipt;
      try {
        receipt = validateGlobalNavigationReceipt(
          await this.bridge.call('selectGlobalAll', request), request, true
        );
      } catch (error) {
        const pending = {
          ...attempted,
          recoveryAttempt: {
            ...attempted.recoveryAttempt,
            phase: 'uncertain',
            systemEventsInvocations: 0,
            eventCounts: { move: null, down: null, up: null },
          },
        };
        this.recoveryLatch = pending;
        await this.checkpointJournalV2(pending).catch(() => {});
        throw new AutomationError('OPERATION_UNCERTAIN', 'HID owner-bound recovery 結果不明', {
          needsRecovery: true,
          causeCode: error?.code || 'NATIVE_FAILURE',
        });
      }
      const unchanged = await this.readOwnedGlobalNavigationRecord(record.operationId);
      if (unchanged.rawSha256 !== checkpoint.rawSha256) {
        this.recoveryLatch = attempted;
        throw new AutomationError('OPERATION_UNCERTAIN', 'recovery journal 在 selector 期間發生漂移', {
          needsRecovery: true,
        });
      }
      const verified = {
        ...attempted,
        phase: 'verified',
        verifiedThrough: 0,
        recoveredCurrentView: true,
        recoveryAttempt: {
          ...attempted.recoveryAttempt,
          phase: 'verified',
          systemEventsInvocations: receipt.systemEventsInvocations,
          eventCounts: receipt.eventCounts,
        },
      };
      await this.checkpointJournalV2(verified);
      try {
        await this.clearJournalV2();
      } catch (error) {
        this.recoveryLatch = verified;
        await this.createJournalV2(verified).catch(() => {});
        throw new AutomationError('OPERATION_UNCERTAIN', 'owner-bound recovery 已驗證但 journal 未安全清除', {
          needsRecovery: true,
          causeCode: error?.code || 'JOURNAL_FAILURE',
        });
      }
      this.recoveryLatch = null;
      return {
        mode: 'recovered', complete: true, recoveredCurrentView: true,
        inputAttempted: receipt.inputAttempted,
        systemEventsInvocations: receipt.systemEventsInvocations, allSelected: true,
      };
    });
  }

  async isLineRunning() {
    const result = await this.bridge.call('processStatus');
    return result.running === true;
  }

  async activateLine() {
    return this.lock.withLock(() => this.bridge.call('activateLine'));
  }

  async hasAccessibilityPermission() {
    const result = await this.bridge.call('accessibilityStatus');
    return result.trusted === true;
  }

  storeCursor(cursor) {
    const token = this.uniqueToken(this.cursors, 24);
    const stored = deepFreeze(cloneJson({
      ...cursor,
      bootNonce: this.bootNonce,
      expiresAt: this.now() + TOKEN_TTL_MS,
    }, 'cursor'));
    this.storeBounded(this.cursors, token, stored);
    return token;
  }

  storeBounded(store, key, value) {
    while (store.size >= MAX_STORED_TOKENS) store.delete(store.keys().next().value);
    store.set(key, value);
  }

  uniqueToken(store, length) {
    for (let attempt = 0; attempt < 10; attempt += 1) {
      const token = this.randomBytes(length).toString('base64url');
      if (!store.has(token)) return token;
    }
    throw new AutomationError('TOKEN_GENERATION_FAILED', '無法產生唯一的一次性 token');
  }

  pruneStores() {
    for (const store of [this.plans, this.cursors]) {
      for (const [key, value] of store) {
        if (value.expiresAt <= this.now()) store.delete(key);
      }
    }
  }

  async hasPendingJournal() {
    if (this.recoveryLatch || this.exportReader?.recoveryLatch) return true;
    try {
      await this.fs.access(this.journalPath);
      return true;
    } catch (error) {
      if (error?.code === 'ENOENT') return false;
      throw error;
    }
  }

  async assertNoPendingJournal() {
    if (await this.hasPendingJournal()) {
      throw new AutomationError('NEEDS_RECOVERY', '偵測到未完成的桌面異動，人工確認前禁止後續異動', {
        needsRecovery: true,
      });
    }
  }

  async recoveryStatus() {
    let record = this.recoveryLatch;
    if (!record && this.exportReader?.recoveryLatch) {
      // 匯出不明狀態不含明文 journal；仍須阻擋所有後續 UI 異動等待人工確認。
      return { state: 'pending', valid: false };
    }
    if (!record) {
      try {
        const stat = await this.fs.stat(this.journalPath);
        if (stat.size > MAX_JOURNAL_BYTES) return { state: 'pending', valid: false };
        record = JSON.parse(await this.fs.readFile(this.journalPath, 'utf8'));
      } catch (error) {
        if (error?.code === 'ENOENT') return null;
        return { state: 'pending', valid: false };
      }
    }
    if (!this.validJournalV2(record)) return { state: 'pending', valid: false };
    const verifiedPrefix = record.verifiedThrough + 1;
    const uncertainCurrent = record.phase === 'verified' ? null : record.currentIndex;
    return {
      state: 'pending',
      valid: true,
      operationId: record.operationId,
      verifiedPrefix,
      uncertainCurrent,
      notAttemptedSuffix: record.itemCount - verifiedPrefix - (uncertainCurrent === null ? 0 : 1),
    };
  }

  validJournalV2(record) {
    const shapeValid = isPlainObject(record) && record.schemaVersion === 2 &&
      typeof record.operationId === 'string' && record.operationId.length > 0 && record.operationId.length <= 200 &&
      typeof record.planHash === 'string' && /^[a-f0-9]{64}$/.test(record.planHash) &&
      Array.isArray(record.itemHashes) && record.itemHashes.length === record.itemCount &&
      record.itemHashes.every((value) => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value)) &&
      Number.isInteger(record.itemCount) && record.itemCount >= 1 && record.itemCount <= 20 &&
      Number.isInteger(record.currentIndex) && record.currentIndex >= 0 && record.currentIndex < record.itemCount &&
      Number.isInteger(record.verifiedThrough) && record.verifiedThrough >= -1 &&
      record.verifiedThrough < record.itemCount &&
      ['prepared', 'committed_unverified', 'verified', 'terminal_known_partial', 'uncertain'].includes(record.phase);
    if (!shapeValid || record.verifiedThrough > record.currentIndex) return false;
    if (record.phase === 'prepared') return record.currentIndex === 0 && record.verifiedThrough === -1;
    if (record.phase === 'verified') return record.verifiedThrough === record.currentIndex;
    return record.verifiedThrough === record.currentIndex - 1;
  }

  async writeJournal(record) {
    await this.fs.mkdir(path.dirname(this.journalPath), { recursive: true, mode: 0o700 });
    const handle = await this.fs.open(this.journalPath, 'wx', 0o600);
    try {
      await handle.writeFile(JSON.stringify(record));
      await handle.sync();
    } finally {
      await handle.close();
    }
  }

  async clearJournal() {
    await this.fs.rm(this.journalPath, { force: true });
  }

  async createJournalV2(record) {
    await this.fs.mkdir(path.dirname(this.journalPath), { recursive: true, mode: 0o700 });
    const handle = await this.fs.open(this.journalPath, 'wx', 0o600);
    try {
      await handle.writeFile(JSON.stringify(record));
      await handle.sync();
    } finally {
      await handle.close();
    }
    await this.syncJournalDirectory();
  }

  async checkpointJournalV2(record) {
    const temporaryPath = `${this.journalPath}.${this.randomBytes(12).toString('hex')}.tmp`;
    let handle;
    try {
      handle = await this.fs.open(temporaryPath, 'wx', 0o600);
      await handle.writeFile(JSON.stringify(record));
      await handle.sync();
      await handle.close();
      handle = null;
      await this.fs.rename(temporaryPath, this.journalPath);
      await this.fs.chmod(this.journalPath, 0o600);
      await this.syncJournalDirectory();
    } catch (error) {
      if (handle) await handle.close().catch(() => {});
      await this.fs.rm(temporaryPath, { force: true }).catch(() => {});
      throw error;
    }
  }

  async clearJournalV2() {
    await this.fs.unlink(this.journalPath);
    await this.syncJournalDirectory();
  }

  async syncJournalDirectory() {
    const directory = await this.fs.open(path.dirname(this.journalPath), 'r');
    try {
      await directory.sync();
    } finally {
      await directory.close();
    }
  }
}
