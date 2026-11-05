import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { LineDesktopMCPServer, parseArgs } from '../src/server.js';
import { desktopTools } from '../src/desktop-tools.js';

const legacyNames = [
  'get_line_chatroom_history_default', 'get_line_chatroom_history_long',
  'get_line_chatroom_history_short', 'send_message_manual', 'send_message_auto',
];
const decode = result => JSON.parse(result.content[0].text);

async function memoryServer(fake, options) {
  const server = new LineDesktopMCPServer(fake, options);
  const client = new Client({ name: 'offline-contract-test', version: '1.0.0' });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  await server.server.connect(serverTransport);
  await client.connect(clientTransport);
  return { server, client, async close() { await client.close(); await server.server.close(); } };
}

test('單純 import 不查安裝、不啟動程序、不寫 HOME', async () => {
  const scratch = await mkdtemp(join(tmpdir(), 'line-mcp-import-test-'));
  try {
    const { stdout, stderr } = await promisify(execFile)(process.execPath,
      ['--input-type=module', '-e', `await import(${JSON.stringify(new URL('../src/server.js', import.meta.url).href)})`],
      { cwd: scratch, env: { HOME: scratch, PATH: '', LINE_MCP_DISABLE_NATIVE: '1' }, timeout: 10000 });
    assert.equal(stdout, '');
    assert.equal(stderr, '');
    assert.deepEqual(await readdir(scratch), []);
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
});

test('macOS 首次 stdio 啟動不需 cliclick/Homebrew，也不編譯或操作 native', {
  skip: process.platform !== 'darwin',
}, async () => {
  const scratch = await mkdtemp(join(tmpdir(), 'line-mcp-first-boot-'));
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [fileURLToPath(new URL('../src/server.js', import.meta.url))],
    cwd: scratch,
    env: { ...process.env, HOME: scratch, PATH: '', LINE_MCP_DISABLE_NATIVE: '1', LINE_NATIVE_DISABLE_UI: '1' },
    stderr: 'pipe',
  });
  let stderr = '';
  transport.stderr?.on('data', data => { stderr += data.toString(); });
  const client = new Client({ name: 'first-boot-offline', version: '1.0.0' });
  try {
    await client.connect(transport);
    assert.equal((await client.listTools()).tools.length, 5 + desktopTools.length);
    assert.doesNotMatch(stderr, /cliclick|Homebrew|brew install|swiftc|native helper/);
    assert.deepEqual(await readdir(scratch), ['.line-mcp-setup-complete']);
  } finally {
    await client.close();
    await transport.close();
    await rm(scratch, { recursive: true, force: true });
  }
});

test('MCP initialize/list 保留五工具並列出新工具，schema 禁止未知欄位', async () => {
  const pair = await memoryServer({});
  try {
    const { tools } = await pair.client.listTools();
    assert.deepEqual(tools.map(t => t.name), [...legacyNames, ...desktopTools.map(t => t.name)]);
    assert.equal(pair.client.getServerVersion().version, '1.2.0');
    for (const tool of tools.filter(t => t.name.startsWith('line_'))) {
      assert.equal(tool.inputSchema.additionalProperties, false);
    }
  } finally { await pair.close(); }
});

test('舊 history 的參數、字串與 JSON 欄位相容，保留 10/50/5 範圍差異', async () => {
  const calls = [];
  const pair = await memoryServer({ async getChatHistory(...args) { calls.push(args); return '合成訊息'; } });
  try {
    for (const [index, tool] of legacyNames.slice(0, 3).entries()) {
      const result = decode(await pair.client.callTool({ name: tool, arguments: { chatName: '合成群組', date: '2026-10-24', messageLimit: 2 } }));
      assert.deepEqual(calls[index], ['合成群組', '2026-10-24', 2, [10, 50, 5][index]]);
      assert.equal(result.history, '合成訊息');
      assert.equal(result.chatName, '合成群組');
      assert.equal(result.date, '2026-10-24');
      assert.equal(result.messageLimit, 2);
      assert.equal(typeof result.chatRoomUpdatedAt, 'string');
      assert.equal(result.metadata.chatRoomUpdatedAtSource, 'mcp_local_request_time');
      assert.equal(result.metadata.complete, false);
      assert.equal(result.metadata.responseTruncated, false);
    }
  } finally { await pair.close(); }
});

