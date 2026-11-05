import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { desktopTools } from '../src/desktop-tools.js';
import { readFile } from 'node:fs/promises';

// 安裝驗收只協商協定與列舉工具，不呼叫讀取聊天或傳送工具。
const transport = new StdioClientTransport({
  command: process.execPath,
  args: [fileURLToPath(new URL('../src/server.js', import.meta.url))],
  cwd: fileURLToPath(new URL('..', import.meta.url)),
  env: { ...process.env, CHAT_LOG_ON: 'false' },
  stderr: 'pipe',
});
transport.stderr?.on('data', data => process.stderr.write(data));
const client = new Client({ name: 'line-install-check', version: '1.0.0' });
try {
  await client.connect(transport);
  const { version } = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  assert.equal(client.getServerVersion().version, version);
  const { tools } = await client.listTools();
  assert.deepEqual(tools.map(tool => tool.name).sort(), [
    'get_line_chatroom_history_default', 'get_line_chatroom_history_long',
    'get_line_chatroom_history_short', 'send_message_manual', 'send_message_auto',
    ...desktopTools.map(tool => tool.name),
  ].sort());
  console.log(JSON.stringify({ protocol: 'PASS', server: client.getServerVersion(), tools: tools.map(tool => tool.name) }));
} finally {
  await client.close();
  await transport.close();
}
