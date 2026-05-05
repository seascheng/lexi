import AppKit
import Foundation
import Network

private let logURL = URL(fileURLWithPath: "/tmp/lexi-selection-helper.log")
private let toolbarHandleWidth: CGFloat = 18
private let toolbarSegmentWidth: CGFloat = 34
private let toolbarHeight: CGFloat = 30
private let toolbarIconSize: CGFloat = 16
private let toolbarVerticalGap: CGFloat = 6

private struct ToolbarAction: Decodable {
    let id: String
    let title: String
    let icon: String
}

private func defaultToolbarActions() -> [ToolbarAction] {
    [
        ToolbarAction(id: "translation", title: "Translate", icon: "languages"),
        ToolbarAction(id: "rewrite", title: "Rewrite", icon: "pen"),
        ToolbarAction(id: "speak", title: "Speak", icon: "volume"),
    ]
}

private func lucideImage(for icon: String, title: String) -> NSImage? {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#000000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">\(lucideMarkup(for: icon))</svg>
    """
    guard let image = NSImage(data: Data(svg.utf8)) else {
        return NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: title)
    }
    image.isTemplate = true
    image.size = NSSize(width: toolbarIconSize, height: toolbarIconSize)
    image.accessibilityDescription = title
    return image
}

private func lucideMarkup(for icon: String) -> String {
    switch icon {
    case "languages":
        return """
        <path d="m5 8 6 6"/><path d="m4 14 6-6 2-3"/><path d="M2 5h12"/><path d="M7 2h1"/><path d="m22 22-5-10-5 10"/><path d="M14 18h6"/>
        """
    case "pen":
        return """
        <path d="M12 20h9"/><path d="M16.376 3.622a1 1 0 0 1 3.002 3.002L7.368 18.635a2 2 0 0 1-.855.506l-2.872.838a.5.5 0 0 1-.62-.62l.838-2.872a2 2 0 0 1 .506-.854z"/>
        """
    case "sparkles":
        return """
        <path d="M9.937 15.5A2 2 0 0 0 8.5 14.063l-6.135-1.582a.5.5 0 0 1 0-.962L8.5 9.936A2 2 0 0 0 9.937 8.5l1.582-6.135a.5.5 0 0 1 .963 0L14.063 8.5A2 2 0 0 0 15.5 9.937l6.135 1.581a.5.5 0 0 1 0 .964L15.5 14.063a2 2 0 0 0-1.437 1.437l-1.582 6.135a.5.5 0 0 1-.963 0z"/><path d="M20 3v4"/><path d="M22 5h-4"/><path d="M4 17v2"/><path d="M5 18H3"/>
        """
    case "book-plus":
        return """
        <path d="M12 7v6"/><path d="M4 19.5v-15A2.5 2.5 0 0 1 6.5 2H19a1 1 0 0 1 1 1v18a1 1 0 0 1-1 1H6.5a1 1 0 0 1 0-5H20"/><path d="M9 10h6"/>
        """
    case "highlighter":
        return """
        <path d="m9 11-6 6v3h9l3-3"/><path d="m22 12-4.6 4.6a2 2 0 0 1-2.8 0l-5.2-5.2a2 2 0 0 1 0-2.8L14 4"/>
        """
    case "file-text":
        return """
        <path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/><path d="M10 9H8"/><path d="M16 13H8"/><path d="M16 17H8"/>
        """
    case "message":
        return """
        <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>
        """
    case "volume":
        return """
        <path d="M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.705.705 0 0 0 11 19.298z"/><path d="M16 9a5 5 0 0 1 0 6"/><path d="M19.364 18.364a9 9 0 0 0 0-12.728"/>
        """
    case "clipboard":
        return """
        <rect width="8" height="4" x="8" y="2" rx="1" ry="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/><path d="M12 11h4"/><path d="M12 16h4"/><path d="M8 11h.01"/><path d="M8 16h.01"/>
        """
    case "copy":
        return """
        <rect width="14" height="14" x="8" y="8" rx="2" ry="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>
        """
    case "search":
        return """
        <circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>
        """
    case "notebook-pen":
        return """
        <path d="M13.4 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-7.4"/><path d="M2 6h4"/><path d="M2 10h4"/><path d="M2 14h4"/><path d="M2 18h4"/><path d="M21.378 5.626a1 1 0 1 0-3.004-3.004l-5.01 5.012a2 2 0 0 0-.506.854l-.837 2.87a.5.5 0 0 0 .62.62l2.87-.837a2 2 0 0 0 .854-.506z"/>
        """
    case "wand":
        return """
        <path d="M15 4V2"/><path d="M15 16v-2"/><path d="M8 9h2"/><path d="M20 9h2"/><path d="M17.8 11.8 19 13"/><path d="M15 9h.01"/><path d="M17.8 6.2 19 5"/><path d="m3 21 9-9"/><path d="M12.2 6.2 11 5"/>
        """
    case "book-open":
        return """
        <path d="M2 3h6a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3H2z"/><path d="M22 3h-6a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3h7z"/>
        """
    case "send":
        return """
        <path d="M14.536 21.686a.5.5 0 0 0 .937-.024l6.5-19a.496.496 0 0 0-.635-.635l-19 6.5a.5.5 0 0 0-.024.937l7.93 3.18a2 2 0 0 1 1.112 1.11z"/><path d="m21.854 2.147-10.94 10.939"/>
        """
    default:
        return """
        <path d="m21.64 3.64-1.28-1.28a1.21 1.21 0 0 0-1.72 0L2.36 18.64a1.21 1.21 0 0 0 0 1.72l1.28 1.28a1.2 1.2 0 0 0 1.72 0L21.64 5.36a1.2 1.2 0 0 0 0-1.72"/><path d="m14 7 3 3"/><path d="M5 6v4"/><path d="M19 14v4"/><path d="M10 2v2"/><path d="M7 8H3"/><path d="M21 16h-4"/><path d="M11 3H9"/>
        """
    }
}

private enum ToolbarTheme: String {
    case dark
    case light

    var backgroundColor: NSColor {
        switch self {
        case .dark:
            return NSColor(calibratedWhite: 0.07, alpha: 0.94)
        case .light:
            return NSColor(calibratedWhite: 0.98, alpha: 0.94)
        }
    }

    var iconColor: NSColor {
        switch self {
        case .dark:
            return .white
        case .light:
            return NSColor(calibratedWhite: 0.08, alpha: 1)
        }
    }

    var hoverColor: NSColor {
        switch self {
        case .dark:
            return NSColor(calibratedWhite: 1, alpha: 0.12)
        case .light:
            return NSColor(calibratedWhite: 0, alpha: 0.06)
        }
    }

    var pressedColor: NSColor {
        switch self {
        case .dark:
            return NSColor(calibratedWhite: 1, alpha: 0.18)
        case .light:
            return NSColor(calibratedWhite: 0, alpha: 0.10)
        }
    }
}

private final class ToolbarButton: NSButton {
    var theme: ToolbarTheme = .dark {
        didSet {
            contentTintColor = theme.iconColor
            updateBackground()
            needsDisplay = true
        }
    }
    private var trackingAreaRef: NSTrackingArea?
    private var isPressed = false {
        didSet {
            updateBackground()
        }
    }
    private var isHovering = false {
        didSet {
            updateBackground()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
    }

    private func updateBackground() {
        let color: NSColor
        if isPressed {
            color = theme.pressedColor
        } else if isHovering {
            color = theme.hoverColor
        } else {
            color = .clear
        }
        layer?.backgroundColor = color.cgColor
    }

    override func updateTrackingAreas() {
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaRef = tracking
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        isPressed = false
        NSCursor.arrow.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        super.mouseDown(with: event)
        isPressed = false
    }

    override var acceptsFirstResponder: Bool {
        false
    }
}

private final class ToolbarDragHandle: NSView {
    var theme: ToolbarTheme = .dark {
        didSet {
            needsDisplay = true
        }
    }
    var onMouseDown: ((NSEvent) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "Move toolbar"
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        toolTip = "Move toolbar"
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let color = theme.iconColor.withAlphaComponent(theme == .dark ? 0.55 : 0.42)
        color.setStroke()

        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        let top = bounds.midY + 5
        let bottom = bounds.midY - 5
        for x in [bounds.midX - 2.5, bounds.midX + 2.5] {
            path.move(to: NSPoint(x: x, y: bottom))
            path.line(to: NSPoint(x: x, y: top))
        }
        path.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.set()
        onMouseDown?(event)
        NSCursor.openHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.openHand.set()
    }
}

final class SelectionToolbarApp: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var container: NSView!
    private var dragHandle: ToolbarDragHandle!
    private var buttons: [ToolbarButton] = []
    private var actions = defaultToolbarActions()
    private var theme: ToolbarTheme = .dark
    private var selectedText = ""
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var listener: NWListener?
    private let listenerQueue = DispatchQueue(label: "lexi.toolbar.display")
    private let connectionQueue = DispatchQueue(label: "lexi.toolbar.connection")
    private let actionPort: String
    private let toolbarPort: UInt16

    override init() {
        actionPort = SelectionToolbarApp.argumentValue("--action-port") ?? "43876"
        toolbarPort = UInt16(SelectionToolbarApp.argumentValue("--toolbar-port") ?? "") ?? 43877
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("helper started bundle=\(Bundle.main.bundleIdentifier ?? "none") toolbarPort=\(toolbarPort) actionPort=\(actionPort)")
        NSApp.setActivationPolicy(.accessory)
        terminateOlderHelperInstances()
        buildPanel()
        installMouseMonitors()
        startDisplayServer()
    }

    private static func argumentValue(_ name: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else {
            return nil
        }

        return arguments[index + 1]
    }

    private func terminateOlderHelperInstances() {
        let currentPid = ProcessInfo.processInfo.processIdentifier
        let currentBundleId = Bundle.main.bundleIdentifier

        for application in NSWorkspace.shared.runningApplications {
            guard application.bundleIdentifier == currentBundleId,
                  application.processIdentifier != currentPid else {
                continue
            }

            log("terminating stale helper pid=\(application.processIdentifier)")
            application.terminate()
        }
    }

    private func buildPanel() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: toolbarWidth(for: actions.count), height: toolbarHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.alphaValue = 1
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        container = NSView(frame: panel.contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.backgroundColor = theme.backgroundColor.cgColor
        container.layer?.cornerRadius = 8
        container.layer?.borderWidth = 0
        container.layer?.masksToBounds = true

        panel.contentView = container
        dragHandle = ToolbarDragHandle(frame: NSRect(x: 0, y: 0, width: toolbarHandleWidth, height: toolbarHeight))
        dragHandle.autoresizingMask = [.height]
        dragHandle.theme = theme
        dragHandle.onMouseDown = { [weak self] event in
            self?.panel.performDrag(with: event)
        }
        container.addSubview(dragHandle)
        applyActions(actions)
    }

    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.hideIfClickOutsidePanel(event)
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.hideIfClickOutsidePanel(event)
        }

    }

    private func applyActions(_ nextActions: [ToolbarAction]) {
        let normalized = nextActions.filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        actions = normalized
        buttons.forEach { $0.removeFromSuperview() }
        buttons.removeAll()

        if actions.isEmpty {
            hidePanel(force: true)
            return
        }

        let width = toolbarWidth(for: actions.count)
        container.frame = NSRect(x: 0, y: 0, width: width, height: toolbarHeight)
        panel.setContentSize(NSSize(width: width, height: toolbarHeight))
        dragHandle.frame = NSRect(x: 0, y: 0, width: toolbarHandleWidth, height: toolbarHeight)

        for (index, action) in actions.enumerated() {
            addToolbarButton(action: action, index: index)
        }
    }

    private func addToolbarButton(action: ToolbarAction, index: Int) {
        let button = ToolbarButton(
            frame: NSRect(
                x: toolbarHandleWidth + CGFloat(index) * toolbarSegmentWidth,
                y: 0,
                width: toolbarSegmentWidth,
                height: toolbarHeight
            )
        )
        button.autoresizingMask = [.height]
        button.identifier = NSUserInterfaceItemIdentifier(action.id)
        button.toolTip = action.title
        button.image = lucideImage(for: action.icon, title: action.title)
        button.imageScaling = .scaleProportionallyDown
        button.theme = theme
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(runToolbarAction(_:))
        buttons.append(button)
        container.addSubview(button)
    }

    private func toolbarWidth(for actionCount: Int) -> CGFloat {
        toolbarHandleWidth + CGFloat(max(actionCount, 1)) * toolbarSegmentWidth
    }

    private func startDisplayServer() {
        guard let port = NWEndpoint.Port(rawValue: toolbarPort) else {
            log("invalid toolbar port \(toolbarPort)")
            return
        }

        do {
            listener = try NWListener(using: .tcp, on: port)
        } catch {
            log("toolbar listener failed \(error)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            self?.log("toolbar listener state \(state)")
        }
        listener?.newConnectionHandler = { [weak self] connection in
            self?.receive(connection)
        }
        listener?.start(queue: listenerQueue)
        log("toolbar listener start requested")
    }

    private func receive(_ connection: NWConnection) {
        connection.start(queue: connectionQueue)
        var buffer = Data()
        var expectedLength: Int?

        func readNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
                guard let self, let data else {
                    connection.cancel()
                    return
                }

                buffer.append(data)

                // Parse Content-Length from headers once
                if expectedLength == nil {
                    if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
                        if let headerStr = String(data: headerData, encoding: .utf8) {
                            for line in headerStr.components(separatedBy: "\r\n") {
                                if line.lowercased().hasPrefix("content-length:") {
                                    expectedLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
                                    break
                                }
                            }
                        }
                        // If no Content-Length header, just process what we have
                        if expectedLength == nil {
                            self.handleRequestData(buffer)
                            self.writeResponse(connection)
                            return
                        }
                    } else {
                        // Headers not complete yet, keep reading
                        readNext()
                        return
                    }
                }

                // Check if we have the full body
                if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let bodyStart = headerEnd.upperBound
                    let bodyLength = buffer.endIndex - bodyStart
                    if bodyLength >= expectedLength! {
                        self.handleRequestData(buffer)
                        self.writeResponse(connection)
                        return
                    }
                }

                // Not complete yet, keep reading unless connection closed
                if isComplete {
                    self.handleRequestData(buffer)
                    self.writeResponse(connection)
                } else {
                    readNext()
                }
            }
        }

        readNext()
    }

    private func handleRequestData(_ data: Data) {
        guard let request = String(data: data, encoding: .utf8) else {
            return
        }

        if request.hasPrefix("POST /hide ") {
            log("hide request")
            DispatchQueue.main.async {
                self.hidePanel()
            }
            return
        }

        if request.hasPrefix("POST /theme "),
           let body = request.components(separatedBy: "\r\n\r\n").last,
           let bodyData = body.data(using: .utf8),
           let payload = try? JSONDecoder().decode(ThemePayload.self, from: bodyData) {
            DispatchQueue.main.async {
                self.applyTheme(payload.theme)
            }
            return
        }

        guard request.hasPrefix("POST /show "),
              let body = request.components(separatedBy: "\r\n\r\n").last,
              let bodyData = body.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ShowPayload.self, from: bodyData) else {
            log("invalid request \(request.prefix(80))")
            return
        }

        DispatchQueue.main.async {
            self.showPanel(payload)
        }
    }

    private func writeResponse(_ connection: NWConnection) {
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func showPanel(_ payload: ShowPayload) {
        let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || payload.pending == true else {
            hidePanel(force: true)
            return
        }

        applyActions(payload.actions ?? actions)
        if actions.isEmpty {
            hidePanel(force: true)
            return
        }

        if panel.isVisible && payload.pending != true {
            selectedText = text
            return
        }

        let width = toolbarWidth(for: actions.count)
        let origin = clampedPanelOrigin(near: currentMouseLocation(fallback: payload), width: width)
        let frame = NSRect(x: origin.x, y: origin.y, width: width, height: toolbarHeight)
        log("show panel textLength=\(text.count) mouse=\(Int(origin.x)),\(Int(origin.y)) payload=\(payload.x),\(payload.y) frame=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))")
        selectedText = text
        panel.setFrame(frame, display: true)
        NSApp.unhide(nil)
        panel.orderFrontRegardless()
    }

    private func applyTheme(_ themeName: String) {
        theme = ToolbarTheme(rawValue: themeName) ?? .dark
        container.layer?.backgroundColor = theme.backgroundColor.cgColor
        dragHandle.theme = theme
        buttons.forEach { $0.theme = theme }
        log("theme applied \(theme.rawValue)")
    }

    private func currentMouseLocation(fallback: ShowPayload) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        if NSScreen.screens.contains(where: { $0.frame.contains(mouse) }) {
            return mouse
        }

        return NSPoint(x: fallback.x, y: fallback.y)
    }

    private func clampedPanelOrigin(near point: NSPoint, width: CGFloat) -> NSPoint {
        var origin = NSPoint(
            x: point.x,
            y: point.y + toolbarVerticalGap
        )

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            origin.x = min(max(origin.x, frame.minX + 6), frame.maxX - width - 6)
            origin.y = min(max(origin.y, frame.minY + 6), frame.maxY - toolbarHeight - 6)
        }

        return origin
    }

    private func hidePanel(force: Bool = false) {
        selectedText = ""
        panel.orderOut(nil)
    }

    private func hideIfClickOutsidePanel(_ event: NSEvent) {
        guard panel.isVisible else {
            return
        }

        let screenPoint = NSEvent.mouseLocation
        if event.window === panel {
            return
        }

        if panel.frame.contains(screenPoint) {
            return
        }

        log("hide outside click x=\(Int(screenPoint.x)) y=\(Int(screenPoint.y))")
        hidePanel(force: true)
    }

    @objc private func runToolbarAction(_ sender: NSButton) {
        guard let action = sender.identifier?.rawValue, !selectedText.isEmpty else {
            return
        }

        let text = selectedText
        hidePanel(force: true)
        postAction(action: action, text: text)
    }

    private func postAction(action: String, text: String) {
        guard let url = URL(string: "http://127.0.0.1:\(actionPort)/action") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "action": action,
            "text": text,
        ])

        URLSession.shared.dataTask(with: request).resume()
    }

    private func log(_ message: String) {
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }

        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

private struct ShowPayload: Decodable {
    let text: String
    let x: Int
    let y: Int
    let pending: Bool?
    let actions: [ToolbarAction]?
}

private struct ThemePayload: Decodable {
    let theme: String
}

let app = NSApplication.shared
let delegate = SelectionToolbarApp()
app.delegate = delegate
app.run()
