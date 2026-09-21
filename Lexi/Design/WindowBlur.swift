import AppKit
import Foundation

/// Window-server background blur — exactly goty's chain
/// (ghostty_set_window_background_blur bottoms out in this call; verified
/// working on this machine). The window keeps a translucent self-drawn
/// fill (Background Purity); the server blurs whatever sits behind the
/// window and the fill composites over it — a TRUE continuous radius
/// driven 1:1 by the Background Blur slider.
///
/// Dynamically resolved: if the symbol ever disappears the call becomes a
/// no-op and surfaces fall back to plain translucent fills.
enum WindowBlur {
    private typealias SetBlur = @convention(c) (UInt32, Int, Int) -> Void
    private typealias MainConnection = @convention(c) () -> UInt32

    private static let impl: (connection: UInt32, set: SetBlur)? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) ?? dlopen(nil, RTLD_LAZY),
              let mainConnSymbol = dlsym(handle, "CGSMainConnectionID"),
              let setBlurSymbol = dlsym(handle, "CGSSetWindowBackgroundBlurRadius")
        else { return nil }
        let mainConn = unsafeBitCast(mainConnSymbol, to: MainConnection.self)
        let setBlur = unsafeBitCast(setBlurSymbol, to: SetBlur.self)
        return (mainConn(), setBlur)
    }()

    static func set(radius: Int, on window: NSWindow) {
        guard let impl, radius > 0 else { return }
        impl.set(impl.connection, window.windowNumber, radius)
    }
}
