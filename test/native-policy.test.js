import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { MacOSDesktopAutomation } from '../src/automation/desktop-automation.js';
import {
  globalNavigationReceipt,
  memoryJournalFS,
  syntheticValidLINEWindow,
} from './fixtures/global-navigation-fixtures.mjs';

const source = fileURLToPath(new URL('../src/automation/line-desktop-native.swift', import.meta.url));

function run(binary, request) {
  const result = spawnSync(binary, [], {
    input: JSON.stringify(request),
    encoding: 'utf8',
    timeout: 10_000,
    env: { ...process.env, LINE_MCP_DISABLE_NATIVE: '1', LINE_NATIVE_DISABLE_UI: '1' },
  });
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}

test('native 純策略涵蓋幾何、OCR、overlay、同名列與 live scope 零事件', {
  skip: process.platform !== 'darwin',
}, async (t) => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'line-native-policy-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const binary = path.join(directory, 'line-desktop-native');
  const moduleCache = path.join(directory, 'module-cache');
  await fs.mkdir(moduleCache);
  const architecture = process.arch === 'arm64' ? 'arm64' : 'x86_64';
  const compile = spawnSync('/usr/bin/swiftc', [
    source, '-target', `${architecture}-apple-macosx14.0`, '-O', '-o', binary,
  ], {
    encoding: 'utf8',
    timeout: 120_000,
    env: {
      ...process.env,
      CLANG_MODULE_CACHE_PATH: moduleCache,
      SWIFT_MODULECACHE_PATH: moduleCache,
    },
  });
  assert.equal(compile.status, 0, compile.stderr);

  const selfTest = run(binary, { name: 'selfTest', args: {} });
  assert.equal(selfTest.ok, true);
  assert.equal(selfTest.result.passed, true);
  assert.deepEqual(Object.keys(selfTest.result.checks).sort(), [
    'ax-semantic-calibration-gate',
    'ax-semantic-cf-order-drift',
    'ax-semantic-invalid-present-rejected',
    'ax-semantic-mixed-name-state',
    'ax-semantic-role-drift',
    'ax-semantic-state-drift',
    'ax-semantic-state-types',
    'ax-semantic-string-types',
    'ax-semantic-twofresh-stable',
    'badge-baseline-emoji-rejected',
    'badge-large-component-rejected',
    'badge-nonround-component-rejected',
    'badge-row-origin-roundtrip',
    'badge-small-top-circle-eligible',
    'freshmodel-complete-six',
    'freshmodel-consumer-cf-order',
    'freshmodel-consumer-count-flags',
    'freshmodel-consumer-index-frame',
    'freshmodel-consumer-missing-row',
    'freshmodel-count-bounds',
    'freshmodel-deadline-rejected',
    'freshmodel-duplicate-id-rejected',
    'freshmodel-grid-rejected',
    'freshmodel-index-rejected',
    'freshmodel-role-rejected',
    'freshmodel-second-cf-order-drift',
    'freshmodel-second-foreign-cf',
    'freshmodel-second-frame-drift',
    'freshmodel-second-index-drift',
    'freshmodel-second-order-drift',
    'freshmodel-single-row',
    'freshmodel-window-list-rejected',
    'image-send-dimension-budget',
    'image-send-exact-args',
    'image-send-invalid-args',
    'image-sheet-owned-chain',
    'image-sheet-duplicate-foreign-denied',
    'image-sheet-background-control-denied',
    'image-goto-selected-path-ready',
    'image-goto-unready-foreign-denied',
    'image-selection-transient-waits-without-input',
    'image-selection-drift-no-retry',
    'image-selection-probe-budget-bounded',
    'geometry-1x-negative-roi-origin',
    'geometry-2x-roundtrip',
    'geometry-drift-rejected',
    'global-all-core-down-failure-release-once',
    'global-all-core-move-only-no-release',
    'global-all-core-ordered',
    'global-all-core-preinput-zero',
    'global-all-core-up-failure-no-retry',
    'global-all-core-up-guard-release-once',
    'global-all-diagnostic-invalid-proof',
    'global-all-diagnostic-not-selected',
    'global-all-diagnostic-profile-change',
    'global-all-diagnostic-selected-unchanged',
    'global-all-event-builder-32767',
    'global-all-event-builder-fields',
    'global-all-event-builder-large-rejected-zero-post',
    'global-all-merged-conflict-overlap',
    'global-all-merged-containment-area',
    'global-all-merged-duplicates-rejected',
    'global-all-merged-invalid-box',
    'global-all-merged-invalid-candidate-rejected',
    'global-all-merged-missing-box-token-rejected',
    'global-all-merged-real-geometry',
    'global-all-merged-threshold',
    'global-all-merged-token-boundaries',
    'global-all-raw-exact-unique',
    'global-all-raw-invalid-bbox-rejected',
    'global-all-raw-low-duplicate-rejected',
    'global-all-raw-merged-duplicate-rejected',
    'global-all-raw-other-literal-rejected',
    'global-all-receipt-exact-schema',
    'global-all-rgb-invalid-retained',
    'global-all-rgb-noise-canonicalized',
    'global-all-strict-identity-fields',
    'global-all-v4-core-false-counted-once',
    'global-all-v4-core-proof-failure-counted-once',
    'global-all-v4-core-success-one-invocation',
    'global-all-v4-core-throw-counted-once',
    'global-all-v4-numeric-error-only',
    'global-all-v4-permission-status',
    'global-all-v4-rounded-point-bounds',
    'global-all-v4-script-compiles',
    'global-all-v4-script-forbidden-absent',
    'global-all-v4-script-owner-bounded',
    'global-all-window-exact-binding',
    'global-args-no-tab',
    'global-args-tab-rejected',
    'global-header-exact-unique',
    'global-history-domain-bound',
    'global-indexed-args-scope',
    'global-indexed-cursor-rejected',
    'global-live-scope-allows-exact-read',
    'global-live-scope-allows-observer',
    'global-live-scope-allows-selector',
    'global-live-scope-denies-inventory',
    'global-model-complete',
    'global-model-duplicate-zero-action',
    'global-model-missing-name-zero-action',
    'global-model-reorder-zero-action',
    'global-model-stale-handle-zero-action',
    'global-query-exact',
    'global-semantic-conflict-rejected',
    'global-semantic-title-only',
    'indexed-ax-chat-domain',
    'indexed-chat-section-count-bounds',
    'indexed-chat-section-domain-crops',
    'indexed-chat-section-label-count',
    'indexed-first-line-adaptive',
    'indexed-first-line-preview-rejected',
    'indexed-header-aux-domains',
    'indexed-header-aux-prefix-color-edge-rejected',
    'indexed-header-topdown-background',
    'indexed-name-edge-color-rejected',
    'indexed-name-ellipsis-invalid-rejected',
    'indexed-name-normalization-full-rgb',
    'indexed-name-normalized-backup-strict',
    'indexed-name-numeric-noise-bounded',
    'indexed-name-prefix-suffix-rejected',
    'indexed-name-raw-contradiction-blocks-fallback',
    'indexed-name-raw-first',
    'indexed-name-threshold',
    'indexed-name-whole-glyph-ownership',
    'indexed-no-retry-ax-post-input',
    'indexed-no-retry-hid-post-input',
    'indexed-query-mutation-route',
    'indexed-query-passive-commit',
    'indexed-scene-cursor-exact-trust',
    'indexed-scene-overlay-ax-rejected',
    'indexed-search-settle-bounded',
    'indexed-search-settle-clock-stuck',
    'indexed-search-settle-late-positive-rejected',
    'indexed-search-settle-nontransient-stops',
    'indexed-search-settle-transient-positive',
    'indexed-ui-version-pinned',
    'indexed-viewport-background-drift-rejected',
    'indexed-viewport-boundary',
    'indexed-viewport-global-body-roi',
    'indexed-viewport-multiple-divider-rejected',
    'indexed-windowserver-path-bytes',
    'indexed-windowserver-trust-fields',
    'legacy-live-scope-denies-global',
    'legacy-live-scope-denies-observer',
    'legacy-live-scope-denies-selector',
    'live-scope-zero-events',
    'mention-token-rejected',
    'message-row-inside-container-visible',
    'message-row-negative-offscreen-rejected',
    'mutation-draft-attempt-post',
    'mutation-nested-pre-overridden',
    'nameband-cgimage-topdown-privacy',
    'nameband-crop-edge-rejected',
    'nameband-dark-missing-title-does-not-use-preview',
    'nameband-dark-title-preview-crop-excludes-preview',
    'nameband-duplicate-rejected',
    'nameband-ellipsis-rejected',
    'nameband-frame-geometry-stable',
    'nameband-low-confidence-not-passable',
    'nameband-missing-title-does-not-use-preview',
    'nameband-multiline-title-rejected',
    'nameband-right-duplicate-rejected',
    'nameband-row-drift-rejected',
    'nameband-title-preview-crop-excludes-preview',
    'nameband-unique-name-timestamp-accepted',
    'nameprobe-active-overlap-rejected',
    'nameprobe-empty-idle-allowed',
    'nameprobe-nonempty-rejected',
    'native-export-action-args',
    'native-export-calibration-zero-side-effects',
    'native-export-path-rejected',
    'native-export-prepare-args',
    'ocr-2x-aspect-dimensions',
    'ocr-2x-corner-orientation',
    'ocr-duplicate-rejected',
    'ocr-header-raw-high-confidence-retained',
    'ocr-invalid-bbox-rejected',
    'ocr-processed-0949-rejected',
    'ocr-processed-095-accepted',
    'ocr-processed-conflict-rejected',
    'ocr-processed-duplicate-rejected',
    'ocr-processed-iou-0799-rejected',
    'ocr-processed-low-confidence-duplicate-rejected',
    'ocr-processed-low-raw-upgraded',
    'ocr-processed-only-rejected',
    'ocr-processed-partial-overlap-conflict-rejected',
    'ocr-processed-prefix-rejected',
    'ocr-processed-suffix-rejected',
    'ocr-raw-partial-overlap-conflict-rejected',
    'ocr-threshold-fixed',
    'ocr-unique-stable',
    'ocr-zero-area-touch-not-conflict',
    'ocrregion-full-right-tab-roi-equivalent',
    'ocrregion-header-empty-right-rejected',
    'ocrregion-tabs-duplicate-left-rejected',
    'ocrregion-tabs-duplicate-search-rejected',
    'ocrregion-tabs-empty-right',
    'ocrregion-tabs-invalid-chrome-rejected',
    'ocrregion-tabs-invalid-roi-rejected',
    'ocrregion-tabs-missing-left-rejected',
    'ocrregion-tabs-missing-search-rejected',
    'ocrregion-tabs-partial-rejected',
    'overlay-rejected',
    'p2-action-whitelist-four',
    'p2-bidi-name-rejected',
    'p2-builtin-without-capability-blocked',
    'p2-c0-name-rejected',
    'p2-capacity-mismatch-conflicting',
    'p2-capacity-multiple-conflicting',
    'p2-capacity-ui-label-parsed',
    'p2-conflicting-capacity-blocked',
    'p2-create-absent-capacity-blocked',
    'p2-create-full-capacity-blocked',
    'p2-dialog-composer-rejected',
    'p2-dialog-disabled-rejected',
    'p2-dialog-rename-original-exact',
    'p2-dialog-search-rejected',
    'p2-dialog-wrong-field-rejected',
    'p2-duplicate-chat-rejected',
    'p2-exact-observed-rename-label-allowed',
    'p2-fingerprint-binds-label-capacity',
    'p2-long-name-rejected',
    'p2-mixed-batch-rejected',
    'p2-move-destination-absent-blocked',
    'p2-move-destination-full-blocked',
    'p2-move-source-absent-allowed',
    'p2-move-source-conflict-blocked',
    'p2-popup-danger-label-not-substitute',
    'p2-popup-duplicate-label-rejected',
    'p2-popup-parent-mismatch-rejected',
    'p2-popup-row-mismatch-rejected',
    'p2-popup-stale-rejected',
    'p2-postphase-forced-after-confirm',
    'p2-readback-destination-missing-rejected',
    'p2-readback-move-verified',
    'p2-readback-source-present-rejected',
    'p2-regular-chat-label-capacity-absent',
    'p2-remove-absent-capacity-allowed',
    'p2-remove-does-not-accept-delete',
    'p2-remove-full-capacity-allowed',
    'p2-rename-absent-capacity-allowed',
    'p2-rename-full-capacity-allowed',
    'p2-rename-label-duplicate-rejected',
    'p2-rename-label-substring-rejected',
    'p2-rename-same-rejected',
    'p2-source-destination-same-rejected',
    'p2-tab-pages-duplicate-preserved',
    'p2-tab-pages-gap-rejected',
    'p2-tab-pages-overlap-merged',
    'p2-unknown-field-rejected',
    'p3-body-date-not-separator',
    'p3-changed-page-progress-verified',
    'p3-complete-algebra-continuation-false',
    'p3-complete-algebra-terminal',
    'p3-content-anchor-detects-text-drift',
    'p3-date-leap-day-valid',
    'p3-date-nonleap-invalid',
    'p3-earliest-boundary-terminal',
    'p3-hmac-id-does-not-use-message-text',
    'p3-hmac-id-lower-hex-64',
    'p3-hmac-id-scope-bound',
    'p3-invalid-state-rejected',
    'p3-offset-no-skipped-rows',
    'p3-ordered-overlap-deduplicated',
    'p3-precondition-drift-zero-body',
    'p3-producer-state-byte-budget',
    'p3-random-id-flags-duplicates',
    'p3-relative-date-unknown',
    'p3-repeated-page-complete-false',
    'p3-repeated-page-no-continuation',
    'p3-repeated-page-not-terminal',
    'p3-same-page-real-boundary-terminal',
    'p3-same-viewport-seen-id-not-dropped',
    'p3-scroll-boundary-both-verified',
    'p3-scroll-boundary-middle-not-terminal',
    'p3-scroll-only-after-viewport-exhausted',
    'p3-single-id-overlap-retained',
    'p3-stable-ids-no-false-duplicate',
    'p3-sync-body-word-not-status',
    'p3-sync-explicit-complete-status',
    'p3-sync-explicit-progress-status',
    'p3-valid-state-accepted',
    'page-budget-10',
    'page-budget-100-capped',
    'page-budget-5',
    'page-budget-50',
    'page-budget-time-stop',
    'plain-at-symbol-allowed',
    'popup-bbox-drift-rejected',
    'popup-duplicate-rejected',
    'popup-exact-stable-target',
    'popup-inmemory-corner-roundtrip',
    'popup-substring-not-exact',
    'popup-transition-ambiguous-not-retryable',
    'popup-transition-modal-not-retryable',
    'popup-transition-not-found-retryable',
    'primer-bounds-rejected',
    'primer-cfset-mismatch-rejected',
    'primer-count-mismatch-rejected',
    'primer-dense-indices-required',
    'primer-duplicate-row-rejected',
    'primer-foreign-hit-rejected',
    'primer-grid-rejected',
    'primer-height-rejected',
    'primer-known-nonrow-rejected',
    'primer-missing-frames-rejected',
    'primer-slot-budget-capped',
    'primer-stale-prefix-valid-seeds',
    'primer-timeout-stops',
    'primer-valid-model',
    'primer-zero-rows-rejected',
    'qt-raw-selected-0949-rejected',
    'qt-raw-selected-badge-drift-rejected',
    'qt-raw-selected-candidate-drift-rejected',
    'qt-raw-selected-competing-selected-rejected',
    'qt-raw-selected-dimensions-drift-rejected',
    'qt-raw-selected-duplicate-rejected',
    'qt-raw-selected-ignores-processed-zero-click',
    'qt-raw-selected-multiple-underline-rejected',
    'qt-raw-selected-roi-drift-rejected',
    'qt-raw-selected-second-invalid-no-fallback',
    'qt-raw-selected-underline-drift-rejected',
    'qt-raw-selected-window-signature-drift-rejected',
    'qt-raw-visible-unselected-allows-fallback',
    'qt-wheel-deadline-budget-blocked',
    'qt-wheel-independent-boundaries-complete',
    'qt-wheel-no-progress-unknown-boundary-incomplete',
    'qt-wheel-point-delta-budget',
    'qt-wheel-unsafe-preflight-zero-event',
    'readnavigation-dark-selected-canonical',
    'readnavigation-legacy-profile-combination',
    'readnavigation-light-selected-canonical',
    'readnavigation-readonly-profile-accepted',
    'readnavigation-readonly-profile-drift-rejected',
    'readnavigation-readonly-profile-missing-rejected',
    'readprofile-alpha-rejected',
    'readprofile-boundary-079-dark',
    'readprofile-boundary-080-dark',
    'readprofile-boundary-081-rejected',
    'readprofile-boundary-179-rejected',
    'readprofile-boundary-180-light',
    'readprofile-boundary-181-light',
    'readprofile-dark-inversion',
    'readprofile-drift-rejected',
    'readprofile-light-identity',
    'readprofile-mask-position-profile',
    'readprofile-original-green-unchanged',
    'readprofile-required-mismatch-rejected',
    'readprofile-size-rejected',
    'readprofile-white-selected-underline',
    'readtab-chrome-rejected',
    'readtab-duplicate-list-rejected',
    'readtab-duplicate-search-rejected',
    'readtab-empty-right-layout',
    'readtab-empty-right-old-layout-rejected',
    'readtab-empty-right-search-field',
    'readtab-full-width-list-rejected',
    'readtab-high-roi-rejected',
    'readtab-left-only-ancestor-rejected',
    'readtab-missing-list-rejected',
    'readtab-out-of-window-rejected',
    'readtab-partial-rejected',
    'readtab-search-geometry-rejected',
    'refinement-apostrophe-rejected',
    'refinement-prefix-rejected',
    'refinement-suffix-digit-rejected',
    'renderer-attached-halo-accepted',
    'renderer-aux-color-rejected',
    'renderer-aux-dark-rejected',
    'renderer-aux-gap23-rejected',
    'renderer-aux-gap24-accepted',
    'renderer-bbox-nonfinite-rejected',
    'renderer-bbox-one-pixel-bounds',
    'renderer-border-ink-rejected',
    'renderer-cgimage-aux-isolated',
    'renderer-coarse-overlap-one-pixel',
    'renderer-colored-rejected',
    'renderer-component-endpoints',
    'renderer-core-strong-required',
    'renderer-count-equivalence',
    'renderer-count-language-fixed',
    'renderer-count-low-confidence-rejected',
    'renderer-count-not-capacity',
    'renderer-decoded-gap-rejected',
    'renderer-fractional-ownership-rejected',
    'renderer-gap-dot-rejected',
    'renderer-geometry-gap-endpoints',
    'renderer-grapheme-missing-rejected',
    'renderer-grapheme-space-allowed',
    'renderer-grapheme-without-strong-rejected',
    'renderer-identity-false-stable',
    'renderer-independent-weak-rejected',
    'renderer-last-count-prefix-preserved',
    'renderer-literal-parentheses-not-rewritten',
    'renderer-mismatched-brackets-rejected',
    'renderer-mutual-crop-boundaries',
    'renderer-no-ink-rejected',
    'renderer-pixel-complete-fixture',
    'renderer-prefix-mismatch-rejected',
    'renderer-raw-suffix-parsed',
    'renderer-row-literal-preserved',
    'renderer-row-same-text-dedup',
    'renderer-row-target-selects-refined',
    'renderer-source-coverage-endpoints',
    'renderer-source-epsilon',
    'renderer-suffix-rejected',
    'renderer-suffix-requires-pixels',
    'renderer-three-part-aux-rejected',
    'renderer-transparent-rejected',
    'renderer-two-part-aux-accepted',
    'renderer-weak-border-rejected',
    'roi-source-1x-plan',
    'roi-source-2x-plan',
    'roi-source-canvas-byte-roundtrip',
    'roi-source-canvas-four-corners',
    'roi-source-canvas-invalid-plan-rejected',
    'roi-source-canvas-outside-blank',
    'roi-source-cross-display-rejected',
    'roi-source-display-selection-ambiguous',
    'roi-source-display-selection-unique',
    'roi-source-filter-geometry',
    'roi-source-fractional-edges',
    'roi-source-invalid-bounds-rejected',
    'roi-source-local-window-pixels-separated',
    'roi-source-negative-display-origins',
    'roi-source-nonzero-window-origin',
    'roi-source-overflow-rejected',
    'roi-source-post-display-stability',
    'roi-source-post-scale-exact',
    'roi-source-scale-boundaries',
    'roi-source-scale-rejected',
    'roi-source-secondary-positive-x',
    'roi-source-size-caps-rejected',
    'same-element-row-deduplicated',
    'same-name-distinct-rows-preserved',
    'scroll-overlap-identifier-deduplicated',
    'scroll-same-name-distinct-identifiers-preserved',
    'selection-diagnostics-absent',
    'selection-diagnostics-invalid',
    'selection-diagnostics-masked',
    'selection-diagnostics-no-names',
    'selection-diagnostics-nonfinite',
    'selection-diagnostics-selected',
    'splitgroup-1pt-sibling-jitter',
    'tabsweep-global-budget-descends',
    'tabsweep-invalid-direction-rejected',
    'tabsweep-legacy-repeat-stops',
    'tabsweep-negative-budget-rejected',
    'tabsweep-readonly-bidirectional-trace',
    'tabsweep-readonly-right-repeat-stops',
    'tabsweep-zero-budget-no-flip',
    'uitime-formats-bounded',
    'uitime-invalid-ranges',
    'uitime-refinement-endpoints',
    'uitime-unknown-rejected',
    'uitime-yesterday-allowed',
    'underline-adjacent-tab-rejected',
    'underline-gray-separator-rejected',
    'underline-icon-rejected',
    'underline-missing-rejected',
    'underline-target-associated',
    'unread-badge-associated',
    'unread-unrelated-badge-rejected',
  ].sort());
  assert.equal(Object.values(selfTest.result.checks).every(Boolean), true);

  // 同一個正式 binary 驗收真實解碼與檔案邊界；雙停用下不得接觸桌面。
  const image = await fs.readFile(new URL('./fixtures/synthetic-image.png', import.meta.url));
  const imageFile = path.join(directory, 'synthetic.png');
  const badFile = path.join(directory, 'not-image.png');
  const truncatedFile = path.join(directory, 'truncated.png');
  const linkedFile = path.join(directory, 'link.png');
  const oversizedFile = path.join(directory, 'oversized.png');
  await fs.writeFile(imageFile, image);
  await fs.writeFile(badFile, 'synthetic text only');
  await fs.writeFile(truncatedFile, image.subarray(0, 44));
  await fs.symlink(imageFile, linkedFile);
  await fs.writeFile(oversizedFile, Buffer.alloc(20 * 1024 * 1024 + 1));
  const imageHash = createHash('sha256').update(image).digest('hex');
  const inspected = run(binary, { name: 'inspectImage', args: { imagePath: imageFile, imageSha256: imageHash } });
  assert.equal(inspected.ok, true);
  assert.equal(inspected.result.uiAccessed, false);
  assert.equal(inspected.result.width, 640);
  assert.equal(inspected.result.height, 360);
  for (const [filename, sha, code] of [
    [imageFile, '0'.repeat(64), 'IMAGE_HASH_MISMATCH'],
    [linkedFile, imageHash, 'IMAGE_FILE_UNSAFE'],
    [badFile, createHash('sha256').update(await fs.readFile(badFile)).digest('hex'), 'IMAGE_INVALID'],
    [truncatedFile, createHash('sha256').update(await fs.readFile(truncatedFile)).digest('hex'), 'IMAGE_INVALID'],
    [oversizedFile, '0'.repeat(64), 'IMAGE_FILE_UNSAFE'],
  ]) {
    const rejected = run(binary, { name: 'inspectImage', args: { imagePath: filename, imageSha256: sha } });
    assert.equal(rejected.ok, false);
    assert.equal(rejected.error.code, code);
  }
  const hardlink = path.join(directory, 'hardlink.png');
  await fs.link(imageFile, hardlink);
  assert.equal(run(binary, { name: 'inspectImage', args: { imagePath: hardlink, imageSha256: imageHash } }).error.code,
    'IMAGE_FILE_UNSAFE');

  // fixture 必須由 Swift 的正式 constructor 產生，再走 JS 真 validator。
  const nativeFixtureCalls = [];
  const journalFS = memoryJournalFS();
  const fixtureDesktop = new MacOSDesktopAutomation({
    bridge: { async call(name, args) {
      nativeFixtureCalls.push({ name, args });
      if (name === 'status') {
        return {
          running: true, accessibilityTrusted: true, foreground: true, usable: true,
          mainWindow: syntheticValidLINEWindow,
        };
      }
      if (name === 'selectGlobalAll') return selfTest.result.globalAllNavigationFixture;
      assert.equal(name, 'readGlobalHistoryPage');
      return selfTest.result.globalHistoryFixture;
    } },
    lock: { withLock: (work) => work() },
    exportReader: null,
    bootNonce: 'native-global-producer-fixture',
    fileSystem: journalFS,
    journalPath: '/synthetic-native-policy/pending-operation.json',
    randomBytes: length => Buffer.alloc(length, 0xaa),
  });
  const navigationRequest = {
    chatName: '測試對話', requestNonce: 'a'.repeat(64), expectedWindow: syntheticValidLINEWindow,
  };
  const navigationFixtures = selfTest.result.globalAllNavigationFixtures;
  assert.deepEqual(navigationFixtures, {
    alreadySelected: globalNavigationReceipt(navigationRequest),
    inputVerified: globalNavigationReceipt(navigationRequest, {
      inputAttempted: true, eventCounts: { move: 1, down: 1, up: 1 },
    }),
    preInputFailure: globalNavigationReceipt(navigationRequest, {
      allSelected: false, phase: 'pre_input',
    }),
    postInputUnknown: globalNavigationReceipt(navigationRequest, {
      allSelected: false, inputAttempted: true, eventCounts: { move: 1, down: 1, up: 1 },
      phase: 'post_input', identityVerified: false,
    }),
  });
  assert.deepEqual(selfTest.result.globalAllNavigationFixture, navigationFixtures.alreadySelected);
  const projectedFixture = await fixtureDesktop.call('line_get_chat_history_global',
    { chatName: '測試對話', limit: 5 },
    { transport: 'stdio', sessionId: 'native-global-producer-fixture' });
  assert.deepEqual(projectedFixture.scope, { kind: 'chat', chatName: '測試對話', verified: true });
  assert.deepEqual(nativeFixtureCalls.map(({ name }) => name),
    ['status', 'selectGlobalAll', 'readGlobalHistoryPage']);
  assert.equal(projectedFixture.complete, false);
  assert.equal(journalFS.files.size, 0);

  const swiftSource = await fs.readFile(source, 'utf8');
  const captureSource = swiftSource.slice(
    swiftSource.indexOf('func captureWindowImage('),
    swiftSource.indexOf('func visionRequest('),
  );
  assert.notEqual(swiftSource.indexOf('func roiSourceCapturePlan('), -1);
  assert.match(captureSource, /opaqueForRead:\s*Bool\s*=\s*false/);
  assert.match(captureSource, /configuration\.shouldBeOpaque\s*=\s*opaqueForRead/);
  assert.match(captureSource, /#available\(macOS 14\.2, \*\)/);
  assert(captureSource.indexOf('#available(macOS 14.2, *)') <
    captureSource.indexOf('SCShareableContent.getExcludingDesktopWindows'));
  assert.match(captureSource,
    /SCContentFilter\(display:\s*selectedDisplay,\s*including:\s*\[windows\[0\]\]\)/);
  assert.match(captureSource, /uniqueDisplayGeometryIndex\(/);
  assert.doesNotMatch(captureSource, /CGMainDisplayID\(\)/);
  assert.match(captureSource, /\$0\.windowID\s*==\s*identity\.windowID/);
  assert.match(captureSource, /\$0\.owningApplication\?\.processID\s*==\s*identity\.pid/);
  assert.match(captureSource, /\$0\.title\s*==\s*expectedWindowTitle/);
  assert.match(captureSource, /similar\(\$0\.frame,\s*identity\.bounds,\s*tolerance:\s*0\.5\)/);
  assert.match(captureSource, /filter\.includeMenuBar\s*=\s*false/);
  assert.match(captureSource, /guard filter\.style\s*==\s*\.display/);
  assert.match(captureSource, /validDisplayFilterGeometry\(contentRect:\s*filter\.contentRect/);
  assert.match(captureSource,
    /if #available\(macOS 15\.2, \*\)\s*\{[\s\S]*filter\.includedWindows\.count\s*==\s*1/);
  assert.equal((captureSource.match(/filter\.includedWindows/g) || []).length, 2);
  assert.equal((captureSource.match(/postFilter\.includedWindows/g) || []).length, 2);
  assert.match(captureSource, /configuration\.sourceRect\s*=\s*plan\.sourceRect/);
  assert.match(captureSource, /configuration\.width\s*=\s*plan\.roiWidth/);
  assert.match(captureSource, /configuration\.height\s*=\s*plan\.roiHeight/);
  assert.match(captureSource, /configuration\.includeChildWindows\s*=\s*false/);
  assert.match(captureSource, /configuration\.capturesAudio\s*=\s*false/);
  assert.match(captureSource,
    /#available\(macOS 15\.0, \*\)[\s\S]*configuration\.captureMicrophone\s*=\s*false/);
  assert.match(captureSource,
    /image\.width\s*==\s*plan\.roiWidth,\s*image\.height\s*==\s*plan\.roiHeight/);
  assert.match(captureSource, /postContent\.displays\.map/);
  assert.match(captureSource, /stableDisplayGeometryIndex\(/);
  assert.match(captureSource, /exactDisplayScale\(/);
  assert.match(captureSource, /ROI_DISPLAY_CHANGED/);
  assert.doesNotMatch(captureSource,
    /desktopIndependentWindow|ignoreShadowsSingleWindow|configuration\.(?:width|height)[^\n]*identity\.bounds/);
  assert.doesNotMatch(captureSource, /SEMANTIC_|TAB_SELECTION/);
  const readOnlyCaptureCalls = [
    swiftSource.slice(swiftSource.indexOf('func captureNameBandSample('),
                      swiftSource.indexOf('func stableNameBandGeometry(')),
    swiftSource.slice(swiftSource.indexOf('func captureReadTabOCR('),
                      swiftSource.indexOf('func exactOCRMatches(')),
  ];
  assert(readOnlyCaptureCalls.every((value) => /captureWindowImage\([^\n]+opaqueForRead:\s*true\)/.test(value)));
  const p2Source = swiftSource.slice(
    swiftSource.indexOf('enum TabChangeAction'),
    swiftSource.indexOf('struct RowProbe'),
  );
  assert.doesNotMatch(p2Source, /pairedReturnKey|virtualKey:\s*36/);
  const mainWindowSource = swiftSource.slice(
    swiftSource.indexOf('func mainWindow('),
    swiftSource.indexOf('func lineLayout('),
  );
  assert.doesNotMatch(mainWindowSource, /\.activate\s*\(/);
  const historyPageSource = swiftSource.slice(
    swiftSource.indexOf('func readHistoryPage('),
    swiftSource.indexOf('func freshComposer('),
  );
  assert.doesNotMatch(historyPageSource, /activateLine|lineApplication\(\)\.activate/);
  const ocrSource = swiftSource.slice(
    swiftSource.indexOf('func upscaledWholeROI2x('),
    swiftSource.indexOf('struct NameBandSample'),
  );
  assert.match(ocrSource, /processedOCRMaxPixels/);
  assert.match(ocrSource, /rawCandidates\.allSatisfy\(\{ validNormalizedBox/);
  assert.match(ocrSource, /processedCandidates\.allSatisfy\(\{ validNormalizedBox/);
  assert.doesNotMatch(ocrSource, /customWords|range\(of:/);
  const legacyCaptureSource = swiftSource.slice(
    swiftSource.indexOf('func captureOCR('),
    swiftSource.indexOf('func captureReadTabOCR('),
  );
  assert.match(legacyCaptureSource, /upscaledWholeROI2x\(masked \?\? originalROI\)/);
  assert.match(legacyCaptureSource, /ocrRegionROI\(region, tree: tree, window: identity\)/);
  assert.doesNotMatch(legacyCaptureSource, /lineLayout\(tree, window: identity\)/);
  assert.doesNotMatch(legacyCaptureSource, /canonicalReadROI|ReadColorProfile/);
  const roiResolverSource = swiftSource.slice(
    swiftSource.indexOf('func ocrRegionROI('),
    swiftSource.indexOf('func captureOCR('),
  );
  assert.match(roiResolverSource,
    /case \.tabs:[\s\S]*readTabLayout\(tree, window: window\)\.tabROI/);
  assert.match(roiResolverSource,
    /case \.header:[\s\S]*lineLayout\(tree, window: window\)\.headerROI/);
  assert.doesNotMatch(roiResolverSource,
    /mainWindow|captureWindowImage|CGEvent|AXUIElement(?:Copy|Get|Set|Perform)|NSPasteboard/);
  const readTabSource = swiftSource.slice(
    swiftSource.indexOf('func captureReadTabOCR('),
    swiftSource.indexOf('func exactOCRMatches('),
  );
  assert.match(readTabSource, /greenComponents\(image,/);
  assert.match(readTabSource, /maskedBadgeROI\(image,/);
  assert.match(readTabSource, /globalAllSourceRGB:\s*Bool\s*=\s*false/);
  assert.match(readTabSource,
    /visionCandidates\(globalAllSourceRGB\s*\?\s*originalROI\s*:\s*canonical\.image\)/);
  assert.equal((readTabSource.match(/canonicalReadOCRCandidates\(/g) || []).length, 2);
  assert.match(readTabSource,
    /globalAllSourceRGB\s*\?\s*canonicalReadOCRCandidates\([\s\S]*originalROI\.width,[\s\S]*originalROI\.height/);
  assert.match(readTabSource,
    /globalAllSourceRGB\s*\?\s*canonicalReadOCRCandidates\([\s\S]*candidateImage\.width,[\s\S]*candidateImage\.height/);
  assert.match(readTabSource,
    /let candidateMaskedImage\s*=\s*globalAllSourceRGB\s*\?\s*masked\s*:\s*canonicalMasked/);
  assert.match(readTabSource, /let navigationImage\s*=\s*masked\s*\?\?\s*originalROI/);
  assert.match(readTabSource, /visionRequest\(navigationImage\)/);
  assert.match(readTabSource, /upscaledWholeROI2x\(navigationImage\)/);
  assert.match(readTabSource,
    /originalWidth:\s*navigationImage\.width,\s*originalHeight:\s*navigationImage\.height/);
  const mergedFallbackSource = readTabSource.slice(
    readTabSource.indexOf('if rawExact.isEmpty'),
    readTabSource.indexOf('let underlines ='),
  );
  assert.ok(mergedFallbackSource.indexOf('if rawExact.isEmpty')
    < mergedFallbackSource.indexOf('let navigationImage'));
  assert.doesNotMatch(mergedFallbackSource, /canonicalMasked|canonical\.image/);
  assert.match(readTabSource, /boundingBox\(for:\s*token\.range\)/);
  assert.match(readTabSource, /substringBox[\s\S]*\?\?\s*\.null/);
  assert.doesNotMatch(readTabSource,
    /greenComponents\(canonical|CGEvent|AXUIElementPerformAction|AXUIElementSetAttributeValue/);
  const preSelfTestSource = swiftSource.slice(0, swiftSource.indexOf('func runSelfTests('));
  assert.equal((preSelfTestSource.match(
    /captureReadTabOCR\(globalAllSourceRGB:\s*true\)/g
  ) || []).length, 4);
  const globalTargetSource = swiftSource.slice(
    swiftSource.indexOf('func freshGlobalAllTarget('),
    swiftSource.indexOf('func verifyGlobalAllForRead('),
  );
  assert.equal((globalTargetSource.match(/globalAllSourceRGB:\s*true/g) || []).length, 2);
  const globalSelectedSource = swiftSource.slice(
    swiftSource.indexOf('func verifyGlobalAllSelected('),
    swiftSource.indexOf('func windowStateExactlyMatches('),
  );
  assert.equal((globalSelectedSource.match(/globalAllSourceRGB:\s*true/g) || []).length, 2);
  assert.match(globalSelectedSource, /stableGlobalAllSelection\(first:\s*first,\s*second:\s*second\)/);
  assert.match(readTabSource, /let canonical\s*=\s*try canonicalReadROI\(originalROI\)/);
  assert.match(readTabSource, /underlineComponentsROI\(canonical\.image/);
  const indexedTargetSource = swiftSource.slice(
    swiftSource.indexOf('func indexedSearchTarget('),
    swiftSource.indexOf('func stableIndexedSearchTarget('),
  );
  assert.match(indexedTargetSource, /readTabLayout\(/);
  assert.equal((indexedTargetSource.match(/captureWindowImage\(/g) || []).length, 2);
  assert.match(indexedTargetSource, /adaptiveIndexedNameBandROI\(/);
  assert.match(indexedTargetSource, /indexedWholeGlyphOwnershipAllowed\(/);
  assert.match(indexedTargetSource, /rawCandidates\s*=\s*try visionCandidates\(crop\)/);
  assert.match(indexedTargetSource, /indexedNameCandidateChoice\(/);
  assert.match(indexedTargetSource,
    /sourceOwnership:[\s\S]*indexedWholeGlyphOwnershipAllowed\([\s\S]*crop,/);
  assert.match(indexedTargetSource,
    /normalizedCandidates:\s*\{\s*try visionCandidates\(normalized\)\s*\}/);
  assert.match(indexedTargetSource, /rgbaBottomUp\(normalized\)/);
  assert.match(indexedTargetSource, /sectionInset\s*=\s*indexedChatSectionInsetCrop\(/);
  assert.match(indexedTargetSource, /sectionNormalized\s*=\s*try normalizedFullNameImage\(sectionCanonical\)/);
  assert.match(indexedTargetSource, /sectionDomains\s*=\s*try indexedChatSectionDomainCrops\(/);
  assert.match(indexedTargetSource,
    /uniqueStrictCropCandidate\(sectionDomains\.label,\s*kind:\s*\.nameOrTime\)/);
  assert.match(indexedTargetSource,
    /uniqueStrictCropCandidate\(sectionDomains\.count,\s*kind:\s*\.nameOrTime\)/);
  assert.doesNotMatch(indexedTargetSource,
    /uniqueStrictCropCandidate\(sectionDomains\.count,\s*kind:\s*\.count\)/);
  assert.match(indexedTargetSource, /indexedChatSectionCount\(/);
  assert.match(indexedTargetSource, /indexedChatSectionResultAllowed\(count:\s*sectionCount,/);
  assert.ok(indexedTargetSource.indexOf('indexedChatSectionResultAllowed') <
    indexedTargetSource.indexOf('adaptiveIndexedNameBandROI'));
  const indexedSectionDomainSource = swiftSource.slice(
    swiftSource.indexOf('func indexedChatSectionDomainCrops('),
    swiftSource.indexOf('func indexedWholeInkCrop('),
  );
  assert.match(indexedSectionDomainSource, /y:\s*0,/);
  assert.match(indexedSectionDomainSource, /height:\s*CGFloat\(image\.height\)/);
  const indexedCandidateSource = swiftSource.slice(
    swiftSource.indexOf('func canonicalReadOCRCandidate('),
    swiftSource.indexOf('func indexedExactNameCandidate('),
  );
  assert.match(indexedCandidateSource, /boundedOCRPixelRect\(/);
  assert.match(indexedCandidateSource, /maximumOutside:\s*0\.00001/);
  assert.match(indexedCandidateSource, /validNormalizedBox\(normalized\)/);
  assert.match(indexedCandidateSource,
    /candidates\.map\s*\{[\s\S]*canonicalReadOCRCandidate\([\s\S]*\?\?\s*\$0/);
  assert.doesNotMatch(indexedCandidateSource, /compactMap|filter\s*\{/);
  const indexedNameChoiceSource = swiftSource.slice(
    swiftSource.indexOf('func indexedRawNameAllowsNormalizedFallback('),
    swiftSource.indexOf('func indexedChatSectionCount('),
  );
  assert.match(indexedNameChoiceSource,
    /candidates\.filter\(\{\s*\$0\.text\s*==\s*expected\s*\}\)\.count\s*<\s*2/);
  assert.match(indexedNameChoiceSource,
    /\$0\.confidence\s*>=\s*ocrConfidenceThreshold/);
  assert.match(indexedNameChoiceSource,
    /candidate\.text\s*==\s*expected\s*\|\|\s*rendererUITimeText\(candidate\.text\)/);
  assert.ok(indexedNameChoiceSource.indexOf('try sourceOwnership(raw, rawCandidates)') <
    indexedNameChoiceSource.indexOf('let normalized = try normalizedCandidates()'));
  assert.equal((indexedNameChoiceSource.match(/normalizedCandidates\(\)/g) || []).length, 1);
  assert.match(indexedTargetSource, /headerHeight:\s*CGFloat\s*=\s*34/);
  const indexedSetterSource = swiftSource.slice(
    swiftSource.indexOf('func setIndexedSearchValue('),
    swiftSource.indexOf('struct GlobalSearchRowProof'),
  );
  assert.match(indexedSetterSource, /AXUIElementIsAttributeSettable/);
  assert.match(indexedSetterSource, /indexedSearchMutationRoute\(/);
  assert.match(indexedSetterSource, /AXUIElementSetAttributeValue/);
  assert.equal((indexedSetterSource.match(/AXUIElementSetAttributeValue/g) || []).length, 1);
  assert.match(indexedSetterSource, /indexedPassiveCommitAllowed\(/);
  assert.doesNotMatch(indexedSetterSource, /\bindexedSearchTarget\(/);
  assert.equal((indexedSetterSource.match(/settledIndexedSearchTarget\(/g) || []).length, 4);
  const indexedSettleSource = swiftSource.slice(
    swiftSource.indexOf('func indexedSearchTransientFailure('),
    swiftSource.indexOf('func setIndexedSearchValue('),
  );
  assert.match(indexedSettleSource, /deadline\s*=\s*started\s*\+\s*8/);
  assert.match(indexedSettleSource, /for _ in 0\.\.<160/);
  assert.match(indexedSettleSource, /ProcessInfo\.processInfo\.systemUptime/);
  assert.match(indexedSettleSource, /strictGlobalAllWindow\(expected:\s*expected\.json\)/);
  assert.match(indexedSettleSource, /globalQueryMatches\(observed:\s*query,\s*expected:\s*chatName\)/);
  assert.match(indexedSettleSource, /stableIndexedSearchTarget\(/);
  assert.ok(indexedSettleSource.indexOf('let afterProbe = clock()') <
    indexedSettleSource.indexOf('return value'));
  assert.match(indexedSettleSource,
    /afterProbe\s*>=\s*deadline[\s\S]*if let lastTransient[\s\S]*SEARCH_RESULTS_NOT_READY/);
  assert.doesNotMatch(indexedSettleSource,
    /AXUIElementSetAttributeValue|NSPasteboard|CGEvent|runGlobalAllMouseCore|historyRows/);
  const indexedAXProofSource = swiftSource.slice(
    swiftSource.indexOf('func proveIndexedGlobalHistoryScopeAX('),
    swiftSource.indexOf('func proveIndexedGlobalHistoryScopeOCR('),
  );
  const indexedOCRProofSource = swiftSource.slice(
    swiftSource.indexOf('func proveIndexedGlobalHistoryScopeOCR('),
    swiftSource.indexOf('func proveIndexedGlobalHistoryScope('),
  );
  assert.match(indexedAXProofSource, /setIndexedSearchValue\(/);
  assert.match(indexedAXProofSource,
    /perform\(kAXPressAction[\s\S]*indexedSelectionOutcomeUnknown\(error,[\s\S]*axPressAttempts:\s*1\)/);
  assert.match(indexedOCRProofSource, /setIndexedSearchValue\(/);
  assert.match(indexedOCRProofSource,
    /failure\.counts\.inputAttempted[\s\S]*indexedSelectionOutcomeUnknown\(failure\.cause,[\s\S]*failure\.counts/);
  assert.match(indexedOCRProofSource,
    /verifyIndexedHeader[\s\S]*indexedSelectionOutcomeUnknown\(error,\s*counts:\s*counts\)/);
  const indexedSceneSource = swiftSource.slice(
    swiftSource.indexOf('struct IndexedSceneWindow'),
    swiftSource.indexOf('func indexedTopDownCropRect('),
  );
  assert.ok(indexedSceneSource.indexOf('strictGlobalAllWindow(expected: expected.json)') <
    indexedSceneSource.indexOf('CGWindowListCopyWindowInfo'));
  assert.ok(indexedSceneSource.indexOf('CGWindowListCopyWindowInfo') <
    indexedSceneSource.indexOf('AXUIElementCopyElementAtPosition'));
  assert.doesNotMatch(indexedSceneSource,
    /strictGlobalAllWindow\(expected:\s*expected\.json,\s*point:|nearestAXWindow/);
  assert.match(indexedSceneSource, /CGWindowLevelForKey\(\.cursorWindow\)/);
  assert.match(indexedSceneSource, /trustedWindowServerCursorPID\(/);
  assert.match(indexedSceneSource, /indexedSceneAllowsTarget\(/);
  assert.match(indexedSceneSource, /AXUIElementGetPid\(hit,\s*&hitPID\)/);
  assert.match(indexedSceneSource, /axOwnerVerified:\s*axOwnerVerified/);
  assert.match(indexedSceneSource,
    /\$0\.layer\s*==\s*cursorLayer\s*&&\s*\$0\.trustedCursor/);
  assert.doesNotMatch(indexedSceneSource,
    /kCGWindowOwnerName|kCGWindowAlpha|ownerName|fixedPID|cursorWindowID/);
  const cursorIdentitySource = swiftSource.slice(
    swiftSource.indexOf('func canonicalExpectedWindowServerPath('),
    swiftSource.indexOf('func lineApplication('),
  );
  assert.match(swiftSource,
    /\/System\/Library\/PrivateFrameworks\/SkyLight\.framework\/Resources\/WindowServer/);
  assert.match(cursorIdentitySource, /resolvingSymlinksInPath\(\)/);
  assert.match(cursorIdentitySource, /proc_pidpath\(/);
  assert.equal((cursorIdentitySource.match(/rawProcessPath\(pid\)/g) || []).length, 2);
  assert.match(cursorIdentitySource, /count\s*>\s*0,\s*count\s*<\s*buffer\.count/);
  assert.match(cursorIdentitySource, /buffer\[count\]\s*==\s*0/);
  assert.match(cursorIdentitySource, /!buffer\[\.\.<count\]\.contains\(0\)/);
  assert.match(cursorIdentitySource,
    /anchor apple and identifier \\"com\.apple\.WindowServer\\"/);
  assert.match(cursorIdentitySource, /SecStaticCodeCheckValidity\([\s\S]*kSecCSStrictValidate/);
  assert.match(cursorIdentitySource, /kSecCodeInfoIdentifier/);
  const indexedDispatchSource = swiftSource.slice(
    swiftSource.indexOf('func proveIndexedGlobalHistoryScope('),
    swiftSource.indexOf('func proveGlobalHistoryScope('),
  );
  assert.match(indexedDispatchSource, /indexedAXFailureAllowsOCRFallback\(/);
  const adaptiveNameSource = swiftSource.slice(
    swiftSource.indexOf('func adaptiveIndexedNameBandROI('),
    swiftSource.indexOf('func indexedFirstLineHeight('),
  );
  assert.match(adaptiveNameSource, /height:\s*24/);
  assert.match(adaptiveNameSource,
    /let x\s*=\s*listFrame\.minX\s*\+\s*74,\s*width:\s*CGFloat\s*=\s*176/);
  assert.match(adaptiveNameSource, /width:\s*80,\s*height:\s*2/);
  assert.match(adaptiveNameSource, /offset\s*<\s*52/);
  assert.match(adaptiveNameSource, /indexedFirstLineHeight\(rows,\s*scale:\s*scale\)/);
  const firstLineSource = swiftSource.slice(
    swiftSource.indexOf('func indexedFirstLineHeight('),
    swiftSource.indexOf('func indexedExactNameCandidate('),
  );
  assert.match(firstLineSource, /24\s*\*\s*scale/);
  assert.match(firstLineSource, /ceil\(2\s*\*\s*scale\)/);
  assert.match(firstLineSource, /CGFloat\(lastInk\s*-\s*firstInk\s*\+\s*1\)\s*\/\s*scale\s*<=\s*26/);
  const indexedHeaderSource = swiftSource.slice(
    swiftSource.indexOf('func verifyIndexedHeader('),
    swiftSource.indexOf('func verifiedGlobalSelection('),
  );
  assert.match(indexedHeaderSource, /readTabLayout\(/);
  assert.equal((indexedHeaderSource.match(/captureWindowImage\(/g) || []).length, 1);
  assert.match(indexedHeaderSource, /actualGlyphCoverageAllowed\(/);
  assert.match(indexedHeaderSource, /indexedHeaderBackground\(/);
  assert.match(indexedHeaderSource, /indexedTopDownCropRect\(/);
  assert.match(indexedHeaderSource, /indexedHeaderAuxiliaryDomainsValid\(/);
  const indexedHeaderAuxSource = swiftSource.slice(
    swiftSource.indexOf('func indexedHeaderAuxiliaryDomainsValid('),
    swiftSource.indexOf('func verifyIndexedHeader('),
  );
  assert.match(indexedHeaderAuxSource, /auxiliaryComponentVerdict\(/);
  assert.match(indexedHeaderAuxSource, /componentCount:\s*domain\.count/);
  const indexedViewportSource = swiftSource.slice(
    swiftSource.indexOf('func captureIndexedViewport('),
    swiftSource.indexOf('func indexedViewportHistoryResult('),
  );
  assert.match(indexedViewportSource, /readTabLayout\(/);
  assert.equal((indexedViewportSource.match(/captureWindowImage\(/g) || []).length, 3);
  assert.match(indexedViewportSource, /indexedViewportBounds\(/);
  assert.match(indexedViewportSource, /indexedBodyGlobalROI\(/);
  assert.match(indexedViewportSource, /let leftROI[\s\S]*width:\s*2/);
  assert.match(indexedViewportSource, /let rightROI[\s\S]*width:\s*2/);
  assert.ok(indexedViewportSource.indexOf('let stripROI') < indexedViewportSource.indexOf('let bodyROI'));
  assert.ok(indexedViewportSource.indexOf('if readText') <
    indexedViewportSource.indexOf('captureWindowImage(identity, roi: bodyROI'));
  assert.doesNotMatch(indexedViewportSource, /crop\.cropping\(to:\s*bodyRect/);
  assert.doesNotMatch(indexedViewportSource, /window\.bounds\.maxY\s*-\s*128/);
  assert.match(readOnlyCaptureCalls[0], /readTabLayout\(/);
  assert.doesNotMatch(readOnlyCaptureCalls[0], /lineLayout\(/);
  assert.match(readTabSource, /readTabLayout\(/);
  assert.doesNotMatch(readTabSource, /lineLayout\(/);
  const metadataResolverSource = swiftSource.slice(
    swiftSource.indexOf('func postFreshMetadataWheel('),
    swiftSource.indexOf('func pageSignature('),
  ) + swiftSource.slice(
    swiftSource.indexOf('func metadataChatPage('),
    swiftSource.indexOf('func scanTabChatsMetadata('),
  );
  assert.equal((metadataResolverSource.match(/readTabLayout\(/g) || []).length, 3);
  assert.doesNotMatch(metadataResolverSource, /lineLayout\(/);
  const primerSource = swiftSource.slice(
    swiftSource.indexOf('func passivePrimeVisibleRows('),
    swiftSource.indexOf('func visibleChatRows('),
  );
  assert.match(primerSource, /AXUIElementGetAttributeValueCount/);
  assert.match(primerSource, /AXUIElementCopyAttributeValues/);
  assert.match(primerSource, /AXUIElementCopyElementAtPosition/);
  assert.match(primerSource, /AXUIElementSetMessagingTimeout/);
  assert.match(primerSource, /throws -> VisibleRowsReceipt/);
  assert.match(primerSource, /freshModelCanSkipPrimer/);
  assert.match(primerSource,
    /freshReceiptOrderStable\(firstReceipt\.rows\.map\(\\\.element\),[\s\S]*secondReceipt\.rows\.map\(\\\.element\)\)/);
  const receiptOrderSource = swiftSource.slice(
    swiftSource.indexOf('func freshReceiptOrderStable('),
    swiftSource.indexOf('func visibleReceiptConsumerValid('),
  );
  assert.match(receiptOrderSource, /zip\(first, second\)\.allSatisfy \{ CFEqual\(\$0, \$1\) \}/);
  assert.doesNotMatch(receiptOrderSource,
    /AXUIElementCopy|AXUIElementGet|AXUIElementSet|CGEvent|NSPasteboard/);
  assert.match(primerSource, /for depth in 0\.\.<6/);
  assert.doesNotMatch(primerSource,
    /CGEvent|AXUIElementPerformAction|AXUIElementSetAttributeValue|AXEnhancedUserInterface|Thread\.sleep|kAX(?:Title|Value|Description)Attribute/);
  assert.equal((preSelfTestSource.match(/passivePrimeVisibleRows\(/g) || []).length, 2);
  assert.match(readOnlyCaptureCalls[0], /passivePrimeVisibleRows\(/);
  assert.match(readOnlyCaptureCalls[0], /visibleReceiptConsumerValid/);
  assert.doesNotMatch(p2Source, /VisibleRowsReceipt|freshModelCanSkipPrimer|passivePrimeVisibleRows/);
  const rendererSource = swiftSource.slice(
    swiftSource.indexOf('struct ParsedRendererLabel'),
    swiftSource.indexOf('struct PrimerPrefixRow'),
  );
  assert.match(rendererSource, /boundingBox\(for:/);
  assert.doesNotMatch(rendererSource,
    /customWords|AXUIElementSetAttributeValue|AXUIElementPerformAction|CGEvent|NSPasteboard|readHistoryPage|getHistory|sendMessage|AXEnhancedUserInterface/);
  assert.doesNotMatch(
    swiftSource.slice(swiftSource.indexOf('func rendererLabelRefinement('),
                      swiftSource.indexOf('func primerBudgetOpen(')),
    /\btarget\b/,
  );
  assert.equal((preSelfTestSource.match(/rendererLabelRefinement\(/g) || []).length, 2);
  assert.equal((preSelfTestSource.match(/nameProbeIdleProof\(/g) || []).length, 4);
  const rendererFieldSource = swiftSource.slice(
    swiftSource.indexOf('enum RendererFieldKind'),
    swiftSource.indexOf('func darkestInk('),
  );
  assert.equal((preSelfTestSource.slice(0, preSelfTestSource.indexOf('func indexedSearchTarget('))
    .match(/uniqueStrictCropCandidate\(/g) || []).length, 4);
  assert.equal((indexedTargetSource.match(/uniqueStrictCropCandidate\(/g) || []).length, 2);
  assert.match(rendererFieldSource,
    /request\.recognitionLanguages = rendererLanguages\(kind\)/);
  assert.match(rendererFieldSource,
    /kind == \.count \? \["en-US"\] : \["zh-Hant", "en-US"\]/);
  assert.doesNotMatch(rendererFieldSource,
    /customWords|\btarget\b|AXUIElement|CGEvent|NSPasteboard/);
  const passiveReadSource = swiftSource.slice(
    swiftSource.indexOf('struct NameBandSample'),
    swiftSource.indexOf('enum OCRRegion'),
  ) + swiftSource.slice(
    swiftSource.indexOf('func validReadROIShape('),
    swiftSource.indexOf('func maskedBadgeROI('),
  );
  assert.doesNotMatch(passiveReadSource,
    /CGEvent|AXUIElementPerformAction|AXUIElementSetAttributeValue|pairedKey|setSearchValue|readHistoryPage|getHistory|sendMessage|AXEnhancedUserInterface/);
  const navigateTabSource = swiftSource.slice(
    swiftSource.indexOf('func navigateTab(_ tabName:'),
    swiftSource.indexOf('func chatRows('),
  );
  const captureModeSource = navigateTabSource.slice(
    navigateTabSource.indexOf('func captureTabFrame('),
    navigateTabSource.indexOf('var seen ='),
  );
  assert.equal((navigateTabSource.match(/mode: TabNavigationMode = \.legacy/g) || []).length, 2);
  assert.ok(navigateTabSource.indexOf('navigateAXTabIfVerified(')
    < navigateTabSource.indexOf('func captureTabFrame('));
  assert.match(captureModeSource,
    /case \.readOnly:[\s\S]*captureReadTabOCR\(\)[\s\S]*expectedReadProfile/);
  assert.equal((captureModeSource.match(/captureOCR\(/g) || []).length, 1);
  assert.match(navigateTabSource,
    /verifySelectedTab\(match\.0, mode: mode,[\s\S]*expectedReadProfile: expectedReadProfile\)/);
  const labelsNavigationSource = navigateTabSource.slice(
    navigateTabSource.indexOf('func navigateTab(labels:'),
  );
  const advanceStart = swiftSource.indexOf('func advanceTabSearch(');
  const advanceSource = swiftSource.slice(
    advanceStart,
    swiftSource.indexOf('@discardableResult\nfunc navigateTab(labels:', advanceStart),
  );
  assert.doesNotMatch(advanceSource,
    /CGEvent|AXUIElement|capture|click|scrollTabStrip|mainWindow|Thread\.sleep/);
  assert.equal((labelsNavigationSource.match(/advanceTabSearch\(/g) || []).length, 1);
  assert.match(labelsNavigationSource, /remainingPages: maxPages - page - 1/);
  assert.match(labelsNavigationSource, /scrollTabStrip\(first, direction: direction\)/);
  assert.doesNotMatch(labelsNavigationSource, /scrollTabStrip\(first\)\s/);
  assert.equal((labelsNavigationSource.match(/for page in 0\.\.<maxPages/g) || []).length, 1);
  assert.ok(labelsNavigationSource.indexOf('guard matches.isEmpty')
    < labelsNavigationSource.indexOf('guard advanceTabSearch('));
  assert.ok(labelsNavigationSource.indexOf('guard advanceTabSearch(')
    < labelsNavigationSource.indexOf('scrollTabStrip(first, direction: direction)'));
  const verifySelectedSource = swiftSource.slice(
    swiftSource.indexOf('func verifySelectedTab('),
    swiftSource.indexOf('// 只回傳數量、信心與幾何布林'),
  );
  assert.match(verifySelectedSource,
    /case \.readOnly:[\s\S]*verifyReadSelectedTab\(tabName,[\s\S]*expectedProfile: expectedReadProfile\)/);
  assert.equal((verifySelectedSource.match(/captureOCR\(/g) || []).length, 2);
  const metadataModeSource = swiftSource.slice(
    swiftSource.indexOf('func postFreshMetadataWheel('),
    swiftSource.indexOf('func listTabChats('),
  );
  assert.equal((metadataModeSource.match(/mode: TabNavigationMode = \.legacy/g) || []).length, 3);
  assert.equal((metadataModeSource.match(/verifySelectedTab\(tabName, mode: mode\)/g) || []).length, 2);
  assert.equal((metadataModeSource.match(/let page = try metadataChatPage\([^\n]+mode: mode\)/g) || []).length, 2);
  assert.equal((metadataModeSource.match(/switch try postFreshMetadataWheel\([\s\S]*?mode: mode\n\s*\)/g) || []).length, 2);
  const listTabChatsSource = swiftSource.slice(
    swiftSource.indexOf('func listTabChats('),
    swiftSource.indexOf('struct TabEvidence'),
  );
  assert.equal((listTabChatsSource.match(/mode: \.readOnly/g) || []).length, 2);
  const p3ScopeSource = swiftSource.slice(
    swiftSource.indexOf('func proveHistoryScope('),
    swiftSource.indexOf('func scrollBoundaryEvidence('),
  ) + swiftSource.slice(
    swiftSource.indexOf('func verifyHistoryScopeStillSelected('),
    swiftSource.indexOf('func historySyncState('),
  );
  assert.equal((p3ScopeSource.match(/mode: \.readOnly/g) || []).length, 4);
  assert.equal((p3ScopeSource.match(/verifyHistoryScopeStillSelected\(/g) || []).length, 3);
  assert.equal((swiftSource.match(/verifyReadSelectedTab\(/g) || []).length, 4);
  assert.equal((swiftSource.match(/captureReadTabOCR\(/g) || []).length, 8);
  const globalRowNameSource = swiftSource.slice(
    swiftSource.indexOf('func globalRowName('),
    swiftSource.indexOf('func readGlobalSearchModel('),
  );
  assert.match(globalRowNameSource, /kAXTitleAttribute/);
  assert.match(globalRowNameSource, /kAXTitleUIElementAttribute/);
  assert.doesNotMatch(globalRowNameSource,
    /kAXValueAttribute|kAXDescriptionAttribute|\.texts\b|capture|vision|OCR/);
  const globalSearchSource = swiftSource.slice(
    swiftSource.indexOf('func readGlobalSearchModel('),
    swiftSource.indexOf('func verifyGlobalAllSelected('),
  );
  assert.match(globalSearchSource, /snapshot\(window, mode: \.geometryOnly\)/);
  assert.match(globalSearchSource, /readTabLayout\(geometry, window: identity\)/);
  assert.match(globalSearchSource, /globalQueryMatches/);
  assert.match(globalSearchSource, /AXUIElementGetPid/);
  assert.match(globalSearchSource, /kAXParentAttribute/);
  assert.doesNotMatch(globalSearchSource,
    /mode: \.text|currentChatRows|chatRows\(|captureNameBandSample|captureWindowImage|visionRequest/);
  const globalRouteSource = swiftSource.slice(
    swiftSource.indexOf('func verifyGlobalAllSelected('),
    swiftSource.indexOf('func verifyGlobalHeader('),
  );
  assert.match(globalRouteSource, /\["全部", "All"\]/);
  assert.equal((globalRouteSource.match(/captureReadTabOCR\(/g) || []).length, 4);
  assert.doesNotMatch(globalRouteSource,
    /scrollTabStrip|scanFullTabInventory|listTabs|listTabChats|navigateTab\(/);
  const selectorSource = globalRouteSource.slice(
    globalRouteSource.indexOf('func selectGlobalAll('),
  );
  assert.match(selectorSource, /runGlobalAllMouseCore\(/);
  assert.match(selectorSource, /buildGlobalAllMouseEvents\(/);
  assert.equal((selectorSource.match(/\.post\(tap: \.cghidEventTap\)/g) || []).length, 1);
  assert.doesNotMatch(selectorSource,
    /runSystemEventsAllCore|compileSystemEventsAllScript|executeSystemEventsAllScript|postToPid|navigateGlobalAll|clickSemanticPoint|NSEvent|windowNumber|kCGWindowNumber|CGWarpMouseCursorPosition/);
  const observerSource = globalRouteSource.slice(
    globalRouteSource.indexOf('func observeGlobalAll('),
    globalRouteSource.indexOf('func selectGlobalAll('),
  );
  assert.match(observerSource, /verifyGlobalAllSelected\(/);
  assert.doesNotMatch(observerSource,
    /AXRaise|activate|NSAppleScript|SystemEvents|execute|CGEvent|postToPid|perform\(/);
  const systemEventsSource = swiftSource.slice(
    swiftSource.indexOf('struct SystemEventsAllCoreFailure'),
    swiftSource.indexOf('enum RawSelectedProof'),
  );
  assert.match(systemEventsSource, /AEDeterminePermissionToAutomateTarget\([\s\S]*false/);
  assert.doesNotMatch(systemEventsSource, /askUserIfNeeded:\s*true|CGRequestPostEventAccess/);
  assert.ok(systemEventsSource.indexOf('invocations = 1')
    < systemEventsSource.indexOf('guard try invoke()'));
  assert.match(systemEventsSource, /with timeout of 3 seconds/);
  assert.match(systemEventsSource, /NSAppleScript\.errorNumber/);
  assert.doesNotMatch(systemEventsSource,
    /NSAppleScript\.(?:errorMessage|errorBriefMessage|errorAppName)/);
  assert.equal((systemEventsSource.match(/click at/g) || []).length, 2,
    '一處固定腳本文字與一處安全 validator literal');
  const signingGuardSource = swiftSource.slice(
    swiftSource.indexOf('func strictLineSigningInfo('),
    swiftSource.indexOf('func lineApplication('),
  );
  assert.match(signingGuardSource, /SecStaticCodeCheckValidity\([^\n]+kSecCSStrictValidate/);
  assert.match(signingGuardSource, /expectedLineExecutablePath/);
  assert.match(signingGuardSource, /expectedLineTeamIdentifier/);
  const pidGuardSource = globalRouteSource.slice(
    globalRouteSource.indexOf('func globalAllInputReady('),
    globalRouteSource.indexOf('enum GlobalAllTargetState'),
  );
  for (const proof of [
    '.hidSystemState', '.combinedSessionState', 'buttonState', 'flagsState',
    'secondsSinceLastEventType', 'CGPreflightPostEventAccess', 'kAXFocusedWindowAttribute',
    'AXUIElementCopyElementAtPosition', 'nearestAXWindow', 'strictLineSigningInfo',
  ]) assert(pidGuardSource.includes(proof), `PID guard 缺少 ${proof}`);
  assert.doesNotMatch(pidGuardSource, /CGRequestPostEventAccess/);
  const eventBuilderSource = swiftSource.slice(
    swiftSource.indexOf('func buildGlobalAllMouseEvents('),
    swiftSource.indexOf('func runGlobalAllMouseCore('),
  );
  for (const proof of [
    '.mouseMoved', '.leftMouseDown', '.leftMouseUp', 'event.flags = []',
    '.mouseEventNumber', '.mouseEventClickState', '.mouseEventPressure',
  ]) assert(eventBuilderSource.includes(proof), `PID event builder 缺少 ${proof}`);
  const eventNumberGuard = eventBuilderSource.indexOf('eventNumber <= Int64(Int16.max)');
  assert(eventNumberGuard >= 0, 'PID event number 必須限制為可無損回讀的 Int16 正整數');
  assert(eventNumberGuard < eventBuilderSource.indexOf('CGEventSource('),
    'PID event number 必須在建立任何 CGEvent 前拒絕');
  const readerAllGateSource = globalRouteSource.slice(
    globalRouteSource.indexOf('func verifyGlobalAllForRead('),
    globalRouteSource.indexOf('func selectGlobalAll('),
  );
  assert.match(readerAllGateSource, /verifyGlobalAllSelected\(/);
  assert.doesNotMatch(readerAllGateSource,
    /selectGlobalAll|navigateGlobalAll|clickSemanticPoint|postToPid|CGEvent/);
  const globalHeaderSource = swiftSource.slice(
    swiftSource.indexOf('func verifyGlobalHeader('),
    swiftSource.indexOf('func verifyAXHeaderIfAvailable('),
  );
  assert.match(globalHeaderSource, /kAXTitleUIElementAttribute/);
  assert.match(globalHeaderSource, /AXUIElementGetPid\(titleElement, &pid\)/);
  assert.ok(globalHeaderSource.indexOf('AXUIElementGetPid(titleElement, &pid)')
    < globalHeaderSource.indexOf('copyAttribute(titleElement, kAXTitleAttribute)'));
  assert.match(globalHeaderSource, /let fallback = try verifyHeader\(chatName\)/);
  assert.doesNotMatch(globalHeaderSource, /captureNameBandSample|captureWindowImage|\.texts\b/);
  const globalProofSource = swiftSource.slice(
    swiftSource.indexOf('func proveGlobalHistoryScope('),
    swiftSource.indexOf('struct IndexedViewportCapture'),
  );
  assert.match(globalProofSource, /globalPressTarget\(/);
  assert.match(globalProofSource, /let target = final\.rows\[targetToken\]/);
  assert.equal((globalProofSource.match(/perform\(kAXPressAction, on: target\.element\)/g) || []).length, 1);
  assert.ok(globalProofSource.indexOf('verifyGlobalAllForRead(')
    < globalProofSource.indexOf('setSearchValue('));
  assert.doesNotMatch(globalProofSource,
    /navigateGlobalAll|selectGlobalAll|clickSemanticPoint|postToPid|currentChatRows|captureNameBandSample|captureWindowImage|scanFullTabInventory|listTabChats/);
  assert.doesNotMatch(p2Source,
    /canonicalReadROI|captureReadTabOCR|verifyReadSelectedTab|TabNavigationMode|\.readOnly/);
  const canonicalSource = swiftSource.slice(
    swiftSource.indexOf('func canonicalReadROI('),
    swiftSource.indexOf('func maskedBadgeROI('),
  );
  assert.ok(canonicalSource.indexOf('validReadROIShape(') < canonicalSource.indexOf('rgbaBottomUp('),
    '唯讀 ROI 預算必須在 RGBA allocation 前驗證');
  const axProbeSource = swiftSource.slice(
    swiftSource.indexOf('func probeAXReadScope('),
    swiftSource.indexOf('func validHex('),
  );
  assert.match(axProbeSource, /metadataSnapshot\(window, maximumNodes: 224, maximumDepth: 12\)/);
  assert.match(axProbeSource, /let menuBudget = max\(1, 256 - tree\.nodes\.count\)/);
  assert.match(axProbeSource, /metadataSnapshot\(rawMenu as! AXUIElement,[\s\S]*maximumNodes: menuBudget, maximumDepth: 12\)/);
  assert.match(axProbeSource, /"ocrUsed": false, "uiEvents": 0/);
  assert.doesNotMatch(axProbeSource,
    /vision|captureWindowImage|captureOCR|CGEvent|AXUIElementPerformAction|AXUIElementSetAttributeValue|NSPasteboard|setSearchValue|readHistoryPage|getHistory|sendMessage|AXEnhancedUserInterface/);
  const exportGateSource = swiftSource.slice(
    swiftSource.indexOf('func validHex('),
    swiftSource.indexOf('func selectChat('),
  );
  assert.match(exportGateSource, /AX_EXPORT_CALIBRATION_REQUIRED/);
  assert.match(exportGateSource, /"sideEffectsAttempted": false/);
  assert.doesNotMatch(exportGateSource,
    /mainWindow|capture|CGEvent|AXUIElement(?:Copy|Get|Set|Perform)|NSPasteboard|FileHandle|Data\(/);
  assert.match(swiftSource, /let axTabOverflowCalibrationVerified = false/);
  assert.match(swiftSource, /if let semantic = try axListTabsIfVerified/);
  assert.match(swiftSource, /if let semantic = try navigateAXTabIfVerified/);
  assert.match(swiftSource, /if let identity = try verifyAXHeaderIfAvailable/);

  const scope = { tabName: 'Scope tab', chatName: 'Scope chat' };
  for (const request of [
    { name: 'listTabChats', args: { tabName: 'Wrong tab', limit: 100, offset: 0 }, liveScope: scope },
    { name: 'previewMarkTabRead', args: { tabName: scope.tabName }, liveScope: scope },
    { name: 'snapshotMarkTabRead', args: { tabName: scope.tabName }, liveScope: scope },
    { name: 'executeMarkTabRead', args: { tabName: scope.tabName }, liveScope: scope },
    { name: 'sendMessage', args: { tabName: scope.tabName, chatName: scope.chatName, message: 'x' }, liveScope: scope },
    { name: 'previewTabChanges', args: { changes: [{ action: 'create_tab', name: 'New' }] }, liveScope: scope },
    { name: 'snapshotTabChanges', args: { changes: [{ action: 'create_tab', name: 'New' }] }, liveScope: scope },
    { name: 'executeTabChange', args: { change: { action: 'create_tab', name: 'New' }, index: 0 }, liveScope: scope },
    { name: 'getHistory', args: { tabName: scope.tabName, chatName: 'Wrong chat' }, liveScope: scope },
    { name: 'probeReadChatTitles', args: {
      tabName: scope.tabName, chatName: 'Wrong chat',
    }, liveScope: scope },
    { name: 'probeReadChatTitles', args: {
      tabName: scope.tabName, chatName: scope.chatName, x: 1,
    }, liveScope: scope },
    { name: 'probeAXReadScope', args: {
      tabName: scope.tabName, chatName: 'Wrong chat',
    }, liveScope: scope },
    { name: 'probeAXReadScope', args: {
      tabName: scope.tabName, chatName: scope.chatName, x: 1,
    }, liveScope: scope },
    { name: 'prepareTextExportScope', args: {
      tabName: scope.tabName, chatName: 'Wrong chat', identityKey: 'a'.repeat(64),
      requestNonce: 'b'.repeat(32),
    }, liveScope: scope },
    { name: 'exportChatText', args: {
      tabName: scope.tabName, chatName: scope.chatName, identityKey: 'a'.repeat(64),
      requestNonce: 'b'.repeat(32), expectedProofDigest: 'c'.repeat(64),
      outputDirectory: '/private/tmp/../escape', outputFileName: `${'d'.repeat(32)}.txt`,
    }, liveScope: scope },
    { name: 'readHistoryPage', args: {
      tabName: scope.tabName, chatName: 'Wrong chat', limit: 10, identityKey: 'a'.repeat(64),
    }, liveScope: scope },
    { name: 'selectGlobalAll', args: {
      chatName: '測試對話', requestNonce: 'a'.repeat(64), expectedWindow: syntheticValidLINEWindow,
    }, liveScope: scope },
    { name: 'observeGlobalAll', args: {
      chatName: '測試對話', requestNonce: 'a'.repeat(64), expectedWindow: syntheticValidLINEWindow,
    }, liveScope: scope },
  ]) {
    const response = run(binary, request);
    assert.equal(response.ok, false);
    assert.equal(response.error.code, 'LIVE_SCOPE_DENIED');
  }

  const globalScope = { kind: 'global', chatName: '測試對話' };
  const globalArgs = { chatName: '測試對話', limit: 5, identityKey: 'a'.repeat(64) };
  for (const request of [
    { name: 'listTabs', args: {}, liveScope: globalScope },
    { name: 'listTabChats', args: { tabName: '全部', limit: 100, offset: 0 }, liveScope: globalScope },
    { name: 'readHistoryPage', args: {
      tabName: '全部', chatName: '測試對話', limit: 5, identityKey: 'a'.repeat(64),
    }, liveScope: globalScope },
    { name: 'readGlobalHistoryPage', args: { ...globalArgs, chatName: '其他' }, liveScope: globalScope },
    { name: 'readGlobalHistoryPage', args: { ...globalArgs, tabName: '全部' }, liveScope: globalScope },
    { name: 'readGlobalHistoryPage', args: globalArgs, liveScope: scope },
    { name: 'selectGlobalAll', args: {
      chatName: '其他', requestNonce: 'a'.repeat(64), expectedWindow: syntheticValidLINEWindow,
    }, liveScope: globalScope },
    { name: 'selectGlobalAll', args: {
      chatName: '測試對話', requestNonce: 'A'.repeat(64), expectedWindow: syntheticValidLINEWindow,
    }, liveScope: globalScope },
    { name: 'observeGlobalAll', args: {
      chatName: '其他', requestNonce: 'a'.repeat(64), expectedWindow: syntheticValidLINEWindow,
    }, liveScope: globalScope },
  ]) {
    const response = run(binary, request);
    assert.equal(response.ok, false);
    assert.equal(response.error.code, 'LIVE_SCOPE_DENIED');
  }
  const invalidMixedGlobalScope = run(binary, {
    name: 'readGlobalHistoryPage', args: globalArgs,
    liveScope: { kind: 'global', chatName: '測試對話', tabName: '全部' },
  });
  assert.equal(invalidMixedGlobalScope.error.code, 'INVALID_LIVE_SCOPE');

  const disabled = run(binary, { name: 'status', args: {} });
  assert.equal(disabled.ok, false);
  assert.equal(disabled.error.code, 'NATIVE_DISABLED');
  const scopedReadDisabled = run(binary, {
    name: 'getHistory', args: { tabName: scope.tabName, chatName: scope.chatName }, liveScope: scope,
  });
  assert.equal(scopedReadDisabled.error.code, 'NATIVE_DISABLED');
  const scopedPageDisabled = run(binary, {
    name: 'readHistoryPage',
    args: { tabName: scope.tabName, chatName: scope.chatName, limit: 10, identityKey: 'a'.repeat(64) },
    liveScope: scope,
  });
  assert.equal(scopedPageDisabled.error.code, 'NATIVE_DISABLED');
  const scopedGlobalPageDisabled = run(binary, {
    name: 'readGlobalHistoryPage', args: globalArgs, liveScope: globalScope,
  });
  assert.equal(scopedGlobalPageDisabled.error.code, 'NATIVE_DISABLED');
  const scopedGlobalSelectorDisabled = run(binary, {
    name: 'selectGlobalAll',
    args: {
      chatName: '測試對話', requestNonce: 'a'.repeat(64), expectedWindow: syntheticValidLINEWindow,
    },
    liveScope: globalScope,
  });
  assert.equal(scopedGlobalSelectorDisabled.error.code, 'NATIVE_DISABLED');
  const scopedGlobalObserverDisabled = run(binary, {
    name: 'observeGlobalAll',
    args: {
      chatName: '測試對話', requestNonce: 'a'.repeat(64), expectedWindow: syntheticValidLINEWindow,
    },
    liveScope: globalScope,
  });
  assert.equal(scopedGlobalObserverDisabled.error.code, 'NATIVE_DISABLED');
  const scopedInventoryDisabled = run(binary, {
    name: 'listTabChats', args: { tabName: scope.tabName, limit: 100, offset: 0 }, liveScope: scope,
  });
  assert.equal(scopedInventoryDisabled.error.code, 'NATIVE_DISABLED');
  const scopedNameProbeDisabled = run(binary, {
    name: 'probeReadChatTitles',
    args: { tabName: scope.tabName, chatName: scope.chatName }, liveScope: scope,
  });
  assert.equal(scopedNameProbeDisabled.error.code, 'NATIVE_DISABLED');
  const scopedAXProbeDisabled = run(binary, {
    name: 'probeAXReadScope',
    args: { tabName: scope.tabName, chatName: scope.chatName }, liveScope: scope,
  });
  assert.equal(scopedAXProbeDisabled.error.code, 'NATIVE_DISABLED');
  const scopedExportDisabled = run(binary, {
    name: 'exportChatText',
    args: {
      tabName: scope.tabName, chatName: scope.chatName, identityKey: 'a'.repeat(64),
      requestNonce: 'b'.repeat(32), expectedProofDigest: 'c'.repeat(64),
      outputDirectory: '/private/tmp/line-export-fixture',
      outputFileName: `${'d'.repeat(32)}.txt`,
    },
    liveScope: scope,
  });
  assert.equal(scopedExportDisabled.error.code, 'NATIVE_DISABLED');
  const p2Disabled = run(binary, {
    name: 'previewTabChanges', args: { changes: [{ action: 'create_tab', name: 'New' }] },
  });
  assert.equal(p2Disabled.error.code, 'NATIVE_DISABLED');

  const nameProbeSource = swiftSource.slice(
    swiftSource.indexOf('func probeReadChatTitles('),
    swiftSource.indexOf('enum OCRRegion'),
  );
  assert.doesNotMatch(nameProbeSource,
    /AXUIElementPerformAction|CGEvent|activate\s*\(|pairedKey|setSearchValue|readHistoryPage|getHistory|sendMessage|AXEnhancedUserInterface/);
});

test('freshSearchField 僅依賴左側搜尋幾何，右側聊天讀寫仍保留完整 layout gate', async () => {
  const swiftSource = await fs.readFile(source, 'utf8');
  const functionSlice = (startMarker, endMarker) => {
    const start = swiftSource.indexOf(startMarker);
    const end = swiftSource.indexOf(endMarker, start + startMarker.length);
    assert(start >= 0, `找不到 source 起點：${startMarker}`);
    assert(end > start, `source 終點無效：${endMarker}`);
    const value = swiftSource.slice(start, end);
    assert(value.length > 0, `${startMarker} source slice 不可為空`);
    return value;
  };
  const searchFieldSource = functionSlice('func freshSearchField(', 'func postMouse(');
  assert.match(searchFieldSource, /readTabLayout\(geometry, window: identity\)/);
  assert.doesNotMatch(searchFieldSource, /lineLayout\(/);
  assert.match(searchFieldSource, /sameWindow\(expected, identity\)/);
  assert.match(searchFieldSource, /record\.frame/);
  assert.match(searchFieldSource, /kAXValueAttribute/);

  const currentChatRowsSource = functionSlice('func currentChatRows(', 'func pairedKey(');
  const fullLayoutConsumers = [
    currentChatRowsSource,
    functionSlice('func verifyAXHeaderIfAvailable(', 'func verifyHeader('),
    functionSlice('func freshComposer(', 'func sendMessage('),
  ];
  const retainsFullLayoutGate = (value) => /lineLayout\(/.test(value);
  assert(fullLayoutConsumers.every(retainsFullLayoutGate));

  const weakenedCurrentChatRows = currentChatRowsSource.replace(
    'lineLayout(geometry, window: identity)',
    'readTabLayout(geometry, window: identity)',
  );
  assert.notEqual(weakenedCurrentChatRows, currentChatRowsSource);
  assert.equal(retainsFullLayoutGate(weakenedCurrentChatRows), false);
});

test('global All 核對分開回報色彩改變、未選取與無效證據，不再共用模糊原因', async () => {
  const native = await fs.readFile(source, 'utf8');
  assert(/func stableGlobalAllSelection\(/.test(native), '全域選取需要獨立且可測的失敗分類');
  for (const code of ['GLOBAL_ALL_PROFILE_CHANGED', 'GLOBAL_ALL_NOT_SELECTED', 'GLOBAL_ALL_SELECTION_INVALID']) {
    assert(native.includes(`NativeFailure("${code}"`));
  }
  assert(/let selected = try stableGlobalAllSelection\(first: first, second: second\)/.test(native),
    '正式全域入口必須使用已測的分類函式');
});


test('搜尋字串已 exact 時先結束，避免重送未知的選單貼上', async () => {
  const swift = await fs.readFile(source, 'utf8');
  const begin = swift.indexOf('func setSearchValue(');
  const clipboard = swift.indexOf('let pasteboard = NSPasteboard.general', begin);
  assert(begin >= 0 && clipboard > begin);
  const prefix = swift.slice(begin, clipboard);
  assert.match(prefix, /freshSearchField\(expected: expected\)/);
  assert.match(prefix, /globalQueryMatches\(observed: existing, expected: value\)/);
  assert.match(prefix, /"usedClipboard": false/);
  assert.doesNotMatch(prefix, /pressSearchMenuItem|postMouse|pairedKey|AXUIElementSetAttributeValue/);
});
