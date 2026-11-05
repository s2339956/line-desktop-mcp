import applescript from 'applescript';
import { promisify } from 'node:util';
import { AutomationError } from './automation-error.js';
import { MacOSDesktopAutomation } from './desktop-automation.js';

const execAppleScript = promisify(applescript.execString);

export class MacOSLineAutomation {
  constructor({ desktop = new MacOSDesktopAutomation(), appleScript = execAppleScript } = {}) {
    this.desktop = desktop;
    this.appleScript = appleScript;
  }

  // 保留 boolean 原型，避免 AppleScript true 被舊字串轉換邏輯誤判為空字串。
  async osa(script) {
    const result = await this.appleScript(script);
    return typeof result === 'string' ? result.trim() : result;
  }

  async hasAccessibilityPermission() {
    return this.desktop.hasAccessibilityPermission();
  }

  async isLineRunning() {
    return this.desktop.isLineRunning();
  }

  async activateLine() {
    try {
      return await this.desktop.activateLine();
    } catch (error) {
      return { success: false, error: error?.message || String(error) };
    }
  }

  async selectChat(chatName) {
    try {
      await this.desktop.legacySelectChat(chatName);
      return true;
    } catch {
      return false;
    }
  }

  async getChatHistoryResult(chatName, date, messageLimit = 100, pageUpTimes = 10) {
    const result = await this.desktop.legacyHistory(chatName, date, messageLimit, pageUpTimes);
    if (typeof result.history !== 'string' || !result.metadata || typeof result.metadata !== 'object') {
      throw new AutomationError('NATIVE_PROTOCOL_ERROR', '歷史讀取缺少字串或 metadata');
    }
    return result;
  }

  async sendChatMessage(chatName, message, autoSend = false) {
    return this.desktop.legacySend(chatName, message, autoSend);
  }

  async sendMessage(chatName, message, autoSend = false) {
    return this.sendChatMessage(chatName, message, autoSend);
  }

  async switchToEnglish() {
    // 新流程以受控的原生貼上處理文字，不依賴目前輸入法。
  }

  async pageUp() {
    throw new AutomationError('LEGACY_SEQUENCE_UNSUPPORTED', 'Page Up 已併入原子化歷史讀取流程');
  }

  async copyAllChatToClipboard() {
    throw new AutomationError('LEGACY_SEQUENCE_UNSUPPORTED', '歷史讀取已改用 AX 語意內容，不再改動剪貼簿');
  }
}
