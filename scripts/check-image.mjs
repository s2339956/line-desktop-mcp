import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

// 驗收使用原 MCP 入口。未加 --send 只選入圖片，不按可能立即發送的「打開」。
const values = {};
let send = false;
for (let index = 2; index < process.argv.length; index += 1) {
  const flag = process.argv[index];
  if (flag === '--send' && !send) { send = true; continue; }
  if (!['--chat', '--file', '--sha256'].includes(flag) || values[flag] !== undefined ||
      !process.argv[index + 1] || process.argv[index + 1].startsWith('--')) {
    throw new Error('用法：node scripts/check-image.mjs --chat 名稱 --file 絕對路徑 --sha256 SHA256 [--send]');
  }
  values[flag] = process.argv[++index];
}
if (!values['--chat'] || !values['--file']?.startsWith('/') || !/^[a-f0-9]{64}$/.test(values['--sha256'] ?? '')) {
  throw new Error('必須明確提供收件對話、圖片絕對路徑與 SHA256');
}
const transport = new StdioClientTransport({ command: process.execPath,
  args: [new URL('../src/server.js', import.meta.url).pathname],
  cwd: new URL('..', import.meta.url).pathname,
  env: { ...process.env, CHAT_LOG_ON: 'false' }, stderr: 'pipe' });
transport.stderr?.on('data', data => process.stderr.write(data));
const client = new Client({ name: 'line-image-acceptance', version: '1.0.0' });
try {
  await client.connect(transport);
  const catalog = await client.listTools();
  if (!catalog.tools.some(tool => tool.name === 'line_send_image')) throw new Error('目前連線沒有圖片工具');
  const preflight = await client.callTool({ name: 'line_desktop_status', arguments: {} });
  if (preflight.isError) throw new Error('LINE 狀態檢查失敗，不操作圖片');
  const status = JSON.parse(preflight.content[0].text);
  if (status.running !== true || status.foreground !== true || status.usable !== true || status.needsRecovery === true) {
    throw new Error('LINE 不是可用前景視窗或仍有待恢復狀態，不操作圖片');
  }
  // 每次驗收只呼叫一次；錯誤或 timeout 均不重送。
  const result = await client.callTool({ name: 'line_send_image', arguments: {
    chatName: values['--chat'], imagePath: values['--file'], imageSha256: values['--sha256'], autoSend: send,
  } });
  process.stdout.write(JSON.stringify({ isError: result.isError === true,
    result: JSON.parse(result.content[0].text) }) + '\n');
  if (result.isError) process.exitCode = 1;
} finally {
  await client.close();
  await transport.close();
}
