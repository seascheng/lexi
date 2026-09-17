import Observation
import ServiceManagement
import SwiftUI

// ---------------------------------------------------------------------------
// Settings panes. Every pane: grouped Form, transparent scroll background so
// the window's material shows through, top margin clearing the toolbar.
// ---------------------------------------------------------------------------

/// Side effects the panes trigger after persisting. Wired by the window
/// controller — the panes themselves never reach past the store.
struct LexiSettingsEffects {
    var panelStyleChanged: (_ theme: String?, _ opacity: Int?, _ blur: String?) -> Void
    var nativeSettingsChanged: () -> Void
}

@MainActor
@Observable
final class LexiSettingsModel {
    var effects: LexiSettingsEffects?

    // Appearance
    var theme = "dark"
    var panelBlur = "clear"
    var panelOpacity = 40

    // AI
    var apiBaseUrl = ""
    var apiKey = ""
    var aiModel = ""

    // Shortcuts
    var popupShortcut = "Ctrl+Ctrl"
    var launcherShortcut = "Shift+Shift"
    var clipboardShortcut = "Alt+V"

    // General
    var toolbarEnabled = true

    /// Read every value from the store (fresh window show).
    func reload() {
        theme = LexiStore.setting("theme") ?? "dark"
        panelBlur = LexiStore.setting("panelBlur") ?? "clear"
        panelOpacity = LexiStore.settingInt("panelOpacity", in: 10...90, default: 40)
        apiBaseUrl = LexiStore.setting("apiBaseUrl") ?? ""
        apiKey = LexiStore.setting("apiKey") ?? ""
        aiModel = LexiStore.setting("model") ?? ""
        popupShortcut = LexiStore.setting("popupShortcut") ?? "Ctrl+Ctrl"
        launcherShortcut = LexiStore.setting("launcherShortcut") ?? "Shift+Shift"
        clipboardShortcut = LexiStore.setting("clipboardShortcut") ?? "Alt+V"
        toolbarEnabled = LexiStore.settingBool("toolbarEnabled", default: true)
    }

    // MARK: - Appearance

    func setTheme(_ value: String) {
        guard value != theme else { return }
        theme = value
        LexiStore.setSetting("theme", value)
        effects?.panelStyleChanged(value, nil, nil)
    }

    /// Slider drags apply live without touching the store.
    func applyLivePanelStyle() {
        effects?.panelStyleChanged(nil, panelOpacity, panelBlur)
    }

    /// Drag end / picker change persists both style values at once.
    func persistPanelStyle() {
        LexiStore.setSetting("panelOpacity", String(panelOpacity))
        LexiStore.setSetting("panelBlur", panelBlur)
        effects?.panelStyleChanged(nil, panelOpacity, panelBlur)
    }

    // MARK: - AI (Rust reads these rows per card-show — live by construction)

    func setApiBaseUrl(_ value: String) {
        apiBaseUrl = value.trimmingCharacters(in: .whitespacesAndNewlines)
        LexiStore.setSetting("apiBaseUrl", apiBaseUrl)
    }

    func setApiKey(_ value: String) {
        apiKey = value
        LexiStore.setSetting("apiKey", apiKey)
    }

    func setAiModel(_ value: String) {
        aiModel = value.trimmingCharacters(in: .whitespacesAndNewlines)
        LexiStore.setSetting("model", aiModel)
    }

    // MARK: - Shortcuts & General (persisted, then Rust reloads its statics)

    func setPopupShortcut(_ value: String) {
        guard value != popupShortcut else { return }
        popupShortcut = value
        LexiStore.setSetting("popupShortcut", value)
        effects?.nativeSettingsChanged()
    }

    func setLauncherShortcut(_ value: String) {
        guard value != launcherShortcut else { return }
        launcherShortcut = value
        LexiStore.setSetting("launcherShortcut", value)
        effects?.nativeSettingsChanged()
    }

    func setClipboardShortcut(_ value: String) {
        guard value != clipboardShortcut else { return }
        clipboardShortcut = value
        LexiStore.setSetting("clipboardShortcut", value)
        effects?.nativeSettingsChanged()
    }

    func setToolbarEnabled(_ value: Bool) {
        guard value != toolbarEnabled else { return }
        toolbarEnabled = value
        LexiStore.setSetting("toolbarEnabled", value ? "true" : "false")
        effects?.nativeSettingsChanged()
    }
}

// MARK: - General

