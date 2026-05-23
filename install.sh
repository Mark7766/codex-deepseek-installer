#!/usr/bin/env bash
# =============================================================================
#  Codex CLI × DeepSeek Installer
#  https://github.com/Mark7766/codex-deepseek-installer
#
#  支持系统: macOS (Intel / Apple Silicon), Linux (x86_64 / arm64)
#  依赖: Node.js >= 18, npm
#
#  用法:
#    curl -fsSL https://raw.githubusercontent.com/Mark7766/codex-deepseek-installer/main/install.sh | bash
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
    *)      die "不支持的操作系统: $(uname -s)，仅支持 macOS 和 Linux" ;;
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
  info "Shell 配置文件: $SHELL_RC"
}

# 检查命令是否存在
has_cmd() { command -v "$1" &>/dev/null; }

# 检查端口是否被占用
port_in_use() { lsof -ti:"$1" &>/dev/null 2>&1 || ss -tlnp 2>/dev/null | grep -q ":$1 "; }

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
    read -r -p "  是否重新安装最新版本？[y/N] " yn
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
  local proxy_src=""
  if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/proxy/deepseek-proxy.mjs" ]]; then
    proxy_src="$SCRIPT_DIR/proxy/deepseek-proxy.mjs"
    info "使用本地代理文件: $proxy_src"
  else
    info "从 GitHub 下载代理文件..."
    local tmp_proxy
    tmp_proxy="$(mktemp /tmp/deepseek-proxy.XXXXXX.mjs)"
    download \
      "https://raw.githubusercontent.com/Mark7766/codex-deepseek-installer/main/proxy/deepseek-proxy.mjs" \
      "$tmp_proxy"
    proxy_src="$tmp_proxy"
  fi

  cp "$proxy_src" "$PROXY_FILE"
  success "代理文件已复制到 $PROXY_FILE ✓"

  # 安装 ws 依赖（本地安装到 ~/.codex/node_modules）
  info "安装代理依赖 ws ..."
  npm install --prefix "$CODEX_DIR" ws \
    --registry "$NPM_REGISTRY_CN" \
    --save-exact \
    --no-fund \
    --no-audit \
    2>/dev/null \
    || npm install --prefix "$CODEX_DIR" ws --save-exact --no-fund --no-audit \
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
  echo "  1) deepseek-chat      (DeepSeek V3, 推荐 - 速度快，性价比高)"
  echo "  2) deepseek-reasoner  (DeepSeek R1, 深度推理 - 速度慢，质量高)"
  echo "  3) 自定义输入"
  read -r -p "  请输入选项 [1]: " model_choice
  model_choice="${model_choice:-1}"

  case "$model_choice" in
    1) CODEX_MODEL="deepseek-chat" ;;
    2) CODEX_MODEL="deepseek-reasoner" ;;
    3) read -r -p "  请输入模型名称: " CODEX_MODEL ;;
    *) CODEX_MODEL="deepseek-chat" ;;
  esac

  cat > "$CONFIG_FILE" << EOF
# Codex CLI 配置 - 由 codex-deepseek-installer 生成
# 修改后需重启代理生效

model = "${CODEX_MODEL}"
openai_base_url = "http://127.0.0.1:${PROXY_PORT}/v1"
EOF

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
    read -r -s -p "  API Key (sk-...): " api_key
    echo
    if [[ -z "$api_key" ]]; then
      warn "API Key 不能为空，请重新输入"
    elif [[ "${#api_key}" -lt 20 ]]; then
      warn "API Key 看起来太短，请确认是否正确"
      read -r -p "  继续使用此 Key？[y/N] " yn
      [[ "$yn" =~ ^[Yy]$ ]] || api_key=""
    fi
  done

  # 写入 auth.json（权限设为 600，仅自己可读）
  cat > "$AUTH_FILE" << EOF
{
  "auth_mode": "apikey",
  "OPENAI_API_KEY": "${api_key}"
}
EOF
  chmod 600 "$AUTH_FILE"

  success "API Key 已保存到 $AUTH_FILE (权限 600) ✓"
}

# ─── 步骤 6: 配置自动启动 ──────────────────────────────────────────────────────
setup_autostart() {
  step "配置代理自动启动"

  local marker="# codex-deepseek-proxy auto-start"

  if grep -q "$marker" "$SHELL_RC" 2>/dev/null; then
    warn "自动启动配置已存在于 $SHELL_RC，跳过"
    return 0
  fi

  cat >> "$SHELL_RC" << 'SHELLEOF'

# codex-deepseek-proxy auto-start
# 由 codex-deepseek-installer 添加，每次新终端检查代理是否运行
if ! lsof -ti:11435 >/dev/null 2>&1 && [ -f "$HOME/.codex/deepseek-proxy.mjs" ]; then
  _DS_KEY=$(node -e "
    try {
      const fs = require('fs'), os = require('os');
      const a = JSON.parse(fs.readFileSync(os.homedir() + '/.codex/auth.json', 'utf8'));
      console.log(a.OPENAI_API_KEY || '');
    } catch {}
  " 2>/dev/null)
  if [ -n "$_DS_KEY" ]; then
    DEEPSEEK_API_KEY="$_DS_KEY" \
      nohup node "$HOME/.codex/deepseek-proxy.mjs" \
      >> "$HOME/.codex/proxy.log" 2>&1 &
    disown
  fi
  unset _DS_KEY
fi
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

  DEEPSEEK_API_KEY="$api_key" nohup node "$PROXY_FILE" >> "$LOG_FILE" 2>&1 &
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
