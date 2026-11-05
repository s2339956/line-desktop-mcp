import os from 'node:os';
import fs from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { AutomationError } from './automation-error.js';

const execute = promisify(execFile);
export const indexedProfile = Object.freeze({ version: '26.4.2', build: '3955' });

export function capabilitiesFor({ platform, nodeVersion, systemVersion, lineVersion, lineBuild }) {
  const supported = platform === 'darwin' && Number(nodeVersion.split('.')[0]) >= 22 &&
    Number(String(systemVersion ?? '0').split('.')[0]) >= 14;
  const indexed = supported && lineVersion === indexedProfile.version && lineBuild === indexedProfile.build;
  return { runtimeSupported: supported, indexedUI: indexed,
    features: { status: supported, imageSend: indexed, indexedSearch: indexed,
      tabAutomation: supported ? 'requires_live_layout_check' : false },
    expectedIndexedProfile: indexedProfile,
    reasons: [...(!supported ? ['RUNTIME_UNSUPPORTED'] : []), ...(!indexed ? ['INDEXED_UI_PROFILE_UNAVAILABLE'] : [])] };
}

export async function doctor({ bridge, probeNative = false, run = execute, fileSystem = fs,
  platform = process.platform, nodeVersion = process.versions.node, systemVersion = os.release() } = {}) {
  if (typeof probeNative !== 'boolean') throw new AutomationError('INVALID_ARGUMENT', 'probeNative須為boolean');
  const checks = {};
  let macVersion = platform === 'darwin' ? null : systemVersion, lineVersion = null, lineBuild = null;
  if (platform === 'darwin') {
    try { macVersion = (await run('/usr/bin/sw_vers', ['-productVersion'], { timeout: 5000 })).stdout.trim(); } catch {}
    for (const [key, target] of [['CFBundleShortVersionString', 'version'], ['CFBundleVersion', 'build']]) {
      try {
        const result = await run('/usr/bin/plutil', ['-extract', key, 'raw', '-o', '-', '/Applications/LINE.app/Contents/Info.plist'], { timeout: 5000 });
        if (target === 'version') lineVersion = result.stdout.trim(); else lineBuild = result.stdout.trim();
      } catch {}
    }
    try { await run('/usr/bin/xcrun', ['--find', 'swiftc'], { timeout: 5000 }); checks.compiler = 'available'; }
    catch { checks.compiler = 'missing'; }
  } else checks.compiler = 'unsupported_platform';
  let cached = false;
  if (bridge && platform === 'darwin') {
    try {
      const digest = await bridge.journalSourceDigest();
      await fileSystem.access(`${bridge.cacheDir}/line-desktop-native-${digest}`);
      cached = true;
    } catch {}
  }
  checks.nativeCache = cached ? 'available' : 'not_prepared';
  if (probeNative && bridge) {
    try {
      const result = await bridge.call('diagnostics');
      checks.native = Object.fromEntries(['checked', 'accessibilityTrusted', 'screenCaptureTrusted', 'lineRunning']
        .map(key => [key, result[key] === true]));
      if (checks.native.checked) { cached = true; checks.nativeCache = 'available'; }
    }
    catch (error) { checks.native = { checked: false, reason: /^[A-Z0-9_]+$/.test(error.code ?? '') ? error.code : 'PROBE_FAILED' }; }
  } else checks.native = { checked: false, reason: 'NATIVE_PROBE_NOT_REQUESTED' };
  const compatibility = capabilitiesFor({ platform, nodeVersion, systemVersion: macVersion, lineVersion, lineBuild });
  return { platform, nodeVersion, macOSVersion: macVersion, line: { version: lineVersion, build: lineBuild },
    compatibility,
    checks, uiReadinessConfirmed: compatibility.runtimeSupported && checks.native?.accessibilityTrusted === true &&
      checks.native?.screenCaptureTrusted === true && checks.native?.lineRunning === true,
    recommendations: [...(checks.compiler === 'missing' ? ['INSTALL_XCODE_COMMAND_LINE_TOOLS'] : []),
      ...(!cached ? ['RUN_MAC_SETUP_TO_PRECOMPILE'] : []),
      ...(!probeNative ? ['RUN_DOCTOR_WITH_NATIVE_PROBE_FOR_PERMISSION_CHECKS'] : [])],
    inputAttempted: false, contentRead: false };
}
