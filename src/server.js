#!/usr/bin/env node
import 'dotenv/config';

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import express from 'express';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  ErrorCode,
  McpError,
} from '@modelcontextprotocol/sdk/types.js';

import { platform } from 'os';
import { execSync } from 'child_process';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

import { LineAutomation } from './automation/line-automation.js';
import { desktopTools, desktopToolNames } from './desktop-tools.js';
import { randomUUID } from 'node:crypto';

// 取得當前模組的目錄路徑
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
// 協定版本直接沿用套件版本，避免安裝包與工具握手顯示不同版號。
const { version: packageVersion } = JSON.parse(fs.readFileSync(new URL('../package.json', import.meta.url), 'utf8'));


// 只保留人工恢復需要的識別資訊，不把 native 私人內容放進 MCP error data。
function recoveryDetails(error) {
  const details = {};
  if (typeof error.details?.operationId === 'string' && /^[a-f0-9-]{36}$/i.test(error.details.operationId)) {
    details.operationId = error.details.operationId;
  }
  if (error.details?.needsRecovery === true) details.needsRecovery = true;
  if (typeof error.details?.causeCode === 'string' && /^[A-Z0-9_]{1,64}$/.test(error.details.causeCode)) {
    details.causeCode = error.details.causeCode;
  }
  for (const key of ['completedCount', 'totalCount', 'failedIndex']) {
    if (Number.isInteger(error.details?.[key]) && error.details[key] >= 0 && error.details[key] <= 10) details[key] = error.details[key];
  }
  return details;
}

// 首次執行時的設定檢查
async function firstRunSetup() {
  const configMarker = path.join(process.env.HOME || process.env.USERPROFILE, '.line-mcp-setup-complete');
  
  // 如果已經設定過，跳過
  if (fs.existsSync(configMarker)) {
    // 已完成安裝時保持安靜，不輸出使用者家目錄。
    return;
  }

  console.error('First-time setup...');

  let allDependenciesInstalled = true;

  // Windows: 檢查 AutoHotkey
  if (platform() === 'win32') {
    // 建立測試用的 AHK script
    const testScriptPath = path.join(process.env.TEMP || '.', 'test-ahk-installation.ahk');
    const testScriptContent = 'MsgBox "AutoHotkey installation detected successfully"\nExitApp()';
    
    try {
      // 寫入測試 script
      fs.writeFileSync(testScriptPath, testScriptContent);
      
      // 第一次嘗試執行測試 script
      execSync(`autohotkey.exe "${testScriptPath}"`, { stdio: 'ignore', timeout: 5000 });
      console.error('AutoHotkey found');
      
      // 清理測試檔案
      if (fs.existsSync(testScriptPath)) {
        fs.unlinkSync(testScriptPath);
      }
    } catch (firstError) {
      console.error('AutoHotkey not found in PATH, attempting to setup...');
      
      try {
        // 執行 setup-claude-extension.bat 來設定 PATH
        const setupScriptPath = path.join(__dirname, '..', 'scripts', 'setup-claude-extension.bat');
        console.error(`Running setup script: ${setupScriptPath}`);
        execSync(`"${setupScriptPath}"`, { stdio: 'inherit' });
        
        // 再次嘗試執行測試 script
        execSync(`autohotkey.exe "${testScriptPath}"`, { stdio: 'ignore', timeout: 5000 });
        console.error('AutoHotkey found after setup');
        
        // 清理測試檔案
        if (fs.existsSync(testScriptPath)) {
          fs.unlinkSync(testScriptPath);
        }
      } catch (secondError) {
        console.error('ERROR: AutoHotkey installation could not be detected.');
        console.error('Please ensure AutoHotkey is installed and added to your system PATH.');
        console.error('Download from: https://www.autohotkey.com/');
        console.error(`First attempt error: ${firstError.message}`);
        console.error(`Second attempt error: ${secondError.message}`);
        
        // 清理測試檔案
        if (fs.existsSync(testScriptPath)) {
          fs.unlinkSync(testScriptPath);
        }
        
        allDependenciesInstalled = false;
      }
    }
  }
  
  // macOS 改用惰性編譯的內建 Swift helper；協定啟動不應安裝套件或操作桌面。

  // 標記為已設定
  if (allDependenciesInstalled)
    fs.writeFileSync(configMarker, new Date().toISOString());

  console.error('Setup complete!');
}

