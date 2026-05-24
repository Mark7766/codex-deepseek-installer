#!/usr/bin/env bash
# =============================================================================
#  Codex CLI × DeepSeek Installer
#  https://github.com/Mark7766/codex-deepseek-installer
#
#  支持系统: macOS (Intel / Apple Silicon), Linux (x86_64 / arm64)
#  依赖: Node.js >= 18, npm
#
#  用法:
#    curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/Mark7766/codex-deepseek-installer/main/install.sh | bash
#    或克隆后执行: bash install.sh
# =============================================================================
set -euo pipefail

# ─── 颜色 ──────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }
step()    { echo -e "\n${CYAN}${BOLD}▶ $*${NC}"; }

# ─── 常量 ──────────────────────────────────────────────────────────────────────
CODEX_DIR="$HOME/.codex"
PROXY_FILE="$CODEX_DIR/deepseek-proxy.mjs"
CONFIG_FILE="$CODEX_DIR/config.toml"
AUTH_FILE="$CODEX_DIR/auth.json"
LOG_FILE="$CODEX_DIR/proxy.log"
PROXY_PORT=11435
NPM_REGISTRY_CN="https://registry.npmmirror.com"
CODEX_PACKAGE="@openai/codex"
MIN_NODE_MAJOR=18

# 获取脚本所在目录（同时支持 curl 管道安装和本地执行）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"

