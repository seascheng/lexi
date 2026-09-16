//! Launcher panel — double-Shift native launcher (folders + running apps).
//! Top-level isolated subsystem; see
//! docs/superpowers/specs/2026-09-16-launcher-panel-design.md

use core_graphics::event::CGEvent;
use tauri::AppHandle;

/// FlagsChanged hook — called by the event tap. The full double-modifier
/// detection lands in Task 2; this shell keeps the tap seam compiling.
pub(crate) fn handle_flags_changed(_app: &AppHandle, _event: &CGEvent) {}