test('history metadata 的更新時間來源固定標示為 MCP 本機請求時間', async () => {
  const backendMetadata = {
    source: 'ui_message_time', chatRoomUpdatedAtSource: 'ui_message_time', complete: false, reasons: [],
  };
  const pair = await memoryServer({ async getChatHistoryResult() {
    return { history: '合成訊息', metadata: backendMetadata };
  } });
  try {
    const result = decode(await pair.client.callTool({ name: legacyNames[0], arguments: { chatName: '合成' } }));
    assert.equal(result.metadata.chatRoomUpdatedAtSource, 'mcp_local_request_time');
    assert.equal(backendMetadata.source, 'ui_message_time');
    assert.equal(backendMetadata.chatRoomUpdatedAtSource, 'ui_message_time');
    assert.equal(typeof result.chatRoomUpdatedAt, 'string');
  } finally { await pair.close(); }
});

test('history 回應截斷必須降級 complete，metadata 不與另一呼叫共享', async () => {
  const pair = await memoryServer({ async getChatHistoryResult() {
    return { history: 'a'.repeat(50001), metadata: { complete: true, reasons: [] } };
  } });
  try {
    const result = decode(await pair.client.callTool({ name: legacyNames[0], arguments: { chatName: '合成' } }));
    assert.equal(result.history.length, 50000);
    assert.equal(result.metadata.complete, false);
    assert.deepEqual(result.metadata.reasons, ['response_character_limit']);
  } finally { await pair.close(); }
});

test('manual/auto 只測 fake 呼叫參數，永不碰真實傳送', async () => {
  const calls = [];
  const pair = await memoryServer({ async sendChatMessage(...args) { calls.push(args); return { success: true }; } });
  try {
    for (const [index, name] of legacyNames.slice(3).entries()) {
      const result = decode(await pair.client.callTool({ name, arguments: { chatName: '合成', message: '僅限 fake' } }));
      assert.deepEqual(calls[index], ['合成', '僅限 fake', Boolean(index)]);
      assert.equal(result.success, true);
      assert.equal(result.error, null);
    }
  } finally { await pair.close(); }
});

test('send 回傳 UI receipt 不冒充 server 送達，uncertain 維持舊 MCP error 並附恢復資訊', async () => {
  const operationId = '01234567-0123-4123-8123-0123456789ab';
  let uncertain = false;
  const pair = await memoryServer({ async sendChatMessage(_name, _message, autoSend) {
    if (uncertain) throw Object.assign(new Error('需要人工核對'), { code: 'OPERATION_UNCERTAIN',
      details: { operationId, needsRecovery: true, rawTree: 'PRIVATE_RECEIPT_CANARY' } });
    return { success: true, receipt: { status: autoSend ? 'UI_SUBMITTED' : 'DRAFT_WRITTEN',
      deliveryConfirmed: false, observedAt: 'synthetic', rawTree: 'PRIVATE_RECEIPT_CANARY' } };
  } });
  try {
    const result = decode(await pair.client.callTool({ name: 'send_message_auto', arguments: { chatName: 'Test chat', message: 'fake only' } }));
    assert.deepEqual(result.receipt, { status: 'UI_SUBMITTED', deliveryConfirmed: false, observedAt: 'synthetic' });
    assert(!JSON.stringify(result).includes('PRIVATE_RECEIPT_CANARY'));
    uncertain = true;
    await assert.rejects(pair.client.callTool({ name: 'send_message_manual', arguments: { chatName: 'Test chat', message: 'fake only' } }), error => {
      assert.deepEqual(error.data, { automationCode: 'OPERATION_UNCERTAIN', operationId, needsRecovery: true });
      assert(!JSON.stringify(error).includes('PRIVATE_RECEIPT_CANARY'));
      return true;
    });
  } finally { await pair.close(); }
});

