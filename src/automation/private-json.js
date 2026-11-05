import fs from 'node:fs/promises';
import { constants } from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { AutomationError } from './automation-error.js';

// 所有呼叫者須先取得同一用途的操作鎖（UI或本機索引）；檔名只由程式產生，不接受任意使用者路徑。
export async function readPrivateJSON(file, maximum = 1024 * 1024) {
  let handle;
  try {
    handle = await fs.open(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const stat = await handle.stat();
    if (!stat.isFile() || stat.nlink !== 1 || stat.uid !== process.getuid() ||
        (stat.mode & 0o777) !== 0o600 || stat.size < 1 || stat.size > maximum) {
      throw new AutomationError('LOCAL_RECORD_UNSAFE', '本機紀錄型態、權限或大小不符');
    }
    const buffer = Buffer.alloc(stat.size + 1);
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
    if (bytesRead !== stat.size) throw new AutomationError('LOCAL_RECORD_CHANGED', '本機紀錄讀取期間變更');
    const raw = buffer.subarray(0, bytesRead);
    return { value: JSON.parse(raw.toString('utf8')), raw };
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    if (error instanceof SyntaxError) throw new AutomationError('LOCAL_RECORD_INVALID', '本機紀錄格式錯誤');
    throw error;
  } finally { await handle?.close(); }
}

export async function privateDirectory(directory) {
  await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  const stat = await fs.lstat(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid()) {
    throw new AutomationError('LOCAL_RECORD_UNSAFE', '本機資料夾歸屬不符');
  }
  await fs.chmod(directory, 0o700);
}

export async function syncDirectory(directory) {
  const handle = await fs.open(directory, constants.O_RDONLY);
  try { await handle.sync(); } finally { await handle.close(); }
}

export async function writePrivateJSON(file, value) {
  const directory = path.dirname(file);
  await privateDirectory(directory);
  // 既有檔案必須同樣通過安全讀取，不能藉rename覆蓋未知紀錄或symlink。
  await readPrivateJSON(file);
  const temporary = `${file}.${randomUUID()}.tmp`;
  const handle = await fs.open(temporary, 'wx', 0o600);
  try {
    try {
      await handle.writeFile(JSON.stringify(value) + '\n');
      await handle.sync();
    } finally { await handle.close(); }
    await fs.rename(temporary, file);
    await syncDirectory(directory);
  } finally { await fs.rm(temporary, { force: true }); }
}
