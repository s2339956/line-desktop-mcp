#!/usr/bin/env node
import fs from 'node:fs/promises';
import { constants } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { execFileSync, spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';

const root = fileURLToPath(new URL('..', import.meta.url));
const plain = value => value !== null && typeof value === 'object' && !Array.isArray(value);

export function makeConfig(projectRoot, nodePath = process.execPath) {
  if (!path.isAbsolute(projectRoot) || !path.isAbsolute(nodePath)) throw new Error('安裝路徑必須是絕對路徑');
  return { mcpServers: { 'line-desktop-mcp': {
    command: nodePath, args: [path.join(projectRoot, 'src/server.js')],
    env: { CHAT_LOG_ON: 'false' },
  } } };
}

export async function mergeClientConfig(configPath, addition) {
  await fs.mkdir(path.dirname(configPath), { recursive: true, mode: 0o700 });
  let previous = null;
  try {
    // 拒絕跟隨設定檔symlink，且在覆寫前重新核對原文，保留其他MCP與client設定。
    const handle = await fs.open(configPath, constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
      const stat = await handle.stat();
      if (!stat.isFile() || stat.nlink !== 1 || stat.size > 1024 * 1024) throw new Error('設定檔類型或大小不安全');
      previous = await handle.readFile('utf8');
    } finally { await handle.close(); }
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const config = previous === null ? {} : JSON.parse(previous);
  if (!plain(config) || (config.mcpServers !== undefined && !plain(config.mcpServers))) throw new Error('既有設定格式不正確，不會覆寫');
  const merged = { ...config, mcpServers: { ...config.mcpServers, ...addition.mcpServers } };
  const text = JSON.stringify(merged, null, 2) + '\n';
  if (text === previous) return { changed: false, backup: false };
  const nonce = randomUUID();
  const temporary = `${configPath}.tmp-${nonce}`;
  if (previous !== null) await fs.writeFile(`${configPath}.backup-${nonce}`, previous, { flag: 'wx', mode: 0o600 });
  try {
    await fs.writeFile(temporary, text, { flag: 'wx', mode: 0o600 });
    let current = null;
    try {
      const stat = await fs.lstat(configPath);
      if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1) throw new Error('設定檔在安裝期間變更');
      current = await fs.readFile(configPath, 'utf8');
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (current !== previous) throw new Error('設定檔在安裝期間變更，請重新執行安裝');
    await fs.rename(temporary, configPath);
  } finally { await fs.rm(temporary, { force: true }); }
  return { changed: true, backup: previous !== null };
}

export async function setupMac(args = process.argv.slice(2)) {
  if (args.some(arg => !['--claude', '--config-only'].includes(arg))) throw new Error('只接受 --claude 或 --config-only');
  if (process.platform !== 'darwin') throw new Error('此發行版只提供macOS安裝入口');
  if (Number(process.versions.node.split('.')[0]) < 22) throw new Error('需要Node.js 22以上');
  const config = makeConfig(root);
  if (!args.includes('--config-only')) {
    execFileSync('/usr/bin/xcrun', ['--find', 'swiftc'], { stdio: 'pipe' });
    // 發行ZIP已有鎖定依賴；原始碼下載才使用lock安裝，不執行第三方lifecycle scripts。
    try { await fs.access(path.join(root, 'node_modules/@modelcontextprotocol/sdk/package.json')); }
    catch {
      const install = spawnSync('npm', ['ci', '--ignore-scripts', '--no-audit', '--no-fund'], { cwd: root, stdio: 'inherit' });
      if (install.error || install.status !== 0) throw new Error('依賴安裝失敗，未修改client設定');
    }
    const { NativeBridge } = await import('../src/automation/native-bridge.js');
    const bridge = new NativeBridge({ compileTimeoutMs: 180_000 });
    const binary = await bridge.ensureBinary();
    const selfTest = JSON.parse(execFileSync(binary, [], {
      input: JSON.stringify({ name: 'selfTest', args: {} }), encoding: 'utf8', timeout: 15_000,
      env: { ...process.env, LINE_MCP_DISABLE_NATIVE: '1', LINE_NATIVE_DISABLE_UI: '1' },
    }));
    if (selfTest.ok !== true || selfTest.result?.passed !== true) throw new Error('原生自檢未通過，未修改client設定');
    execFileSync(process.execPath, [path.join(root, 'scripts/check-install.mjs')], {
      cwd: root, stdio: 'inherit', timeout: 20_000,
      env: { ...process.env, LINE_MCP_DISABLE_NATIVE: '1', LINE_NATIVE_DISABLE_UI: '1' },
    });
    console.log('原生編譯與MCP協定檢查通過；沒有讀取或傳送LINE內容。');
  }
  await mergeClientConfig(path.join(root, 'mcp-config.json'), config);
  if (args.includes('--claude')) {
    await mergeClientConfig(path.join(os.homedir(), 'Library/Application Support/Claude/claude_desktop_config.json'), config);
    console.log('Claude Desktop設定完成；其他設定保留，原檔存在時先備份。');
  }
  console.log('通用AI agent設定已寫入mcp-config.json；此檔含本機路徑，請勿上傳。');
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  setupMac().catch(error => {
    console.error(`安裝中止：${error.message}\n請確認Node.js、Xcode Command Line Tools與安裝目錄的寫入權限。`);
    process.exitCode = 1;
  });
}
