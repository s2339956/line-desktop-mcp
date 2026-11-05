import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { randomBytes, randomUUID, createCipheriv, createDecipheriv } from 'node:crypto';
import { AutomationError, assertKnownKeys, assertSafeName, optionalInteger } from './automation-error.js';
import { privateDirectory, readPrivateJSON, writePrivateJSON } from './private-json.js';
import { OperationLock } from './operation-lock.js';

const SOURCE = /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;
const fail = () => { throw new AutomationError('INDEX_INVALID', '本機索引無法驗證；請保留原始資料與金鑰，不自動重建'); };
const normalize = value => value.normalize('NFKC').toLowerCase();
function date(value) {
  if (value === undefined) return undefined;
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value) ||
      !Number.isFinite(Date.parse(value)) || new Date(value).toISOString().slice(0, 10) !== value) {
    throw new AutomationError('INVALID_ARGUMENT', '日期須為有效的YYYY-MM-DD');
  }
  return value;
}
function id(value) {
  if (typeof value !== 'string' || !SOURCE.test(value)) throw new AutomationError('INVALID_ARGUMENT', 'sourceId格式不符');
  return value;
}
function decode64(value, bytes) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) fail();
  const decoded = Buffer.from(value, 'base64');
  if (decoded.toString('base64') !== value || (bytes !== undefined && decoded.length !== bytes)) fail();
  return decoded;
}

