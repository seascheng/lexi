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
        ToolbarAction(id: "rewrite", title: "Rewrite", icon: "wand"),
        ToolbarAction(id: "speak", title: "Speak", icon: "volume"),
        ToolbarAction(id: "extract", title: "Extract", icon: "sparkles"),
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
    // ── New Icons ──────────────────────────────────
    case "type":
        return """
        <polyline points="4 7 4 4 20 4 20 7"/><line x1="9" x2="15" y1="20" y2="20"/><line x1="12" x2="12" y1="4" y2="20"/>
        """
    case "heading":
        return """
        <path d="M6 12h12"/><path d="M6 20V4"/><path d="M18 20V4"/>
        """
    case "bookmark":
        return """
        <path d="m19 21-7-4-7 4V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2v16z"/>
        """
    case "star":
        return """
        <path d="M11.525 2.295a.53.53 0 0 1 .95 0l2.31 4.679a2.123 2.123 0 0 0 1.595 1.16l5.166.756a.53.53 0 0 1 .294.904l-3.736 3.638a2.123 2.123 0 0 0-.611 1.878l.882 5.14a.53.53 0 0 1-.771.56l-4.618-2.428a2.122 2.122 0 0 0-1.973 0L6.396 21.01a.53.53 0 0 1-.77-.56l.881-5.139a2.122 2.122 0 0 0-.611-1.879L2.16 9.795a.53.53 0 0 1 .294-.906l5.165-.755a2.122 2.122 0 0 0 1.597-1.16z"/>
        """
    case "heart":
        return """
        <path d="M19 14c1.49-1.46 3-3.21 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.76 0-3 .5-4.5 2-1.5-1.5-2.74-2-4.5-2A5.5 5.5 0 0 0 2 8.5c0 2.3 1.5 4.05 3 5.5l7 7Z"/>
        """
    case "flag":
        return """
        <path d="M4 15s1-1 4-1 5 2 8 2 4-1 4-1V3s-1 1-4 1-5-2-8-2-4 1-4 1z"/><line x1="4" x2="4" y1="22" y2="15"/>
        """
    case "tag":
        return """
        <path d="M12.586 2.586A2 2 0 0 0 11.172 2H4a2 2 0 0 0-2 2v7.172a2 2 0 0 0 .586 1.414l8.704 8.704a2.426 2.426 0 0 0 3.42 0l6.58-6.58a2.426 2.426 0 0 0 0-3.42z"/><circle cx="7.5" cy="7.5" r=".5" fill="currentColor"/>
        """
    case "hash":
        return """
        <line x1="4" x2="20" y1="9" y2="9"/><line x1="4" x2="20" y1="15" y2="15"/><line x1="10" x2="8" y1="3" y2="21"/><line x1="16" x2="14" y1="3" y2="21"/>
        """
    case "check-circle":
        return """
        <path d="M21.801 10A10 10 0 1 1 17 3.335"/><path d="m9 11 3 3L22 4"/>
        """
    case "info":
        return """
        <circle cx="12" cy="12" r="10"/><path d="M12 16v-4"/><path d="M12 8h.01"/>
        """
    case "help-circle":
        return """
        <circle cx="12" cy="12" r="10"/><path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"/><path d="M12 17h.01"/>
        """
    case "shield":
        return """
        <path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/>
        """
    case "globe":
        return """
        <circle cx="12" cy="12" r="10"/><path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/><path d="M2 12h20"/>
        """
    case "compass":
        return """
        <path d="m16.24 7.76-1.804 5.411a2 2 0 0 1-1.265 1.265L7.76 16.24l1.804-5.411a2 2 0 0 1 1.265-1.265z"/><circle cx="12" cy="12" r="10"/>
        """
    case "mail":
        return """
        <rect width="20" height="16" x="2" y="4" rx="2"/><path d="m22 7-8.97 5.7a1.94 1.94 0 0 1-2.06 0L2 7"/>
        """
    case "at-sign":
        return """
        <circle cx="12" cy="12" r="4"/><path d="M16 8v5a3 3 0 0 0 6 0v-1a10 10 0 1 0-4 8"/>
        """
    case "share-2":
        return """
        <circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/><line x1="8.59" x2="15.42" y1="13.51" y2="17.49"/><line x1="15.41" x2="8.59" y1="6.51" y2="10.49"/>
        """
    case "image":
        return """
        <rect width="18" height="18" x="3" y="3" rx="2" ry="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21"/>
        """
    case "mic":
        return """
        <path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/><line x1="12" x2="12" y1="19" y2="22"/>
        """
    case "sun":
        return """
        <circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="m6.34 17.66-1.41 1.41"/><path d="m19.07 4.93-1.41 1.41"/>
        """
    case "moon":
        return """
        <path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/>
        """
    case "zap":
        return """
        <path d="M4 14a1 1 0 0 1-.78-1.63l9.9-10.2a.5.5 0 0 1 .86.46l-1.92 6.02A1 1 0 0 0 13 10h7a1 1 0 0 1 .78 1.63l-9.9 10.2a.5.5 0 0 1-.86-.46l1.92-6.02A1 1 0 0 0 11 14z"/>
        """
    case "flame":
        return """
        <path d="M8.5 14.5A2.5 2.5 0 0 0 11 12c0-1.38-.5-2-1-3-1.072-2.143-.224-4.054 2-6 .5 2.5 2 4.9 4 6.5 2 1.6 3 3.5 3 5.5a7 7 0 1 1-14 0c0-1.153.433-2.294 1-3a2.5 2.5 0 0 0 2.5 2.5z"/>
        """
    case "user":
        return """
        <path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/>
        """
    case "clock":
        return """
        <circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>
        """
    case "calendar":
        return """
        <path d="M8 2v4"/><path d="M16 2v4"/><rect width="18" height="18" x="3" y="4" rx="2"/><path d="M3 10h18"/>
        """
    case "code":
        return """
        <polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/>
        """
    case "terminal":
        return """
        <polyline points="4 17 10 11 4 5"/><line x1="12" x2="20" y1="19" y2="19"/>
        """
    case "graduation-cap":
        return """
        <path d="M21.42 10.922a1 1 0 0 0-.019-1.838L12.83 5.18a2 2 0 0 0-1.66 0L2.6 9.08a1 1 0 0 0 0 1.832l8.57 3.908a2 2 0 0 0 1.66 0z"/><path d="M22 10v6"/><path d="M6 12.5V16a6 3 0 0 0 12 0v-3.5"/>
        """
    case "brain":
        return """
        <path d="M12 5a3 3 0 1 0-5.997.125 4 4 0 0 0-2.526 5.77 4 4 0 0 0 .556 6.588A4 4 0 1 0 12 18Z"/><path d="M12 5a3 3 0 1 1 5.997.125 4 4 0 0 1 2.526 5.77 4 4 0 0 1-.556 6.588A4 4 0 1 1 12 18Z"/><path d="M15 13a4.5 4.5 0 0 1-3-4 4.5 4.5 0 0 1-3 4"/><path d="M17.599 6.5a3 3 0 0 0 .399-1.375"/><path d="M6.003 5.125A3 3 0 0 0 6.401 6.5"/><path d="M3.477 10.896a4 4 0 0 1 .585-.396"/><path d="M19.938 10.5a4 4 0 0 1 .585.396"/><path d="M6 18a4 4 0 0 1-1.967-.516"/><path d="M19.967 17.484A4 4 0 0 1 18 18"/>
        """
    case "lightbulb":
        return """
        <path d="M15 14c.2-1 .7-1.7 1.5-2.5 1-.9 1.5-2.2 1.5-3.5A6 6 0 0 0 6 8c0 1 .2 2.2 1.5 3.5.7.7 1.3 1.5 1.5 2.5"/><path d="M9 18h6"/><path d="M10 22h4"/>
        """
    case "target":
        return """
        <circle cx="12" cy="12" r="10"/><circle cx="12" cy="12" r="6"/><circle cx="12" cy="12" r="2"/>
        """
    case "trophy":
        return """
        <path d="M6 9H4.5a2.5 2.5 0 0 1 0-5H6"/><path d="M18 9h1.5a2.5 2.5 0 0 0 0-5H18"/><path d="M4 22h16"/><path d="M10 14.66V17c0 .55-.47.98-.97 1.21C7.85 18.75 7 20.24 7 22"/><path d="M14 14.66V17c0 .55.47.98.97 1.21C16.15 18.75 17 20.24 17 22"/><path d="M18 2H6v7a6 6 0 0 0 12 0V2Z"/>
        """
    case "rocket":
        return """
        <path d="M4.5 16.5c-1.5 1.26-2 5-2 5s3.74-.5 5-2c.71-.84.7-2.13-.09-2.91a2.18 2.18 0 0 0-2.91-.09z"/><path d="m12 15-3-3a22 22 0 0 1 2-3.95A12.88 12.88 0 0 1 22 2c0 2.72-.78 7.5-6 11a22.35 22.35 0 0 1-4 2z"/><path d="M9 12H4s.55-3.03 2-4c1.62-1.08 5 0 5 0"/><path d="M12 15v5s3.03-.55 4-2c1.08-1.62 0-5 0-5"/>
        """
    case "palette":
        return """
        <circle cx="13.5" cy="6.5" r=".5" fill="currentColor"/><circle cx="17.5" cy="10.5" r=".5" fill="currentColor"/><circle cx="8.5" cy="7.5" r=".5" fill="currentColor"/><circle cx="6.5" cy="12.5" r=".5" fill="currentColor"/><path d="M12 2C6.5 2 2 6.5 2 12s4.5 10 10 10c.926 0 1.648-.746 1.648-1.688 0-.437-.18-.835-.437-1.125-.29-.289-.438-.652-.438-1.125a1.64 1.64 0 0 1 1.668-1.668h1.996c3.051 0 5.555-2.503 5.555-5.554C21.965 6.012 17.461 2 12 2z"/>
        """
    case "pencil":
        return """
        <path d="M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z"/><path d="m15 5 4 4"/>
        """
    case "refresh-cw":
        return """
        <path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/>
        """
    case "download":
        return """
        <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" x2="12" y1="15" y2="3"/>
        """
    case "upload":
        return """
        <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" x2="12" y1="3" y2="15"/>
        """
    case "link":
        return """
        <path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>
        """
    case "eye":
        return """
        <path d="M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0"/><circle cx="12" cy="12" r="3"/>
        """
    case "settings":
        return """
        <path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/><circle cx="12" cy="12" r="3"/>
        """
    case "wrench":
        return """
        <path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/>
        """
    case "plus":
        return """
        <path d="M5 12h14"/><path d="M12 5v14"/>
        """
    case "filter":
        return """
        <polygon points="22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3"/>
        """
    case "folder":
        return """
        <path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>
        """
    case "file":
        return """
        <path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/>
        """
    case "bold":
        return """
        <path d="M6 12h9a4 4 0 0 1 0 8H7a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h7a4 4 0 0 1 0 8"/>
        """
    case "italic":
        return """
        <line x1="19" x2="10" y1="4" y2="4"/><line x1="14" x2="5" y1="20" y2="20"/><line x1="15" x2="9" y1="4" y2="20"/>
        """
    case "diamond":
        return """
        <path d="M2.7 10.3a2.41 2.41 0 0 0 0 3.41l7.59 7.59a2.41 2.41 0 0 0 3.41 0l7.59-7.59a2.41 2.41 0 0 0 0-3.41l-7.59-7.59a2.41 2.41 0 0 0-3.41 0Z"/>
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
