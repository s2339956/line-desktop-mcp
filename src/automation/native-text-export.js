import crypto from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { TextDecoder } from 'node:util';
import { AutomationError, assertSafeName } from './automation-error.js';

const HEX_32 = /^[a-f0-9]{32}$/;
const HEX_64 = /^[a-f0-9]{64}$/;
const MAX_RAW_BYTES = 8 * 1024 * 1024;
const MAX_CACHE_BYTES = 16 * 1024 * 1024;
const MAX_SNAPSHOTS = 8;
const SNAPSHOT_TTL_MS = 5 * 60_000;
const MAX_CHUNK_UTF16 = 4096;
const MAX_PAGE_UTF16 = 50_000;
const EXPORT_REASONS = Object.freeze([
  'NATIVE_EXPORT_VISIBLE_ONLY',
  'EXPORT_MESSAGE_BOUNDARIES_UNVERIFIED',
  'UNKNOWN_DATE',
]);

function stable(value) {
  if (Array.isArray(value)) return value.map(stable);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, stable(value[key])]));
  }
  return value;
}

function hmac(key, value) {
  // 跨語言 producer 必須使用 sorted-key JSON、UTF-8 hex key，且不可額外跳脫斜線。
  return crypto.createHmac('sha256', key).update(JSON.stringify(stable(value))).digest('hex');
}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function fail(code, message, details = {}) {
  throw new AutomationError(code, message, details);
}

function exactKeys(value, keys, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      Object.keys(value).sort().join('\0') !== [...keys].sort().join('\0')) {
    fail('NATIVE_PROTOCOL_ERROR', `${label} 格式不正確`);
  }
}

function validateWindow(value) {
  exactKeys(value, [
    'pid', 'windowId', 'title', 'bounds', 'bundleIdentifier', 'executableURL',
    'signingIdentifier', 'teamIdentifier',
  ], 'export proof window');
  exactKeys(value.bounds, ['x', 'y', 'width', 'height'], 'export proof bounds');
  if (!Number.isInteger(value.pid) || value.pid <= 0 ||
      !Number.isInteger(value.windowId) || value.windowId <= 0 ||
      value.title !== 'LINE' || value.bundleIdentifier !== 'jp.naver.line.mac' ||
      value.executableURL !== '/Applications/LINE.app/Contents/MacOS/LINE' ||
      !['x', 'y', 'width', 'height'].every((key) => Number.isFinite(value.bounds[key])) ||
      value.bounds.width < 320 || value.bounds.height < 240 ||
      typeof value.signingIdentifier !== 'string' || typeof value.teamIdentifier !== 'string') {
    fail('NATIVE_PROTOCOL_ERROR', 'export proof window 身分不正確');
  }
}

function proofPayload(proof) {
  const { proofDigest: _proofDigest, ...payload } = proof;
  return payload;
}

export function textExportProofDigest(identityKey, proof) {
  if (!HEX_64.test(identityKey)) fail('INVALID_ARGUMENT', 'identityKey 格式不正確');
  return hmac(identityKey, { purpose: 'line-text-export-scope-v1', ...proofPayload(proof) });
}

export function validateTextExportProof(proof, expected, identityKey, label = 'text export proof') {
  exactKeys(proof, [
    'scope', 'window', 'headerDigest', 'memberMatchCount', 'selectedMatchCount',
    'headerMatchCount', 'selectedTabVerified', 'requestNonce', 'proofDigest',
  ], label);
  exactKeys(proof.scope, ['tabName', 'chatName', 'verified'], `${label}.scope`);
  validateWindow(proof.window);
  if (proof.scope.tabName !== expected.tabName || proof.scope.chatName !== expected.chatName ||
      proof.scope.verified !== true || proof.requestNonce !== expected.requestNonce ||
      !HEX_32.test(proof.requestNonce) || !HEX_64.test(proof.headerDigest) ||
      !HEX_64.test(proof.proofDigest) || proof.memberMatchCount !== 1 ||
      proof.selectedMatchCount !== 1 || proof.headerMatchCount !== 1 ||
      proof.selectedTabVerified !== true ||
      !crypto.timingSafeEqual(
        Buffer.from(proof.proofDigest, 'hex'),
        Buffer.from(textExportProofDigest(identityKey, proof), 'hex')
      )) {
    fail('NATIVE_PROTOCOL_ERROR', `${label} 未證明 exact scope`);
  }
  return proof;
}