struct GeneralSettingsPane: View {
    @Environment(LexiSettingsModel.self) private var model

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.toolbarEnabled },
                    set: { model.setToolbarEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Selection toolbar")
                        Text("Show the action toolbar when text is selected.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            } header: {
                Text("Selection")
            }
            Section {
                Toggle(isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            FileLog.write("SMAppService error: \(error.localizedDescription)")
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at login")
                        Text("Start Lexi automatically when you log in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            } header: {
                Text("Startup")
            }
            Section {
                LabeledContent("Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Database") {
                    Text(LexiStore.databasePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

// MARK: - Appearance

struct AppearanceSettingsPane: View {
    @Environment(LexiSettingsModel.self) private var model

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: Binding(
                    get: { model.theme },
                    set: { model.setTheme($0) }
                )) {
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Theme")
            } footer: {
                Text("Applies to the toolbar, panels and cards immediately.")
            }

            Section {
                Picker("Panel blur", selection: Binding(
                    get: { model.panelBlur },
                    set: {
                        model.panelBlur = $0
                        model.persistPanelStyle()
                    }
                )) {
                    Text("Clear").tag("clear")
                    Text("Frosted").tag("frosted")
                    Text("Solid").tag("solid")
                }
                .pickerStyle(.menu)

                LabeledContent("Panel opacity") {
                    HStack(spacing: 12) {
                        Slider(
                            value: Binding(
                                get: { Double(model.panelOpacity) },
                                set: { model.panelOpacity = Int($0) }
                            ),
                            in: 10...90
                        ) { editing in
                            if editing {
                                model.applyLivePanelStyle()
                            } else {
                                model.persistPanelStyle()
                            }
                        }
                        .frame(width: 180)
                        Text("\(model.panelOpacity)%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                }
            } header: {
                Text("Panels")
            } footer: {
                Text("Blur presets map to system vibrancy materials; opacity is the scrim layer under the glass.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

// MARK: - AI

struct AISettingsPane: View {
    @Environment(LexiSettingsModel.self) private var model

    var body: some View {
        Form {
            Section {
                LabeledContent("Base URL") {
                    TextField("https://api.openai.com/v1", text: Binding(
                        get: { model.apiBaseUrl },
                        set: { model.setApiBaseUrl($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                }
                LabeledContent("Model") {
                    TextField("gpt-4o-mini", text: Binding(
                        get: { model.aiModel },
                        set: { model.setAiModel($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                }
                LabeledContent("API key") {
                    SecureField("sk-…", text: Binding(
                        get: { model.apiKey },
                        set: { model.setApiKey($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                }
            } header: {
                Text("OpenAI-compatible API")
            } footer: {
                Text("Any OpenAI-compatible endpoint works. Values take effect on the next selection run.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

// MARK: - Shortcuts

/// Presets mirror exactly what ShortcutMode::parse accepts on the Rust side:
/// key combos and double-modifier taps.
private struct ShortcutOption: Identifiable {
    let value: String
    let label: String
    var id: String { value }
}

private let popupOptions = [
    ShortcutOption(value: "Ctrl+Ctrl", label: "Double Control"),
    ShortcutOption(value: "Alt+Alt", label: "Double Option"),
    ShortcutOption(value: "Cmd+Cmd", label: "Double Command"),
    ShortcutOption(value: "Cmd+Shift+T", label: "⌘⇧T"),
]

private let launcherOptions = [
    ShortcutOption(value: "Shift+Shift", label: "Double Shift"),
    ShortcutOption(value: "Alt+Alt", label: "Double Option"),
    ShortcutOption(value: "Cmd+Cmd", label: "Double Command"),
    ShortcutOption(value: "Cmd+Shift+L", label: "⌘⇧L"),
]

private let clipboardOptions = [
    ShortcutOption(value: "Alt+V", label: "⌥V"),
    ShortcutOption(value: "Ctrl+Shift+V", label: "⌃⇧V"),
    ShortcutOption(value: "Alt+Alt", label: "Double Option"),
    ShortcutOption(value: "Cmd+Cmd", label: "Double Command"),
]

struct ShortcutsSettingsPane: View {
    @Environment(LexiSettingsModel.self) private var model

    var body: some View {
        Form {
            Section {
                Picker("Show popup", selection: Binding(
                    get: { model.popupShortcut },
                    set: { model.setPopupShortcut($0) }
                )) {
                    ForEach(popupOptions) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                Picker("Show launcher", selection: Binding(
                    get: { model.launcherShortcut },
                    set: { model.setLauncherShortcut($0) }
                )) {
                    ForEach(launcherOptions) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                Picker("Show clipboard", selection: Binding(
                    get: { model.clipboardShortcut },
                    set: { model.setClipboardShortcut($0) }
                )) {
                    ForEach(clipboardOptions) { option in
                        Text(option.label).tag(option.value)
                    }
                }
            } header: {
                Text("Global shortcuts")
            } footer: {
                Text("Changes apply immediately. Double-tap shortcuts ignore keystrokes while you type.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}