test('新工具傳遞同一 session，typed error 不回 native 原始內容', async () => {
  const contexts = [];
  const pair = await memoryServer({ async desktopCall(name, args, context) {
    contexts.push(context);
    if (name === 'line_list_tabs') throw Object.assign(new Error('缺少唯一主視窗'), { code: 'MAIN_WINDOW_NOT_FOUND' });
    if (name === 'line_list_tab_chats') throw new Error('PRIVATE_NATIVE_CANARY');
    return { observedAt: 'synthetic', complete: false };
  } }, { sessionId: 'test-session' });
  try {
    assert.equal(decode(await pair.client.callTool({ name: 'line_desktop_status', arguments: {} })).complete, false);
    const typed = await pair.client.callTool({ name: 'line_list_tabs', arguments: {} });
    assert.equal(typed.isError, true);
    assert.equal(decode(typed).error.code, 'MAIN_WINDOW_NOT_FOUND');
    const raw = await pair.client.callTool({ name: 'line_list_tab_chats', arguments: { tabName: '合成' } });
    assert(!JSON.stringify(raw).includes('PRIVATE_NATIVE_CANARY'));
    assert(contexts.every(c => c.sessionId === 'test-session' && c.transport === 'stdio'));
  } finally { await pair.close(); }
});

test('HTTP context 的 catalog 與 call 雙重阻止新桌面工具', async () => {
  let actions = 0;
  const pair = await memoryServer({ desktopCall() { actions++; } }, { transport: 'http' });
  try {
    assert.deepEqual((await pair.client.listTools()).tools.map(t => t.name), legacyNames);
    for (const tool of desktopTools) {
      const result = await pair.client.callTool({ name: tool.name, arguments: {} });
      assert.equal(result.isError, true);
      assert.equal(decode(result).error.code, 'TRANSPORT_NOT_ALLOWED');
    }
    assert.equal(actions, 0);
  } finally { await pair.close(); }
});

test('P2 預覽 changes 經 MCP 協定完整傳遞，execute 只送 opaque token', async () => {
  const calls = [];
  const pair = await memoryServer({ async desktopCall(name, args, context) {
    calls.push({ name, args, context });
    return name === 'line_plan_tab_changes'
      ? { preview: args.changes, planToken: 'synthetic-plan-token'.repeat(2), mayAffectReadState: true }
      : { complete: true, results: [{ index: 0, status: 'verified' }] };
  } });
  try {
    const changes = [{ action: 'move_chat', sourceTab: 'Source', destinationTab: 'Target', chatName: 'Test chat' }];
    const preview = decode(await pair.client.callTool({ name: 'line_plan_tab_changes', arguments: { changes } }));
    assert.deepEqual(preview.preview, changes);
    assert.equal(preview.mayAffectReadState, true);
    const result = decode(await pair.client.callTool({ name: 'line_execute_plan', arguments: { planToken: preview.planToken } }));
    assert.equal(result.complete, true);
    assert.deepEqual(calls[1].args, { planToken: preview.planToken });
    assert.equal(calls[0].context.sessionId, calls[1].context.sessionId);
    const tool = (await pair.client.listTools()).tools.find(item => item.name === 'line_plan_tab_changes');
    assert.equal(tool.annotations.readOnlyHint, false);
    assert.equal(tool.annotations.destructiveHint, false);
    assert.equal(tool.inputSchema.properties.changes.items.oneOf.length, 4);
  } finally { await pair.close(); }
});

