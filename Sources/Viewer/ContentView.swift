import SwiftUI
import ViewerCore

struct ContentView: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var viewerWindow: ViewerWindow
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var windowedColumnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 175, ideal: 210, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if let notice = model.notice {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(notice).font(.caption).textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button { model.notice = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).help("Dismiss message")
                    }
                    .padding(12).background(.yellow.opacity(0.12))
                }
                if !model.hasOpenedCollection {
                    WelcomeView(model: model)
                } else {
                    if !viewerWindow.isFullScreen {
                        collectionHeader
                        Divider()
                    }
                    if model.visiblePhotos.isEmpty {
                        EmptyPhotosView(title: "No images in this folder", description: "Choose another folder to start browsing.", symbol: "photo.on.rectangle.angled")
                    } else if model.mode == .grid {
                        PhotoGrid(model: model)
                    } else {
                        PhotoDetail(model: model)
                    }
                    if model.mode == .grid, !model.visiblePhotos.isEmpty {
                        Divider()
                        HStack {
                            Text(model.selectedPhoto?.name ?? "No matching photo selected")
                                .font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            RatingControl(model: model)
                        }.padding(.horizontal, 18).padding(.vertical, 10)
                    }
                    if !model.visiblePhotos.isEmpty, model.mode == .photo, model.showsFilmstrip {
                        Divider()
                        Filmstrip(model: model)
                    }
                    if !viewerWindow.isFullScreen {
                        Divider()
                        statusBar
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay {
                if model.isLoading {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Finding photos…").font(.headline)
                        Text("\(model.discoveredCount.formatted()) images found · Including subfolders")
                            .foregroundStyle(.secondary).font(.callout)
                        Button("Cancel") { model.cancelLoading() }
                    }
                    .padding(32).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.12))
                }
            }
            .navigationTitle(model.hasOpenedCollection ? model.collectionTitle : "Viewer")
        }
        .frame(minWidth: 760, minHeight: 560)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.openImagePanel() } label: { Label("Open Image", systemImage: "photo") }
                    .help("Open images (⌘O)")
                Button { model.openFolderPanel() } label: { Label("Open Folder", systemImage: "folder") }
                    .help("Open a folder and its subfolders (⇧⌘O)")
                Picker("View", selection: $model.mode) {
                    Image(systemName: "photo").tag(DisplayMode.photo).accessibilityLabel("Photo view")
                    Image(systemName: "square.grid.2x2").tag(DisplayMode.grid).accessibilityLabel("Grid view")
                }.pickerStyle(.segmented).frame(width: 80).disabled(!model.hasOpenedCollection)
                Menu {
                    Picker("Rating", selection: $model.filter) {
                        ForEach(RatingFilter.allCases) { filter in Text(filter.title).tag(filter) }
                    }
                } label: {
                    Label(model.filter.title, systemImage: model.filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                }.labelStyle(.titleAndIcon).help("Filter navigation by rating; every thumbnail stays visible")
                Button { viewerWindow.toggleFullScreen() } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }.help("Toggle full screen (F)")
                Toggle(isOn: $model.showsFilmstrip) {
                    Label("Filmstrip", systemImage: "film")
                }.toggleStyle(.button).help("Show or hide filmstrip (T)")
            }
        }
        .toolbar(viewerWindow.isFullScreen ? .hidden : .visible, for: .windowToolbar)
        .onChange(of: viewerWindow.isFullScreen) { _, fullScreen in
            if fullScreen {
                windowedColumnVisibility = columnVisibility
                columnVisibility = .detailOnly
                model.mode = .photo
            } else {
                columnVisibility = windowedColumnVisibility
            }
        }
        .background(KeyboardHandler(model: model, viewerWindow: viewerWindow).frame(width: 0, height: 0))
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            model.open(urls)
            return true
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }

    private var collectionHeader: some View {
        HStack {
            Image(systemName: model.rootFolder == nil ? "photo" : "folder").foregroundStyle(.secondary)
            Text(model.selectedFolder?.lastPathComponent ?? model.rootFolder?.lastPathComponent ?? "Opened images")
                .font(.callout).lineLimit(1).truncationMode(.middle)
                .help(model.selectedFolder?.path ?? model.rootFolder?.path ?? "Opened from files")
            if model.rootFolder != nil {
                Text("Includes subfolders").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Picker("Sort", selection: $model.sort) {
                ForEach(PhotoSort.allCases) { sort in Text(sort.title).tag(sort) }
            }.labelsHidden().fixedSize().help("Sort photos")
        }.padding(.horizontal, 18).padding(.vertical, 10)
    }

    private var statusBar: some View {
        HStack {
            Text("\(model.matchingIDs.count.formatted()) matching · \(model.visiblePhotos.count.formatted()) total")
                .monospacedDigit()
            if model.matchingIDs.count != model.visiblePhotos.count {
                Text("\((model.visiblePhotos.count - model.matchingIDs.count).formatted()) excluded")
            }
            Spacer(minLength: 8)
            Text("← → Matching photos   1–5 Rate   0 Clear   F Full screen   T Filmstrip").lineLimit(1)
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 9)
    }
}

private struct Sidebar: View {
    @ObservedObject var model: ViewerModel
    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("Folders") {
                    folderButton(title: "All photos", symbol: "photo.stack", count: model.photos.count, url: nil)
                    if let root = model.rootFolder {
                        Section(root.lastPathComponent) {
                            OutlineGroup(model.folders, children: \.children) { folder in
                                folderButton(title: folder.url.lastPathComponent, symbol: "folder", count: folder.count, url: folder.url)
                            }
                        }
                    }
                }
            }.listStyle(.sidebar)
            VStack(alignment: .leading, spacing: 5) {
                Label("Originals stay untouched", systemImage: "checkmark.shield")
                Text("Ratings are saved in Viewer.")
            }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }

    private func folderButton(title: String, symbol: String, count: Int, url: URL?) -> some View {
        Button { model.selectedFolder = url } label: {
            HStack {
                Label(title, systemImage: symbol).lineLimit(1)
                Spacer(minLength: 4)
                Text(count.formatted()).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7).padding(.vertical, 6)
            .background(model.selectedFolder == url ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help(url?.path ?? "Every image in this collection")
    }
}

private struct WelcomeView: View {
    @ObservedObject var model: ViewerModel
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 56, weight: .light)).foregroundStyle(.secondary)
            Text("A closer look.").font(.largeTitle.weight(.medium))
            Text("Open a photo, or explore a folder and all its subfolders.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Open Image…") { model.openImagePanel() }.buttonStyle(.bordered)
                Button("Open Folder…") { model.openFolderPanel() }.buttonStyle(.borderedProminent)
            }
            Text("You can also drop images or a folder here.").font(.caption).foregroundStyle(.secondary)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyPhotosView: View {
    let title: String
    let description: String
    let symbol: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.medium))
            Text(description).foregroundStyle(.secondary).multilineTextAlignment(.center).font(.callout)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
