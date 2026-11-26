import AppKit
import SwiftUI

struct KeyboardHandler: NSViewRepresentable {
    let model: ViewerModel
    let viewerWindow: ViewerWindow

    func makeNSView(context: Context) -> KeyboardView { KeyboardView(model: model, viewerWindow: viewerWindow) }
    func updateNSView(_ nsView: KeyboardView, context: Context) {
        nsView.model = model
        nsView.viewerWindow = viewerWindow
    }
    static func dismantleNSView(_ nsView: KeyboardView, coordinator: ()) { nsView.removeMonitor() }
}

@MainActor
final class KeyboardView: NSView {
    var model: ViewerModel
    var viewerWindow: ViewerWindow
    private var monitor: Any?
    private var trackingMenus = 0

    init(model: ViewerModel, viewerWindow: ViewerWindow) {
        self.model = model
        self.viewerWindow = viewerWindow
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        viewerWindow.attach(window)
        guard window != nil else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(menuBeganTracking), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuEndedTracking), name: NSMenu.didEndTrackingNotification, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, window.isKeyWindow,
                  event.window === window, NSApp.modalWindow == nil, self.trackingMenus == 0,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            if let text = window.firstResponder as? NSTextView, text.isEditable { return event }
            if window.firstResponder is NSPopUpButton { return event }
            if event.charactersIgnoringModifiers?.lowercased() == "f" {
                if !event.isARepeat { self.viewerWindow.toggleFullScreen() }
                return nil
            }
            if event.charactersIgnoringModifiers?.lowercased() == "t" {
                if !event.isARepeat { self.model.showsFilmstrip.toggle() }
                return nil
            }
            if event.keyCode == 53, window.styleMask.contains(.fullScreen) {
                if !event.isARepeat { self.viewerWindow.toggleFullScreen() }
                return nil
            }
            guard !self.model.isLoading else { return event }
            switch event.keyCode {
            case 123: self.model.navigate(.previous)
            case 124: self.model.navigate(.next)
            case 53:
                guard self.model.hasOpenedCollection else { return event }
                self.model.mode = .grid
            case 36, 76:
                guard self.model.mode == .grid, self.model.selectedPhoto != nil else { return event }
                self.model.mode = .photo
            default:
                guard let text = event.charactersIgnoringModifiers, text.count == 1,
                      let rating = Int(text), (0...5).contains(rating), self.model.selectedPhoto != nil else { return event }
                self.model.setRating(rating)
            }
            return nil
        }
    }

    @objc private func menuBeganTracking(_ notification: Notification) { trackingMenus += 1 }
    @objc private func menuEndedTracking(_ notification: Notification) { trackingMenus = max(0, trackingMenus - 1) }

    func removeMonitor() {
        NotificationCenter.default.removeObserver(self)
        trackingMenus = 0
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