function sameProof(pre, post) {
  return pre.scope.tabName === post.scope.tabName &&
    pre.scope.chatName === post.scope.chatName &&
    pre.window.pid === post.window.pid && pre.window.windowId === post.window.windowId &&
    JSON.stringify(pre.window.bounds) === JSON.stringify(post.window.bounds) &&
    pre.window.executableURL === post.window.executableURL &&
    pre.window.bundleIdentifier === post.window.bundleIdentifier &&
    pre.window.signingIdentifier === post.window.signingIdentifier &&
    pre.window.teamIdentifier === post.window.teamIdentifier &&
    pre.headerDigest === post.headerDigest &&
    pre.requestNonce === post.requestNonce &&
    pre.memberMatchCount === post.memberMatchCount &&
    pre.selectedMatchCount === post.selectedMatchCount &&
    pre.headerMatchCount === post.headerMatchCount &&
    pre.selectedTabVerified === post.selectedTabVerified;
}

export function validateTextExportReceipt(receipt, expected, identityKey) {
  exactKeys(receipt, [
    'scope', 'observedAt', 'source', 'uiRestored', 'completionVerified',
    'preActionProof', 'postActionProof',
  ], 'text export receipt');
  exactKeys(receipt.scope, ['tabName', 'chatName', 'verified'], 'text export receipt.scope');
  if (receipt.scope.tabName !== expected.tabName || receipt.scope.chatName !== expected.chatName ||
      receipt.scope.verified !== true || receipt.source !== 'NATIVE_TEXT_EXPORT' ||
      receipt.uiRestored !== true || receipt.completionVerified !== true ||
      typeof receipt.observedAt !== 'string' || !Number.isFinite(Date.parse(receipt.observedAt))) {
    fail('NATIVE_PROTOCOL_ERROR', 'text export receipt 未證明完成或 exact scope');
  }
  const pre = validateTextExportProof(receipt.preActionProof, expected, identityKey, 'preActionProof');
  const post = validateTextExportProof(receipt.postActionProof, expected, identityKey, 'postActionProof');
  if (!sameProof(pre, post)) fail('NATIVE_PROTOCOL_ERROR', 'text export 前後 scope proof 漂移');
  return receipt;
}

function sameStat(a, b) {
  return a.dev === b.dev && a.ino === b.ino && a.size === b.size &&
    a.mtimeNs === b.mtimeNs && a.ctimeNs === b.ctimeNs && a.mode === b.mode &&
    a.nlink === b.nlink && a.uid === b.uid;
}

function validateFileStat(stat, uid) {
  const type = Number(stat.mode & 0o170000n);
  return type === 0o100000 && stat.uid === BigInt(uid) && stat.nlink === 1n &&
    stat.size >= 0n && stat.size <= BigInt(MAX_RAW_BYTES);
}

function knownOwnFileStat(stat, uid) {
  return Number(stat.mode & 0o170000n) === 0o100000 && stat.uid === BigInt(uid) &&
    stat.nlink === 1n;
}

function validateDirectoryStat(stat, uid) {
  return Number(stat.mode & 0o170000n) === 0o040000 && stat.uid === BigInt(uid) &&
    (stat.mode & 0o0777n) === 0o0700n && stat.nlink >= 1n;
}

function decodeExport(bytes) {
  let encoding;
  let body = bytes;
  if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    encoding = 'utf-8-bom'; body = bytes.subarray(3);
  } else if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) {
    encoding = 'utf-16le'; body = bytes.subarray(2);
  } else if (bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff) {
    encoding = 'utf-16be'; body = bytes.subarray(2);
  } else {
    encoding = 'utf-8';
  }
  if (body.includes(0) && encoding.startsWith('utf-8')) fail('EXPORT_ENCODING_UNSUPPORTED', '匯出文字含 NUL');
  let text;
  try {
    text = new TextDecoder(encoding.replace('-bom', ''), { fatal: true }).decode(body);
  } catch {
    fail('EXPORT_ENCODING_UNSUPPORTED', '匯出文字編碼無法無損解析');
  }
  if (text.includes('\0')) fail('EXPORT_ENCODING_UNSUPPORTED', '匯出文字含 NUL');
  return { text, encoding };
}