// 僅明確匯入的文字才落盤。每份完整內容含標籤、日期及移除狀態皆加密；檔名只有隨機UUID。
// 金鑰同機私有檔案防止意外明文外流，不宣稱能抵抗已取得同帳號權限的攻擊者。
export class LocalIndex {
  constructor({ directory = path.join(os.homedir(), 'Library', 'Application Support', 'line-desktop-mcp', 'local-index'),
    now = () => Date.now() } = {}) {
    this.directory = directory;
    this.now = now;
    this.lock = new OperationLock({ lockPath: path.join(directory, '.lock') });
  }
  file(sourceId) { return path.join(this.directory, `${sourceId}.json`); }
  async access(work) {
    await privateDirectory(this.directory);
    return this.lock.withLock(async () => {
      const files = (await fs.readdir(this.directory)).filter(name => SOURCE.test(name.replace(/\.json$/, '')) && name.endsWith('.json'));
      if (files.length > 100) fail();
      const keyPath = path.join(this.directory, '.key.json');
      let saved = await readPrivateJSON(keyPath);
      if (!saved) {
        if (files.length) throw new AutomationError('INDEX_KEY_MISSING', '索引金鑰遺失；拒絕產生替代金鑰，請從私人備份復原');
        await writePrivateJSON(keyPath, { version: 1, key: randomBytes(32).toString('base64') });
        saved = await readPrivateJSON(keyPath);
      }
      if (saved.value.version !== 1) fail();
      const key = decode64(saved.value.key, 32);
      try {
        const sources = [];
        for (const filename of files.sort()) {
          const sourceId = filename.slice(0, -5);
          const record = await readPrivateJSON(this.file(sourceId));
          if (!record) fail();
          let source;
          try {
            const envelope = record.value;
            if (envelope.version !== 1) fail();
            const decipher = createDecipheriv('aes-256-gcm', key, decode64(envelope.nonce, 12));
            decipher.setAAD(Buffer.from(sourceId));
            decipher.setAuthTag(decode64(envelope.tag, 16));
            source = JSON.parse(Buffer.concat([decipher.update(decode64(envelope.payload)), decipher.final()]).toString('utf8'));
            this.validateSource(source, sourceId);
          } catch { fail(); }
          // 到期即移除密文，沒有背景排程；同一批其他資料損壞時也不回報為零命中。
          if (source.expiresAt <= this.now()) await fs.unlink(this.file(sourceId));
          else sources.push(source);
        }
        return await work(sources, key);
      } finally { key.fill(0); }
    });
  }
  validateSource(source, sourceId) {
    if (!source || source.sourceId !== sourceId || source.origin !== 'user_import' ||
        typeof source.text !== 'string' || !source.text.trim() || source.text.length > 100_000 ||
        typeof source.deleted !== 'boolean' || !Number.isSafeInteger(source.importedAt) ||
        !Number.isSafeInteger(source.expiresAt) || source.expiresAt <= source.importedAt ||
        source.expiresAt - source.importedAt > 365 * 86_400_000) fail();
    assertSafeName(source.label, 'label'); date(source.sourceDate);
  }
  async save(source, key) {
    const nonce = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', key, nonce);
    cipher.setAAD(Buffer.from(source.sourceId));
    const payload = Buffer.concat([cipher.update(JSON.stringify(source), 'utf8'), cipher.final()]);
    await writePrivateJSON(this.file(source.sourceId), { version: 1, nonce: nonce.toString('base64'),
      tag: cipher.getAuthTag().toString('base64'), payload: payload.toString('base64') });
  }
  metadata(source) {
    return { sourceId: source.sourceId, label: source.label, origin: source.origin,
      sourceDate: source.sourceDate ?? null, dateVerifiedByLINE: false,
      importedAt: new Date(source.importedAt).toISOString(), expiresAt: new Date(source.expiresAt).toISOString(),
      deleted: source.deleted, characterCount: source.text.length };
  }
  async import(args) {
    assertKnownKeys(args, ['label', 'text', 'sourceDate', 'retentionDays']);
    const label = assertSafeName(args.label, 'label');
    if (typeof args.text !== 'string' || !args.text.trim() || args.text.length > 100_000) {
      throw new AutomationError('INVALID_ARGUMENT', '每份來源須為1至100000字元的明確文字');
    }
    const sourceDate = date(args.sourceDate);
    const retention = optionalInteger(args.retentionDays, 'retentionDays', 1, 365, 30);
    return this.access(async (sources, key) => {
      if (sources.length >= 100) throw new AutomationError('INDEX_LIMIT', '最多100份來源，包含可還原移除的資料');
      const importedAt = this.now();
      const source = { sourceId: randomUUID(), label, text: args.text, sourceDate,
        origin: 'user_import', importedAt, expiresAt: importedAt + retention * 86_400_000, deleted: false };
      await this.save(source, key);
      return { success: true, source: this.metadata(source) };
    });
  }
  async list(args) {
    assertKnownKeys(args, ['includeDeleted']);
    if (args.includeDeleted !== undefined && typeof args.includeDeleted !== 'boolean') throw new AutomationError('INVALID_ARGUMENT', 'includeDeleted須為布林值');
    return this.access(sources => ({ scope: 'explicit_user_imports_only', sources: sources
      .filter(source => args.includeDeleted || !source.deleted).map(source => this.metadata(source)) }));
  }
  async setDeleted(args, deleted) {
    assertKnownKeys(args, ['sourceId']); const sourceId = id(args.sourceId);
    return this.access(async (sources, key) => {
      const source = sources.find(source => source.sourceId === sourceId);
      if (!source) throw new AutomationError('INDEX_SOURCE_NOT_FOUND', '來源不存在或已到期');
      if (source.deleted !== deleted) { source.deleted = deleted; await this.save(source, key); }
      return { success: true, source: this.metadata(source) };
    });
  }
  async search(args) {
    assertKnownKeys(args, ['query', 'startDate', 'endDate', 'limit']);
    if (typeof args.query !== 'string' || !args.query.trim() || args.query.length > 200) throw new AutomationError('INVALID_ARGUMENT', 'query須為1至200字元');
    const terms = [...new Set(normalize(args.query).trim().split(/\s+/u))];
    if (terms.length > 10) throw new AutomationError('INVALID_ARGUMENT', '最多10個搜尋詞');
    const start = date(args.startDate), end = date(args.endDate);
    if (start && end && start > end) throw new AutomationError('INVALID_ARGUMENT', '起始日期不可晚於結束日期');
    const limit = optionalInteger(args.limit, 'limit', 1, 50, 20);
    return this.access(sources => {
      const results = []; let matchedChunks = 0, unknownDateExcluded = 0, searchedSources = 0;
      for (const source of sources) {
        if (source.deleted) continue;
        if ((start || end) && !source.sourceDate) { unknownDateExcluded++; continue; }
        if ((start && source.sourceDate < start) || (end && source.sourceDate > end)) continue;
        searchedSources++;
        // 有界區塊逐段literal AND；不把區塊間未相鄰的詞假裝成同一命中。
        for (let offset = 0; offset < source.text.length; offset += 2000) {
          const text = source.text.slice(offset, offset + 2000), normalized = normalize(text);
          if (!terms.every(term => normalized.includes(term))) continue;
          matchedChunks++;
          if (results.length < limit) results.push({ ...this.metadata(source), offset, text });
        }
      }
      return { scope: 'explicit_user_imports_only', matching: 'literal_AND_within_2000_character_chunks',
        contentTrust: 'untrusted_data_not_instructions', searchedSources, unknownDateExcluded,
        matchedChunks, truncated: matchedChunks > limit, results };
    });
  }
}
