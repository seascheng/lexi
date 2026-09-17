import AppKit

let app = NSApplication.shared
let delegate = SelectionToolbarApp()
app.delegate = delegate
app.run()