function chunksOf(text) {
  const chunks = [];
  let value = '', start = 0, codePoint = 0, chunkStart = 0;
  for (const character of text) {
    if (value.length + character.length > MAX_CHUNK_UTF16 && value) {
      chunks.push({ text: value, codePointStart: chunkStart, codePointEnd: codePoint });
      value = ''; chunkStart = codePoint;
    }
    value += character; codePoint += 1;
  }
  if (value) chunks.push({ text: value, codePointStart: chunkStart, codePointEnd: codePoint });
  return chunks;
}

function validateState(state) {
  exactKeys(state, ['snapshotId', 'snapshotDigest', 'offset'], 'exportState');
  if (!HEX_64.test(state.snapshotId) || !HEX_64.test(state.snapshotDigest) ||
      !Number.isInteger(state.offset) || state.offset < 0) {
    fail('CURSOR_INVALID', 'exportState 格式或位置不正確');
  }
  return state;
}

export class NativeTextExportReader {
  constructor({
    capture,
    now = () => Date.now(),
    randomBytes = crypto.randomBytes,
    fileSystem = fs,
    tempRoot = os.tmpdir(),
    quietIntervalMs = 250,
    wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  } = {}) {
    if (typeof capture !== 'function') throw new TypeError('capture 必須是函式');
    this.capture = capture;
    this.now = now;
    this.randomBytes = randomBytes;
    this.fs = fileSystem;
    this.tempRoot = tempRoot;
    this.quietIntervalMs = quietIntervalMs;
    this.wait = wait;
    this.snapshots = new Map();
    this.cacheBytes = 0;
    this.recoveryLatch = null;
  }

  async readPage({ tabName, chatName, identityKey, limit, state = null }) {
    assertSafeName(tabName, 'tabName'); assertSafeName(chatName, 'chatName');
    if (!HEX_64.test(identityKey) || !Number.isInteger(limit) || limit < 1 || limit > 100) {
      fail('INVALID_ARGUMENT', 'text export 參數格式不正確');
    }
    this.prune();
    if (state !== null) return this.pageFromSnapshot(validateState(state), { tabName, chatName, identityKey, limit });
    if (this.recoveryLatch) fail('NEEDS_RECOVERY', '原生文字匯出有未確認結果', { needsRecovery: true });
    // 先預留 UTF-16 轉 UTF-8 的最壞容量，避免 UI capture 後才發現無法收納。
    if (this.snapshots.size >= MAX_SNAPSHOTS || this.cacheBytes + 12 * 1024 * 1024 > MAX_CACHE_BYTES) {
      fail('EXPORT_CACHE_FULL', '原生文字快取已滿');
    }
    return this.captureAndRead({ tabName, chatName, identityKey, limit });
  }

  async captureAndRead(request) {
    const directory = await this.fs.mkdtemp(path.join(this.tempRoot, 'line-text-export-'));
    await this.fs.chmod(directory, 0o700);
    const directoryStat = await this.fs.lstat(directory, { bigint: true });
    if (!validateDirectoryStat(directoryStat, process.getuid())) {
      fail('EXPORT_DIRECTORY_UNSAFE', '匯出暫存目錄型別或權限不安全');
    }
    const outputFileName = `${this.randomBytes(16).toString('hex')}.txt`;
    const expectedPath = path.join(directory, outputFileName);
    const requestNonce = this.randomBytes(16).toString('hex');
    let receipt;
    try {
      receipt = await this.capture({
        tabName: request.tabName, chatName: request.chatName, identityKey: request.identityKey,
        requestNonce, outputDirectory: directory, outputFileName,
      });
    } catch (error) {
      const clean = await this.cleanup(directory, expectedPath, directoryStat, null);
      if (error?.code === 'AX_EXPORT_CALIBRATION_REQUIRED' &&
          error?.details?.sideEffectsAttempted === false && clean) return null;
      if (error?.code === 'AX_EXPORT_CALIBRATION_REQUIRED' &&
          error?.details?.sideEffectsAttempted === false && !clean) {
        this.recoveryLatch = { needsRecovery: true };
        fail('OPERATION_UNCERTAIN', '原生匯出宣稱未動作但留下未知檔案狀態', {
          needsRecovery: true, causeCode: 'PREACTION_SIDE_EFFECT_CONTRADICTION',
        });
      }
      if (error?.details?.sideEffectsAttempted !== false) this.recoveryLatch = { needsRecovery: true };
      throw error;
    }
    const evidence = { fileStat: null, snapshotId: null };
    try {
      validateTextExportReceipt(receipt, { ...request, requestNonce }, request.identityKey);
      const snapshot = await this.readStableFile(
        directory, expectedPath, directoryStat, request, receipt, evidence
      );
      if (!await this.cleanup(directory, expectedPath, directoryStat, evidence.fileStat)) {
        fail('EXPORT_CLEANUP_UNCERTAIN', '原生匯出暫存檔清理狀態不明');
      }
      if (this.snapshots.has(snapshot.id)) fail('TOKEN_GENERATION_FAILED', 'export snapshot ID 重複');
      this.snapshots.set(snapshot.id, snapshot);
      this.cacheBytes += snapshot.bytes;
      evidence.snapshotId = snapshot.id;
      return this.pageFromSnapshot({
        snapshotId: snapshot.id, snapshotDigest: snapshot.digest, offset: 0,
      }, request);
    } catch (error) {
      if (evidence.snapshotId) this.release(evidence.snapshotId);
      const deterministic = ['EXPORT_ENCODING_UNSUPPORTED', 'EXPORT_FILE_UNSAFE', 'EXPORT_CACHE_FULL']
        .includes(error?.code);
      let clean = false;
      if (deterministic && evidence.fileStat) {
        clean = await this.cleanup(directory, expectedPath, directoryStat, evidence.fileStat);
      }
      if (!deterministic || !clean) this.recoveryLatch = { needsRecovery: true };
      throw error;
    }
  }

