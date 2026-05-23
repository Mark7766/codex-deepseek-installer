/**
 * DeepSeek Proxy for Codex CLI
 * ─────────────────────────────────────────────────────────────────────────────
 * Bridges OpenAI Responses API (WebSocket + HTTP SSE) used by Codex CLI
 * to DeepSeek Chat Completions API.
 *
 * Why this proxy is needed:
 *   Codex CLI v0.132+ speaks exclusively the OpenAI Responses API with WebSocket
 *   streaming. DeepSeek only exposes Chat Completions. This proxy translates
 *   between the two protocols transparently.
 *
 * Key protocol details handled:
 *   - WebSocket upgrade on /v1/responses with openai-beta header
 *   - Multi-turn tool calls: injects missing function_call before orphaned
 *     function_call_output items (Codex only sends the output on same-connection turns)
 *   - Thinking models (deepseek-reasoner / deepseek-v4-pro): captures and
 *     replays reasoning_content across turns so DeepSeek doesn't reject the request
 *
 * Usage:
 *   DEEPSEEK_API_KEY=sk-xxx node deepseek-proxy.mjs
 *   PORT=11435 DEEPSEEK_API_KEY=sk-xxx node deepseek-proxy.mjs
 *
 * Dependencies:
 *   ws (installed by the installer into ~/.codex/node_modules)
 * ─────────────────────────────────────────────────────────────────────────────
 */

import http from 'node:http';
import https from 'node:https';
import { createRequire } from 'node:module';

// Load ws from the local node_modules next to this file (installed by installer)
const _require = createRequire(import.meta.url);
const { WebSocketServer } = _require('ws');

const DEEPSEEK_BASE = 'api.deepseek.com';
const DEEPSEEK_API_KEY = process.env.DEEPSEEK_API_KEY || '';
const PORT = parseInt(process.env.PORT || '11435', 10);

const VALID_ROLES = new Set(['system', 'user', 'assistant', 'tool']);

// Global map: call_id -> reasoning_content
// Persists within a proxy process lifetime so reconnecting WebSocket clients
// can still replay the reasoning_content that the thinking model requires.
const callReasoningMap = new Map();

// ─── Role normalisation ───────────────────────────────────────────────────────

function normalizeRole(r) {
  r = (r || 'user').toLowerCase();
  if (r === 'developer') return 'system';
  return VALID_ROLES.has(r) ? r : 'user';
}

// ─── Responses API items → DeepSeek Chat messages ────────────────────────────

function itemsToMessages(input) {
  const messages = [];
  if (!Array.isArray(input)) return messages;
  for (const item of input) {
    if (typeof item === 'string') {
      messages.push({ role: 'user', content: item });
      continue;
    }
    if (item.type === 'function_call_output') {
      messages.push({
        role: 'tool',
        tool_call_id: item.call_id,
        content: typeof item.output === 'string'
          ? item.output
          : JSON.stringify(item.output ?? ''),
      });
      continue;
    }
    if (item.type === 'function_call') {
      const callId = item.call_id || item.id || ('call_' + Date.now());
      const msg = {
        role: 'assistant',
        content: '',
        tool_calls: [{
          id: callId,
          type: 'function',
          function: {
            name: item.name || '',
            arguments: typeof item.arguments === 'string'
              ? item.arguments
              : JSON.stringify(item.arguments ?? {}),
          },
        }],
      };
      // Thinking models require reasoning_content to be passed back
      const rc = callReasoningMap.get(callId);
      if (rc) msg.reasoning_content = rc;
      messages.push(msg);
      continue;
    }
    const role = normalizeRole(item.role);
    let content = '';
    if (typeof item.content === 'string') {
      content = item.content;
    } else if (Array.isArray(item.content)) {
      content = item.content
        .map(c => typeof c === 'string' ? c : (c.text || ''))
        .filter(Boolean)
        .join('\n');
    }
    if (content) messages.push({ role, content });
  }
  return messages;
}

// ─── Inject missing function_call before orphaned function_call_output ────────
//
// On the same WebSocket connection Codex only sends function_call_output in
// the follow-up turn, without repeating the function_call. We inject the
// saved function_call from lastToolCalls so DeepSeek gets a valid sequence.