# ─── Banner ────────────────────────────────────────────────────────────────────
print_banner() {
  echo -e "${CYAN}${BOLD}"
  cat << 'EOF'
   ____          _             ____                 ____            _
  / ___|___   __| | _____  __ |  _ \  ___  ___ _ __/ ___|  ___  ___| | __
 | |   / _ \ / _` |/ _ \ \/ / | | | |/ _ \/ _ \ '_ \___ \ / _ \/ _ \ |/ /
 | |__| (_) | (_| |  __/>  <  | |_| |  __/  __/ |_) |__) |  __/  __/   <
  \____\___/ \__,_|\___/_/\_\ |____/ \___|\___| .__/____/ \___|\___|_|\_\
                                               |_|
              ×  DeepSeek  —  国内直连，无需 VPN
EOF
  echo -e "${NC}"
  echo -e "  ${BOLD}GitHub:${NC} https://github.com/Mark7766/codex-deepseek-installer"
  echo -e "  ${BOLD}Codex:${NC}  https://github.com/openai/codex"
  echo
}

# ─── 工具函数 ──────────────────────────────────────────────────────────────────

# 检测操作系统
detect_os() {
  case "$(uname -s)" in
    Darwin) OS="macos" ;;
    Linux)  OS="linux" ;;
    MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
    *)      die "不支持的操作系统: $(uname -s)，仅支持 macOS, Linux 和 Windows (Git Bash)" ;;
  esac
  ARCH="$(uname -m)"
  info "检测到系统: ${OS} / ${ARCH}"
}

# 检测 shell 配置文件
detect_shell_rc() {
  local shell_name
  shell_name="$(basename "${SHELL:-bash}")"
  case "$shell_name" in
    zsh)  SHELL_RC="$HOME/.zshrc" ;;
    bash) SHELL_RC="$HOME/.bashrc" ;;
    *)    SHELL_RC="$HOME/.profile" ;;
  esac
  
  # 对于 Windows Git Bash，如果默认 shell 是 bash，确保 ~/.bashrc 会被加载
  if [[ "$OS" == "windows" && ! -f "$SHELL_RC" ]]; then
    touch "$SHELL_RC"
    if [[ ! -f "$HOME/.bash_profile" ]]; then
      echo "if [ -f ~/.bashrc ]; then . ~/.bashrc; fi" > "$HOME/.bash_profile"
    fi
  fi
  
  info "Shell 配置文件: $SHELL_RC"
}

# 检查命令是否存在
has_cmd() { command -v "$1" &>/dev/null; }

# 检查端口是否被占用
port_in_use() {
  if [[ "$OS" == "windows" ]]; then
    netstat -an | grep -q ":$1 "
  else
    lsof -ti:"$1" &>/dev/null 2>&1 || ss -tlnp 2>/dev/null | grep -q ":$1 "
  fi
}

# 下载文件（优先 curl，备用 wget）
download() {
  local url="$1" dest="$2"
  if has_cmd curl; then
    curl -fsSL "$url" -o "$dest"
  elif has_cmd wget; then
    wget -qO "$dest" "$url"
  else
    die "需要 curl 或 wget 来下载文件"
  fi
}

# Windows 下通过系统代理设置检测 HTTPS 代理（供 Node.js 使用）
detect_windows_https_proxy() {
  [[ "$OS" == "windows" ]] || return 0
  has_cmd powershell.exe || return 0

  powershell.exe -NoProfile -Command "
    \$uri = [Uri]'https://api.deepseek.com';
    \$proxy = [System.Net.WebRequest]::GetSystemWebProxy();
    \$p = \$proxy.GetProxy(\$uri);
    if (\$p -and \$p.AbsoluteUri -and \$p.AbsoluteUri -ne \$uri.AbsoluteUri) {
      [Console]::Write(\$p.AbsoluteUri)
    }
  " 2>/dev/null | tr -d '\r'
}

# ─── 步骤 1: 检查 Node.js ──────────────────────────────────────────────────────
check_node() {
  step "检查 Node.js 环境"

  if ! has_cmd node; then
    die "未找到 Node.js。请先安装 Node.js >= ${MIN_NODE_MAJOR}\n  推荐安装方式:\n  - macOS: brew install node  或  https://nodejs.org\n  - Linux: https://nodejs.org/en/download/package-manager"
  fi

  local version major
  version="$(node --version)"          # e.g. v20.11.0
  major="${version#v}"
  major="${major%%.*}"

  if [[ "$major" -lt "$MIN_NODE_MAJOR" ]]; then
    die "Node.js 版本过低 ($version)，需要 >= v${MIN_NODE_MAJOR}\n  请升级: https://nodejs.org"
  fi

  success "Node.js $version ✓"
  success "npm $(npm --version) ✓"
}

# ─── 步骤 2: 安装 Codex CLI ────────────────────────────────────────────────────
install_codex() {
  step "安装 Codex CLI"

  if has_cmd codex; then
    local current_ver
    current_ver="$(codex --version 2>/dev/null | head -1 || echo '未知')"
    warn "Codex 已安装: $current_ver"
    read -r -p "  是否重新安装最新版本？[y/N] " yn < /dev/tty || yn="N"
    [[ "$yn" =~ ^[Yy]$ ]] || { info "跳过 Codex 安装"; return 0; }
  fi

  info "使用淘宝镜像安装 ${CODEX_PACKAGE} ..."
  info "镜像地址: $NPM_REGISTRY_CN"

  npm install -g "$CODEX_PACKAGE" \
    --registry "$NPM_REGISTRY_CN" \
    --prefer-online \
    || die "Codex 安装失败。如果镜像不可用，请尝试: npm install -g $CODEX_PACKAGE"

  success "Codex CLI $(codex --version 2>/dev/null | head -1) 安装完成 ✓"
}

# ─── 步骤 3: 安装代理依赖 ──────────────────────────────────────────────────────
install_proxy() {
  step "部署 DeepSeek 代理"

  mkdir -p "$CODEX_DIR"

  # 确定代理源文件位置
  if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/proxy/deepseek-proxy.mjs" ]]; then
    info "使用本地代理文件: $SCRIPT_DIR/proxy/deepseek-proxy.mjs"
    cp "$SCRIPT_DIR/proxy/deepseek-proxy.mjs" "$PROXY_FILE"
  else
    info "尝试下载最新版代理文件..."
    local proxy_tmp
    local fetched=false
    proxy_tmp="$(mktemp 2>/dev/null || echo "$CODEX_DIR/deepseek-proxy.tmp")"

    for proxy_url in \
      "https://ghproxy.net/https://raw.githubusercontent.com/Mark7766/codex-deepseek-installer/main/proxy/deepseek-proxy.mjs" \
      "https://ghproxy.cn/https://raw.githubusercontent.com/Mark7766/codex-deepseek-installer/main/proxy/deepseek-proxy.mjs" \
      "https://raw.githubusercontent.com/Mark7766/codex-deepseek-installer/main/proxy/deepseek-proxy.mjs"; do
      if download "$proxy_url" "$proxy_tmp" 2>/dev/null; then
        mv "$proxy_tmp" "$PROXY_FILE"
        fetched=true
        info "已下载代理文件: $proxy_url"
        break
      fi
    done

    if [[ "$fetched" != "true" ]]; then
      info "下载失败，回退到内置代理文件..."
      cat > "$PROXY_FILE" << 'PROXY_EOF'
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

// Windows / corporate networks often have certificate chains that Node.js
// built-in CA bundle does not trust (Windows uses its own cert store).
// Use a permissive agent for all upstream DeepSeek calls.
const dsAgent = new https.Agent({ rejectUnauthorized: false });
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
        content: null,           // must be null (not '') when only tool_calls present
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
        // Ensure the injected function_call has the SAME call_id as the output.
        // If using fallback (lastToolCalls[0]) the ids may differ; create a copy.
        if (tc) result.push(tc.call_id === item.call_id ? tc : { ...tc, call_id: item.call_id });
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
      agent: dsAgent,
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
      agent: dsAgent,
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
      agent: dsAgent,
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
PROXY_EOF
    fi
  fi

  success "代理文件已写入 $PROXY_FILE ✓"

  # 安装 ws 依赖（本地安装到 ~/.codex/node_modules）
  info "安装代理依赖 ws ..."
  local npm_prefix="$CODEX_DIR"
  if [[ "$OS" == "windows" ]]; then
    npm_prefix="$(cygpath -w "$CODEX_DIR")"
  fi

  npm install --prefix "$npm_prefix" ws \
    --registry "$NPM_REGISTRY_CN" \
    --save-exact \
    --no-fund \
    --no-audit \
    2>/dev/null \
    || npm install --prefix "$npm_prefix" ws --save-exact --no-fund --no-audit \
    || die "ws 依赖安装失败"

  success "代理依赖安装完成 ✓"
}

# ─── 步骤 4: 配置 Codex ────────────────────────────────────────────────────────
configure_codex() {
  step "配置 Codex"

  mkdir -p "$CODEX_DIR"

  # config.toml
  if [[ -f "$CONFIG_FILE" ]]; then
    warn "config.toml 已存在，备份为 config.toml.bak"
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
  fi

  # 选择模型
  echo
  echo -e "  ${BOLD}请选择 DeepSeek 模型:${NC}"
  echo "  1) deepseek-v4-pro    (DeepSeek V4 Pro, 默认推荐 - 性能最强)"
  echo "  2) deepseek-chat      (DeepSeek V3, 速度快，性价比高)"
  echo "  3) deepseek-reasoner  (DeepSeek R1, 深度推理)"
  echo "  4) 自定义输入"
  read -r -p "  请输入选项 [1]: " model_choice < /dev/tty || model_choice=""
  model_choice="${model_choice:-1}"
  model_choice="${model_choice//$'\r'/}"

  case "$model_choice" in
    1) CODEX_MODEL="deepseek-v4-pro" ;;
    2) CODEX_MODEL="deepseek-chat" ;;
    3) CODEX_MODEL="deepseek-reasoner" ;;
    4) 
      read -r -p "  请输入模型名称: " CODEX_MODEL < /dev/tty || CODEX_MODEL="deepseek-v4-pro" 
      CODEX_MODEL="${CODEX_MODEL//$'\r'/}"
      ;;
    *) CODEX_MODEL="deepseek-v4-pro" ;;
  esac

  # 仅写 ASCII 内容，避免 Windows 上多字节编码问题；强制去除 \r
  printf 'model = "%s"\nopenai_base_url = "http://127.0.0.1:%s/v1"\n' \
    "$CODEX_MODEL" "$PROXY_PORT" > "$CONFIG_FILE"
  tr -d '\r' < "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

  success "config.toml 已写入 ✓  (model: $CODEX_MODEL)"
}

# ─── 步骤 5: 配置 API Key ──────────────────────────────────────────────────────
configure_auth() {
  step "配置 DeepSeek API Key"

  echo
  echo -e "  ${BOLD}请输入您的 DeepSeek API Key${NC}"
  echo -e "  获取地址: ${CYAN}https://platform.deepseek.com/api_keys${NC}"
  echo -e "  ${YELLOW}(输入内容不会显示，这是正常的)${NC}"
  echo

  local api_key=""
  while [[ -z "$api_key" ]]; do
    read -r -s -p "  API Key (sk-...): " api_key < /dev/tty || api_key=""
    api_key="${api_key//$'\r'/}"
    # Strip terminal control chars to avoid invalid JSON in auth.json
    api_key="$(printf '%s' "$api_key" | tr -d '\000-\037\177')"
    # If terminal escape noise is prefixed, recover from the last sk- prefix
    if [[ "$api_key" == *"sk-"* && "$api_key" != sk-* ]]; then
      api_key="sk-${api_key##*sk-}"
    fi
    echo
    if [[ -z "$api_key" ]]; then
      warn "API Key 不能为空，请重新输入"
    elif [[ "${#api_key}" -lt 20 ]]; then
      warn "API Key 看起来太短，请确认是否正确"
      read -r -p "  继续使用此 Key？[y/N] " yn < /dev/tty || yn="N"
      yn="${yn//$'\r'/}"
      [[ "$yn" =~ ^[Yy]$ ]] || api_key=""
    fi
  done

  # 写入并强制去除 \r，防止 Windows CRLF 污染 JSON
  printf '{\n  "auth_mode": "apikey",\n  "OPENAI_API_KEY": "%s"\n}\n' \
    "$api_key" > "$AUTH_FILE"
  tr -d '\r' < "$AUTH_FILE" > "${AUTH_FILE}.tmp" && mv "${AUTH_FILE}.tmp" "$AUTH_FILE"
  chmod 600 "$AUTH_FILE"

  success "API Key 已保存到 $AUTH_FILE (权限 600) ✓"
}

# ─── 步骤 6: 配置自动启动 ──────────────────────────────────────────────────────
setup_autostart() {
  step "配置代理自动启动"

  local marker="# codex-deepseek-proxy auto-start"

  # 如果旧配置存在，先删除再重写（避免残留使用 lsof 的旧版本）
  if grep -q "$marker" "$SHELL_RC" 2>/dev/null; then
    info "更新 $SHELL_RC 中的旧版自动启动配置..."
    if [[ "$OS" == "macos" ]]; then
      sed -i '' "/# codex-deepseek-proxy auto-start/,/^unset _DS_PORT_IN_USE$/d" "$SHELL_RC"
    else
      sed -i "/# codex-deepseek-proxy auto-start/,/^unset _DS_PORT_IN_USE$/d" "$SHELL_RC"
    fi
  fi

  cat >> "$SHELL_RC" << 'SHELLEOF'

# codex-deepseek-proxy auto-start
# 由 codex-deepseek-installer 添加，每次新终端检查代理是否运行
_DS_PORT_IN_USE=false
if command -v lsof >/dev/null 2>&1; then
  lsof -ti:11435 >/dev/null 2>&1 && _DS_PORT_IN_USE=true
elif command -v ss >/dev/null 2>&1; then
  ss -tlnp 2>/dev/null | grep -q ":11435 " && _DS_PORT_IN_USE=true
else
  netstat -an 2>/dev/null | grep -q ":11435 " && _DS_PORT_IN_USE=true
fi

if [ "$_DS_PORT_IN_USE" = false ] && [ -f "$HOME/.codex/deepseek-proxy.mjs" ]; then
  _DS_KEY=$(node -e "
    try {
      const fs = require('fs'), os = require('os');
      const a = JSON.parse(fs.readFileSync(os.homedir() + '/.codex/auth.json', 'utf8'));
      console.log(a.OPENAI_API_KEY || '');
    } catch {}
  " 2>/dev/null)
  if [ -n "$_DS_KEY" ]; then
    _DS_PROXY=""
    if command -v powershell.exe >/dev/null 2>&1; then
      _DS_PROXY=$(powershell.exe -NoProfile -Command "
        \$uri = [Uri]'https://api.deepseek.com';
        \$proxy = [System.Net.WebRequest]::GetSystemWebProxy();
        \$p = \$proxy.GetProxy(\$uri);
        if (\$p -and \$p.AbsoluteUri -and \$p.AbsoluteUri -ne \$uri.AbsoluteUri) {
          [Console]::Write(\$p.AbsoluteUri)
        }
      " 2>/dev/null | tr -d '\r')
    fi
    _SCRIPT_PATH="$HOME/.codex/deepseek-proxy.mjs"
    command -v cygpath >/dev/null 2>&1 && _SCRIPT_PATH=$(cygpath -w "$_SCRIPT_PATH")
    if [ -n "$_DS_PROXY" ]; then
      HTTPS_PROXY="$_DS_PROXY" HTTP_PROXY="$_DS_PROXY" \
        DEEPSEEK_API_KEY="$_DS_KEY" \
        nohup node "$_SCRIPT_PATH" \
        >> "$HOME/.codex/proxy.log" 2>&1 &
    else
      DEEPSEEK_API_KEY="$_DS_KEY" \
        nohup node "$_SCRIPT_PATH" \
        >> "$HOME/.codex/proxy.log" 2>&1 &
    fi
    disown
  fi
  unset _DS_KEY
  unset _DS_PROXY
fi
unset _DS_PORT_IN_USE
SHELLEOF

  success "自动启动已添加到 $SHELL_RC ✓"
}

# ─── 步骤 7: 启动代理 ──────────────────────────────────────────────────────────
start_proxy() {
  step "启动 DeepSeek 代理"

  if port_in_use "$PROXY_PORT"; then
    warn "端口 $PROXY_PORT 已被占用，代理可能已在运行"
    return 0
  fi

  local api_key
  api_key="$(node -e "
    try {
      const fs = require('fs'), os = require('os');
      const a = JSON.parse(fs.readFileSync(os.homedir() + '/.codex/auth.json', 'utf8'));
      console.log(a.OPENAI_API_KEY || '');
    } catch {}
  " 2>/dev/null)"

  if [[ -z "$api_key" ]]; then
    warn "无法读取 API Key，请手动启动代理:"
    echo "  DEEPSEEK_API_KEY=sk-xxx node ~/.codex/deepseek-proxy.mjs &"
    return 0
  fi

  local node_script="$PROXY_FILE"
  local log_output="$LOG_FILE"
  local https_proxy=""
  if [[ "$OS" == "windows" ]]; then
    node_script="$(cygpath -w "$PROXY_FILE")"
    log_output="$(cygpath -w "$LOG_FILE")"
    https_proxy="$(detect_windows_https_proxy || true)"
    if [[ -n "$https_proxy" ]]; then
      info "检测到系统代理: $https_proxy"
    fi
  fi

  if [[ -n "$https_proxy" ]]; then
    HTTPS_PROXY="$https_proxy" HTTP_PROXY="$https_proxy" \
      DEEPSEEK_API_KEY="$api_key" nohup node "$node_script" >> "$log_output" 2>&1 &
  else
    DEEPSEEK_API_KEY="$api_key" nohup node "$node_script" >> "$log_output" 2>&1 &
  fi
  disown

  # 等待代理就绪
  local attempts=0
  while ! port_in_use "$PROXY_PORT"; do
    sleep 0.3
    attempts=$((attempts + 1))
    [[ $attempts -ge 15 ]] && { warn "代理启动超时，请查看日志: $LOG_FILE"; return 0; }
  done

  success "代理已启动，监听端口 $PROXY_PORT ✓"
}

# ─── 步骤 8: 验证安装 ──────────────────────────────────────────────────────────
verify_installation() {
  step "验证安装"

  local pass=true

  # 检查 codex 命令
  if has_cmd codex; then
    success "codex 命令可用: $(codex --version 2>/dev/null | head -1) ✓"
  else
    error "codex 命令不可用"
    pass=false
  fi

  # 检查代理文件
  if [[ -f "$PROXY_FILE" ]]; then
    success "代理文件存在: $PROXY_FILE ✓"
  else
    error "代理文件缺失: $PROXY_FILE"
    pass=false
  fi

  # 检查 ws 依赖
  if [[ -d "$CODEX_DIR/node_modules/ws" ]]; then
    success "ws 依赖已安装: ~/.codex/node_modules/ws ✓"
  else
    error "ws 依赖缺失"
    pass=false
  fi

  # 检查 config.toml
  if [[ -f "$CONFIG_FILE" ]]; then
    success "config.toml 存在 ✓"
  else
    error "config.toml 缺失"
    pass=false
  fi

  # 检查代理运行
  if port_in_use "$PROXY_PORT"; then
    success "代理运行中 (端口 $PROXY_PORT) ✓"
  else
    warn "代理未运行，请执行: DEEPSEEK_API_KEY=sk-xxx node ~/.codex/deepseek-proxy.mjs &"
    pass=false
  fi

  $pass
}

# ─── 打印使用说明 ──────────────────────────────────────────────────────────────
print_usage() {
  echo
  echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}${BOLD}  🎉  安装完成！Codex CLI 已成功配置 DeepSeek  🎉${NC}"
  echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════════${NC}"
  echo
  echo -e "${BOLD}快速上手:${NC}"
  echo
  echo -e "  ${CYAN}# 交互模式（AI 编程助手）${NC}"
  echo -e "  codex"
  echo
  echo -e "  ${CYAN}# 执行单个命令${NC}"
  echo -e "  codex exec \"列出当前目录的文件\""
  echo
  echo -e "  ${CYAN}# 完全自动执行（跳过审批）${NC}"
  echo -e "  codex exec --dangerously-bypass-approvals-and-sandbox \"echo hello\""
  echo
  echo -e "${BOLD}代理管理:${NC}"
  echo
  echo -e "  ${CYAN}# 查看代理状态${NC}"
  echo -e "  lsof -ti:${PROXY_PORT}"
  echo
  echo -e "  ${CYAN}# 查看代理日志${NC}"
  echo -e "  tail -f ~/.codex/proxy.log"
  echo
  echo -e "  ${CYAN}# 手动启动代理${NC}"
  echo -e "  DEEPSEEK_API_KEY=sk-xxx node ~/.codex/deepseek-proxy.mjs &"
  echo
  echo -e "  ${CYAN}# 停止代理${NC}"
  echo -e "  kill \$(lsof -ti:${PROXY_PORT})"
  echo
  echo -e "${BOLD}配置文件:${NC}"
  echo -e "  ~/.codex/config.toml   — 模型和 URL 配置"
  echo -e "  ~/.codex/auth.json     — API Key（权限 600，仅自己可读）"
  echo
  echo -e "${YELLOW}重要提示:${NC} 代理在每次新终端时自动启动（已添加到 ${SHELL_RC}）"
  echo -e "          重启代理需要先: ${CYAN}kill \$(lsof -ti:${PROXY_PORT})${NC} 然后重开终端"
  echo
  echo -e "${BOLD}项目地址:${NC} https://github.com/Mark7766/codex-deepseek-installer"
  echo
}

# ─── 主流程 ────────────────────────────────────────────────────────────────────
main() {
  print_banner
  detect_os
  detect_shell_rc

  check_node
  install_codex
  install_proxy
  configure_codex
  configure_auth
  setup_autostart
  start_proxy

  if verify_installation; then
    print_usage
  else
    echo
    warn "安装过程中存在问题，请检查上方错误信息"
    echo -e "  查看日志: ${CYAN}tail -f $LOG_FILE${NC}"
    echo -e "  提交问题: ${CYAN}https://github.com/Mark7766/codex-deepseek-installer/issues${NC}"
    exit 1
  fi
}

main "$@"
