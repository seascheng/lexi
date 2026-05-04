# Lexi

macOS 桌面英语学习工具。选中任意文本即可翻译、收藏、复习。

## 功能

- **全局划词翻译** — 选中文字自动弹出翻译，支持全局快捷键（默认 `Cmd+Shift+T`）
- **AI 翻译引擎** — 基于 OpenAI 兼容 API，可自定义模型和提示词
- **生词本** — 自动保存翻译结果，支持搜索、筛选、导出（JSON/CSV）
- **间隔重复复习** — SM-2 算法，支持闪卡和打字两种模式
- **笔记本** — 标签管理，Markdown 渲染
- **自定义 AI 功能** — 创建翻译以外的自定义 AI 功能，自定义提示词和输出格式
- **原生浮动工具栏** — 配套 Swift 辅助应用，macOS 原生渲染
- **多窗口** — 主窗口、浮动翻译栏、弹窗卡片，支持置顶和位置记忆
- **主题** — 深色/浅色模式，6 种强调色，支持透明和 macOS Liquid Glass 效果
- **朗读** — macOS `say` 命令或 API 驱动的文本转语音

## 技术栈

- **前端:** React 18 + TypeScript + Tailwind CSS
- **桌面:** Tauri v2
- **后端:** Rust
- **数据库:** SQLite（浏览器预览模式回退到 localStorage）
- **配套应用:** Swift（原生浮动工具栏）

## 开发

```bash
npm install
npm run tauri dev
```

## 构建

```bash
npm run tauri build
```

## 项目结构

```
src/                # React 前端
  pages/            # 页面：生词本、复习、笔记本、配置、设置
  components/       # 组件：翻译窗口、复习、UI 基础组件
  lib/              # 工具库：AI、数据库、SM-2、导出、主题
src-tauri/          # Tauri/Rust 后端
  src/              # Rust 源码：命令、事件监听、窗口管理
  migrations/       # SQLite 迁移（001-008）
  native/           # Swift 辅助应用（划词工具栏）
```

## 要求

- macOS
- Node.js
- Rust 工具链
- OpenAI 兼容 API（用于翻译功能）
