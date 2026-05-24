# Codex × DeepSeek Installer

> 🇨🇳 **为国内开发者打造** — 一键安装 [OpenAI Codex CLI](https://github.com/openai/codex)，并自动配置 [DeepSeek](https://platform.deepseek.com) 作为 AI 提供商，**无需 VPN，无需 OpenAI 账号**。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Node.js >= 18](https://img.shields.io/badge/node-%3E%3D18-brightgreen)](https://nodejs.org)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows%20(Git%20Bash)-blue)](#)

---

## ✨ 特性

- **一键安装** — 自动通过淘宝 npm 镜像安装 Codex CLI，国内极速
- **DeepSeek 适配** — 内置代理层，将 Codex 的 OpenAI Responses API 转换为 DeepSeek Chat Completions API
- **WebSocket 支持** — 完整支持 Codex v0.132+ 的 WebSocket 流式协议
- **思考模型支持** — 正确处理 `deepseek-reasoner`（R1）的 `reasoning_content`，跨轮自动回传
- **自动启动** — 代理进程随终端启动，零手动管理
- **安全** — API Key 仅存储在本机 `~/.codex/auth.json`（权限 600），不写入任何配置文件，不上传

## 📋 系统要求

| 要求 | 说明 |
|------|------|
| 操作系统 | macOS 12+、Linux (Ubuntu 20.04+, Debian 11+ 等) 或 Windows (Git Bash) |
| Node.js | >= 18（推荐 20 LTS） |
| npm | 随 Node.js 自带 |
| DeepSeek API Key | [申请地址](https://platform.deepseek.com/api_keys) |

## 🚀 快速安装

### 方式一：一行命令安装（推荐）

```bash
# 国内推荐使用 ghproxy 代理加速下载 (增加时间戳或随机参数防止缓存旧版本)
curl -fsSL "https://ghproxy.net/https://raw.githubusercontent.com/Mark7766/codex-deepseek-installer/main/install.sh?v=$(date +%s)" | bash
```

> **提示**：如果 ghproxy 失效，可尝试将 `ghproxy.net` 替换为 `ghproxy.cn`，或使用下方的克隆方式安装。

### 方式二：克隆后安装

```bash
git clone https://github.com/Mark7766/codex-deepseek-installer.git
cd codex-deepseek-installer
bash install.sh
```

### 安装过程

安装脚本会引导你完成以下步骤：

1. ✅ 检查 Node.js 版本
2. 📦 通过淘宝镜像安装 `@openai/codex`
3. 🔧 部署 DeepSeek 代理到 `~/.codex/`
4. ⚙️ 选择模型并生成 `~/.codex/config.toml`
5. 🔑 安全输入并保存 DeepSeek API Key
6. 🔄 配置代理随终端自动启动
7. ▶️ 启动代理并验证安装

## 💡 使用方法

安装完成后，打开新终端即可使用：

```bash
# 交互式 AI 编程助手
codex

# 执行单个任务（自动决策）
codex exec "帮我写一个 Python 冒泡排序并测试"

# 完全自动执行（跳过每步确认）
codex exec --dangerously-bypass-approvals-and-sandbox "创建 hello.py 并运行"

# 指定工作目录
codex --cwd /path/to/project
```

## 🏗️ 架构说明

```
┌─────────────────────┐     WebSocket/HTTP      ┌──────────────────────┐
│   Codex CLI         │ ──── Responses API ────► │  deepseek-proxy.mjs  │
│  (OpenAI Responses) │     ws://localhost:11435  │   (本地代理)          │
└─────────────────────┘                          └──────────┬───────────┘
                                                            │  HTTPS
                                                            │  Chat Completions
                                                            ▼
                                                 ┌──────────────────────┐
                                                 │   api.deepseek.com   │
                                                 │   /v1/chat/completions│
                                                 └──────────────────────┘
```

**为什么需要代理？**

Codex CLI v0.132+ 仅使用 OpenAI Responses API（包含 WebSocket 流式传输），而 DeepSeek 仅提供 Chat Completions API。代理层在本地实现协议转换，完全透明。

### 代理解决的技术问题

| 问题 | 解决方案 |
|------|----------|
| 协议不兼容 | Responses API WebSocket ↔ Chat Completions HTTP 双向转换 |
| 工具调用连续性 | 同连接内孤立 `function_call_output` 自动注入对应 `function_call` |
| 思考模型支持 | 跨轮捕获并回传 `reasoning_content`（R1 必需） |

## ⚙️ 配置文件

### `~/.codex/config.toml`

```toml
model = "deepseek-v4-pro"            # 或 deepseek-chat / deepseek-reasoner
openai_base_url = "http://127.0.0.1:11435/v1"
```

**可用模型：**

| 模型 | 说明 | 推荐场景 |
|------|------|----------|
| `deepseek-v4-pro` | DeepSeek V4 Pro，性能最强 | 默认推荐，最强代码能力 |
| `deepseek-chat` | DeepSeek V3，速度快 | 日常编程，性价比高 |
| `deepseek-reasoner` | DeepSeek R1，深度推理 | 复杂算法、架构设计 |

### `~/.codex/auth.json`（权限 600，不会上传）

```json
{
  "auth_mode": "apikey",
  "OPENAI_API_KEY": "sk-你的key"
}
```

## 🔧 常用操作

> 所有 `curl` 命令均使用 **ghproxy.net** 代理加速（国内直连），URL 末尾附加 `?v=$(date +%s)` 时间戳，防止 CDN 缓存旧版本。

---

### 📦 安装

```bash
curl -fsSL "https://ghproxy.net/https://raw.githubusercontent.com/Mark7766/codex-deepseek-installer/main/install.sh?v=$(date +%s)" | bash
```

---

### 🗑️ 卸载

> **注意**：卸载脚本有交互确认步骤，必须先下载再执行（不能直接 `curl | bash`，否则交互输入异常）。

```bash
# 先下载，再执行（macOS / Linux / Windows Git Bash 通用）
curl -fsSL "https://ghproxy.net/https://raw.githubusercontent.com/Mark7766/codex-deepseek-installer/main/uninstall.sh?v=$(date +%s)" -o /tmp/codex-uninstall.sh && bash /tmp/codex-uninstall.sh
```

> 卸载会移除 `~/.codex/` 目录、codex 全局包，并清理 shell 配置中的自动启动片段。

---

### ⏹️ 停止代理（Kill 代理进程）

**macOS / Linux：**

```bash
kill $(lsof -ti:11435) 2>/dev/null; echo "代理已停止"
```

**Windows Git Bash：**

```bash
netstat -ano | grep LISTENING | grep :11435 | awk '{print $5}' | xargs -I{} taskkill //PID {} //F 2>/dev/null; echo "代理已停止"
```

---

### ▶️ 启动 / 重启代理

代理随每次新终端自动启动，**打开新终端** 是最简单的重启方式。也可手动触发：

**macOS / Linux：**

```bash
# zsh 用户
source ~/.zshrc
# bash 用户
source ~/.bashrc
```

**Windows Git Bash：**

```bash
source ~/.bashrc
```

---

### 🔁 重新安装（一键完整流程）

> **适用场景**：升级到最新版、修复安装异常、更换 API Key 或模型。
>
> 执行顺序：**停止代理 → 卸载（自动全确认） → 安装（交互输入 Key/模型）**

**macOS / Linux：**

```bash
kill $(lsof -ti:11435) 2>/dev/null; sleep 1; \
curl -fsSL "https://ghproxy.net/https://raw.githubusercontent.com/Mark7766/codex-deepseek-installer/main/uninstall.sh?v=$(date +%s)" | bash -s -- -y; \
curl -fsSL "https://ghproxy.net/https://raw.githubusercontent.com/Mark7766/codex-deepseek-installer/main/install.sh?v=$(date +%s)" -o /tmp/codex-install.sh && bash /tmp/codex-install.sh
```

**Windows Git Bash：**

```bash
netstat -ano | grep LISTENING | grep :11435 | awk '{print $5}' | xargs -I{} taskkill //PID {} //F 2>/dev/null; sleep 2; \
curl -fsSL "https://ghproxy.net/https://raw.githubusercontent.com/Mark7766/codex-deepseek-installer/main/uninstall.sh?v=$(date +%s)" | bash -s -- -y; \
curl -fsSL "https://ghproxy.net/https://raw.githubusercontent.com/Mark7766/codex-deepseek-installer/main/install.sh?v=$(date +%s)" -o /tmp/codex-install.sh && bash /tmp/codex-install.sh
```

> 卸载步骤使用 `-y` 静默全自动模式（无需手动确认），安装步骤下载到本地后再执行（支持交互输入 API Key）。

---

### 📋 查看状态 / 日志

```bash
# 检查安装完整性
curl -fsSL "https://ghproxy.net/https://raw.githubusercontent.com/Mark7766/codex-deepseek-installer/main/scripts/check.sh?v=$(date +%s)" | bash

# 检查代理端口（macOS/Linux）
lsof -ti:11435
# 检查代理端口（Windows）
netstat -ano | findstr :11435

# 实时查看代理日志
tail -f ~/.codex/proxy.log
```

## 🤝 兼容的 AI 编程工具

本项目将 DeepSeek 暴露为标准 OpenAI 兼容接口，除 Codex CLI 外，以下工具也可受益：

- **[Claude Code](https://claude.ai/code)** — 配置 `ANTHROPIC_BASE_URL` 或使用 OpenAI 兼容模式
- **[Cursor](https://cursor.sh)** — 在设置中配置 OpenAI Base URL 为 `http://127.0.0.1:11435/v1`
- **[Opencode](https://opencode.ai)** — 配置 provider 为 openai，base url 指向本地代理
- **[Continue.dev](https://continue.dev)** — 添加 OpenAI 兼容 provider

## 🐛 常见问题

**Q: 安装后运行 `codex` 提示找不到命令？**

```bash
# 重新加载 shell 配置
source ~/.zshrc   # zsh 用户
source ~/.bashrc  # bash 用户
# Git Bash 用户可执行: source ~/.bashrc
```

**Q: 代理报错 `DEEPSEEK_API_KEY not set`？**

检查 `~/.codex/auth.json` 是否存在且格式正确，或重新运行 `bash install.sh`。

**Q: DeepSeek API 返回 400 错误？**

- 确认 API Key 有效且有余额（[查看余额](https://platform.deepseek.com)）
- 若使用 `deepseek-reasoner` 报 `reasoning_content` 错误，说明代理版本过旧，请重新安装

**Q: 在 Linux 上 `lsof` 命令不存在？**

```bash
# Ubuntu/Debian
sudo apt install lsof
# CentOS/RHEL
sudo yum install lsof
```

**Q: 代理每次都要手动启动？**

确认 `~/.zshrc`（或 `~/.bashrc`）包含自动启动片段（`codex-deepseek-proxy auto-start`），并重新加载：

```bash
grep "codex-deepseek-proxy" ~/.zshrc   # 检查是否存在
source ~/.zshrc                         # 重新加载
```

## 📄 许可证

[MIT License](LICENSE) — 自由使用、修改和分发。

---

<div align="center">
  如果这个项目对你有帮助，请给个 ⭐ Star！<br>
  有问题或建议？欢迎 <a href="https://github.com/Mark7766/codex-deepseek-installer/issues">提交 Issue</a>
</div>
