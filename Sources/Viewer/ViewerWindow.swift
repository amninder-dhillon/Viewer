import AppKit
import SwiftUI

/// Observe the actual window so F, the green button, and macOS's full-screen command stay in sync.
@MainActor
final class ViewerWindow: NSObject, ObservableObject {
    @Published private(set) var isFullScreen = false
    private weak var window: NSWindow?

    func attach(_ window: NSWindow?) {
        guard self.window !== window else { return }
        NotificationCenter.default.removeObserver(self)
        self.window = window
        if let window {
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(fullScreenChanged), name: name, object: window)
            }
        }
        updateState()
    }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    @objc private func fullScreenChanged(_ notification: Notification) {
        updateState()
    }

    private func updateState() {
        let value = window?.styleMask.contains(.fullScreen) == true
        if isFullScreen != value { isFullScreen = value }
    }
}
