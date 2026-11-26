import AppKit
import SwiftUI
import ViewerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var showMainWindow: (() -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        showMainWindow?()
        ViewerModel.shared.open(urls)
        application.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow?() }
        return true
    }
}

@main
struct ViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = ViewerModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Viewer", id: "main") {
            ContentView(model: model)
                .onAppear { delegate.showMainWindow = { openWindow(id: "main") } }
        }
        .defaultSize(width: 1120, height: 780)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Image…") { openWindow(id: "main"); model.openImagePanel() }
                    .keyboardShortcut("o")
                Button("Open Folder…") { openWindow(id: "main"); model.openFolderPanel() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Navigate") {
                Button("Previous Matching Photo") { model.navigate(.previous) }
                    .disabled(model.destination(.previous) == nil)
                Button("Next Matching Photo") { model.navigate(.next) }
                    .disabled(model.destination(.next) == nil)
                Divider()
                Button(model.mode == .photo ? "Show Grid" : "Show Photo") {
                    model.mode = model.mode == .photo ? .grid : .photo
                }.keyboardShortcut("g")
            }
            CommandMenu("Rating") {
                ForEach(1...5, id: \.self) { rating in
                    Button("\(rating) \(rating == 1 ? "Star" : "Stars")") { model.setRating(rating) }
                        .disabled(model.selectedPhoto == nil)
                }
                Button("Clear Rating") { model.setRating(0) }.disabled(model.selectedPhoto == nil)
                Divider()
                Picker("Filter", selection: $model.filter) {
                    ForEach(RatingFilter.allCases) { filter in Text(filter.title).tag(filter) }
                }
            }
        }
    }
}