export class LineDesktopMCPServer {
  constructor(lineAutomation = new LineAutomation(), { transport = 'stdio', sessionId = randomUUID() } = {}) {
    this.server = new Server(
      {
        name: 'line-desktop-mcp',
        version: packageVersion,
      },
      {
        capabilities: {
          tools: {},
        },
      }
    );

    this.lineAutomation = lineAutomation;
    this.desktopContext = { transport, sessionId };
    this.setupToolHandlers();
  }

  setupToolHandlers() {
    // List available tools
    /* 圖片功能，先實作在 LineDesktopMCP_DQ 的 PC 版中
              outputSchema: {
                type: 'object',
                properties: {
                  content: {
                    type: 'array',
                    items: {
                      oneOf: [
                        // TextContent 格式
                        { type: 'text', text: 'string' , description: 'JSON string containing chat metadata and text history'},
                        // ImageContent 格式  
                        { type: 'image', data: 'string', mimeType: 'string' , description: 'last image data which Base64 encoded PNG or JPEG format in chat history'}
                      ]
                    }
                  }
                }
              }
    */
    this.server.setRequestHandler(ListToolsRequestSchema, async () => {
      return {
        tools: [
          {
            name: 'get_line_chatroom_history_default',
            description: 'Extract conversation history from a specific LINE group chat or individual chat, when the amount of data to be read is uncertain, always use this function.',
            inputSchema: {
              type: 'object',
              properties: {
                chatName: {
                  type: 'string',
                  description: 'Name of the chat/group to extract history from',
                },
                date: {
                  type: 'string',
                  description: 'Date to extract history for (YYYY-MM-DD format, defaults to today)',
                },
                messageLimit: {
                  type: 'number',
                  description: 'Maximum number of messages to extract (default: 100)',
                  default: 100,
                },
              },
              required: ['chatName'],
            },
          },
          {
            name: 'get_line_chatroom_history_long',
            description: 'Extract conversation history from a specific LINE group chat or individual chat, when a more complete set of content is needed, such as for summarizing or analyzing data over a period of time.',
            inputSchema: {
              type: 'object',
              properties: {
                chatName: {
                  type: 'string',
                  description: 'Name of the chat/group to extract history from',
                },
                date: {
                  type: 'string',
                  description: 'Date to extract history for (YYYY-MM-DD format, defaults to today)',
                },
                messageLimit: {
                  type: 'number',
                  description: 'Maximum number of messages to extract (default: 100)',
                  default: 100,
                },
              },
              required: ['chatName'],
            },
          },
          {
            name: 'get_line_chatroom_history_short',
            description: 'Extract conversation history from a specific LINE group chat or individual chat, when a quick response is needed, only retrieve the most recent few messages.',
            inputSchema: {
              type: 'object',
              properties: {
                chatName: {
                  type: 'string',
                  description: 'Name of the chat/group to extract history from',
                },
                date: {
                  type: 'string',
                  description: 'Date to extract history for (YYYY-MM-DD format, defaults to today)',
                },
                messageLimit: {
                  type: 'number',
                  description: 'Maximum number of messages to extract (default: 100)',
                  default: 100,
                },
              },
              required: ['chatName'],
            },
          },
          {
            name: 'send_message_manual',
            description: 'Send a message to a specific LINE chat or group, with pre-send review in LINE. If the user’s intent to auto-send is unclear, use this function by default',
            inputSchema: {
              type: 'object',
              properties: {
                chatName: {
                  type: 'string',
                  description: 'Name of the chat/group to send message to',
                },
                message: {
                  type: 'string',
                  description: 'Message content to send',
                },
                requestId: { type: 'string', minLength: 16, maxLength: 128, description: '本機stdio的持久化防重請求編號；同編號不可更換內容。' },
              },
              required: ['chatName', 'message'],
            },
          },
          {
            name: 'send_message_auto',
            description: 'Send a message to a specific LINE chat or group. Sends immediately with no pre-send review in LINE. Use this only if the user explicitly requests immediate sending; otherwise, do not call this function',
            inputSchema: {
              type: 'object',
              properties: {
                chatName: {
                  type: 'string',
                  description: 'Name of the chat/group to send message to',
                },
                message: {
                  type: 'string',
                  description: 'Message content to send',
                },
                requestId: { type: 'string', minLength: 16, maxLength: 128, description: '本機stdio的持久化防重請求編號；同編號不可更換內容。' },
              },
              required: ['chatName', 'message'],
            },
          },
          // 舊 HTTP 安全模型不適合新增桌面操作；本次僅開放原有的五工具。
          ...(this.desktopContext.transport === 'stdio' ? desktopTools : []),
        ]
      };
    });

    // Handle tool calls
    this.server.setRequestHandler(CallToolRequestSchema, async (request) => {
      const { name, arguments: args } = request.params;

      try {
        if (desktopToolNames.has(name)) {
          return await this.handleDesktopTool(name, args);
        }
        switch (name) {
          case 'get_line_chatroom_history_default':
            return await this.handleGetLineChatroomHistoryDefault(args);

          case 'get_line_chatroom_history_long':
            return await this.handleGetLineChatroomHistoryLong(args);

          case 'get_line_chatroom_history_short':
            return await this.handleGetLineChatroomHistoryShort(args);

          case 'send_message_manual':
            return await this.handleSendMessage(args);

          case 'send_message_auto':
            return await this.handleSendMessageAuto(args);

          default:
            throw new McpError(
              ErrorCode.MethodNotFound,
              `Unknown tool: ${name}`
            );
        }
      } catch (error) {
        throw new McpError(
          ErrorCode.InternalError,
          `Error executing tool ${name}: ${error.message}`,
          typeof error.code === 'string' && /^[A-Z0-9_]{1,64}$/.test(error.code)
            ? { automationCode: error.code, ...recoveryDetails(error) } : undefined
        );
      }
    });
  }