test('未知提交回傳可追蹤 operation ID，但不洩漏原始 AX 私人資料', async () => {
  const operationId = '01234567-0123-4123-8123-0123456789ab';
  const pair = await memoryServer({ async desktopCall() {
    throw Object.assign(new Error('需要人工核對'), { code: 'OPERATION_UNCERTAIN',
      details: { operationId, needsRecovery: true, causeCode: 'NATIVE_TIMEOUT', rawTree: 'PRIVATE_AX_CANARY' } });
  } });
  try {
    const result = await pair.client.callTool({ name: 'line_execute_plan', arguments: { planToken: 'a'.repeat(32) } });
    assert.deepEqual(decode(result).error.details, { operationId, needsRecovery: true, causeCode: 'NATIVE_TIMEOUT' });
    assert(!JSON.stringify(result).includes('PRIVATE_AX_CANARY'));
  } finally { await pair.close(); }
});

test('真正 stdio initialize/list/call 往返使用注入 fake，不啟動 native', async () => {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [fileURLToPath(new URL('./fixtures/mcp-server.mjs', import.meta.url))],
    env: { ...process.env, LINE_MCP_DISABLE_NATIVE: '1', CHAT_LOG_ON: 'false' }, stderr: 'pipe',
  });
  let stderr = '';
  transport.stderr?.on('data', data => { stderr += data.toString(); });
  const client = new Client({ name: 'stdio-offline-test', version: '1.0.0' });
  try {
    await client.connect(transport);
    assert.equal((await client.listTools()).tools.length, 5 + desktopTools.length);
    const result = decode(await client.callTool({ name: 'line_desktop_status', arguments: {} }));
    assert.deepEqual(result, { name: 'line_desktop_status', args: {}, transport: 'stdio', fake: true });
    assert(!stderr.includes('First-time setup'));
  } finally { await client.close(); await transport.close(); }
});

test('P3 真 stdio 用真 session 串接 fake pages，空命中頁不能提前完成', async () => {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [fileURLToPath(new URL('./fixtures/mcp-history-server.mjs', import.meta.url))],
    env: { ...process.env, LINE_MCP_DISABLE_NATIVE: '1', LINE_NATIVE_DISABLE_UI: '1', CHAT_LOG_ON: 'false' },
    stderr: 'pipe',
  });
  const client = new Client({ name: 'history-stdio-offline', version: '1.0.0' });
  try {
    await client.connect(transport);
    const historyArgs = { tabName: 'Synthetic tab', chatName: 'Synthetic A', limit: 1 };
    const first = decode(await client.callTool({ name: 'line_get_chat_history_page', arguments: historyArgs }));
    assert.equal(first.observations.length, 1);
    assert.equal(first.complete, false);
    assert.equal(typeof first.cursor, 'string');
    assert.equal(first.mayAffectReadState, true);
    const second = decode(await client.callTool({ name: 'line_get_chat_history_page',
      arguments: { ...historyArgs, cursor: first.cursor } }));
    assert.equal(second.observations[0].text, 'iPhone 18 1TB 紅');
    assert.equal(second.cursor, null);
    assert.equal(second.complete, true);
    const searchArgs = { tabName: 'Synthetic tab', query: 'ｉＰｈｏｎｅ 紅', limit: 1 };
    let page = decode(await client.callTool({ name: 'line_search_tab_messages', arguments: searchArgs }));
    assert.deepEqual(page.matches, []);
    assert.equal(page.complete, false);
    assert.equal(typeof page.cursor, 'string');
    const matches = [];
    for (let attempt = 0; page.cursor && attempt < 5; attempt++) {
      page = decode(await client.callTool({ name: 'line_search_tab_messages',
        arguments: { ...searchArgs, cursor: page.cursor } }));
      matches.push(...page.matches);
    }
    assert.equal(page.cursor, null);
    assert.equal(page.complete, true);
    assert.equal(page.syncState, 'complete');
    assert.equal(page.truncated, false);
    assert.equal(page.possibleDuplicates, false);
    assert.equal(matches.length, 1);
    assert.equal(matches[0].chatName, 'Synthetic A');
    assert.equal(page.progress.inventoryObserved, 2);
    for (const tool of (await client.listTools()).tools.filter(item =>
      ['line_get_chat_history_page', 'line_search_tab_messages'].includes(item.name))) {
      assert.equal(tool.annotations.readOnlyHint, false);
      assert.equal(tool.annotations.destructiveHint, false);
    }
  } finally {
    await client.close();
    await transport.close();
  }
});