function fixOrphanedToolResults(input, lastToolCalls) {
  if (!lastToolCalls?.length || !Array.isArray(input)) return input;
  const result = [];
  for (const item of input) {
    if (item.type === 'function_call_output') {
      const hasPreceding = result.some(
        x => x.type === 'function_call' && x.call_id === item.call_id,
      );
      if (!hasPreceding) {
        const tc = lastToolCalls.find(t => t.call_id === item.call_id)
          || lastToolCalls[0];
        if (tc) result.push(tc);
      }
    }
    result.push(item);
  }
  return result;
}

// ─── Extract OpenAI-style tools → DeepSeek function definitions ──────────────

function extractTools(tools) {
  if (!Array.isArray(tools) || !tools.length) return undefined;
  const result = [];
  for (const t of tools) {
    if (t.type === 'web_search' || t.type === 'web_search_preview') continue;
    const name = (t.function?.name) || t.name || '';
    if (!name) continue;
    result.push({
      type: 'function',
      function: {
        name,
        description: (t.function?.description) || t.description || '',
        parameters: (t.function?.parameters) || t.parameters
          || { type: 'object', properties: {} },
      },
    });
  }
  return result.length > 0 ? result : undefined;
}

// ─── Non-streaming DeepSeek call ─────────────────────────────────────────────

function callDeepSeekSync(body) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const req = https.request({
      hostname: DEEPSEEK_BASE,
      path: '/v1/chat/completions',
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${DEEPSEEK_API_KEY}`,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(data),
      },
    }, (res) => {
      let buf = '';
      res.on('data', c => buf += c);
      res.on('end', () => {
        try { resolve({ status: res.statusCode, body: JSON.parse(buf) }); }
        catch (e) { reject(new Error(`Parse: ${e.message}`)); }
      });
    });
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

// ─── Streaming DeepSeek call → Responses API events ─────────────────────────

function streamDeepSeek(chatReq, respId, onEvent) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify({ ...chatReq, stream: true });
    let buffer = '', textItemId = null, textOutputIdx = -1;
    let accText = '', accReasoning = '', nextOutputIdx = 0;
    const toolCalls = {};

    const req = https.request({
      hostname: DEEPSEEK_BASE,
      path: '/v1/chat/completions',
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${DEEPSEEK_API_KEY}`,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(data),
      },
    }, (dsRes) => {
      if (dsRes.statusCode !== 200) {
        let e = '';
        dsRes.on('data', c => e += c);
        dsRes.on('end', () => reject(new Error(`DeepSeek ${dsRes.statusCode}: ${e.slice(0, 300)}`)));
        return;
      }

      dsRes.on('data', chunk => {
        buffer += chunk.toString();
        const lines = buffer.split('\n');
        buffer = lines.pop();
        for (const line of lines) {
          if (!line.startsWith('data: ')) continue;
          const payload = line.slice(6).trim();
          if (payload === '[DONE]') continue;
          try {
            const parsed = JSON.parse(payload);
            const delta = parsed.choices?.[0]?.delta;
            if (!delta) continue;

            // Capture reasoning_content from thinking models
            if (delta.reasoning_content) accReasoning += delta.reasoning_content;

            if (delta.content) {
              if (!textItemId) {
                textItemId = 'msg_' + Date.now();
                textOutputIdx = nextOutputIdx++;
                onEvent('response.output_item.added', {
                  output_index: textOutputIdx,
                  item: { id: textItemId, type: 'message', status: 'in_progress', role: 'assistant', content: [] },
                });
                onEvent('response.content_part.added', {
                  item_id: textItemId, output_index: textOutputIdx, content_index: 0,
                  part: { type: 'output_text', text: '', annotations: [] },
                });
              }
              accText += delta.content;
              onEvent('response.output_text.delta', {
                item_id: textItemId, output_index: textOutputIdx, content_index: 0, delta: delta.content,
              });
            }

            if (delta.tool_calls) {
              for (const tc of delta.tool_calls) {
                const idx = tc.index ?? 0;
                if (!toolCalls[idx]) {
                  const fcId = 'fc_' + Date.now() + '_' + idx;
                  const callId = tc.id || ('call_' + Date.now() + '_' + idx);
                  const fcOutputIdx = nextOutputIdx++;
                  toolCalls[idx] = { outputIdx: fcOutputIdx, id: fcId, callId, name: tc.function?.name || '', args: '' };
                  onEvent('response.output_item.added', {
                    output_index: fcOutputIdx,
                    item: { id: fcId, type: 'function_call', status: 'in_progress', name: tc.function?.name || '', call_id: callId, arguments: '' },
                  });
                  if (tc.function?.arguments) {
                    toolCalls[idx].args += tc.function.arguments;
                    onEvent('response.function_call_arguments.delta', { item_id: fcId, output_index: fcOutputIdx, delta: tc.function.arguments });
                  }
                } else {
                  const fc = toolCalls[idx];
                  if (tc.id && tc.id !== fc.callId) fc.callId = tc.id;
                  if (tc.function?.name && !fc.name) fc.name = tc.function.name;
                  if (tc.function?.arguments) {
                    fc.args += tc.function.arguments;
                    onEvent('response.function_call_arguments.delta', { item_id: fc.id, output_index: fc.outputIdx, delta: tc.function.arguments });
                  }
                }
              }
            }
          } catch { /* ignore malformed SSE chunks */ }
        }
      });

      dsRes.on('end', () => {
        const outputItems = new Array(nextOutputIdx).fill(null);

        if (textItemId) {
          onEvent('response.output_text.done', { item_id: textItemId, output_index: textOutputIdx, content_index: 0, text: accText });
          onEvent('response.content_part.done', {
            item_id: textItemId, output_index: textOutputIdx, content_index: 0,
            part: { type: 'output_text', text: accText, annotations: [] },
          });
          const ti = { id: textItemId, type: 'message', status: 'completed', role: 'assistant', content: [{ type: 'output_text', text: accText, annotations: [] }] };
          onEvent('response.output_item.done', { output_index: textOutputIdx, item: ti });
          outputItems[textOutputIdx] = ti;
        }

        for (const fc of Object.values(toolCalls)) {
          onEvent('response.function_call_arguments.done', { item_id: fc.id, output_index: fc.outputIdx, arguments: fc.args });
          const fi = { id: fc.id, type: 'function_call', status: 'completed', name: fc.name, call_id: fc.callId, arguments: fc.args };
          onEvent('response.output_item.done', { output_index: fc.outputIdx, item: fi });
          outputItems[fc.outputIdx] = fi;
          // Save reasoning_content so it can be replayed on reconnect
          if (accReasoning) callReasoningMap.set(fc.callId, accReasoning);
        }

        const finalOutput = outputItems.filter(Boolean);
        onEvent('response.completed', {
          response: { id: respId, object: 'response', status: 'completed', model: chatReq.model, output: finalOutput },
        });
        resolve({ outputItems: finalOutput, reasoningContent: accReasoning });
      });

      dsRes.on('error', reject);
    });

    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