  async handleDesktopTool(name, args) {
    try {
      if (this.desktopContext.transport !== 'stdio') {
        const error = new Error('新增桌面工具目前僅支援本機 stdio 連線。');
        error.code = 'TRANSPORT_NOT_ALLOWED';
        throw error;
      }
      const result = await this.lineAutomation.desktopCall(name, args ?? {}, this.desktopContext);
      return { content: [{ type: 'text', text: JSON.stringify(result) }] };
    } catch (error) {
      // 不回傳 native script、剪貼簿或完整 AX tree，避免錯誤診斷洩漏私人內容。
      const details = recoveryDetails(error);
      return {
        isError: true,
        content: [{ type: 'text', text: JSON.stringify({ error: {
          code: typeof error.code === 'string' ? error.code : 'DESKTOP_OPERATION_FAILED',
          message: typeof error.code === 'string' ? error.message : '桌面操作未完成，請檢查狀態後再繼續。',
          ...(Object.keys(details).length ? { details } : {}),
        } }) }],
      };
    }
  }

  async readHistory(chatName, date, messageLimit, pages) {
    if (typeof this.lineAutomation.getChatHistoryResult === 'function') {
      return this.lineAutomation.getChatHistoryResult(chatName, date, messageLimit, pages);
    }
    return { history: await this.lineAutomation.getChatHistory(chatName, date, messageLimit, pages),
      metadata: { complete: false, reasons: ['legacy_backend_without_completeness_evidence'] } };
  }

  async handleGetLineChatroomHistoryDefault(args) {
    return this.handleHistory(args, 10);
  }

  async handleGetLineChatroomHistoryLong(args) {
    return this.handleHistory(args, 50);
  }

  async handleGetLineChatroomHistoryShort(args) {
    return this.handleHistory(args, 5);
  }

