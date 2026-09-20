import AppKit
import AVFoundation
import Foundation

// ---------------------------------------------------------------------------
// AI streaming + TTS, in-process: feature config comes from the shared DB,
// SSE streams over URLSession, events feed the card renderer directly.
// ---------------------------------------------------------------------------

// MARK: - Translation model (exact port of the Rust pipeline)

struct LexiTranslation: Codable {
    let word: String
    let translation: String
    let pos: String
    let definition: String
    let example: String

    /// Strip markdown fences some models wrap around JSON.
    static func cleanModelText(_ content: String) -> String {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        for fence in ["```json", "```"] where text.hasPrefix(fence) {
            text = String(text.dropFirst(fence.count))
        }
        if text.hasSuffix("```") { text = String(text.dropLast(3)) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(_ content: String) -> LexiTranslation? {
        guard let data = cleanModelText(content).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LexiTranslation.self, from: data)
    }

    var formatted: String {
        "### \(word)\n\n- **Word:** \(word)\n- **Translation:** \(translation)\n- **Part of speech:** \(pos)\n- **Definition:** \(definition)\n- **Example:** \(example)"
    }
}

// MARK: - Feature runs

extension SelectionToolbarApp {
    /// Start a feature run entirely inside the helper: read the feature row,
    /// present the card, stream, and feed events to the renderer.
    func runFeatureLocally(featureId: String, text: String) {
        FileLog.write("CARD run=feature id=\(featureId) text=\(text.prefix(24))")
        guard let feature = LexiStore.aiFeature(id: featureId) else {
            FileLog.write("ai: unknown feature \(featureId)")
            return
        }
        let runId = "run-\(UUID().uuidString.prefix(8))"
        showResultCard(ResultShowPayload(
            runId: runId,
            featureId: featureId,
            title: feature.name,
            icon: feature.icon,
            inputText: text
        ))
        cardRunTasks[runId] = Task { [weak self] in
            await self?.streamRun(runId: runId, feature: feature, text: text)
        }
    }

    func streamRun(runId: String, feature: LexiAIFeature, text: String) async {
        let apiBase = (LexiStore.setting("apiBaseUrl") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let apiKey = LexiStore.setting("apiKey") ?? ""
        let model = LexiStore.setting("model") ?? ""
        guard !apiBase.isEmpty, !model.isEmpty else {
            pushCardEvent(runId, error: "API settings missing — open Settings (gear in the launcher).")
            return
        }
        guard !apiKey.isEmpty else {
            pushCardEvent(runId, error: "API key is not saved. Open Settings, enter the key.")
            return
        }

        let isJSON = feature.outputMode == "translation_json"
        let systemMessage = isJSON
            ? "Return compact JSON only. Do not wrap it in markdown."
            : "Follow the user prompt exactly. Return the answer directly without markdown fences unless requested."
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemMessage],
                ["role": "user", "content": Self.renderPrompt(feature: feature, text: text)]
            ],
            "temperature": 0.2,
            "stream": true
        ]
        // deepseek thinking: ON = omit (server default), OFF = explicit disable
        // for fast first token — parity with the Rust body builder.
        if !feature.thinking {
            body["thinking"] = ["type": "disabled"]
        }

