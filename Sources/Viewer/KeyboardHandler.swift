import AppKit
import SwiftUI

struct KeyboardHandler: NSViewRepresentable {
    let model: ViewerModel

    func makeNSView(context: Context) -> KeyboardView { KeyboardView(model: model) }
    func updateNSView(_ nsView: KeyboardView, context: Context) { nsView.model = model }
    static func dismantleNSView(_ nsView: KeyboardView, coordinator: ()) { nsView.removeMonitor() }
}

@MainActor
final class KeyboardView: NSView {
    var model: ViewerModel
    private var monitor: Any?

    init(model: ViewerModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, window.isKeyWindow,
                  event.window === window, NSApp.modalWindow == nil,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            if let text = window.firstResponder as? NSTextView, text.isEditable { return event }
            if window.firstResponder is NSPopUpButton { return event }
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

    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
