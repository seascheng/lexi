mod ax;
mod commands;
mod cursor;
mod native_toolbar;
mod clipboard;
mod launcher;
mod text_injection;

use commands::ai::{run_ai_prompt, run_ai_prompt_stream};
use commands::speech::speak_text;
use commands::tools::execute_tool;
use cursor::cursor_position;
use clipboard::set_clipboard_shortcut;
use launcher::set_launcher_shortcut;
use native_toolbar::{
    configure_native_toolbar, handoff_to_app_cmd, hide_native_toolbar, popup_position,
    set_excluded_toolbar_apps, set_handoff_target, set_native_toolbar_actions,
    set_native_toolbar_enabled, set_native_toolbar_theme, set_popup_shortcut,
};
use text_injection::insert_at_focus;

use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{Manager, WindowEvent};
use tauri_plugin_sql::{Migration, MigrationKind};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_liquid_glass::init())
        .plugin(
            tauri_plugin_sql::Builder::default()
                .add_migrations("sqlite:lexi.db", migrations())
                .build(),
        )
        .invoke_handler(tauri::generate_handler![
            cursor_position,
            configure_native_toolbar,
            execute_tool,
            hide_native_toolbar,
            handoff_to_app_cmd,
            popup_position,
            set_excluded_toolbar_apps,
            set_handoff_target,
            run_ai_prompt,
            run_ai_prompt_stream,
            set_native_toolbar_actions,
            set_native_toolbar_enabled,
            set_native_toolbar_theme,
            set_launcher_shortcut,
            set_clipboard_shortcut,
            speak_text,
            insert_at_focus,
        ])
        .on_window_event(|window, event| {
            if window.label() == "main" {
                if let WindowEvent::CloseRequested { api, .. } = event {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .setup(|app| {
            #[cfg(desktop)]
            {
                app.handle().plugin(tauri_plugin_autostart::init(
                    tauri_plugin_autostart::MacosLauncher::LaunchAgent,
                    None,
                ))?;
            }
            native_toolbar::setup_native_toolbar(app)?;
            setup_tray(app)?;
            launcher::initialize(app);
            clipboard::initialize(app);
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("failed to build Lexi")
        .run(|app, event| {
            if let tauri::RunEvent::Reopen { .. } = event {
                show_main_window(app);
            }
        });
}

fn migrations() -> Vec<Migration> {
    vec![
        Migration {
            version: 1,
            description: "create words and settings tables",
            sql: include_str!("../migrations/001_init.sql"),
            kind: MigrationKind::Up,
        },
        Migration {
            version: 2,
            description: "create ai features table",
            sql: include_str!("../migrations/002_ai_features.sql"),
            kind: MigrationKind::Up,
        },
        Migration {
            version: 3,
            description: "add review feature interval",
            sql: include_str!("../migrations/003_review_feature_interval.sql"),
            kind: MigrationKind::Up,
        },
        Migration {
            version: 4,
            description: "add feature speech setting",
            sql: include_str!("../migrations/004_feature_speech_enabled.sql"),
            kind: MigrationKind::Up,
        },
        Migration {
            version: 5,
            description: "add learning entry metadata",
            sql: include_str!("../migrations/005_learning_entry_fields.sql"),
            kind: MigrationKind::Up,
        },
        Migration {
            version: 6,
            description: "add ai feature icon",
            sql: include_str!("../migrations/006_feature_icon.sql"),
            kind: MigrationKind::Up,
        },
        Migration {
            version: 7,
            description: "create_panels_table",
            sql: include_str!("../migrations/007_panels.sql"),
            kind: MigrationKind::Up,
        },
        Migration {
            version: 8,
            description: "create notes and tags tables",
            sql: include_str!("../migrations/008_notes.sql"),
            kind: MigrationKind::Up,
        },
        Migration {
            version: 9,
            description: "add builtin features flag and seed rewrite/ai",
            sql: include_str!("../migrations/009_builtin_features.sql"),
            kind: MigrationKind::Up,
        },
        Migration {
            version: 10,
            description: "cleanup duplicate rewrite/ai features",
            sql: include_str!("../migrations/010_cleanup_duplicate_features.sql"),
            kind: MigrationKind::Up,
        },
        Migration {
            version: 11,
            description: "add per-feature thinking toggle",
            sql: include_str!("../migrations/011_feature_thinking.sql"),
            kind: MigrationKind::Up,
        },
        Migration {
            version: 12,
            description: "add tags sort_order for panel tab order",
            sql: include_str!("../migrations/012_tag_order.sql"),
            kind: MigrationKind::Up,
        },
        Migration {
            version: 13,
            description: "drop notes panel (moved to ClipboardPanel)",
            sql: include_str!("../migrations/013_drop_notes_panel.sql"),
            kind: MigrationKind::Up,
        },
    ]
}

fn setup_tray(app: &tauri::App) -> tauri::Result<()> {
    let open = MenuItem::with_id(app, "open", "Open Lexi", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Lexi", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&open, &quit])?;

    TrayIconBuilder::new()
        .icon(tauri::image::Image::from_path(
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("icons/tray_icon_template.png"),
        ).expect("failed to load tray icon"))
        .icon_as_template(true)
        .tooltip("Lexi")
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open" => show_main_window(app),
            "quit" => app.exit(0),
            _ => {}
        })
        .build(app)?;

    Ok(())
}

fn show_main_window(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.set_focus();
    }
}
