import path from 'node:path';

const clone = (value) => JSON.parse(JSON.stringify(value));

export const syntheticValidLINEWindow = Object.freeze({
  pid: 4321,
  windowId: 9876,
  title: 'LINE',
  bounds: Object.freeze({ x: 100, y: 80, width: 969, height: 650 }),
  bundleIdentifier: 'jp.naver.line.mac',
  executableURL: '/Applications/LINE.app/Contents/MacOS/LINE',
  signingIdentifier: 'jp.naver.line.mac',
  teamIdentifier: 'VUTU7AKEUR',
});

export function globalNavigationReceipt(request, overrides = {}) {
  return {
    route: 'line-hid-all-v1',
    requestNonce: request.requestNonce,
    scope: { kind: 'all-navigation', chatName: request.chatName },
    expectedWindow: clone(request.expectedWindow),
    mainWindow: clone(request.expectedWindow),
    allSelected: true,
    inputAttempted: false,
    eventCounts: { move: 0, down: 0, up: 0 },
    systemEventsInvocations: 0,
    phase: 'verified',
    identityVerified: true,
    ...clone(overrides),
  };
}

export function memoryJournalFS({ failAt = null } = {}) {
  const files = new Map();
  const directories = new Set(['/']);
  const operations = [];
  const failures = new Set(Array.isArray(failAt) ? failAt : failAt ? [failAt] : []);

  const fail = (operation) => {
    operations.push(operation);
    if (!failures.delete(operation)) return;
    const error = new Error(`synthetic ${operation} failure`);
    error.code = 'EIO';
    throw error;
  };
  const missing = (target) => {
    const error = new Error(`missing: ${target}`);
    error.code = 'ENOENT';
    return error;
  };

  const api = {
    files,
    directories,
    operations,
    failures,
    async mkdir(target) {
      fail('mkdir');
      let current = path.resolve(target);
      while (!directories.has(current)) {
        directories.add(current);
        const parent = path.dirname(current);
        if (parent === current) break;
        current = parent;
      }
    },
    async open(target, flags, mode) {
      if (flags === 'r') {
        fail('dir-open');
        if (!directories.has(target)) throw missing(target);
        let closed = false;
        return {
          async sync() {
            if (closed) throw new Error('directory handle already closed');
            fail('dirsync');
          },
          async close() {
            fail('dir-close');
            closed = true;
          },
        };
      }

      fail('open');
      if (flags !== 'wx') throw new Error(`unsupported synthetic flags: ${flags}`);
      if (files.has(target)) {
        const error = new Error(`exists: ${target}`);
        error.code = 'EEXIST';
        throw error;
      }
      files.set(target, { bytes: Buffer.alloc(0), mode });
      let closed = false;
      return {
        async writeFile(value) {
          if (closed) throw new Error('file handle already closed');
          fail('write');
          files.get(target).bytes = Buffer.from(value);
        },
        async sync() {
          if (closed) throw new Error('file handle already closed');
          fail('sync');
        },
        async close() {
          fail('close');
          closed = true;
        },
      };
    },
    async access(target) {
      fail('access');
      if (!files.has(target)) throw missing(target);
    },
    async lstat(target) {
      fail('stat');
      if (directories.has(target)) {
        return {
          size: 0,
          uid: typeof process.getuid === 'function' ? process.getuid() : 0,
          mode: 0o040700,
          isFile: () => false,
          isDirectory: () => true,
          isSymbolicLink: () => false,
        };
      }
      const file = files.get(target);
      if (!file) throw missing(target);
      return {
        size: file.bytes.length,
        uid: typeof process.getuid === 'function' ? process.getuid() : 0,
        mode: 0o100000 | file.mode,
        isFile: () => true,
        isDirectory: () => false,
        isSymbolicLink: () => false,
      };
    },
    async stat(target) {
      return api.lstat(target);
    },
    async readFile(target, encoding) {
      fail('read');
      const file = files.get(target);
      if (!file) throw missing(target);
      return encoding ? file.bytes.toString(encoding) : Buffer.from(file.bytes);
    },
    async unlink(target) {
      fail('unlink');
      if (!files.delete(target)) throw missing(target);
    },
    async rename(from, to) {
      fail('rename');
      const file = files.get(from);
      if (!file) throw missing(from);
      files.set(to, file);
      files.delete(from);
    },
    async chmod(target, mode) {
      fail('chmod');
      const file = files.get(target);
      if (!file) throw missing(target);
      file.mode = mode;
    },
    async rm(target) {
      fail('rm');
      files.delete(target);
    },
    readJson(target) {
      const file = files.get(target);
      if (!file) throw missing(target);
      return JSON.parse(file.bytes.toString('utf8'));
    },
  };
  return api;
}
