import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { LineAutomation } from '../src/automation/line-automation.js';

const root = fileURLToPath(new URL('..', import.meta.url));

test('package、lock、manifest、CLI與協定來源版本一致', async () => {
  const pkg = JSON.parse(await fs.readFile(path.join(root, 'package.json'), 'utf8'));
  const lock = JSON.parse(await fs.readFile(path.join(root, 'package-lock.json'), 'utf8'));
  const manifest = JSON.parse(await fs.readFile(path.join(root, 'manifest.json'), 'utf8'));
  assert.equal(pkg.version, '1.2.0');
  assert.equal(lock.version, pkg.version);
  assert.equal(lock.packages[''].version, pkg.version);
  assert.equal(manifest.version, pkg.version);
  assert.equal(execFileSync(process.execPath, [path.join(root, 'src/server.js'), '--version'], { encoding: 'utf8' }).trim(), pkg.version);
  assert.deepEqual(manifest.compatibility.platforms, ['darwin']);
});

test('即使沿用舊log環境變數也不會把聊天正文寫檔', async t => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'line-privacy-fixture-'));
  const previous = { CHAT_LOG_ON: process.env.CHAT_LOG_ON, CHAT_LOG_PATH: process.env.CHAT_LOG_PATH };
  t.after(async () => {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
    await fs.rm(dir, { recursive: true, force: true });
  });
  process.env.CHAT_LOG_ON = 'true';
  process.env.CHAT_LOG_PATH = dir;
  const automation = new LineAutomation({ platform: 'darwin', automation: {
    async getChatHistoryResult() { return { history: 'SYNTHETIC_CONTENT', metadata: {} }; },
  } });
  assert.equal((await automation.getChatHistoryResult('Synthetic')).history, 'SYNTHETIC_CONTENT');
  assert.deepEqual(await fs.readdir(dir), []);
});
