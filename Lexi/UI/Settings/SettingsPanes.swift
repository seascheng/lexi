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
    // Speech (text to speech) — the `read` tool's config blob
    var ttsEngine = "system"
    var volcAppId = ""
    var volcAccessToken = ""
    var volcVoice = ""

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
        let speech = LexiStore.toolbarToolConfig(id: "read")
        ttsEngine = speech["engine"] ?? "system"
        volcAppId = speech["volcAppId"] ?? ""
        volcAccessToken = speech["volcAccessToken"] ?? ""
        volcVoice = speech["volcVoice"] ?? ""
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

    // MARK: - Speech (the `read` tool reads this blob per run)

    func setTtsEngine(_ value: String) {
        ttsEngine = value
        LexiStore.setToolConfigField(id: "read", field: "engine", value: value)
    }

    func setVolcAppId(_ value: String) {
        volcAppId = value
        LexiStore.setToolConfigField(id: "read", field: "volcAppId", value: value)
    }

    func setVolcAccessToken(_ value: String) {
        volcAccessToken = value
        LexiStore.setToolConfigField(id: "read", field: "volcAccessToken", value: value)
    }

    func setVolcVoice(_ value: String) {
        volcVoice = value
        LexiStore.setToolConfigField(id: "read", field: "volcVoice", value: value)
    }

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
                TextField("Base URL", text: Binding(
                    get: { model.apiBaseUrl },
                    set: { model.setApiBaseUrl($0) }
                ))
                TextField("Model", text: Binding(
                    get: { model.aiModel },
                    set: { model.setAiModel($0) }
                ))
                SecureField("API key", text: Binding(
                    get: { model.apiKey },
                    set: { model.setApiKey($0) }
                ))
            } header: {
                Text("OpenAI-compatible API")
            } footer: {
                Text("Any OpenAI-compatible endpoint works. Values take effect on the next selection run.")
            }

            Section {
                Picker("Engine", selection: Binding(
                    get: { model.ttsEngine },
                    set: { model.setTtsEngine($0) }
                )) {
                    Text("System built-in (say)").tag("system")
                    Text("Volcengine TTS").tag("volcengine")
                }
                if model.ttsEngine == "volcengine" {
                    TextField("APP ID", text: Binding(
                        get: { model.volcAppId },
                        set: { model.setVolcAppId($0) }
                    ))
                    SecureField("Access token", text: Binding(
                        get: { model.volcAccessToken },
                        set: { model.setVolcAccessToken($0) }
                    ))
                    TextField("Voice (zh_female_cancan_mars_bigtts)", text: Binding(
                        get: { model.volcVoice },
                        set: { model.setVolcVoice($0) }
                    ))
                }
            } header: {
                Text("Speech (text to speech)")
            } footer: {
                Text("Used by the Read action on the toolbar and the card.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

// MARK: - Shortcuts

/// One press-to-record row: shows the current combo, records the next
/// keystroke (combo or double-modifier tap) into the binding.
struct ShortcutRecorderRow: View {
    let label: String
    @Binding var value: String
    @State private var recording = false
    @State private var tapCount = 0
    @State private var lastModifier = ""
    @State private var monitor: Any?

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Text(value)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                Button(recording ? "Recording…" : "Record") {
                    if recording { stop() } else { start() }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(recording ? .red : nil)
            }
        }
        // Switching panes mid-recording destroys the view with the global
        // raw-key hook armed and the local monitor installed — stop() is
        // otherwise unreachable (Escape/complete paths only).
        .onDisappear {
            if recording { stop() }
        }
    }

    private func start() {
        recording = true
        tapCount = 0
        // Arm the pre-IME raw key tap: input methods rewrite Option+letter
        // combos at the session level, so the localized keyDown cannot be
        // trusted (Option+V surfaced as Cmd+J under the WeChat IME).
        ShortcutMonitor.rawKeyHandler = { keyCode, rawFlags in
            self.handleRawKey(keyCode: keyCode, rawFlags: rawFlags)
        }
        // Local fallback for double-modifier taps (flagsChanged events).
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                guard let modifier = LexiShortcutMode.modifierName(for: event.modifierFlags) else { return event }
                if modifier == lastModifier {
                    tapCount += 1
                    if tapCount == 2 {
                        value = "\(modifier)+\(modifier)"
                        stop()
                    }
                } else {
                    lastModifier = modifier
                    tapCount = 1
                }
                return event
            }
            if event.keyCode == 53 { // kVK_Escape
                stop()
                return event
            }
            return event
        }
    }

    /// Raw (pre-IME) keyDown from the cghidEventTap: combo = current
    /// modifiers + the hardware key.
    private func handleRawKey(keyCode: UInt16, rawFlags: UInt64) {
        guard recording else { return }
        if keyCode == 53 as UInt16 { // kVK_Escape
            stop()
            return
        }
        let f = NSEvent.ModifierFlags(rawValue: UInt(rawFlags))
        var parts: [String] = []
        if f.contains(.command) { parts.append("Cmd") }
        if f.contains(.control) { parts.append("Ctrl") }
        if f.contains(.option) { parts.append("Alt") }
        if f.contains(.shift) { parts.append("Shift") }
        guard let key = LexiShortcutMode.keyName(for: keyCode), !parts.isEmpty else {
            return // bare keys can't be global shortcuts
        }
        parts.append(key)
        value = parts.joined(separator: "+")
        stop()
    }

    private func stop() {
        recording = false
        tapCount = 0
        lastModifier = ""
        ShortcutMonitor.rawKeyHandler = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        self.monitor = nil
    }
}

struct ShortcutsSettingsPane: View {
    @Environment(LexiSettingsModel.self) private var model

    var body: some View {
        Form {
            Section {
                ShortcutRecorderRow(label: "Show popup", value: Binding(
                    get: { model.popupShortcut },
                    set: { model.setPopupShortcut($0) }
                ))
                ShortcutRecorderRow(label: "Show launcher", value: Binding(
                    get: { model.launcherShortcut },
                    set: { model.setLauncherShortcut($0) }
                ))
                ShortcutRecorderRow(label: "Show clipboard", value: Binding(
                    get: { model.clipboardShortcut },
                    set: { model.setClipboardShortcut($0) }
                ))
            } header: {
                Text("Global shortcuts")
            } footer: {
                Text("Click Record, then press the key combo. Tapping the same modifier twice records a double-tap shortcut. Changes apply immediately; double-tap shortcuts ignore keystrokes while you type.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}
