#!/usr/bin/env bash
# =============================================================================
#  DeepSeek API Key 设置脚本
#  当 API Key 输入错误或需要更新时使用
#
#  用法 (一键执行):
#    curl -fsSL "https://ghproxy.net/https://raw.githubusercontent.com/Mark7766/codex-deepseek-installer/main/scripts/set-apikey.sh" | bash
#    或
#    curl -fsSL "https://raw.githubusercontent.com/Mark7766/codex-deepseek-installer/main/scripts/set-apikey.sh" | bash
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

CODEX_DIR="$HOME/.codex"
AUTH_FILE="$CODEX_DIR/auth.json"
LOG_FILE="$CODEX_DIR/proxy.log"
PROXY_FILE="$CODEX_DIR/deepseek-proxy.mjs"
PROXY_PORT=11435

# ─── 检测操作系统 ──────────────────────────────────────────────────────────────
case "$(uname -s)" in
  Darwin)              OS="macos" ;;
  Linux)               OS="linux" ;;
  MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
  *)                   OS="unknown" ;;
esac

# ─── 端口检测 ──────────────────────────────────────────────────────────────────
port_in_use() {
  if [[ "$OS" == "windows" ]]; then
    netstat -an 2>/dev/null | grep -q ":$1 "
  else
    command -v lsof &>/dev/null && lsof -ti:"$1" &>/dev/null && return 0
    netstat -an 2>/dev/null | grep -q ":$1 "
  fi
}

# ─── 检测 Windows 系统代理 ────────────────────────────────────────────────────
detect_windows_https_proxy() {
  [[ "$OS" == "windows" ]] || return 0
  command -v powershell.exe &>/dev/null || return 0

  powershell.exe -NoProfile -Command "
    \$uri = [Uri]'https://api.deepseek.com';
    \$proxy = [System.Net.WebRequest]::GetSystemWebProxy();
    \$p = \$proxy.GetProxy(\$uri);
    if (\$p -and \$p.AbsoluteUri -and \$p.AbsoluteUri -ne \$uri.AbsoluteUri) {
      [Console]::Write(\$p.AbsoluteUri)
    }
  " 2>/dev/null | tr -d '\r'
}

# ─── 杀死端口进程 ─────────────────────────────────────────────────────────────
kill_port() {
  local port="$1"
  if [[ "$OS" == "windows" ]]; then
    local pids
    pids="$(netstat -ano 2>/dev/null \
      | grep ":${port} " \
      | grep -v "TIME_WAIT\|CLOSE_WAIT" \
      | awk '{print $NF}' \
      | sort -u)"
    if [[ -n "$pids" ]]; then
      while IFS= read -r pid; do
        [[ -z "$pid" || "$pid" == "0" ]] && continue
        taskkill.exe /PID "$pid" /F &>/dev/null && info "  已终止 PID $pid" || true
      done <<< "$pids"
    fi
  else
    local pids
    pids="$(lsof -ti:"$port" 2>/dev/null || true)"
    [[ -n "$pids" ]] && echo "$pids" | xargs kill -9 2>/dev/null || true
  fi
  local i=0
  while port_in_use "$port" && [[ $i -lt 10 ]]; do
    sleep 0.3; i=$((i + 1))
  done
}

# ─── 主流程 ───────────────────────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}▶ 设置 DeepSeek API Key${NC}\n"

mkdir -p "$CODEX_DIR"

# 显示当前 Key（如果存在）
if [[ -f "$AUTH_FILE" ]] && command -v node &>/dev/null; then
  current_key="$(node -e "
    try {
      const a = JSON.parse(require('fs').readFileSync('$AUTH_FILE', 'utf8'));
      process.stdout.write(a.OPENAI_API_KEY || '');
    } catch {}
  " 2>/dev/null || true)"
  if [[ -n "$current_key" ]]; then
    info "当前 API Key: ${current_key:0:8}****${current_key: -4}"
  else
    info "当前 API Key: (未设置或无法读取)"
  fi
fi