  async readStableFile(directory, expectedPath, directoryStat, request, receipt, evidence) {
    const flags = fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW | fsConstants.O_NONBLOCK;
    let handle;
    try {
      const beforeOpenDirectory = await this.fs.lstat(directory, { bigint: true });
      if (!validateDirectoryStat(beforeOpenDirectory, process.getuid()) ||
          directoryStat.dev !== beforeOpenDirectory.dev || directoryStat.ino !== beforeOpenDirectory.ino ||
          directoryStat.uid !== beforeOpenDirectory.uid || directoryStat.mode !== beforeOpenDirectory.mode) {
        fail('EXPORT_DIRECTORY_REPLACED', '匯出暫存目錄已被替換');
      }
      handle = await this.fs.open(expectedPath, flags);
      const first = await handle.stat({ bigint: true });
      if (knownOwnFileStat(first, process.getuid())) evidence.fileStat = first;
      if (!validateFileStat(first, process.getuid()) || (first.mode & 0o077n) !== 0n) {
        fail('EXPORT_FILE_UNSAFE', '匯出檔案型別或權限不安全');
      }
      await this.wait(this.quietIntervalMs);
      const second = await handle.stat({ bigint: true });
      if (!sameStat(first, second)) fail('EXPORT_FILE_UNSTABLE', '匯出檔仍在變動');
      evidence.fileStat = second;
      const expectedSize = Number(second.size);
      const bounded = Buffer.alloc(expectedSize + 1);
      let offset = 0;
      while (offset < bounded.length) {
        const result = await handle.read(bounded, offset, bounded.length - offset, offset);
        if (result.bytesRead === 0) break;
        offset += result.bytesRead;
      }
      if (offset !== expectedSize) fail('EXPORT_FILE_UNSTABLE', '匯出檔讀取長度與穩定大小不符');
      const bytes = bounded.subarray(0, expectedSize);
      const third = await handle.stat({ bigint: true });
      const pathStat = await this.fs.lstat(expectedPath, { bigint: true });
      const currentDirectory = await this.fs.lstat(directory, { bigint: true });
      if (!sameStat(second, third) || !sameStat(third, pathStat) ||
          !validateDirectoryStat(currentDirectory, process.getuid()) ||
          directoryStat.dev !== currentDirectory.dev || directoryStat.ino !== currentDirectory.ino ||
          directoryStat.uid !== currentDirectory.uid || currentDirectory.mode !== directoryStat.mode) {
        fail('EXPORT_FILE_REPLACED', '匯出檔或目錄已被替換');
      }
      const decoded = decodeExport(bytes);
      const utf8Bytes = Buffer.byteLength(decoded.text, 'utf8');
      if (this.cacheBytes + utf8Bytes > MAX_CACHE_BYTES) fail('EXPORT_CACHE_FULL', '匯出內容超過快取上限');
      const digest = hmac(request.identityKey, {
        purpose: 'line-native-text-snapshot-v1',
        tabName: request.tabName, chatName: request.chatName,
        encoding: decoded.encoding, bytesSha256: sha256(bytes), byteLength: bytes.length,
      });
      const id = hmac(request.identityKey, {
        purpose: 'line-native-text-snapshot-id-v1', digest, requestNonce: receipt.preActionProof.requestNonce,
      });
      return {
        id, digest, tabName: request.tabName, chatName: request.chatName,
        identityKey: request.identityKey, observedAt: receipt.observedAt,
        chunks: chunksOf(decoded.text), bytes: utf8Bytes,
        expiresAt: this.now() + SNAPSHOT_TTL_MS,
      };
    } finally {
      await handle?.close();
    }
  }