// ─── HTTP server (models proxy + HTTP SSE fallback) ──────────────────────────

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);

  // Proxy model list
  if (req.method === 'GET' && (url.pathname === '/v1/models' || url.pathname === '/v1')) {
    https.get({
      hostname: DEEPSEEK_BASE,
      path: '/v1/models',
      headers: { 'Authorization': `Bearer ${DEEPSEEK_API_KEY}`, 'Accept': 'application/json' },
    }, (dsRes) => {
      res.writeHead(dsRes.statusCode, { 'Content-Type': 'application/json' });
      dsRes.pipe(res);
    }).on('error', () => {
      res.writeHead(502);
      res.end(JSON.stringify({ error: 'Upstream unreachable' }));
    });
    return;
  }

  // HTTP responses endpoint (SSE streaming + sync)
  if (req.method === 'POST' && url.pathname === '/v1/responses') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', () => {
      try {
        const parsed = JSON.parse(body);
        const sysMsg = parsed.instructions ? [{ role: 'system', content: parsed.instructions }] : [];
        const newMsgs = itemsToMessages(parsed.input);
        const messages = [...sysMsg, ...newMsgs];
        if (!messages.length) messages.push({ role: 'user', content: 'Hello' });

        const chatReq = { model: parsed.model || 'deepseek-chat', messages };
        const tools = extractTools(parsed.tools);
        if (tools) chatReq.tools = tools;
        const respId = 'resp_' + Date.now();

        if (parsed.stream === true) {
          res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', 'Connection': 'keep-alive' });
          const sse = (type, payload) => res.write(`event: ${type}\ndata: ${JSON.stringify({ type, ...payload })}\n\n`);
          sse('response.created', { response: { id: respId, object: 'response', status: 'in_progress', model: chatReq.model, output: [] } });
          streamDeepSeek(chatReq, respId, sse).then(() => res.end()).catch(e => { console.error('[HTTP SSE]', e.message); res.end(); });
        } else {
          callDeepSeekSync({ ...chatReq, stream: false }).then(r => {
            if (r.status !== 200) { res.writeHead(r.status); res.end(JSON.stringify(r.body)); return; }
            const msg = r.body.choices?.[0]?.message || {};
            const msgId = 'msg_' + Date.now();
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({
              id: respId, object: 'response', status: 'completed', model: chatReq.model,
              output: [{ id: msgId, type: 'message', status: 'completed', role: 'assistant', content: [{ type: 'output_text', text: msg.content || '', annotations: [] }] }],
              usage: r.body.usage || {},
            }));
          }).catch(e => { console.error('[HTTP sync]', e.message); res.writeHead(500); res.end(JSON.stringify({ error: { message: e.message } })); });
        }
      } catch (e) {
        console.error('[HTTP parse]', e.message);
        res.writeHead(400);
        res.end(JSON.stringify({ error: { message: e.message } }));
      }
    });
    return;
  }

  res.writeHead(404);
  res.end(JSON.stringify({ error: 'Not found' }));
});

