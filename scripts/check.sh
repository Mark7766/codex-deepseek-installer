#!/usr/bin/env bash
# =============================================================================
#  安装状态检查脚本
#  用法: bash scripts/check.sh
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
fail() { echo -e "  ${RED}✗${NC}  $*"; FAILED=true; }
warn() { echo -e "  ${YELLOW}!${NC}  $*"; }

CODEX_DIR="$HOME/.codex"
PROXY_PORT=11435
FAILED=false

echo -e "\n${BOLD}Codex × DeepSeek 安装状态检查${NC}\n"

# Node.js
if command -v node &>/dev/null; then
  NODE_VER="$(node --version)"
  MAJOR="${NODE_VER#v}"; MAJOR="${MAJOR%%.*}"
  if [[ "$MAJOR" -ge 18 ]]; then
    ok "Node.js $NODE_VER"
  else
    fail "Node.js $NODE_VER (需要 >= v18)"
  fi
else
  fail "Node.js 未安装"
fi

# Codex CLI
if command -v codex &>/dev/null; then
  ok "Codex CLI $(codex --version 2>/dev/null | head -1)"
else
  fail "Codex CLI 未安装"
fi

# 代理文件
PROXY_FILE="$CODEX_DIR/deepseek-proxy.mjs"
if [[ -f "$PROXY_FILE" ]]; then
  ok "代理文件: $PROXY_FILE"
else
  fail "代理文件缺失: $PROXY_FILE"
fi

# ws 依赖（本地 > Homebrew 全局 > npm 全局）
_ws_local="$CODEX_DIR/node_modules/ws"
_ws_brew="/opt/homebrew/lib/node_modules/ws"
_ws_ver=""
if [[ -d "$_ws_local" ]]; then
  _ws_ver="$(node -e "console.log(require('$_ws_local/package.json').version)" 2>/dev/null || echo '?')"
  ok "ws 依赖: v$_ws_ver (本地 ~/.codex/node_modules)"
elif [[ -d "$_ws_brew" ]]; then
  _ws_ver="$(node -e "console.log(require('$_ws_brew/package.json').version)" 2>/dev/null || echo '?')"
  ok "ws 依赖: v$_ws_ver (Homebrew 全局)"
elif node -e "require('ws')" 2>/dev/null; then
  ok "ws 依赖: 全局可用"
else
  fail "ws 依赖缺失（运行: npm install --prefix ~/.codex ws）"
fi

# config.toml
CONFIG="$CODEX_DIR/config.toml"
if [[ -f "$CONFIG" ]]; then
  MODEL="$(grep '^model' "$CONFIG" 2>/dev/null | head -1 | sed 's/.*= *"\(.*\)"/\1/' || echo '?')"
  ok "config.toml (model: $MODEL)"
else
  fail "config.toml 缺失"
fi

# auth.json
AUTH="$CODEX_DIR/auth.json"
if [[ -f "$AUTH" ]]; then
  PERMS="$(stat -f '%A' "$AUTH" 2>/dev/null || stat -c '%a' "$AUTH" 2>/dev/null || echo '?')"
  KEY_PREFIX="$(node -e "
    try {
      const a = JSON.parse(require('fs').readFileSync('$AUTH', 'utf8'));
      const k = a.OPENAI_API_KEY || '';
      console.log(k ? k.slice(0,8) + '...' : '(空)');
    } catch { console.log('(读取失败)'); }
  " 2>/dev/null)"
  ok "auth.json (Key: $KEY_PREFIX, 权限: $PERMS)"
  if [[ "$PERMS" != "600" ]]; then
    warn "建议将 auth.json 权限设为 600: chmod 600 $AUTH"
  fi
else
  fail "auth.json 缺失（API Key 未配置）"
fi

# 代理运行状态
if lsof -ti:$PROXY_PORT &>/dev/null 2>&1; then
  PID="$(lsof -ti:$PROXY_PORT | head -1)"
  ok "代理运行中 (PID: $PID, 端口: $PROXY_PORT)"
else
  warn "代理未运行 (端口 $PROXY_PORT 空闲)"
  echo -e "     启动命令: ${CYAN}DEEPSEEK_API_KEY=sk-xxx node ~/.codex/deepseek-proxy.mjs &${NC}"
fi

# 代理连通性测试（如果代理在运行）
if lsof -ti:$PROXY_PORT &>/dev/null 2>&1; then
  if command -v curl &>/dev/null; then
    HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PROXY_PORT/v1/models" 2>/dev/null || echo '000')"
    if [[ "$HTTP_CODE" =~ ^(200|401|403)$ ]]; then
      ok "代理 HTTP 可达 (GET /v1/models → $HTTP_CODE)"
    else
      warn "代理 HTTP 响应异常 (GET /v1/models → $HTTP_CODE)"
    fi
  fi
fi

echo
if [[ "$FAILED" == "true" ]]; then
  echo -e "${RED}${BOLD}检查未通过，请根据上方提示修复问题${NC}"
  echo -e "  重新安装: ${CYAN}bash install.sh${NC}"
  echo -e "  提交问题: ${CYAN}https://github.com/Mark7766/codex-deepseek-installer/issues${NC}"
  exit 1
else
  echo -e "${GREEN}${BOLD}所有检查通过 ✓${NC}"
fi