  pageFromSnapshot(state, request) {
    const snapshot = this.snapshots.get(state.snapshotId);
    if (!snapshot || snapshot.expiresAt <= this.now() ||
        snapshot.digest !== state.snapshotDigest || snapshot.tabName !== request.tabName ||
        snapshot.chatName !== request.chatName || snapshot.identityKey !== request.identityKey ||
        state.offset > snapshot.chunks.length) {
      this.release(state.snapshotId);
      fail('CURSOR_INVALID', 'export snapshot 已失效或不符合原始範圍');
    }
    const observations = [];
    let utf16 = 0, index = state.offset;
    while (index < snapshot.chunks.length && observations.length < request.limit) {
      const chunk = snapshot.chunks[index];
      if (observations.length > 0 && utf16 + chunk.text.length > MAX_PAGE_UTF16) break;
      utf16 += chunk.text.length;
      observations.push({
        observedId: hmac(request.identityKey, {
          purpose: 'line-native-text-observation-v1', snapshotDigest: snapshot.digest,
          ordinal: index, codePointStart: chunk.codePointStart, codePointEnd: chunk.codePointEnd,
        }),
        text: chunk.text, date: null, dateVerified: false, unit: 'text_block',
        provenance: { source: 'NATIVE_TEXT_EXPORT', complete: false },
        identityVerified: false,
      });
      index += 1;
    }
    const terminal = index >= snapshot.chunks.length;
    const exportState = terminal ? null : {
      snapshotId: snapshot.id, snapshotDigest: snapshot.digest, offset: index,
    };
    if (terminal) this.release(snapshot.id);
    return {
      envelope: {
        scope: { tabName: request.tabName, chatName: request.chatName, verified: true },
        observations, observedAt: snapshot.observedAt, snapshotDigest: snapshot.digest,
        nextState: null, complete: false, reasons: [...EXPORT_REASONS],
        syncState: 'unknown', truncated: false, possibleDuplicates: true,
      },
      exportState,
    };
  }

  release(id) {
    const value = this.snapshots.get(id);
    if (value) { this.cacheBytes -= value.bytes; this.snapshots.delete(id); }
  }

  prune() {
    for (const [id, value] of this.snapshots) if (value.expiresAt <= this.now()) this.release(id);
  }

  async cleanup(directory, expectedPath, directoryStat, fileStat) {
    let fileClean = fileStat === null;
    let directoryClean = false;
    try {
      if (fileStat) {
        const current = await this.fs.lstat(expectedPath, { bigint: true });
        if (current.dev !== fileStat.dev || current.ino !== fileStat.ino) return false;
        await this.fs.unlink(expectedPath);
        fileClean = true;
      } else {
        try {
          await this.fs.lstat(expectedPath, { bigint: true });
          fileClean = false;
        } catch (error) {
          if (error?.code !== 'ENOENT') throw error;
          fileClean = true;
        }
      }
      const currentDirectory = await this.fs.lstat(directory, { bigint: true });
      if (currentDirectory.dev !== directoryStat.dev || currentDirectory.ino !== directoryStat.ino ||
          currentDirectory.uid !== directoryStat.uid || currentDirectory.mode !== directoryStat.mode) return false;
      await this.fs.rmdir(directory);
      directoryClean = true;
    } catch (error) {
      if (error?.code === 'ENOENT') return fileClean && directoryClean;
      if (error?.code === 'ENOTEMPTY') return false;
      throw error;
    }
    return fileClean && directoryClean;
  }
}
