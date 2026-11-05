#!/usr/bin/env node
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import crypto from 'node:crypto';
import { buildMCPB } from './build-mcpb.js';

const root = fileURLToPath(new URL('..', import.meta.url));
const { version } = JSON.parse(await fs.readFile(path.join(root, 'package.json'), 'utf8'));
const directory = path.join(root, 'dist');
await fs.mkdir(directory, { recursive: true });
const base = `line-desktop-mcp-${version}-macos`;
const bundle = path.join(directory, `${base}.mcpb`);
await buildMCPB({ outputFile: bundle });
// MCPB本身為ZIP；相同位元組提供.zip，讓一般MCP client也能使用雙擊安裝入口。
await fs.copyFile(bundle, path.join(directory, `${base}.zip`), fs.constants.COPYFILE_EXCL);
const sums = [];
for (const suffix of ['mcpb', 'zip']) {
  const filename = `${base}.${suffix}`;
  const hash = crypto.createHash('sha256').update(await fs.readFile(path.join(directory, filename))).digest('hex');
  sums.push(`${hash}  ${filename}`);
}
await fs.writeFile(path.join(directory, 'SHA256SUMS'), sums.join('\n') + '\n', { flag: 'wx' });
console.log(`已建立v${version}的MCPB、macOS ZIP與SHA256SUMS。`);