// ─── WebSocket server ─────────────────────────────────────────────────────────

const wss = new WebSocketServer({ noServer: true });

wss.on('connection', (ws) => {
  // Per-connection: remember last tool calls to fix orphaned tool results
  let lastToolCalls = [];

  ws.on('message', (data) => {
    let msg;
    try { msg = JSON.parse(data.toString()); }
    catch (e) { console.error('[WS parse]', e.message); return; }
    if (msg.type !== 'response.create') return;

    const fixedInput = fixOrphanedToolResults(
      Array.isArray(msg.input) ? msg.input : [],
      lastToolCalls,
    );

    const sysMsg = msg.instructions ? [{ role: 'system', content: msg.instructions }] : [];
    const fullMessages = [...sysMsg, ...itemsToMessages(fixedInput)];
    if (!fullMessages.some(m => m.role === 'user' || m.role === 'tool')) {
      fullMessages.push({ role: 'user', content: 'Hello' });
    }

    const chatReq = { model: msg.model || 'deepseek-chat', messages: fullMessages };
    const tools = extractTools(msg.tools);
    if (tools) chatReq.tools = tools;
    const respId = 'resp_' + Date.now();

    const send = (type, payload) => {
      if (ws.readyState === 1) {
        try { ws.send(JSON.stringify({ type, ...payload })); } catch { /* ignore */ }
      }
    };

    send('response.created', {
      response: { id: respId, object: 'response', status: 'in_progress', model: chatReq.model, output: [] },
    });

    streamDeepSeek(chatReq, respId, send)
      .then(({ outputItems }) => {
        lastToolCalls = outputItems.filter(o => o.type === 'function_call');
      })
      .catch(e => {
        console.error('[WS DeepSeek]', e.message);
        send('error', { error: { message: e.message, type: 'server_error' } });
      });
  });

  ws.on('error', e => console.error('[WS]', e.message));
  ws.on('close', code => console.log('[WS] closed', code));
});

server.on('upgrade', (req, socket, head) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  if (url.pathname === '/v1/responses') {
    wss.handleUpgrade(req, socket, head, ws => wss.emit('connection', ws, req));
  } else {
    socket.write('HTTP/1.1 404 Not Found\r\n\r\n');
    socket.destroy();
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[deepseek-proxy] listening on http://127.0.0.1:${PORT}`);
  console.log(`[deepseek-proxy] upstream → https://${DEEPSEEK_BASE}`);
  if (!DEEPSEEK_API_KEY) {
    console.warn('[deepseek-proxy] WARNING: DEEPSEEK_API_KEY is not set!');
  }
});
