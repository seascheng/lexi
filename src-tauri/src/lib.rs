mod commands;
mod cursor;
mod native_toolbar;

use commands::ai::run_ai_prompt;
use commands::speech::speak_text;
use commands::window::{set_popup_height, start_popup_resize};
use cursor::cursor_position;
use native_toolbar::{
    configure_native_toolbar, hide_native_toolbar, set_native_toolbar_actions,
    set_native_toolbar_enabled, set_native_toolbar_theme, set_popup_shortcut,
};
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
                .add_migrations("sqlite:englist.db", migrations())
                .build(),
        )
        .invoke_handler(tauri::generate_handler![
            cursor_position,
            configure_native_toolbar,
            hide_native_toolbar,
            run_ai_prompt,
            set_native_toolbar_actions,
            set_native_toolbar_enabled,
            set_native_toolbar_theme,
            set_popup_shortcut,
            speak_text,
            set_popup_height,
            start_popup_resize
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
            setup_tray(app)?;
            native_toolbar::setup_native_toolbar(app)?;
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("failed to build Lexicon")
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
    ]
}

fn setup_tray(app: &tauri::App) -> tauri::Result<()> {
    let open = MenuItem::with_id(app, "open", "Open Lexicon", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Lexicon", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&open, &quit])?;

    TrayIconBuilder::new()
        .icon(tauri::image::Image::from_path(
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("icons/tray_icon_template.png"),
        ).expect("failed to load tray icon"))
        .icon_as_template(true)
        .tooltip("Lexicon")
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