  async handleHistory(args, pages) {
    const { chatName, date, messageLimit = 100 } = args;
    const now = new Date();
    // LINE 的日曆日期是電腦本地日期，不能以 UTC 在午夜前後換日。
    const localDate = [now.getFullYear(), String(now.getMonth() + 1).padStart(2, '0'), String(now.getDate()).padStart(2, '0')].join('-');
    const targetDate = date || localDate;
    const result = await this.readHistory(chatName, targetDate, messageLimit, pages);
    const history = typeof result.history === 'string' ? result.history : '';
    const responseTruncated = history.length > 50000;
    // 更新時間來自 MCP 本機請求，避免誤標成 LINE 訊息時間。
    const metadata = { ...result.metadata, responseTruncated,
      chatRoomUpdatedAtSource: 'mcp_local_request_time' };
    if (responseTruncated) {
      metadata.complete = false;
      metadata.reasons = [...new Set([...(metadata.reasons || []), 'response_character_limit'])];
    }
    return {
      content: [{ type: 'text', text: JSON.stringify({
        chatName, date: targetDate, messageLimit,
        history: history.slice(-50000),
        chatRoomUpdatedAt: now.toLocaleString(), metadata,
      }, null, 2) }],
    };
  }

  async handleSendMessage(args, autoSend = false) {
    const { chatName, message, requestId } = args;
    
    if (requestId !== undefined && this.desktopContext.transport !== 'stdio') {
      throw Object.assign(new Error('requestId限本機stdio使用'), { code: 'TRANSPORT_NOT_ALLOWED' });
    }
    const result = requestId === undefined
      ? await this.lineAutomation.sendChatMessage(chatName, message, autoSend)
      : await this.lineAutomation.sendChatMessage(chatName, message, autoSend, requestId);
    // 視窗送出只證明 UI 已提交，不能把輸入區清空包裝成 LINE 伺服器送達。
    const receipt = ['DRAFT_WRITTEN', 'UI_SUBMITTED'].includes(result.receipt?.status)
      ? { status: result.receipt.status, deliveryConfirmed: false,
        observedAt: result.receipt.observedAt } : undefined;
    
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify({
            success: result.success,
            ...(result.replayed ? { replayed: true } : {}),
            chatName,
            message,
            timestamp: new Date().toISOString(),
            error: result.error || null,
            ...(receipt ? { receipt } : {}),
          }, null, 2),
        },
      ],
    };
  }

  async handleSendMessageAuto(args) {
    return this.handleSendMessage(args, true);
  }


  async run(useSSE = false, port = 3000, host = '127.0.0.1', token = null) {
    this.desktopContext.transport = useSSE ? 'http' : 'stdio';
    if (useSSE) {
      // 使用 Streamable HTTP 模式（符合 MCP 2025-06-18 規範）
      const app = express();
      
      // 添加 CORS 支援
      app.use((req, res, next) => {
        res.setHeader('Access-Control-Allow-Origin', '*');
        res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
        res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Accept, Authorization');
        if (req.method === 'OPTIONS') {
          res.sendStatus(200);
          return;
        }
        next();
      });
      
      app.use(express.json());
      
      // Bearer token 驗證中間件
      if (token) {
        app.use('/mcp', (req, res, next) => {
          const authHeader = req.headers['authorization'];
          if (!authHeader || authHeader !== `Bearer ${token}`) {
            console.error(`[AUTH] Rejected request from ${req.ip} - invalid or missing token`);
            res.status(401).json({
              jsonrpc: '2.0',
              error: { code: -32001, message: 'Unauthorized: invalid or missing Bearer token' },
              id: null
            });
            return;
          }
          next();
        });
      }
      
      // MCP 端點路徑
      const endpoint = '/mcp';
      
      // 添加全局日誌中間件
      app.use((req, res, next) => {
        console.error(`[${new Date().toISOString()}] ${req.method} ${req.url} from ${req.ip}`);
        console.error(`Headers:`, JSON.stringify(req.headers));
        next();
      });
      
      // 健康檢查端點
      app.get('/', (req, res) => {
        res.json({
          status: 'running',
          server: 'LINE Desktop MCP Server',
          version: packageVersion,
          mcp_endpoint: endpoint,
          transport: 'Streamable HTTP (MCP 2025-06-18)'
        });
      });
      
      app.get('/health', (req, res) => {
        res.json({ status: 'ok', timestamp: new Date().toISOString() });
      });
      
      // Session 管理
      const transports = {};
      
      // 處理 MCP 端點的請求  
      app.all(endpoint, async (req, res) => {
        console.error(`=== MCP ${req.method} Request ===`);
        const sessionId = req.headers['mcp-session-id'];
        console.error(`Session ID: ${sessionId || 'none'}`);
        
        try {
          let transport;
          
          if (sessionId && transports[sessionId]) {
            // 使用現有 session
            transport = transports[sessionId];
            console.error(`Reusing session: ${sessionId}`);
            const body = req.method === 'POST' ? req.body : null;
            await transport.handleRequest(req, res, body);
            
          } else if (req.method === 'POST' && req.body?.method === 'initialize') {
            // 新的初始化請求
            // 不記錄client初始化內容，避免帳號或路徑進入診斷log。
            console.error('Creating new StreamableHTTP transport');
            
            transport = new StreamableHTTPServerTransport({
              sessionIdGenerator: () => {
                const id = Math.random().toString(36).substring(7);
                console.error(`Generated session ID: ${id}`);
                return id;
              },
              onsessioninitialized: (newSessionId) => {
                console.error(`Session initialized: ${newSessionId}`);
                transports[newSessionId] = transport;
              }
            });
            
            transport.onclose = () => {
              const sid = transport.sessionId;
              if (sid) {
                console.error(`Transport closed: ${sid}`);
                delete transports[sid];
              }
            };
            
            transport.onerror = (error) => {
              console.error(`Transport error:`, error);
            };
            
            // 連接 transport 到 server
            await this.server.connect(transport);
            console.error('Server connected to transport');
            
            // 處理請求
            await transport.handleRequest(req, res, req.body);
            
          } else {
            res.status(400).json({
              jsonrpc: '2.0',
              error: { code: -32000, message: 'Invalid request or missing session' },
              id: null
            });
          }
          
        } catch (error) {
          console.error('Error in endpoint handler:', error);
          if (!res.headersSent) {
            res.status(500).json({
              jsonrpc: '2.0',
              error: { code: -32603, message: error.message },
              id: null
            });
          }
        }
      });
      
      
      app.listen(port, host, () => {
        console.error(`LINE Desktop MCP Server running on Streamable HTTP mode`);
        console.error(`  Listening: http://${host}:${port}${endpoint}`);
        console.error(`  Health:    http://${host}:${port}/health`);
        if (token) {
          console.error(`  Auth:      Bearer token required`);
        }
        console.error(`Ready to accept connections...`);
      });
    } else {
      // 使用 stdio 模式
      const transport = new StdioServerTransport();
      await this.server.connect(transport);
      console.error('LINE Desktop MCP Server running on stdio');
    }
  }
}

