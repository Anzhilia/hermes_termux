<div align="center">
  <h1>Hermes Agent Android</h1>
  <p>基于 openclaw-termux-zh 改造的 Hermes Agent Android 独立客户端</p>
  <p>
    <img src="https://img.shields.io/badge/Version-v0.1.0-7C3AED?style=for-the-badge" alt="Version" />
    <img src="https://img.shields.io/badge/Android-10%2B-3DDC84?style=for-the-badge&logo=android&logoColor=white" alt="Android" />
    <img src="https://img.shields.io/badge/License-MIT-111827?style=for-the-badge" alt="License" />
  </p>
  <p>
    <img src="https://img.shields.io/badge/Flutter-App_Shell-02569B?style=flat-square&logo=flutter&logoColor=white" alt="Flutter" />
    <img src="https://img.shields.io/badge/Python-3.11+-3776AB?style=flat-square&logo=python&logoColor=white" alt="Python" />
    <img src="https://img.shields.io/badge/Ubuntu-RootFS-E95420?style=flat-square&logo=ubuntu&logoColor=white" alt="Ubuntu" />
    <img src="https://img.shields.io/badge/Hermes-Agent-7C3AED?style=flat-square" alt="Hermes" />
  </p>
</div>

## 项目说明

本项目基于 [JunWan666/openclaw-termux-zh](https://github.com/JunWan666/openclaw-termux-zh) 改造，将 OpenClaw 替换为 [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)，提供一个开箱即用的 Android 客户端。

**核心变化：**
- 运行时从 Node.js + npm 改为 Python 3 + pip
- 配置从 JSON (`openclaw.json`) 改为 YAML (`config.yaml`)
- 使用 Hermes 官方安装脚本自动处理 Termux/PRoot 兼容
- Dashboard 端口从 18789 改为 9119
- 所有界面文字、多语言（中/英/日/繁）已更新

## 架构

```
Flutter APK
    ↕ MethodChannel
Android Native (Kotlin)
    ↕ PRoot
Ubuntu 容器
    ↕
Hermes Agent CLI + Dashboard WebUI (port 9119)
    ↕
config.yaml (YAML 配置)
```

## 功能

- ✅ 一键安装 Ubuntu RootFS + Python 3 + Hermes Agent
- ✅ 中文安装向导，自动检测已有环境
- ✅ AI 提供商管理（支持 OpenAI 兼容、自定义端点）
- ✅ 终端模拟器（直接运行 `hermes chat` 等命令）
- ✅ Dashboard WebView（嵌入 Hermes Web UI）
- ✅ 消息平台配置（Telegram、Discord、微信等）
- ✅ 配置文件编辑器（YAML 语法）
- ✅ 备份与恢复
- ✅ 节点配对能力（Camera、Location、Screen、Sensors 等）

## 安装方式

### 方式一：下载 APK（推荐）

从 [Releases](../../releases) 页面下载适合你设备架构的 APK：

| 文件 | 适用设备 |
|------|---------|
| `hermes-agent-universal.apk` | 不确定架构，直接安装 |
| `hermes-agent-arm64-v8a.apk` | 大多数现代手机 |
| `hermes-agent-armeabi-v7a.apk` | 较老的 32 位设备 |

### 方式二：源码构建

```bash
git clone https://github.com/YOUR_USERNAME/hermes-agent-android.git
cd hermes-agent-android/flutter_app
flutter pub get
flutter build apk --release
```

## 首次使用

1. 安装 APK，授予必要权限
2. 打开应用，进入安装向导
3. 向导会自动：
   - 下载并解压 Ubuntu RootFS
   - 安装 Python 3 + pip
   - 通过 Hermes 官方安装脚本安装 hermes-agent
4. 安装完成后配置 AI 提供商（API Key + 模型）
5. 启动 Gateway，在终端运行 `hermes chat` 开始对话

## 与 OpenClaw 版本的区别

| 维度 | OpenClaw 版 | Hermes 版 |
|------|------------|-----------|
| 运行时 | Node.js 24 + npm | Python 3.11+ + pip |
| 核心包 | `openclaw` (npm) | `hermes-agent` (PyPI) |
| 配置格式 | JSON | YAML |
| 配置路径 | `/root/.openclaw/openclaw.json` | `/root/.hermes/config.yaml` |
| Dashboard 端口 | 18789 | 9119 |
| 安装方式 | npm install | 官方 install.sh 脚本 |
| 消息平台 | openclaw gateway | hermes gateway |

## 致谢

- [openclaw-termux-zh](https://github.com/JunWan666/openclaw-termux-zh) — 原始 Android 客户端
- [hermes-agent](https://github.com/NousResearch/hermes-agent) — Hermes Agent 核心
- [OpenClaw](https://github.com/openclaw/openclaw) — 原始项目

## 许可证

MIT，详见 [LICENSE](LICENSE)。
