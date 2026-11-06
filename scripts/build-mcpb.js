#!/usr/bin/env node

import { lstat, open, readFile, readdir, unlink } from 'node:fs/promises';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { finished } from 'node:stream/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { ZipArchive } from 'archiver';

const DEFAULT_PROJECT_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const ROOT_FILES = [
  'manifest.json',
  'package.json',
  'package-lock.json',
  'README.md',
  'LICENSE.md',
  'docs/macos-desktop-tools.md',
  'NOTICE.md', 'CHANGELOG.md', 'Install.command',
  'scripts/setup-mac.mjs', 'scripts/check-install.mjs', 'scripts/doctor.mjs', 'scripts/maintenance.mjs',
  'docs/AI-AGENTS.md', 'docs/TESTING.md', 'docs/SOURCE.md',
];
// 發行包只保留安裝所需腳本；測試、實機驗收和診斷工具均不封裝。
const ROOT_DIRECTORIES = ['src', 'node_modules'];
const MAX_BUNDLE_BYTES = 100 * 1024 * 1024;

function parseJson(text, label) {
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`${label} 不是有效 JSON：${error.message}`);
  }
}

function normalizedRecord(value) {
  if (!value) return {};
  return Object.fromEntries(Object.entries(value).sort(([left], [right]) => left.localeCompare(right)));
}

function assertSameRecord(actual, expected, label) {
  if (JSON.stringify(normalizedRecord(actual)) !== JSON.stringify(normalizedRecord(expected))) {
    throw new Error(`package.json 與 package-lock root 的 ${label} 不一致`);
  }
}

function assertSafeZipEntry(entry) {
  const parts = entry.split('/');
  if (isAbsolute(entry) || entry.includes('\\') || parts.some((part) => part === '..' || part === '.')) {
    throw new Error(`不安全 ZIP 路徑：${entry}`);
  }
}

function isExcluded(entry) {
  const parts = entry.split('/');
  const basename = parts.at(-1);

  // 封裝採 allowlist 後仍明確排除測試、收據與本機狀態，避免私密開發資料混入交付物。
  return parts.some((part) => ['.git', '.cache', '.DS_Store', 'test', 'tests', '__tests__'].includes(part))
    || (parts.includes('node_modules') && parts.includes('.bin'))
    || basename === 'LEDGER.md'
    || basename === '.line-ax-mode-trial'
    || basename.startsWith('.env')
    || basename.endsWith('.log')
    || basename.endsWith('.mcpb')
    || /(^|[._-])receipts?([._-]|$)/i.test(basename);
}

async function readRequiredJson(projectRoot, entry) {
  const path = join(projectRoot, entry);
  let entryStat;
  try {
    entryStat = await lstat(path);
  } catch (error) {
    if (error.code === 'ENOENT') throw new Error(`缺少必要檔案：${entry}`);
    throw error;
  }
  if (entryStat.isSymbolicLink()) throw new Error(`不允許 symlink：${entry}`);
  if (!entryStat.isFile()) throw new Error(`必要 JSON 必須是 regular file：${entry}`);

  let text;
  try {
    text = await readFile(path, 'utf8');
  } catch (error) {
    if (error.code === 'ENOENT') throw new Error(`缺少必要檔案：${entry}`);
    throw error;
  }
  return parseJson(text, entry);
}

function matchesPlatformConstraint(values, current) {
  if (!Array.isArray(values) || values.length === 0) return true;
  const denied = values.filter((value) => value.startsWith('!')).map((value) => value.slice(1));
  const allowed = values.filter((value) => !value.startsWith('!'));
  return !denied.includes(current) && (allowed.length === 0 || allowed.includes(current));
}

function mayOmitOptionalPackage(lockEntry) {
  return lockEntry.optional === true
    && (!matchesPlatformConstraint(lockEntry.os, process.platform)
      || !matchesPlatformConstraint(lockEntry.cpu, process.arch));
}

