mod commands;
mod selection;

use commands::ai::run_ai_prompt;
use commands::speech::speak_text;
use commands::window::{set_popup_height, start_popup_resize};
use selection::{cursor_position, get_selected_text};
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{Emitter, Manager, WindowEvent};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};
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
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, _shortcut, event| {
                    if event.state() == ShortcutState::Released {
                        let _ = app.emit("englist://shortcut-triggered", ());
                    }
                })
                .build(),
        )
        .invoke_handler(tauri::generate_handler![
            cursor_position,
            get_selected_text,
            run_ai_prompt,
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
            register_default_shortcut(app)?;
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("failed to build Englist Tool")
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
    ]
}

fn setup_tray(app: &tauri::App) -> tauri::Result<()> {
    let open = MenuItem::with_id(app, "open", "Open Englist Tool", true, None::<&str>)?;
    let mode = MenuItem::with_id(app, "mode", "Switch Display Mode", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&open, &mode, &quit])?;

    TrayIconBuilder::new()
        .icon(tray_icon_image())
        .icon_as_template(true)
        .title("Englist")
        .tooltip("Englist Tool")
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open" => show_main_window(app),
            "mode" => {
                let _ = app.emit("englist://cycle-display-mode", ());
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .build(app)?;

    Ok(())
}

fn tray_icon_image() -> tauri::image::Image<'static> {
    let size = 18u32;
    let mut rgba = vec![0u8; (size * size * 4) as usize];

    for y in 3..15 {
        set_icon_pixel(&mut rgba, size, 4, y);
        set_icon_pixel(&mut rgba, size, 5, y);
    }
    for x in 4..14 {
        set_icon_pixel(&mut rgba, size, x, 3);
        set_icon_pixel(&mut rgba, size, x, 4);
        set_icon_pixel(&mut rgba, size, x, 8);
        set_icon_pixel(&mut rgba, size, x, 9);
        set_icon_pixel(&mut rgba, size, x, 14);
        set_icon_pixel(&mut rgba, size, x, 15);
    }

    tauri::image::Image::new_owned(rgba, size, size)
}

fn set_icon_pixel(rgba: &mut [u8], size: u32, x: u32, y: u32) {
    let index = ((y * size + x) * 4) as usize;
    rgba[index] = 0;
    rgba[index + 1] = 0;
    rgba[index + 2] = 0;
    rgba[index + 3] = 255;
}

fn show_main_window(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.set_focus();
    }
}

fn register_default_shortcut(app: &tauri::App) -> anyhow::Result<()> {
    let shortcut = Shortcut::new(Some(Modifiers::META | Modifiers::SHIFT), Code::KeyT);
    app.global_shortcut().register(shortcut)?;
    Ok(())
}
