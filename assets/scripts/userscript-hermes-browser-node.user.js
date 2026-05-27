// ==UserScript==
// @name         Hermes Browser Node
// @namespace    hermes-browser-node
// @version      3.0
// @description  浏览器节点 — 通过 WS Server 直接接收并执行 JS 命令
// @match        *://*/*
// @grant        none
// @run-at       document-idle
// ==/UserScript==

/**
 * v3 架构:
 *
 * 浏览器只连 WS Server (:18780)。
 * App 端不再注册 JS 类命令，JS 能力完全由浏览器节点提供。
 *
 * 路由:
 *   JS 命令 (js_exec, canvas.*) → Browser (直接执行)
 *   Native 命令 (camera, tap...) → App (原生能力)
 */
(function () {
  'use strict';

  // ── 配置 ──
  // 手机端运行：127.0.0.1:18780
  // 电脑端调试：改成手机局域网 IP
  const WS_SERVER_URL = 'ws://127.0.0.1:18780';

  const RECONNECT_DELAY = 5000;

  // ── 状态 ──
  let wsConn = null;
  let pingTimer = null;
  let challengeNonce = null;
  let wsConnected = false;

  const deviceId = 'browser-' + Math.random().toString(36).slice(2, 10);

  // ── UI 状态指示 ──
  const badge = document.createElement('div');
  Object.assign(badge.style, {
    position: 'fixed', bottom: '8px', right: '8px', zIndex: 2147483647,
    padding: '4px 10px', borderRadius: '12px', fontSize: '11px',
    fontFamily: 'monospace', color: '#fff', cursor: 'pointer',
    transition: 'all 0.3s', opacity: '0.85',
    background: '#e53935',
    boxShadow: '0 2px 8px rgba(0,0,0,0.3)',
  });
  badge.title = 'Hermes Browser Node\n左键重连 / 右键断开';
  badge.onclick = () => {
    if (wsConnected) { wsDisconnect(); } else { wsConnect(); }
  };
  badge.oncontextmenu = (e) => {
    e.preventDefault();
    wsDisconnect();
  };
  document.body.appendChild(badge);

  function updateBadge() {
    if (wsConnected) {
      badge.style.background = '#43a047';
      badge.textContent = '✓ 已连接';
    } else {
      badge.style.background = '#e53935';
      badge.textContent = '⚠ 断开';
    }
    badge.title = `Hermes Browser Node [${deviceId.slice(0, 12)}]\n` +
      `WS: ${wsConnected ? '✓' : '✗'}\n左键重连 / 右键断开`;
  }

  // ── JS 执行引擎 ──
  function executeJS(code) {
    try {
      const fn = new Function('return (' + code + ')');
      const result = fn();
      if (result && typeof result.then === 'function') {
        return result.then(
          val => ({ ok: true, result: safeStringify(val) }),
          err => ({ ok: false, error: String(err) })
        );
      }
      return { ok: true, result: safeStringify(result) };
    } catch (e) {
      try {
        const fn2 = new Function(code);
        const result2 = fn2();
        if (result2 && typeof result2.then === 'function') {
          return result2.then(
            val => ({ ok: true, result: safeStringify(val) }),
            err => ({ ok: false, error: String(err) })
          );
        }
        return { ok: true, result: safeStringify(result2) };
      } catch (e2) {
        return { ok: false, error: String(e2) };
      }
    }
  }

  function safeStringify(val) {
    if (val === undefined) return 'undefined';
    if (val === null) return 'null';
    try { return typeof val === 'string' ? val : JSON.stringify(val); }
    catch { return String(val); }
  }

  // ════════════════════════════════════════════════════════════════════
  //  通道1: WS Server (:18780) — Node Protocol
  //  接收 Gateway 通过 MCP → WS Server 直接下发的 invoke
  // ════════════════════════════════════════════════════════════════════

  function handleWsInvoke(payload) {
    const invokeId = payload.id;
    const command = payload.command;
    let params = {};
    try { params = JSON.parse(payload.paramsJSON || '{}'); } catch {}

    let resultPromise;

    switch (command) {
      case 'accessibility.js_exec':
        resultPromise = Promise.resolve(executeJS(params.code || ''));
        break;
      case 'canvas.eval':
        resultPromise = Promise.resolve(executeJS(params.script || params.code || ''));
        break;
      case 'canvas.navigate':
        if (params.url) {
          window.location.href = params.url;
          resultPromise = Promise.resolve({ ok: true, result: 'navigating to ' + params.url });
        } else {
          resultPromise = Promise.resolve({ ok: false, error: 'url required' });
        }
        break;
      case 'canvas.snapshot':
        resultPromise = Promise.resolve({
          ok: true,
          result: {
            url: location.href,
            title: document.title,
            viewport: { width: window.innerWidth, height: window.innerHeight },
          }
        });
        break;
      case 'accessibility.js_bridge_info':
        resultPromise = Promise.resolve({
          ok: true,
          result: {
            status: wsConnected ? 'connected' : 'disconnected',
            platform: 'browser',
            deviceId: deviceId,
            url: location.href,
            title: document.title,
          }
        });
        break;
      default:
        resultPromise = Promise.resolve({ ok: false, error: 'Unknown command: ' + command });
    }

    resultPromise.then(result => {
      if (!wsConn || wsConn.readyState !== 1) return;
      wsConn.send(JSON.stringify({
        type: 'request',
        request: 'node.invoke.result',
        id: 'res-' + invokeId,
        payload: {
          id: invokeId,
          ok: result.ok !== false,
          error: result.ok === false ? { message: result.error } : undefined,
          payloadJSON: JSON.stringify(result),
        },
      }));
    });
  }

  function wsConnect() {
    if (wsConn && wsConn.readyState <= 1) return;
    try { wsConn = new WebSocket(WS_SERVER_URL); } catch { setTimeout(wsConnect, RECONNECT_DELAY); return; }

    wsConn.onopen = () => { updateBadge(); };

    wsConn.onmessage = (e) => {
      let msg;
      try { msg = JSON.parse(e.data); } catch { return; }

      // Challenge
      if (msg.type === 'event' && msg.event === 'connect.challenge') {
        challengeNonce = msg.payload?.nonce || '';
        wsConn.send(JSON.stringify({
          type: 'request',
          request: 'connect',
          payload: {
            minProtocol: 3, maxProtocol: 3,
            client: {
              id: deviceId,
              displayName: 'Browser Node',
              version: '3.0.0',
              platform: 'browser',  // ★ 标记为 browser 类型
              mode: 'node',
            },
            role: 'node',
            scopes: ['node.device'],
            caps: ['browser.js_exec'],
            // ★ 只注册 JS 类命令，不注册 native 命令
            commands: [
              'accessibility.js_exec',
              'accessibility.js_bridge_info',
              'canvas.eval',
              'canvas.navigate',
              'canvas.snapshot',
            ],
            auth: {},
            device: { id: deviceId, publicKey: '', signature: '', nonce: challengeNonce, signedAt: Date.now() },
          },
        }));
        return;
      }

      // Connect OK
      if (msg.type === 'res' && msg.ok === true && !wsConnected) {
        wsConnected = true;
        updateBadge();
        clearInterval(pingTimer);
        pingTimer = setInterval(() => {
          try { wsConn.send(JSON.stringify({ type: 'ping' })); } catch {}
        }, 25000);
        return;
      }

      // Connect rejected
      if (msg.type === 'res' && msg.ok === false) {
        wsConnected = false;
        updateBadge();
        return;
      }

      // Invoke request
      if (msg.type === 'event' && msg.event === 'node.invoke.request') {
        handleWsInvoke(msg.payload || {});
        return;
      }
    };

    wsConn.onclose = () => {
      wsConnected = false;
      clearInterval(pingTimer);
      updateBadge();
      setTimeout(wsConnect, RECONNECT_DELAY);
    };

    wsConn.onerror = () => { wsConnected = false; updateBadge(); };
  }

  function wsDisconnect() {
    clearInterval(pingTimer);
    if (wsConn) { try { wsConn.close(); } catch {} wsConn = null; }
    wsConnected = false;
    updateBadge();
  }

  // ── 启动 ──
  wsConnect();
})();
