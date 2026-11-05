#!/usr/bin/env node
import { doctor } from '../src/automation/doctor.js';
import { NativeBridge } from '../src/automation/native-bridge.js';

if (process.argv.slice(2).some(arg => arg !== '--native')) throw new Error('用法：npm run doctor -- [--native]');
// --native只讀取權限與程序布林值；不啟用LINE、不讀對話、不要求系統授權。
console.log(JSON.stringify(await doctor({ bridge: new NativeBridge(), probeNative: process.argv.includes('--native') }), null, 2));
