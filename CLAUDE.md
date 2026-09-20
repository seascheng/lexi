# CLAUDE.md

## Tech Stack

One native Swift/AppKit app (see AGENTS.md): swiftc via Lexi/build.sh, no
external dependencies, no webview, no Rust backend, no Node toolchain.

## Guidelines

0. **铁律：先用系统组件** — 任何功能先找 AppKit 组件与组件原生 API（NSTableView drag&drop、NSMenu、NSTrackingArea、NSStackView、Auto Layout…）；禁止手写组件已有的能力（frame 排布、hover 监视器、重排游标）。详见 AGENTS.md 顶部。
1. **Think first** — Ask before assuming. Present alternatives. Push back if a simpler approach exists.
2. **Minimal code** — Only what was asked. No speculative features, abstractions, or unnecessary error handling.
3. **Surgical changes** — Don't touch unrelated code. Match existing style. Clean up only what your changes orphan.
4. **Root causes** — Fix bugs at the source, not with workarounds. Explore upward to find general solutions.
5. **Fit the system** — Reuse existing modules and patterns. Follow project structure. Cohesive over fragmented.
