import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { LineDesktopMCPServer } from '../src/server.js';
import { AgentServices, workflow, describeAttachments } from '../src/automation/agent-workflows.js';
import { LocalIndex } from '../src/automation/local-index.js';
import { publicError } from '../src/automation/mcp-result.js';
import { AutomationError } from '../src/automation/automation-error.js';

async function scratch(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'line-agent-fixture-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true })); return directory;
}

test('附件描述核對原bytes的雜湊與大小，不回傳路徑或內容；拒絕symlink與總量上限', async t => {
  const dir = await scratch(t), file = path.join(dir, 'synthetic.bin'), content = Buffer.from('SYNTHETIC_FILE_CANARY');
  await fs.writeFile(file, content);
  const result = await describeAttachments({ paths: [file] });
  assert.deepEqual(result, { uiAccessed: false, totalBytes: content.length,
    attachments: [{ index: 0, sha256: createHash('sha256').update(content).digest('hex'), byteCount: content.length }] });
  assert.doesNotMatch(JSON.stringify(result), /SYNTHETIC_FILE_CANARY|synthetic.bin/);
  const link = path.join(dir, 'link'); await fs.symlink(file, link);
  await assert.rejects(describeAttachments({ paths: [link] }), { code: 'ATTACHMENT_FILE_UNSAFE' });
  const large = path.join(dir, 'large.bin'); await fs.writeFile(large, 'a'); await fs.truncate(large, 100 * 1024 * 1024 + 1);
  await assert.rejects(describeAttachments({ paths: [large] }), { code: 'ATTACHMENT_FILE_UNSAFE' });
  await assert.rejects(describeAttachments({ paths: ['relative'] }), { code: 'INVALID_ARGUMENT' });
});

test('五個流程範本不執行操作、互不共享可變狀態，送圖及檔案直接提交', () => {
  for (const name of ['read_summarize', 'draft_reply', 'send_images', 'send_files', 'local_search']) {
    const result = workflow({ workflow: name }); assert.equal(result.executable, false);
    assert.ok(result.rules.some(rule => rule.includes('直接發送')));
    result.steps.push('mutated'); assert.ok(!workflow({ workflow: name }).steps.includes('mutated'));
  }
  assert.throws(() => workflow({ workflow: '__proto__' }), { code: 'INVALID_ARGUMENT' });
  assert.throws(() => workflow({ workflow: 'send_files', autoExecute: true }), { code: 'INVALID_ARGUMENT' });
});

test('系統錯誤不洩漏私人路徑或程序內容，受控恢復資訊仍保留', () => {
  assert.equal(publicError(null).code, 'DESKTOP_OPERATION_FAILED');
  const unsafe = Object.assign(new Error('PRIVATE_PATH_CANARY'), { code: 'EACCES', path: 'PRIVATE_PATH_CANARY', syscall: 'open' });
  assert.doesNotMatch(JSON.stringify(publicError(unsafe)), /PRIVATE_PATH_CANARY/);
  const safe = publicError(new AutomationError('OPERATION_UNCERTAIN', '停止', {
    operationId: '11111111-1111-4111-8111-111111111111', needsRecovery: true, completedCount: 2, totalCount: 3, failedIndex: 2,
    clipboard: 'PRIVATE_CLIPBOARD_CANARY', causeCode: 'NATIVE_TIMEOUT',
  }));
  assert.equal(safe.details.completedCount, 2); assert.equal(safe.details.needsRecovery, true);
  assert.doesNotMatch(JSON.stringify(safe), /PRIVATE_CLIPBOARD_CANARY/);
});

test('真MCP協定可匯入搜尋移除還原，結構化與JSON文字一致，全程不呼叫桌面', async t => {
  const directory = await scratch(t);
  const service = new AgentServices({ index: new LocalIndex({ directory }) });
  const server = new LineDesktopMCPServer({ desktopCall() { throw new Error('UI_MUST_NOT_RUN'); } }, { agentServices: service });
  const client = new Client({ name: 'synthetic-agent', version: '1.0.0' });
  const [a, b] = InMemoryTransport.createLinkedPair(); await server.server.connect(b); await client.connect(a);
  t.after(async () => { await client.close(); await server.server.close(); });
  async function call(name, args) {
    const result = await client.callTool({ name, arguments: args });
    assert.deepEqual(result.structuredContent, JSON.parse(result.content[0].text)); return result;
  }
  const imported = await call('line_index_import', { label: '合成來源', text: 'alpha beta' });
  const sourceId = imported.structuredContent.source.sourceId;
  assert.equal((await call('line_index_search', { query: 'beta' })).structuredContent.results.length, 1);
  await call('line_index_delete', { sourceId });
  assert.equal((await call('line_index_sources', {})).structuredContent.sources.length, 0);
  await call('line_index_restore', { sourceId });
  assert.equal((await call('line_index_sources', {})).structuredContent.sources.length, 1);
  assert.equal((await call('line_agent_workflow', { workflow: 'send_files' })).structuredContent.executable, false);
  const bad = await call('line_index_search', { query: 'a', unknown: true });
  assert.equal(bad.isError, true); assert.equal(bad.structuredContent.error.code, 'INVALID_ARGUMENT');
});

test('新agent工具在HTTP context拒絕且不建立索引；partial結果具結構化錯誤旗標', async t => {
  const directory = await scratch(t);
  const server = new LineDesktopMCPServer({}, { transport: 'http', agentServices: new AgentServices({ index: new LocalIndex({ directory }) }) });
  const denied = await server.handleDesktopTool('line_index_import', { label: '合成', text: 'alpha' });
  assert.equal(denied.structuredContent.error.code, 'TRANSPORT_NOT_ALLOWED');
  assert.deepEqual(await fs.readdir(directory), []);
  const partialServer = new LineDesktopMCPServer({ async desktopCall() { return { success: false, partial: true, completedCount: 1 }; } });
  const partial = await partialServer.handleDesktopTool('line_send_files', {});
  assert.equal(partial.isError, true); assert.equal(partial.structuredContent.completedCount, 1);
});
