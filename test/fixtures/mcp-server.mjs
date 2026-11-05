import { LineDesktopMCPServer } from '../../src/server.js';

// stdio 真實協定、假 automation；測試子程序不允許建立原生桌面 driver。
const fake = {
  async getChatHistory(...args) { return JSON.stringify(args); },
  async sendChatMessage() { throw new Error('stdio 測試禁止傳送訊息'); },
  async desktopCall(name, args, context) {
    return { name, args, transport: context.transport, fake: true };
  },
};
await new LineDesktopMCPServer(fake).run(false);