        var request = URLRequest(url: URL(string: apiBase + "/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        var accumulated = ""
        var pending = ""
        var lastEmit = Date.distantPast
        // 40ms emit interval — parity with the Rust coalescer that capped
        // re-renders at 25/sec.
        let emitInterval: TimeInterval = 0.04

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                var bodyText = ""
                for try await line in bytes.lines {
                    bodyText += line
                    if bodyText.count > 2000 { break }
                }
                throw RuntimeError("AI API returned \(http.statusCode): \(bodyText)")
            }

            // `bytes.lines` buffers raw bytes and splits on newline
            // boundaries, decoding only complete lines — multi-byte UTF-8
            // split across TCP segments stays intact (the mojibake fix).
            for try await rawLine in bytes.lines {
                // SSE allows "data:" with or without one space; CRLF
                // servers leave a trailing \r on the line.
                var line = rawLine
                while line.hasSuffix("\r") { line.removeLast() }
                guard line.hasPrefix("data:") else { continue }
                var data = line.dropFirst(5)
                if data.first == " " { data = data.dropFirst() }
                if data == "[DONE]" { continue }
                guard let jsonData = String(data).data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let choices = parsed["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let content = delta["content"] as? String
                else { continue }

                accumulated += content
                if !isJSON {
                    pending += content
                    if Date().timeIntervalSince(lastEmit) >= emitInterval {
                        lastEmit = Date()
                        let chunk = pending
                        pending = ""
                        pushCardEvent(runId, chunk: chunk, done: false)
                    }
                }
            }

            if !isJSON && !pending.isEmpty {
                pushCardEvent(runId, chunk: pending, done: false)
            }

            if isJSON {
                guard let translation = LexiTranslation.parse(accumulated) else {
                    pushCardEvent(runId, error: "Could not parse translation JSON.")
                    return
                }
                var saved = false
                if feature.autoSave && Self.isSingleWord(text) {
                    LexiStore.insertWord(
                        word: translation.word,
                        translation: translation.translation,
                        pos: translation.pos,
                        definition: translation.definition,
                        example: translation.example,
                        entryType: "word",
                        sourceText: text
                    )
                    saved = true
                }
                let translationJson = String(data: try JSONEncoder().encode(translation), encoding: .utf8)
                pushCardEvent(runId, chunk: translation.formatted, done: true,
                              translationJson: translationJson, saved: saved)
            } else {
                let cleaned = LexiTranslation.cleanModelText(accumulated)
                // Plain-text features save single words too: the output IS
                // the translation, the input the word.
                var saved = false
                if feature.autoSave && Self.isSingleWord(text) {
                    LexiStore.insertWord(
                        word: text,
                        translation: cleaned,
                        pos: "", definition: "", example: "",
                        entryType: "word", sourceText: text)
                    saved = true
                }
                pushCardEvent(runId, chunk: cleaned, done: true, saved: saved)
            }
        } catch {
            pushCardEvent(runId, error: "AI request failed: \(error.localizedDescription)")
        }
    }

    /// Feed one run event to the card renderer on the main thread.
    private func pushCardEvent(
        _ runId: String,
        chunk: String? = nil,
        done: Bool = false,
        error: String? = nil,
        translationJson: String? = nil,
        saved: Bool = false
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.handleResultEvent(ResultEventPayload(
                runId: runId,
                chunk: chunk,
                done: done,
                error: error,
                translationJson: translationJson,
                saved: saved
            ))
        }
    }

    static func renderPrompt(feature: LexiAIFeature, text: String) -> String {
        feature.promptTemplate
            .replacingOccurrences(of: "{{targetLanguage}}", with: feature.targetLanguage)
            .replacingOccurrences(of: "{{target_language}}", with: feature.targetLanguage)
            .replacingOccurrences(of: "{{text}}", with: text)
    }

    /// Port of `is_single_word`: trim non-ASCII-alpha from both ends, then
    /// every remaining character must be a letter, hyphen or apostrophe.
    static func isSingleWord(_ text: String) -> Bool {
        var word = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let first = word.first, !(first.isASCII && first.isLetter) { word = word.dropFirst() }
        while let last = word.last, !(last.isASCII && last.isLetter) { word = word.dropLast() }
        return !word.isEmpty && word.allSatisfy { ($0.isASCII && $0.isLetter) || $0 == "-" || $0 == "'" }
    }
}

// MARK: - Builtin tools

