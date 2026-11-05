import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const source = fileURLToPath(new URL('../src/automation/line-desktop-native.swift', import.meta.url));

test('Qt metadata scanner 只供 listTabChats，P2 membership 與 readback 保留舊 scanner', async () => {
  const swift = await fs.readFile(source, 'utf8');
  const listTabChats = swift.slice(swift.indexOf('func listTabChats('), swift.indexOf('struct TabEvidence'));
  const p2Membership = swift.slice(swift.indexOf('final class P2PreviewContext'), swift.indexOf('func capacityJSON('));
  const mutationReadback = swift.slice(swift.indexOf('func completeMembership('), swift.indexOf('func executeCreateOrRename('));
  assert.match(listTabChats, /scanTabChatsMetadata\(/);
  assert.doesNotMatch(listTabChats, /scanTabChats\(expected:/);
  assert.match(p2Membership, /scanTabChats\(expected:/);
  assert.doesNotMatch(p2Membership, /scanTabChatsMetadata/);
  assert.match(mutationReadback, /scanTabChats\(expected:/);
  assert.doesNotMatch(mutationReadback, /scanTabChatsMetadata/);
  assert.equal((swift.match(/scanTabChatsMetadata\(/g) || []).length, 2);
});

test('Qt metadata scanner 不使用 focus、按鍵、點擊、row press、composer 或 popup', async () => {
  const swift = await fs.readFile(source, 'utf8');
  const scanner = swift.slice(swift.indexOf('struct MetadataChatPage'), swift.indexOf('func listTabChats('));
  const wheel = swift.slice(swift.indexOf('func postMetadataWheel('), swift.indexOf('func pageSignature('));
  assert.doesNotMatch(scanner, /kAXFocusedAttribute|pairedKey|click|kAXPressAction|composer|popup/i);
  assert.match(scanner, /snapshot\(list\.element, mode: \.structure\)/);
  assert.doesNotMatch(scanner, /snapshot\(list\.element, mode: \.text\)/);
  assert.match(scanner, /metadataChatRows/);
  assert.match(wheel, /scrollWheelEvent2Source/);
  assert.match(wheel, /wheel1:\s*intent\.delta/);
  assert.doesNotMatch(wheel, /keyboardEventSource|mouseEventSource|kAXFocusedAttribute/);
});

test('raw-selected fast path 在 click 前使用兩張 raw-only capture', async () => {
  const swift = await fs.readFile(source, 'utf8');
  const navigation = swift.slice(swift.indexOf('func navigateTab(labels:'), swift.indexOf('func chatRows('));
  // 共用 wrapper 可選 legacy／canonical，但 fast path 仍需兩次 raw-only 擷取。
  const rawCapture = navigation.indexOf('captureTabFrame(processedTabs: false)');
  const stableProof = navigation.indexOf('stableRawSelectedTab(');
  const click = navigation.indexOf('clickSemanticPoint(');
  assert(rawCapture >= 0 && stableProof > rawCapture && click > stableProof);
  assert.equal((navigation.match(/captureTabFrame\(processedTabs: false\)/g) || []).length, 2);
  assert.match(navigation, /case \.invalid:[\s\S]*TAB_SELECTION_UNVERIFIED/);
});

test('wheel post 前必須使用 fresh production guards，不能沿用 page 的硬編碼布林值', async () => {
  const swift = await fs.readFile(source, 'utf8');
  const freshStart = swift.indexOf('func postFreshMetadataWheel(');
  const scannerStart = swift.indexOf('func scanTabChatsMetadata(');
  assert(freshStart >= 0 && scannerStart > freshStart);
  const fresh = swift.slice(freshStart, swift.indexOf('func pageSignature(', freshStart));
  const scanner = swift.slice(scannerStart, swift.indexOf('func listTabChats('));
  const selected = fresh.indexOf('verifySelectedTab(');
  const foreground = fresh.indexOf('mainWindow(requireForeground: true)', selected);
  const geometry = fresh.indexOf('snapshot(', foreground);
  const overlay = fresh.indexOf('overlayIntersects(', geometry);
  const secondLimit = fresh.lastIndexOf('metadataWheelLimitReason(');
  const intent = fresh.indexOf('metadataWheelIntent(', secondLimit);
  const post = fresh.indexOf('postMetadataWheel(', intent);
  assert(selected >= 0 && foreground > selected && geometry > foreground && overlay > geometry);
  assert(secondLimit > overlay && intent > secondLimit && post > intent);
  assert.doesNotMatch(fresh, /metadataChatRows|pageSignature|stringAttribute\(|snapshot\([^\n]+\.text/);
  assert.doesNotMatch(scanner, /foreground:\s*true|windowMatches:\s*sameWindow|tabSelected:\s*true|listStable:\s*true/);
  assert.match(scanner, /postFreshMetadataWheel\(/);
});
