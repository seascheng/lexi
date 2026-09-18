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
    /// Live view of the `read` tool's speech config (toolbar_tools blob).
    @State private var ttsEngine = "system"
    @State private var volcAppId = ""
    @State private var volcAccessToken = ""
    @State private var volcVoice = ""

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
                    get: { ttsEngine },
                    set: {
                        ttsEngine = $0
                        LexiStore.setToolConfigField(id: "read", field: "engine", value: $0)
                    }
                )) {
                    Text("System built-in (say)").tag("system")
                    Text("Volcengine TTS").tag("volcengine")
                }
                if ttsEngine == "volcengine" {
                    TextField("APP ID", text: Binding(
                        get: { volcAppId },
                        set: {
                            volcAppId = $0
                            LexiStore.setToolConfigField(id: "read", field: "volcAppId", value: $0)
                        }
                    ))
                    SecureField("Access token", text: Binding(
                        get: { volcAccessToken },
                        set: {
                            volcAccessToken = $0
                            LexiStore.setToolConfigField(id: "read", field: "volcAccessToken", value: $0)
                        }
                    ))
                    TextField("Voice (zh_female_cancan_mars_bigtts)", text: Binding(
                        get: { volcVoice },
                        set: {
                            volcVoice = $0
                            LexiStore.setToolConfigField(id: "read", field: "volcVoice", value: $0)
                        }
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
        .onAppear {
            let config = LexiStore.toolbarToolConfig(id: "read")
            ttsEngine = config["engine"] ?? "system"
            volcAppId = config["volcAppId"] ?? ""
            volcAccessToken = config["volcAccessToken"] ?? ""
            volcVoice = config["volcVoice"] ?? ""
        }
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
                Button(recording ? "按下快捷键…" : "录制") {
                    if recording { stop() } else { start() }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(recording ? .red : nil)
            }
        }
    }

    private func start() {
        recording = true
        tapCount = 0
        // Arm the pre-IME raw key tap: input methods rewrite Option+letter
        // combos at the session level, so the localized keyDown cannot be
        // trusted (Option+V surfaced as Cmd+J under the WeChat IME).
        SelectionPipeline.rawKeyHandler = { keyCode, rawFlags in
            DispatchQueue.main.async {
                self.handleRawKey(keyCode: keyCode, rawFlags: rawFlags)
            }
        }
        // Local fallback for double-modifier taps (flagsChanged events).
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                let modifier = Self.modifierName(event.modifierFlags)
                guard !modifier.isEmpty else { return event }
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
        guard let key = Self.keyName(for: keyCode), !parts.isEmpty else {
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
        SelectionPipeline.rawKeyHandler = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        self.monitor = nil
    }

    private static func modifierName(_ flags: NSEvent.ModifierFlags) -> String {
        if flags.contains(.command) { return "Cmd" }
        if flags.contains(.control) { return "Ctrl" }
        if flags.contains(.option) { return "Alt" }
        if flags.contains(.shift) { return "Shift" }
        return ""
    }

    /// Hardware keyCode → stable shortcut name. The table follows the
    /// ANSI hardware keycode layout (keycode 9 = V, not alphabetical).
    private static func keyName(for keyCode: UInt16) -> String? {
        let letters: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P",
            37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        ]
        if let letter = letters[keyCode] { return letter }
        let digitKeys: [UInt16: String] = [
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
            22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        ]
        if let digit = digitKeys[keyCode] { return digit }
        if keyCode == 49 { return "Space" }
        return nil
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
