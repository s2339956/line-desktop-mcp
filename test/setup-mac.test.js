import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { makeConfig, mergeClientConfig } from '../scripts/setup-mac.mjs';

test('通用設定保留含空格路徑且不依賴使用者PATH', () => {
  const config = makeConfig('/tmp/Synthetic Folder', '/usr/local/bin/node');
  assert.equal(config.mcpServers['line-desktop-mcp'].command, '/usr/local/bin/node');
  assert.deepEqual(config.mcpServers['line-desktop-mcp'].args, ['/tmp/Synthetic Folder/src/server.js']);
  assert.equal(config.mcpServers['line-desktop-mcp'].env.CHAT_LOG_ON, 'false');
  assert.throws(() => makeConfig('relative'), /絕對路徑/);
});

test('安裝合併保留其他設定、備份且重複執行不新增備份', async t => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'line-config-fixture-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const file = path.join(dir, 'config.json');
  const previous = JSON.stringify({ theme: 'dark', mcpServers: { other: { command: 'other' } } });
  await fs.writeFile(file, previous);
  const config = makeConfig('/tmp/synthetic');
  assert.deepEqual(await mergeClientConfig(file, config), { changed: true, backup: true });
  const merged = JSON.parse(await fs.readFile(file, 'utf8'));
  assert.equal(merged.theme, 'dark');
  assert.equal(merged.mcpServers.other.command, 'other');
  const backup = (await fs.readdir(dir)).find(name => name.includes('.backup-'));
  assert.equal(await fs.readFile(path.join(dir, backup), 'utf8'), previous);
  assert.equal((await fs.stat(file)).mode & 0o777, 0o600);
  assert.deepEqual(await mergeClientConfig(file, config), { changed: false, backup: false });
  assert.equal((await fs.readdir(dir)).length, 2);
});

test('錯誤JSON或symlink設定不會被安裝器覆寫', async t => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'line-config-reject-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const file = path.join(dir, 'config.json');
  await fs.writeFile(file, '{invalid');
  await assert.rejects(mergeClientConfig(file, makeConfig('/tmp/synthetic')));
  assert.equal(await fs.readFile(file, 'utf8'), '{invalid');
  const link = path.join(dir, 'link.json');
  await fs.symlink(file, link);
  await assert.rejects(mergeClientConfig(link, makeConfig('/tmp/synthetic')));
  assert.equal(await fs.readFile(file, 'utf8'), '{invalid');
});
