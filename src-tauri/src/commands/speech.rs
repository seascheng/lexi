use std::process::Command;

#[tauri::command]
pub fn speak_text(text: String) -> Result<(), String> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Err("Nothing to speak.".into());
    }

    #[cfg(target_os = "macos")]
    {
        Command::new("say")
            .arg(trimmed)
            .spawn()
            .map_err(|error| format!("Could not start macOS speech: {error}"))?;
        Ok(())
    }

    #[cfg(not(target_os = "macos"))]
    {
        Err("Speech is currently available only on macOS.".into())
    }
}