echo
echo -e "  ${BOLD}请输入新的 DeepSeek API Key${NC}"
echo -e "  获取地址: ${CYAN}https://platform.deepseek.com/api_keys${NC}"
echo -e "  ${YELLOW}(输入内容不会显示，这是正常的)${NC}"
echo

# ─── 读取并校验 API Key ───────────────────────────────────────────────────────
api_key=""
while [[ -z "$api_key" ]]; do
  read -r -s -p "  API Key (sk-...): " api_key < /dev/tty || api_key=""
  api_key="${api_key//$'\r'/}"
  # 去除终端控制字符（防止 Git Bash 下 ESC 序列污染）
  api_key="$(printf '%s' "$api_key" | tr -d '\000-\037\177')"
  # 如果前面带了终端噪声，从最后一个 sk- 截取
  if [[ "$api_key" == *"sk-"* && "$api_key" != sk-* ]]; then
    api_key="sk-${api_key##*sk-}"
  fi
  echo

  if [[ -z "$api_key" ]]; then
    warn "API Key 不能为空，请重新输入"
  elif [[ "${#api_key}" -lt 20 ]]; then
    warn "API Key 看起来太短（当前长度: ${#api_key}），请确认是否正确"
    read -r -p "  继续使用此 Key？[y/N] " yn < /dev/tty || yn="N"
    yn="${yn//$'\r'/}"
    [[ "$yn" =~ ^[Yy]$ ]] || api_key=""
  fi
done

# ─── 写入 auth.json ───────────────────────────────────────────────────────────
printf '{\n  "auth_mode": "apikey",\n  "OPENAI_API_KEY": "%s"\n}\n' \
  "$api_key" > "$AUTH_FILE"
# 强制去除 \r，防止 Windows CRLF 污染 JSON
tr -d '\r' < "$AUTH_FILE" > "${AUTH_FILE}.tmp" && mv "${AUTH_FILE}.tmp" "$AUTH_FILE"
chmod 600 "$AUTH_FILE"

ok "API Key 已保存到 $AUTH_FILE ✓"

# ─── 重启代理（如果代理文件存在）────────────────────────────────────────────
if [[ ! -f "$PROXY_FILE" ]]; then
  warn "代理文件不存在，跳过重启（请运行安装脚本）"
  exit 0
fi

echo
info "正在重启代理以使新 Key 生效..."

# 杀掉旧进程
if port_in_use "$PROXY_PORT"; then
  kill_port "$PROXY_PORT"
fi

# 检测系统代理
https_proxy=""
if [[ "$OS" == "windows" ]]; then
  https_proxy="$(detect_windows_https_proxy || true)"
  [[ -n "$https_proxy" ]] && info "检测到系统代理: $https_proxy"
fi

# 转换路径（Git Bash on Windows 需要 Windows 格式路径）
node_script="$PROXY_FILE"
log_output="$LOG_FILE"
if [[ "$OS" == "windows" ]]; then
  node_script="$(cygpath -w "$PROXY_FILE" 2>/dev/null || echo "$PROXY_FILE")"
  log_output="$(cygpath -w "$LOG_FILE" 2>/dev/null || echo "$LOG_FILE")"
fi

# 启动代理
if [[ -n "$https_proxy" ]]; then
  HTTPS_PROXY="$https_proxy" HTTP_PROXY="$https_proxy" \
    DEEPSEEK_API_KEY="$api_key" nohup node "$node_script" >> "$log_output" 2>&1 &
else
  DEEPSEEK_API_KEY="$api_key" nohup node "$node_script" >> "$log_output" 2>&1 &
fi
disown 2>/dev/null || true

# 等待就绪（最多 10 秒）
attempts=0
while ! port_in_use "$PROXY_PORT"; do
  sleep 0.5
  attempts=$((attempts + 1))
  if [[ $attempts -ge 20 ]]; then
    warn "代理启动超时，请查看日志: $LOG_FILE"
    exit 1
  fi
done

ok "代理已重启，监听端口 $PROXY_PORT ✓"
echo -e "\n  ${BOLD}现在可以运行 codex 命令了${NC}\n"
