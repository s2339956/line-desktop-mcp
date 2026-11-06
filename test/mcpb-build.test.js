import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { Writable } from 'node:stream';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { ZipArchive } from 'archiver';
import test from 'node:test';

const repositoryRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const builderUrl = pathToFileURL(join(repositoryRoot, 'scripts', 'build-mcpb.js')).href;
const temporaryRoots = [];

test.after(() => {
  for (const root of temporaryRoots) {
    rmSync(root, { recursive: true, force: true });
  }
});

function makeTempRoot(prefix) {
  const root = mkdtempSync(join(tmpdir(), prefix));
  temporaryRoots.push(root);
  return root;
}

function writeJson(path, value) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}

function hashFile(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

function createFixture() {
  const root = makeTempRoot('line-mcpb-fixture-');
  const manifest = {
    manifest_version: '0.2',
    name: 'line-desktop-mcp',
    version: '1.1.2',
    server: {
      type: 'node',
      entry_point: 'src/server.js',
      mcp_config: {
        command: 'node',
        args: ['${__dirname}/src/server.js'],
      },
    },
    tools_generated: true,
  };
  const packageJson = {
    name: 'line-desktop-mcp',
    version: '1.1.2',
    type: 'module',
    dependencies: { 'fixture-dependency': '1.0.0' },
    devDependencies: {},
  };
  const lock = {
    name: 'line-desktop-mcp',
    version: '1.1.2',
    lockfileVersion: 3,
    requires: true,
    packages: {
      '': {
        name: 'line-desktop-mcp',
        version: '1.1.2',
        dependencies: { 'fixture-dependency': '1.0.0' },
        devDependencies: {},
      },
      'node_modules/fixture-dependency': {
        version: '1.0.0',
      },
    },
  };

  writeJson(join(root, 'manifest.json'), manifest);
  writeJson(join(root, 'package.json'), packageJson);
  writeJson(join(root, 'package-lock.json'), lock);
  writeFileSync(join(root, 'README.md'), '# fixture\n');
  writeFileSync(join(root, 'LICENSE.md'), 'MIT\n');
  mkdirSync(join(root, 'docs', 'plans'), { recursive: true });
  writeFileSync(join(root, 'docs', 'macos-desktop-tools.md'), '# user guide\n');
  writeFileSync(join(root, 'docs', 'plans', 'private-plan.md'), 'PRIVATE_PLAN_CANARY\n');
  mkdirSync(join(root, 'src'), { recursive: true });
  writeFileSync(join(root, 'src', 'server.js'), 'export const fixture = true;\n');
  writeFileSync(join(root, 'src', 'dirty-canary.txt'), 'DO_NOT_CHANGE\n');
  writeFileSync(join(root, 'src', '.env.private'), 'PRIVATE_ENV_CANARY\n');
  writeFileSync(join(root, 'src', 'private.receipt.json'), 'PRIVATE_RECEIPT_CANARY\n');
  mkdirSync(join(root, 'scripts'), { recursive: true });
  writeFileSync(join(root, 'scripts', 'runtime.js'), 'PRIVATE_DIAGNOSTIC_CANARY\n');
  for (const entry of ['NOTICE.md', 'CHANGELOG.md', 'Install.command', 'scripts/setup-mac.mjs', 'scripts/check-install.mjs', 'scripts/doctor.mjs', 'scripts/maintenance.mjs', 'docs/AI-AGENTS.md', 'docs/TESTING.md', 'docs/SOURCE.md']) {
    writeFileSync(join(root, entry), '# synthetic fixture\n');
  }
  mkdirSync(join(root, 'node_modules', 'fixture-dependency'), { recursive: true });
  writeJson(join(root, 'node_modules', 'fixture-dependency', 'package.json'), {
    name: 'fixture-dependency',
    version: '1.0.0',
  });
  writeFileSync(join(root, 'node_modules', 'fixture-dependency', 'index.js'), 'module.exports = {};\n');
  mkdirSync(join(root, 'node_modules', '.bin'), { recursive: true });
  writeFileSync(join(root, 'node_modules', '.bin', 'fixture-bin'), 'excluded bin fixture\n');
  writeFileSync(join(root, 'LEDGER.md'), 'PRIVATE_LEDGER_CANARY\n');
  writeFileSync(join(root, '.line-ax-mode-trial'), 'PRIVATE_TRIAL_CANARY\n');

  return { root, manifest, packageJson, lock };
}

async function loadBuilder() {
  return import(builderUrl);
}

function zipEntries(outputFile) {
  return execFileSync('/usr/bin/unzip', ['-Z1', outputFile], { encoding: 'utf8' })
    .trim()
    .split('\n')
    .filter(Boolean);
}

test('manifest 使用包內 Node entry 並對齊版本', () => {
  const manifest = JSON.parse(readFileSync(join(repositoryRoot, 'manifest.json'), 'utf8'));
  const packageJson = JSON.parse(readFileSync(join(repositoryRoot, 'package.json'), 'utf8'));

  assert.equal(manifest.version, packageJson.version);
  assert.equal(manifest.server.entry_point, 'src/server.js');
  assert.deepEqual(manifest.server.mcp_config, {
    command: 'node',
    args: ['${__dirname}/src/server.js'],
  });
  assert.equal(manifest.tools_generated, true);
});

test('npm files 僅發布 runtime、script、manifest 與 macOS 使用指南', () => {
  const packageJson = JSON.parse(readFileSync(join(repositoryRoot, 'package.json'), 'utf8'));

  assert.ok(packageJson.files.includes('Install.command'));
  assert.ok(packageJson.files.includes('scripts/setup-mac.mjs'));
  assert.equal(packageJson.files.includes('scripts/**/*'), false);
  assert.equal(packageJson.private, true);
});

test('import builder 不會建包，fixture 建包採固定 allowlist 且不修改 source', async (t) => {
  const { root } = createFixture();
  const outputFile = join(root, 'fixture.mcpb');
  const rootArtifact = join(repositoryRoot, 'line-desktop-mcp.mcpb');
  const artifactBefore = lstatSync(rootArtifact, { throwIfNoEntry: false });
  const dirtyCanary = join(root, 'src', 'dirty-canary.txt');
  const dirtyHash = hashFile(dirtyCanary);
  const { buildMCPB } = await loadBuilder();

  assert.deepEqual(lstatSync(rootArtifact, { throwIfNoEntry: false }), artifactBefore);
  const result = await buildMCPB({ projectRoot: root, outputFile });

  assert.equal(result.outputFile, outputFile);
  assert.equal(result.fileCount, 20);
  assert.ok(result.size > 0);
  assert.equal(hashFile(dirtyCanary), dirtyHash);

  await t.test('ZIP entry 集合精確符合 allowlist', (zipTest) => {
    try {
      execFileSync('/usr/bin/unzip', ['-v'], { stdio: 'ignore' });
    } catch {
      zipTest.skip('目前平台沒有 /usr/bin/unzip');
      return;
    }
    const entries = zipEntries(outputFile);
    assert.deepEqual([...entries].sort(), [
      'LICENSE.md',
      'README.md',
      'docs/macos-desktop-tools.md',
      'manifest.json',
      'node_modules/fixture-dependency/index.js',
      'node_modules/fixture-dependency/package.json',
      'package-lock.json',
      'package.json',
      'NOTICE.md', 'CHANGELOG.md', 'Install.command',
      'scripts/setup-mac.mjs', 'scripts/check-install.mjs', 'scripts/doctor.mjs', 'scripts/maintenance.mjs',
      'docs/AI-AGENTS.md', 'docs/TESTING.md', 'docs/SOURCE.md',
      'src/dirty-canary.txt',
      'src/server.js',
    ].sort());
  });
});

test('preflight 在 zero-output 拒絕缺檔、版本、entry 與依賴漂移', async (t) => {
  const { buildMCPB } = await loadBuilder();
  const cases = [
    ['缺少必要檔', ({ root }) => unlinkSync(join(root, 'README.md')), /缺少必要檔案/],
    ['manifest 版本不符', ({ root, manifest }) => {
      manifest.version = '9.9.9';
      writeJson(join(root, 'manifest.json'), manifest);
    }, /版本不一致/],
    ['manifest entry 非本機路徑', ({ root, manifest }) => {
      manifest.server.mcp_config.command = 'npx';
      writeJson(join(root, 'manifest.json'), manifest);
    }, /本機 Node entry/],
    ['缺少相依套件', ({ root }) => rmSync(join(root, 'node_modules', 'fixture-dependency'), { recursive: true }), /缺少已鎖定套件/],
    ['相依套件版本不符', ({ root }) => {
      writeJson(join(root, 'node_modules', 'fixture-dependency', 'package.json'), {
        name: 'fixture-dependency',
        version: '2.0.0',
      });
    }, /套件版本不符/],
    ['lock root 漂移', ({ root, lock }) => {
      lock.packages[''].dependencies['fixture-dependency'] = '^1.0.0';
      writeJson(join(root, 'package-lock.json'), lock);
    }, /dependencies.*不一致/],
    ['lock 外套件', ({ root }) => {
      mkdirSync(join(root, 'node_modules', 'extra-package'));
      writeJson(join(root, 'node_modules', 'extra-package', 'package.json'), {
        name: 'extra-package',
        version: '1.0.0',
      });
    }, /lock 外套件/],
  ];

  for (const [name, mutate, expected] of cases) {
    await t.test(name, async () => {
      const fixture = createFixture();
      const outputFile = join(fixture.root, 'rejected.mcpb');
      mutate(fixture);

      await assert.rejects(buildMCPB({ projectRoot: fixture.root, outputFile }), expected);
      assert.equal(lstatSync(outputFile, { throwIfNoEntry: false }), undefined);
    });
  }
});

test('只有與目前平台不相容的 optional 套件可以缺少', async () => {
  const fixture = createFixture();
  const { buildMCPB } = await loadBuilder();
  const otherPlatform = process.platform === 'win32' ? 'darwin' : 'win32';
  fixture.lock.packages[`node_modules/${otherPlatform}-only`] = {
    version: '1.0.0',
    optional: true,
    os: [otherPlatform],
  };
  writeJson(join(fixture.root, 'package-lock.json'), fixture.lock);
  const outputFile = join(fixture.root, 'optional.mcpb');

  await buildMCPB({ projectRoot: fixture.root, outputFile });

  const applicable = createFixture();
  applicable.lock.packages['node_modules/current-platform'] = {
    version: '1.0.0',
    optional: true,
    os: [process.platform],
  };
  writeJson(join(applicable.root, 'package-lock.json'), applicable.lock);
  await assert.rejects(
    buildMCPB({ projectRoot: applicable.root, outputFile: join(applicable.root, 'rejected.mcpb') }),
    /缺少已鎖定套件/,
  );
});

test('preflight 拒絕 allowlist 內 symlink 與不安全 ZIP 路徑', async (t) => {
  const { buildMCPB } = await loadBuilder();

  await t.test('symlink', async (symlinkTest) => {
    const fixture = createFixture();
    try {
      symlinkSync('server.js', join(fixture.root, 'src', 'server-link.js'));
    } catch (error) {
      if (['EPERM', 'EACCES', 'ENOTSUP'].includes(error.code)) {
        symlinkTest.skip(`目前平台不能建立 symlink：${error.code}`);
        return;
      }
      throw error;
    }
    const outputFile = join(fixture.root, 'rejected.mcpb');
    await assert.rejects(buildMCPB({ projectRoot: fixture.root, outputFile }), /不允許 symlink/);
    assert.equal(lstatSync(outputFile, { throwIfNoEntry: false }), undefined);
  });

  await t.test('反斜線路徑', async (pathTest) => {
    if (process.platform === 'win32') {
      pathTest.skip('Windows 將反斜線解讀為路徑分隔符');
      return;
    }
    const fixture = createFixture();
    writeFileSync(join(fixture.root, 'src', 'unsafe\\name.js'), 'export {};\n');
    const outputFile = join(fixture.root, 'rejected.mcpb');
    await assert.rejects(buildMCPB({ projectRoot: fixture.root, outputFile }), /不安全 ZIP 路徑/);
    assert.equal(lstatSync(outputFile, { throwIfNoEntry: false }), undefined);
  });
});

test('JSON trust boundary 在讀取前拒絕 symlink 且保持 zero-output', async (t) => {
  const { buildMCPB } = await loadBuilder();
  const cases = [
    ['manifest.json', ({ root }) => join(root, 'manifest.json')],
    ['package-lock.json', ({ root }) => join(root, 'package-lock.json')],
    ['dependency package.json', ({ root }) => join(root, 'node_modules', 'fixture-dependency', 'package.json')],
  ];

  for (const [name, targetPath] of cases) {
    await t.test(name, async (symlinkTest) => {
      const fixture = createFixture();
      const privateCanary = join(fixture.root, `private-${name.replaceAll(/[^a-z]/gi, '-')}.txt`);
      const linkPath = targetPath(fixture);
      writeFileSync(privateCanary, 'PRIVATE_CANARY_MUST_NOT_BE_PARSED');
      unlinkSync(linkPath);
      try {
        symlinkSync(privateCanary, linkPath);
      } catch (error) {
        if (['EPERM', 'EACCES', 'ENOTSUP'].includes(error.code)) {
          symlinkTest.skip(`目前平台不能建立 symlink：${error.code}`);
          return;
        }
        throw error;
      }
      const outputFile = join(fixture.root, 'rejected.mcpb');

      await assert.rejects(buildMCPB({ projectRoot: fixture.root, outputFile }), /不允許 symlink/);
      assert.equal(lstatSync(outputFile, { throwIfNoEntry: false }), undefined);
    });
  }
});

test('既有 output 採 exclusive 建立且 sentinel 不變', async () => {
  const fixture = createFixture();
  const { buildMCPB } = await loadBuilder();
  const outputFile = join(fixture.root, 'existing.mcpb');
  writeFileSync(outputFile, 'KEEP_EXISTING_OUTPUT');

  await assert.rejects(buildMCPB({ projectRoot: fixture.root, outputFile }), /已存在/);
  assert.equal(readFileSync(outputFile, 'utf8'), 'KEEP_EXISTING_OUTPUT');
});

test('archive fault 只呼叫 factory 一次、清 partial 且不修改 source', async () => {
  const fixture = createFixture();
  const { buildMCPB } = await loadBuilder();
  const outputFile = join(fixture.root, 'archive-fault.mcpb');
  const dirtyCanary = join(fixture.root, 'src', 'dirty-canary.txt');
  const dirtyHash = hashFile(dirtyCanary);
  let factoryCalls = 0;

  await assert.rejects(buildMCPB({
    projectRoot: fixture.root,
    outputFile,
    archiveFactory: () => {
      factoryCalls += 1;
      const archive = new ZipArchive();
      archive.finalize = async () => {
        archive.emit('error', new Error('ARCHIVE_FAULT'));
      };
      return archive;
    },
  }), /ARCHIVE_FAULT/);

  assert.equal(factoryCalls, 1);
  assert.equal(lstatSync(outputFile, { throwIfNoEntry: false }), undefined);
  assert.equal(hashFile(dirtyCanary), dirtyHash);
});

test('output stream fault 清除同 inode partial 且不重試', async () => {
  const fixture = createFixture();
  const { buildMCPB } = await loadBuilder();
  const outputFile = join(fixture.root, 'stream-fault.mcpb');
  let factoryCalls = 0;

  await assert.rejects(buildMCPB({
    projectRoot: fixture.root,
    outputFile,
    outputFactory: () => {
      factoryCalls += 1;
      return new Writable({
        write(_chunk, _encoding, callback) {
          callback(new Error('OUTPUT_FAULT'));
        },
      });
    },
  }), /OUTPUT_FAULT/);

  assert.equal(factoryCalls, 1);
  assert.equal(lstatSync(outputFile, { throwIfNoEntry: false }), undefined);
});

test('output 路徑被替換時不刪除新 sentinel', async () => {
  const fixture = createFixture();
  const { buildMCPB } = await loadBuilder();
  const outputFile = join(fixture.root, 'replaced-output.mcpb');

  await assert.rejects(buildMCPB({
    projectRoot: fixture.root,
    outputFile,
    outputFactory: () => {
      unlinkSync(outputFile);
      writeFileSync(outputFile, 'KEEP_REPLACEMENT_SENTINEL');
      return new Writable({
        write(_chunk, _encoding, callback) {
          callback(new Error('REPLACED_OUTPUT_FAULT'));
        },
      });
    },
  }), /REPLACED_OUTPUT_FAULT/);

  assert.equal(readFileSync(outputFile, 'utf8'), 'KEEP_REPLACEMENT_SENTINEL');
});