/// Local executions for the toolbar/card builtin tools.
enum LexiTools {
    static func copy(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Unified builtin-tool dispatch — the toolbar bar, the card's input
    /// bar and the chip menu all route through here.
    static func isTool(id: String) -> Bool {
        ["copy", "search", "read", "speak", "note", "handoff"].contains(id)
    }

    static func run(id: String, text: String) {
        switch id {
        case "copy": copy(text: text)
        case "search": search(text: text)
        case "read", "speak": LexiSpeech.shared.speak(text: text)
        case "note": note(text: text)
        case "handoff": handoff(text: text)
        default: break
        }
    }

    static func search(text: String) {
        let config = LexiStore.toolbarToolConfig(id: "search")
        let engine = config["engine"] ?? "google"
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text

        let url: String
        switch engine {
        case "bing": url = "https://www.bing.com/search?q=\(encoded)"
        case "duckduckgo": url = "https://duckduckgo.com/?q=\(encoded)"
        case "custom":
            url = (config["customUrl"] ?? "").replacingOccurrences(of: "{query}", with: encoded)
        default: url = "https://www.google.com/search?q=\(encoded)"
        }
        guard !url.isEmpty, let target = URL(string: url) else {
            FileLog.write("TOOL search: no URL configured")
            return
        }
        NSWorkspace.shared.open(target)
    }

    static func note(text: String) {
        LexiStore.insertNote(content: text)
        FileLog.write("TOOL note saved len=\(text.count)")
    }

    /// Hand the selection to a target app: activate it, then paste through
    /// the pasteboard (Rust do_handoff parity — the ClipboardPaster recipe
    /// covers activation + ⌘V + focus return).
    static func handoff(text: String) {
        let targetApp = LexiStore.toolbarToolConfig(id: "handoff")["targetApp"] ?? "ChatGPT"
        guard !targetApp.isEmpty else {
            FileLog.write("TOOL handoff: no target app configured")
            return
        }
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == targetApp && $0.isActive
        }) ?? NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased() == targetApp.lowercased()
        }) else {
            FileLog.write("TOOL handoff: app \(targetApp) not running")
            return
        }
        ClipboardPaster.pasteString(text, previousApp: running)
        FileLog.write("TOOL handoff target=\(targetApp) len=\(text.count)")
    }
}

struct RuntimeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - TTS

/// Speech dispatcher: Volcengine (streaming NDJSON → in-memory MP3) with a
/// system-voice fallback. Player references are kept so a new speak stops
/// whatever is playing.
final class LexiSpeech {
    static let shared = LexiSpeech()

    private var player: AVAudioPlayer?
    private var synthesizer: AVSpeechSynthesizer?

    func speak(text: String) {
        let config = LexiStore.toolbarToolConfig(id: "read")
        if config["engine"] == "volcengine",
           let appId = config["volcAppId"], !appId.isEmpty,
           let token = config["volcAccessToken"], !token.isEmpty {
            let voice = config["volcVoice"] ?? "zh_female_cancan_mars_bigtts"
            Task {
                do {
                    let mp3 = try await fetchVolcengine(text: text, appId: appId, token: token, voice: voice)
                    try await MainActor.run {
                        self.stopPlayback()
                        self.player = try AVAudioPlayer(data: mp3, fileTypeHint: AVFileType.mp3.rawValue)
                        self.player?.play()
                    }
                } catch {
                    FileLog.write("TTS volcengine failed: \(error.localizedDescription) — system voice fallback")
                    self.speakSystem(text: text)
                }
            }
        } else {
            speakSystem(text: text)
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
    }

    /// System voice via AVSpeechSynthesizer: in-process, stoppable, and no
    /// /usr/bin/say Process (whose bare-argument form would treat a
    /// leading "-" in the text as a flag — argument injection).
    private func speakSystem(text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stopPlayback()
            let synthesizer = AVSpeechSynthesizer()
            // Retained here: a released synthesizer stops speaking mid-word.
            self.synthesizer = synthesizer
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            synthesizer.speak(utterance)
        }
    }

    /// Volcengine unidirectional TTS: NDJSON lines of base64 MP3 chunks,
    /// terminated by code 20000000. Returns the assembled audio.
    private func fetchVolcengine(text: String, appId: String, token: String, voice: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://openspeech.bytedance.com/api/v3/tts/unidirectional")!)
        request.httpMethod = "POST"
        request.setValue(appId, forHTTPHeaderField: "X-Api-App-Id")
        request.setValue(token, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue("seed-tts-1.0", forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "user": ["uid": "lexi_user"],
            "req_params": [
                "text": text,
                "speaker": voice,
                "audio_params": ["format": "mp3", "sample_rate": 24000]
            ]
        ])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RuntimeError("TTS HTTP error \(http.statusCode)")
        }

        var audio = Data()
        for try await line in bytes.lines {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let code = parsed["code"] as? Int ?? 0
            if code == 20000000 { break }
            if code != 0 {
                throw RuntimeError("TTS error code \(code): \(parsed["message"] as? String ?? "unknown")")
            }
            if let b64 = parsed["data"] as? String, !b64.isEmpty,
               let chunk = Data(base64Encoded: b64) {
                audio.append(chunk)
            }
        }
        guard !audio.isEmpty else {
            throw RuntimeError("No audio received from Volcengine TTS.")
        }
        return audio
    }
}