// 解析命令列參數
export function parseArgs(args = process.argv.slice(2)) {
  const config = {
    sseMode: false,
    port: 3000,
    host: '127.0.0.1',
    token: null
  };
  
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--http-mode') {
      config.sseMode = true;
    } else if (args[i] === '--port' && i + 1 < args.length) {
      config.port = parseInt(args[i + 1], 10);
      i++; // 跳過下一個參數
    } else if (args[i] === '--host' && i + 1 < args.length) {
      config.host = args[i + 1];
      i++;
    } else if (args[i] === '--token' && i + 1 < args.length) {
      config.token = args[i + 1];
      i++;
    }
  }
  
  return config;
}

export async function main(args = process.argv.slice(2)) {
  // 匯入模組只提供 factory；只有直接啟動 CLI 才執行原設定流程。
  if (args.includes('--version')) { console.log(packageVersion); return; }
  await firstRunSetup();
  const config = parseArgs(args);

  // 保留原 HTTP 綁定規則；新增桌面工具另有 stdio-only gate。
  if (config.sseMode && config.host !== '127.0.0.1' && config.host !== 'localhost') {
    if (!config.token) {
      throw new Error('Binding to a non-loopback address requires --token <secret> for authentication.');
    }
  }
  const server = new LineDesktopMCPServer(undefined, { transport: config.sseMode ? 'http' : 'stdio' });

  if (config.sseMode) {
    console.error(`Starting server in Streamable HTTP mode on ${config.host}:${config.port}`);
    await server.run(true, config.port, config.host, config.token);
  } else {
    console.error('Starting server in stdio mode');
    await server.run(false);
  }
  return server;
}

// 支援 npm bin 的 symlink；測試 import 不會啟程序、安裝或修改使用者設定。
if (process.argv[1] && fs.existsSync(process.argv[1]) && fs.realpathSync(process.argv[1]) === __filename) {
  main().catch(error => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
