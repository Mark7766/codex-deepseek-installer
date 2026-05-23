#!/usr/bin/env bash
# =============================================================================
#  DeepSeek 代理重启脚本
#  当出现 "connection refused (os error 10061)" 时使用
#
#  用法 (一键执行):
#    curl -fsSL "https://ghproxy.net/https://raw.githubusercontent.com/Mark7766/codex-deepseek-installer/main/scripts/restart-proxy.sh" | bash
#    或
#    curl -fsSL "https://raw.githubusercontent.com/Mark7766/codex-deepseek-installer/main/scripts/restart-proxy.sh" | bash
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

CODEX_DIR="$HOME/.codex"
PROXY_FILE="$CODEX_DIR/deepseek-proxy.mjs"
AUTH_FILE="$CODEX_DIR/auth.json"
LOG_FILE="$CODEX_DIR/proxy.log"
PROXY_PORT=11435

# ─── 检测操作系统 ──────────────────────────────────────────────────────────────
case "$(uname -s)" in
  Darwin)              OS="macos" ;;
  Linux)               OS="linux" ;;
  MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
  *)                   OS="unknown" ;;
esac

# ─── 检测端口是否被占用 ────────────────────────────────────────────────────────
port_in_use() {
  if [[ "$OS" == "windows" ]]; then
    netstat -an 2>/dev/null | grep -q ":$1 "
  else
    command -v lsof &>/dev/null && lsof -ti:"$1" &>/dev/null && return 0
    netstat -an 2>/dev/null | grep -q ":$1 "
  fi
}

# ─── 杀死占用端口的进程 ────────────────────────────────────────────────────────
kill_port() {
  local port="$1"
  info "正在终止端口 $port 上的旧进程..."

  if [[ "$OS" == "windows" ]]; then
    # Git Bash on Windows: 用 netstat + taskkill 精确杀进程
    local pids
    # netstat -ano 最后一列是 PID
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
    else
      info "  未找到占用端口 $port 的进程"
    fi
  else
    # macOS / Linux
    local pids
    pids="$(lsof -ti:"$port" 2>/dev/null || true)"
    if [[ -n "$pids" ]]; then
      echo "$pids" | xargs kill -9 2>/dev/null && info "  已终止 PID(s): $(echo "$pids" | tr '\n' ' ')" || true
    else
      info "  未找到占用端口 $port 的进程"
    fi
  fi

  # 等待端口释放（最多 3 秒）
  local i=0
  while port_in_use "$port" && [[ $i -lt 10 ]]; do
    sleep 0.3
    i=$((i + 1))
  done
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

# ─── 读取 API Key ─────────────────────────────────────────────────────────────
read_api_key() {
  command -v node &>/dev/null || die "未找到 Node.js，请先安装"
  [[ -f "$AUTH_FILE" ]] || die "未找到 $AUTH_FILE，请先运行安装脚本"

  node -e "
    try {
      const fs = require('fs'), os = require('os');
      const a = JSON.parse(fs.readFileSync(os.homedir() + '/.codex/auth.json', 'utf8'));
      process.stdout.write(a.OPENAI_API_KEY || '');
    } catch(e) { process.stderr.write('parse error: ' + e.message + '\n'); }
  " 2>/dev/null
}

# ─── 主流程 ───────────────────────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}▶ DeepSeek 代理重启${NC}\n"

# 1. 检查代理文件
[[ -f "$PROXY_FILE" ]] || die "代理文件不存在: $PROXY_FILE\n  请先运行安装脚本: curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/Mark7766/codex-deepseek-installer/main/install.sh | bash"

# 2. 读取 API Key
api_key="$(read_api_key)"
[[ -n "$api_key" ]] || die "无法读取 API Key，请检查 $AUTH_FILE"
info "API Key: ${api_key:0:8}****"

# 3. 杀死旧进程
if port_in_use "$PROXY_PORT"; then
  kill_port "$PROXY_PORT"
else
  info "端口 $PROXY_PORT 当前未被占用"
fi

# 4. 检测系统代理
https_proxy=""
if [[ "$OS" == "windows" ]]; then
  https_proxy="$(detect_windows_https_proxy || true)"
  if [[ -n "$https_proxy" ]]; then
    info "检测到系统代理: $https_proxy"
  fi
fi

# 5. 将路径转换为 Windows 格式（Git Bash 需要）
node_script="$PROXY_FILE"
log_output="$LOG_FILE"
if [[ "$OS" == "windows" ]]; then
  node_script="$(cygpath -w "$PROXY_FILE" 2>/dev/null || echo "$PROXY_FILE")"
  log_output="$(cygpath -w "$LOG_FILE" 2>/dev/null || echo "$LOG_FILE")"
fi

# 6. 启动代理
info "启动代理..."
if [[ -n "$https_proxy" ]]; then
  HTTPS_PROXY="$https_proxy" HTTP_PROXY="$https_proxy" \
    DEEPSEEK_API_KEY="$api_key" nohup node "$node_script" >> "$log_output" 2>&1 &
else
  DEEPSEEK_API_KEY="$api_key" nohup node "$node_script" >> "$log_output" 2>&1 &
fi
disown 2>/dev/null || true

# 7. 等待代理就绪（最多 10 秒）
attempts=0
while ! port_in_use "$PROXY_PORT"; do
  sleep 0.5
  attempts=$((attempts + 1))
  if [[ $attempts -ge 20 ]]; then
    warn "代理启动超时，请查看日志:"
    warn "  cat $LOG_FILE"
    exit 1
  fi
done

ok "代理已启动，监听端口 $PROXY_PORT ✓"
echo -e "\n  ${BOLD}现在可以重新运行 codex 命令了${NC}\n"
