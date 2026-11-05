import { MacOSDesktopAutomation, UnsupportedDesktopAutomation } from './desktop-automation.js';
import { MacOSLineAutomation } from './macos-line-automation.js';
import { WindowsLineAutomation } from './windows-line-automation.js';

export class LineAutomation {
  constructor({ platform = process.platform, automation, desktop } = {}) {
    this.platform = platform;

    if (automation) {
      this.automation = automation;
      this.desktop = desktop || automation.desktop || new UnsupportedDesktopAutomation();
    } else if (this.platform === 'darwin') {
      this.desktop = desktop || new MacOSDesktopAutomation();
      this.automation = new MacOSLineAutomation({ desktop: this.desktop });
    } else if (this.platform === 'win32') {
      this.desktop = desktop || new UnsupportedDesktopAutomation();
      this.automation = new WindowsLineAutomation();
    } else {
      throw new Error(`Unsupported platform: ${this.platform}`);
    }
  }

  async switchToEnglish() {
    return await this.automation.switchToEnglish();
  }

  async selectChat(chatName) {
    return await this.automation.selectChat(chatName);
  }

  async copyAllChatToClipboard() {
    return await this.automation.copyAllChatToClipboard();
  }

  async pageUp(times = 2) {
    return await this.automation.pageUp(times);
  }

  async getChatHistory(chatName, date, messageLimit = 100, pageUpTimes = 10) {
    return (await this.getChatHistoryResult(chatName, date, messageLimit, pageUpTimes)).history;
  }

  async getChatHistoryResult(chatName, date, messageLimit = 100, pageUpTimes = 10) {
    let result;
    if (typeof this.automation.getChatHistoryResult === 'function') {
      result = await this.automation.getChatHistoryResult(chatName, date, messageLimit, pageUpTimes);
    } else {
      await this.automation.switchToEnglish();
      await this.automation.activateLine();
      const ok = await this.automation.selectChat(chatName);
      if (!ok) throw new Error(`Chat "${chatName}" not found`);
      await this.automation.pageUp(pageUpTimes);
      result = {
        history: await this.automation.copyAllChatToClipboard(),
        metadata: { complete: false, reasons: ['LEGACY_ADAPTER'], mayAffectReadState: true },
      };
    }
    if (typeof result?.history !== 'string' || !result.metadata || typeof result.metadata !== 'object') {
      throw new Error('History adapter returned an invalid result');
    }
    const chatHistory = result.history;

    // 發行版不提供聊天正文落盤log，避免沿用本機診斷環境變數而外流。

    return result;
  }

  async sendChatMessage(chatName, message, autoSend = false, requestId) {
    if (typeof this.automation.sendChatMessage === 'function') {
      return requestId === undefined
        ? this.automation.sendChatMessage(chatName, message, autoSend)
        : this.automation.sendChatMessage(chatName, message, autoSend, requestId);
    }
    await this.automation.switchToEnglish();
    await this.automation.activateLine();
    const ok = await this.automation.selectChat(chatName);
    if (!ok) throw new Error(`Chat "${chatName}" not found`);
    return this.automation.sendMessage(chatName, message, autoSend);
  }

  async getChatList(includeGroups = true, includeIndividual = true) {
    return await this.automation.getChatList(includeGroups, includeIndividual);
  }

  async isLineRunning() {
    return await this.automation.isLineRunning();
  }

  async activateLine() {
    return await this.automation.activateLine();
  }

  async desktopCall(name, args, context = {}) {
    return this.desktop.call(name, args, context);
  }
}