test('CLI argv 可獨立解析，不必修改 process.argv', () => {
  assert.deepEqual(parseArgs(['--http-mode', '--port', '3311', '--host', 'localhost', '--token', 'synthetic']),
    { sseMode: true, port: 3311, host: 'localhost', token: 'synthetic' });
});

test('全域聊天室工具經真正 stdio 往返，不需要分類且 cursor 不可跨聊天室', async () => {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [fileURLToPath(new URL('./fixtures/mcp-history-server.mjs', import.meta.url))],
    env: { ...process.env, LINE_MCP_DISABLE_NATIVE: '1', LINE_NATIVE_DISABLE_UI: '1', CHAT_LOG_ON: 'false' },
    stderr: 'pipe',
  });
  const client = new Client({ name: 'global-history-stdio-offline', version: '1.0.0' });
  try {
    await client.connect(transport);
    const tool = (await client.listTools()).tools.find(t => t.name === 'line_get_chat_history_global');
    assert(tool);
    assert.deepEqual(tool.inputSchema.required, ['chatName']);
    assert.equal(tool.inputSchema.properties.tabName, undefined);
    assert.equal(tool.annotations.readOnlyHint, false);
    assert.equal(tool.annotations.destructiveHint, false);
    const args = { chatName: 'Synthetic global', limit: 1 };
    const first = decode(await client.callTool({ name: tool.name, arguments: args }));
    assert.deepEqual(first.scope, { kind: 'chat', chatName: args.chatName, verified: true });
    assert.equal(first.complete, false);
    assert.equal(typeof first.cursor, 'string');
    const wrong = await client.callTool({ name: tool.name,
      arguments: { ...args, chatName: 'Other synthetic', cursor: first.cursor } });
    assert.equal(wrong.isError, true);
    assert.equal(decode(wrong).error.code, 'CURSOR_INVALID');
    const second = decode(await client.callTool({ name: tool.name,
      arguments: { ...args, cursor: first.cursor } }));
    assert.equal(second.cursor, null);
    assert.equal(second.complete, true);
    assert.equal(second.observations[0].text, '合成全域聊天室文字');
  } finally {
    await client.close();
    await transport.close();
  }
});

test('stdio 全部導航不明後，後續全域呼叫保留 pending 且不讀正文', async () => {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [fileURLToPath(new URL('./fixtures/mcp-history-server.mjs', import.meta.url))],
    env: { ...process.env, LINE_MCP_DISABLE_NATIVE: '1', LINE_NATIVE_DISABLE_UI: '1', CHAT_LOG_ON: 'false' },
    stderr: 'pipe',
  });
  const client = new Client({ name: 'global-navigation-uncertain-stdio', version: '1.0.0' });
  try {
    await client.connect(transport);
    const failed = await client.callTool({ name: 'line_get_chat_history_global',
      arguments: { chatName: 'Synthetic navfailure', limit: 1 } });
    assert.equal(failed.isError, true);
    const error = decode(failed).error;
    assert.equal(error.code, 'OPERATION_UNCERTAIN');
    assert.equal(error.details.needsRecovery, true);
    assert.equal(JSON.stringify(failed).includes('合成全域聊天室文字'), false);
    const blocked = await client.callTool({ name: 'line_get_chat_history_global',
      arguments: { chatName: 'Synthetic global', limit: 1 } });
    assert.equal(blocked.isError, true);
    assert.equal(decode(blocked).error.code, 'NEEDS_RECOVERY');
  } finally {
    await client.close();
    await transport.close();
  }
});