async function scanInstalledPackage(packagePath, lockPath, actualPackages) {
  const packageStat = await lstat(packagePath);
  if (packageStat.isSymbolicLink()) throw new Error(`不允許 symlink：${lockPath}`);
  if (!packageStat.isDirectory()) throw new Error(`套件路徑不是目錄：${lockPath}`);

  const packageJsonPath = join(packagePath, 'package.json');
  let packageJson;
  try {
    const packageJsonStat = await lstat(packageJsonPath);
    if (packageJsonStat.isSymbolicLink()) throw new Error(`不允許 symlink：${lockPath}/package.json`);
    if (!packageJsonStat.isFile()) throw new Error(`套件 package.json 必須是 regular file：${lockPath}`);
    packageJson = parseJson(await readFile(packageJsonPath, 'utf8'), `${lockPath}/package.json`);
  } catch (error) {
    if (error.code === 'ENOENT') throw new Error(`lock 外套件或缺少 package.json：${lockPath}`);
    throw error;
  }
  if (typeof packageJson.version !== 'string') throw new Error(`套件缺少版本：${lockPath}`);
  actualPackages.set(lockPath, packageJson.version);

  const nestedNodeModules = join(packagePath, 'node_modules');
  try {
    await scanNodeModules(nestedNodeModules, `${lockPath}/node_modules`, actualPackages);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
}

async function scanNodeModules(nodeModulesPath, lockPrefix, actualPackages) {
  const directoryStat = await lstat(nodeModulesPath);
  if (directoryStat.isSymbolicLink()) throw new Error(`不允許 symlink：${lockPrefix}`);
  if (!directoryStat.isDirectory()) throw new Error(`node_modules 路徑不是目錄：${lockPrefix}`);

  const entries = (await readdir(nodeModulesPath)).sort();
  for (const name of entries) {
    if (name === '.bin' || name.startsWith('.')) continue;
    const entryPath = join(nodeModulesPath, name);
    if (name.startsWith('@')) {
      const scopeStat = await lstat(entryPath);
      if (scopeStat.isSymbolicLink()) throw new Error(`不允許 symlink：${lockPrefix}/${name}`);
      if (!scopeStat.isDirectory()) throw new Error(`套件 scope 不是目錄：${lockPrefix}/${name}`);
      for (const packageName of (await readdir(entryPath)).sort()) {
        await scanInstalledPackage(
          join(entryPath, packageName),
          `${lockPrefix}/${name}/${packageName}`,
          actualPackages,
        );
      }
      continue;
    }
    await scanInstalledPackage(entryPath, `${lockPrefix}/${name}`, actualPackages);
  }
}

async function validateDependencyTree(projectRoot, packageJson, packageLock) {
  if (packageLock.lockfileVersion !== 3 || !packageLock.packages || !packageLock.packages['']) {
    throw new Error('package-lock.json 必須提供 lockfileVersion 3 的完整 packages map');
  }
  const lockRoot = packageLock.packages[''];
  if (lockRoot.name !== packageJson.name || lockRoot.version !== packageJson.version) {
    throw new Error('package.json 與 package-lock root 的名稱或版本不一致');
  }
  assertSameRecord(packageJson.dependencies, lockRoot.dependencies, 'dependencies');
  assertSameRecord(packageJson.devDependencies, lockRoot.devDependencies, 'devDependencies');

  // 同時核對完整 lock 路徑與實際樹，不能只驗 root 直接相依而漏掉傳遞套件漂移。
  const actualPackages = new Map();
  await scanNodeModules(join(projectRoot, 'node_modules'), 'node_modules', actualPackages);
  const lockedPackages = new Map();

  for (const [lockPath, lockEntry] of Object.entries(packageLock.packages).sort(([a], [b]) => a.localeCompare(b))) {
    if (lockPath === '') continue;
    assertSafeZipEntry(lockPath);
    if (!lockPath.startsWith('node_modules/') || lockEntry.link === true) {
      throw new Error(`不支援的 lock package 路徑：${lockPath}`);
    }
    if (typeof lockEntry.version !== 'string') throw new Error(`lock package 缺少版本：${lockPath}`);
    lockedPackages.set(lockPath, lockEntry);
  }

  for (const [lockPath, lockEntry] of lockedPackages) {
    const actualVersion = actualPackages.get(lockPath);
    if (actualVersion === undefined) {
      if (mayOmitOptionalPackage(lockEntry)) continue;
      throw new Error(`缺少已鎖定套件：${lockPath}@${lockEntry.version}`);
    }
    if (actualVersion !== lockEntry.version) {
      throw new Error(`套件版本不符：${lockPath}，lock=${lockEntry.version}，installed=${actualVersion}`);
    }
  }

  for (const [lockPath, actualVersion] of actualPackages) {
    if (!lockedPackages.has(lockPath)) throw new Error(`發現 lock 外套件：${lockPath}@${actualVersion}`);
  }
}

async function validateManifest(projectRoot, manifest, packageJson) {
  if (manifest.version !== packageJson.version) {
    throw new Error(`manifest 與 package 版本不一致：${manifest.version} !== ${packageJson.version}`);
  }
  const expectedEntry = 'src/server.js';
  const expectedConfig = JSON.stringify({ command: 'node', args: ['${__dirname}/src/server.js'] });
  if (manifest.server?.type !== 'node'
    || manifest.server?.entry_point !== expectedEntry
    || JSON.stringify(manifest.server?.mcp_config) !== expectedConfig) {
    throw new Error('manifest 必須使用包內本機 Node entry');
  }
  if (manifest.tools_generated !== true) throw new Error('manifest.tools_generated 必須為 true');

  let entryStat;
  try {
    entryStat = await lstat(join(projectRoot, expectedEntry));
  } catch (error) {
    if (error.code === 'ENOENT') throw new Error(`缺少必要檔案：${expectedEntry}`);
    throw error;
  }
  if (!entryStat.isFile() || entryStat.isSymbolicLink()) {
    throw new Error(`本機 Node entry 必須是 regular file：${expectedEntry}`);
  }
}

async function collectEntry(projectRoot, entry, collected) {
  assertSafeZipEntry(entry);
  let entryStat;
  try {
    entryStat = await lstat(join(projectRoot, entry));
  } catch (error) {
    if (error.code === 'ENOENT') throw new Error(`缺少必要檔案或目錄：${entry}`);
    throw error;
  }

  if (entryStat.isSymbolicLink()) throw new Error(`不允許 symlink：${entry}`);
  if (isExcluded(entry)) return;
  if (entryStat.isDirectory()) {
    for (const name of (await readdir(join(projectRoot, entry))).sort()) {
      await collectEntry(projectRoot, `${entry}/${name}`, collected);
    }
    return;
  }
  if (!entryStat.isFile()) throw new Error(`只允許 regular file：${entry}`);
  collected.push(entry);
}

async function collectBundleFiles(projectRoot) {
  const collected = [];
  for (const entry of ROOT_FILES) await collectEntry(projectRoot, entry, collected);
  for (const entry of ROOT_DIRECTORIES) await collectEntry(projectRoot, entry, collected);
  return collected.sort();
}

async function preflight(projectRoot) {
  const packageJson = await readRequiredJson(projectRoot, 'package.json');
  const packageLock = await readRequiredJson(projectRoot, 'package-lock.json');
  const manifest = await readRequiredJson(projectRoot, 'manifest.json');

  await validateManifest(projectRoot, manifest, packageJson);
  await validateDependencyTree(projectRoot, packageJson, packageLock);
  return collectBundleFiles(projectRoot);
}

async function removeOwnedPartial(outputFile, fingerprint) {
  if (!fingerprint) return;
  let current;
  try {
    current = await lstat(outputFile);
  } catch (error) {
    if (error.code === 'ENOENT') return;
    throw error;
  }
  // 只清理由本次 exclusive open 建立的 inode；路徑遭替換時保留新檔供呼叫端判斷。
  if (current.isFile() && !current.isSymbolicLink()
    && current.dev === fingerprint.dev && current.ino === fingerprint.ino) {
    await unlink(outputFile);
  }
}

async function closeOutput(output, fileHandle) {
  if (output && !output.destroyed) output.destroy();
  if (output) await finished(output).catch(() => {});
  if (fileHandle) await fileHandle.close().catch(() => {});
}

export async function buildMCPB(options = {}) {
  const projectRoot = resolve(options.projectRoot ?? DEFAULT_PROJECT_ROOT);
  const outputFile = resolve(options.outputFile ?? join(projectRoot, 'line-desktop-mcp.mcpb'));
  const archiveFactory = options.archiveFactory ?? (() => new ZipArchive({ zlib: { level: 9 } }));
  const outputFactory = options.outputFactory ?? (({ fileHandle }) => fileHandle.createWriteStream());
  // 所有來源與依賴驗證必須在建立 output 前完成，失敗時才能保證 zero-output。
  const files = await preflight(projectRoot);
  let fileHandle;
  let fingerprint;
  let archive;
  let output;

  try {
    try {
      fileHandle = await open(outputFile, 'wx', 0o600);
    } catch (error) {
      if (error.code === 'EEXIST') throw new Error(`output 已存在，拒絕覆寫：${outputFile}`);
      throw error;
    }
    const openedStat = await fileHandle.stat();
    fingerprint = { dev: openedStat.dev, ino: openedStat.ino };
    archive = archiveFactory();
    output = outputFactory({ fileHandle, outputFile });

    const archiveFailure = new Promise((_, reject) => {
      archive.once('error', reject);
      archive.once('warning', reject);
    });
    archive.pipe(output);
    for (const entry of files) {
      archive.file(join(projectRoot, ...entry.split('/')), { name: entry, mode: entry === 'Install.command' ? 0o755 : 0o644 });
    }

    const outputCompletion = finished(output);
    const completion = Promise.all([
      Promise.resolve().then(() => archive.finalize()),
      outputCompletion,
    ]);
    await Promise.race([completion, archiveFailure]);
    await fileHandle.close().catch(() => {});
    fileHandle = undefined;

    const outputStat = await lstat(outputFile);
    if (!outputStat.isFile() || outputStat.isSymbolicLink()
      || outputStat.dev !== fingerprint.dev || outputStat.ino !== fingerprint.ino) {
      throw new Error('output 路徑在建置期間被替換');
    }
    if (outputStat.size > MAX_BUNDLE_BYTES) {
      throw new Error(`bundle 超過 100 MiB 上限：${outputStat.size} bytes`);
    }
    return { outputFile, size: outputStat.size, fileCount: files.length };
  } catch (error) {
    if (archive && typeof archive.abort === 'function') archive.abort();
    await closeOutput(output, fileHandle);
    await removeOwnedPartial(outputFile, fingerprint);
    throw error;
  }
}

const invokedUrl = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : undefined;
if (invokedUrl === import.meta.url) {
  buildMCPB()
    .then(({ outputFile, size, fileCount }) => {
      console.log(`Bundle created: ${outputFile}`);
      console.log(`Files: ${fileCount}; bytes: ${size}`);
    })
    .catch((error) => {
      console.error(`Build failed: ${error.message}`);
      process.exitCode = 1;
    });
}
