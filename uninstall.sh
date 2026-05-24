#!/usr/bin/env bash
# =============================================================================
#  Codex × DeepSeek 卸载脚本
#  https://github.com/Mark7766/codex-deepseek-installer
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }

CODEX_DIR="$HOME/.codex"
PROXY_PORT=11435

echo -e "${BOLD}Codex × DeepSeek 卸载程序${NC}"
echo

# 确认
read -r -p "确认卸载 Codex CLI 和 DeepSeek 代理？[y/N] " yn < /dev/tty || yn="N"
yn="${yn//$'\r'/}"
[[ "$yn" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }

# 1. 停止代理
info "停止 DeepSeek 代理（如已运行）..."
if command -v lsof >/dev/null 2>&1; then
  PIDS=$(lsof -ti:$PROXY_PORT 2>/dev/null) && [ -n "$PIDS" ] && kill $PIDS 2>/dev/null || true
elif command -v netstat >/dev/null 2>&1; then
  # Windows Git Bash
  netstat -ano 2>/dev/null | grep LISTENING | grep ":$PROXY_PORT " | awk '{print $5}' \
    | xargs -rI{} taskkill //PID {} //F 2>/dev/null || true
fi
sleep 0.5
success "代理已停止 ✓"

# 2. 移除 shell 自动启动配置
for rc_file in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
  if [[ -f "$rc_file" ]] && grep -q "codex-deepseek-proxy auto-start" "$rc_file"; then
    info "从 $rc_file 移除自动启动配置..."
    # 删除从 marker 注释到结束标记之间的内容（与 install.sh 保持一致）
    if [[ "$(uname -s)" == "Darwin" ]]; then
      sed -i '' '/# codex-deepseek-proxy auto-start/,/^unset _DS_PORT_IN_USE$/d' "$rc_file"
    else
      sed -i '/# codex-deepseek-proxy auto-start/,/^unset _DS_PORT_IN_USE$/d' "$rc_file"
    fi
    success "已从 $rc_file 移除 ✓"
  fi
done

# 3. 卸载 Codex CLI
read -r -p "是否同时卸载 Codex CLI (npm uninstall -g @openai/codex)？[y/N] " yn2 < /dev/tty || yn2="N"
yn2="${yn2//$'\r'/}"
if [[ "$yn2" =~ ^[Yy]$ ]]; then
  info "卸载 Codex CLI..."
  npm uninstall -g @openai/codex 2>/dev/null || warn "Codex CLI 卸载失败（可能未安装）"
  success "Codex CLI 已卸载 ✓"
fi

# 4. 删除 ~/.codex 目录
read -r -p "是否删除 ~/.codex 目录（包含 API Key 和代理文件）？[y/N] " yn3 < /dev/tty || yn3="N"
yn3="${yn3//$'\r'/}"
if [[ "$yn3" =~ ^[Yy]$ ]]; then
  warn "正在删除 $CODEX_DIR ..."
  rm -rf "$CODEX_DIR"
  success "~/.codex 已删除 ✓"
else
  info "保留 ~/.codex 目录"
  info "如需手动清理: rm -rf ~/.codex"
fi

echo
success "卸载完成！"
