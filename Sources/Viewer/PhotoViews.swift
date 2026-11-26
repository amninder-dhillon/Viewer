import AppKit
import SwiftUI
import ViewerCore

struct RatingControl: View {
    @ObservedObject var model: ViewerModel
    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { rating in
                Button { model.setRating(rating) } label: {
                    Image(systemName: model.selectedRating >= rating ? "star.fill" : "star")
                        .foregroundStyle(model.selectedRating >= rating ? Color.accentColor : .secondary)
                        .frame(width: 23, height: 28)
                }
                .buttonStyle(.plain)
                .help("Rate \(rating) \(rating == 1 ? "star" : "stars") (\(rating))")
                .accessibilityLabel("Rate \(rating) stars")
                .accessibilityValue(model.selectedRating >= rating ? "Selected" : "Not selected")
            }
            Button { model.setRating(0) } label: { Image(systemName: "xmark.circle").frame(width: 25, height: 28) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear rating (0)")
                .accessibilityLabel("Clear rating")
                .disabled(model.selectedRating == 0)
        }.disabled(model.selectedPhoto == nil)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Photo rating")
    }
}

struct PhotoDetail: View {
    @ObservedObject var model: ViewerModel
    @State private var decoded: DecodedImage?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .textBackgroundColor)
                if let photo = model.selectedPhoto {
                    if let decoded {
                        Image(decorative: decoded.image, scale: 1)
                            .resizable().scaledToFit().padding(20)
                            .accessibilityLabel(photo.name)
                    } else if failed {
                        EmptyPhotosView(title: "This image couldn’t be displayed", description: "The file may be unavailable, damaged, or in an unsupported format. You can continue browsing.", symbol: "exclamationmark.triangle")
                    } else { ProgressView().controlSize(.small) }
                } else {
                    EmptyPhotosView(title: "No photos match this rating", description: "Change the rating filter, or select any thumbnail below to inspect and rate it.", symbol: "line.3.horizontal.decrease.circle")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.selectedPhoto?.name ?? "No matching photo selected")
                        .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if let photo = model.selectedPhoto {
                        HStack(spacing: 8) {
                            if let decoded {
                                Text("\(decoded.pixelWidth) × \(decoded.pixelHeight)")
                            }
                            Text(photo.url.pathExtension.uppercased())
                            Text(ByteCountFormatter.string(fromByteCount: photo.fileSize, countStyle: .file))
                            if !model.matchingIDs.contains(photo.id) {
                                Label("Excluded by filter", systemImage: "line.3.horizontal.decrease.circle")
                            }
                        }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                RatingControl(model: model)
                HStack(spacing: 8) {
                    Button { model.navigate(.previous) } label: { Image(systemName: "chevron.left") }
                        .disabled(model.destination(.previous) == nil).help("Previous matching photo (←)")
                        .accessibilityLabel("Previous matching photo")
                    Text(model.matchingPosition.map { "\($0) / \(model.matchingIDs.count)" } ?? "— / \(model.matchingIDs.count)")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Button { model.navigate(.next) } label: { Image(systemName: "chevron.right") }
                        .disabled(model.destination(.next) == nil).help("Next matching photo (→)")
                        .accessibilityLabel("Next matching photo")
                }.buttonStyle(.borderless)
            }.padding(.horizontal, 20).padding(.vertical, 14)
        }
        .task(id: model.selectedPhoto) {
            decoded = nil
            failed = false
            guard let photo = model.selectedPhoto else { return }
            let result = await ImagePipeline.previews.load(photo, maxPixelSize: 4000)
            guard !Task.isCancelled, model.selectedID == photo.id else { return }
            decoded = result
            failed = result == nil
        }
    }
}

struct ThumbnailImage: View {
    let photo: Photo
    let eligible: Bool
    @State private var decoded: DecodedImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let decoded {
                Image(decorative: decoded.image, scale: 1)
                    .resizable().scaledToFit()
                    .opacity(eligible ? 1 : 0.3)
                    .saturation(eligible ? 1 : 0)
            } else {
                Image(systemName: failed ? "exclamationmark.triangle" : "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .task(id: photo) {
            decoded = nil
            failed = false
            let result = await ImagePipeline.thumbnails.load(photo, maxPixelSize: 480)
            guard !Task.isCancelled else { return }
            decoded = result
            failed = result == nil
        }
    }
}

private struct RatingSummary: View {
    let rating: Int
    let eligible: Bool
    var body: some View {
        HStack(spacing: 3) {
            if rating == 0 {
                Text("Unrated")
            } else {
                ForEach(0..<rating, id: \.self) { _ in Image(systemName: "star.fill").font(.system(size: 8)) }
            }
            if !eligible { Image(systemName: "line.3.horizontal.decrease.circle").help("Excluded by rating filter") }
        }.font(.caption2).foregroundStyle(.secondary)
    }
}

struct Filmstrip: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 9) {
                    ForEach(model.visiblePhotos) { photo in
                        let eligible = model.matchingIDs.contains(photo.id)
                        Button { model.select(photo) } label: {
                            VStack(spacing: 5) {
                                ThumbnailImage(photo: photo, eligible: eligible)
                                    .frame(width: 86, height: 60).clipShape(RoundedRectangle(cornerRadius: 3))
                                RatingSummary(rating: model.rating(for: photo), eligible: eligible).frame(height: 13)
                            }
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(model.selectedID == photo.id ? Color.accentColor : .clear, lineWidth: 2))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).focusable(false).id(photo.id)
                        .help("\(photo.relativePath) · \(model.rating(for: photo)) stars\(eligible ? "" : " · Excluded by filter")")
                        .accessibilityLabel("\(photo.name), \(model.rating(for: photo)) stars, \(eligible ? "matches filter" : "excluded by filter")")
                        .accessibilityAddTraits(model.selectedID == photo.id ? .isSelected : [])
                    }
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }.frame(height: 111)
                .onChange(of: model.selectedID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
                .onAppear { if let id = model.selectedID { proxy.scrollTo(id, anchor: .center) } }
        }
    }
}

struct PhotoGrid: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 250), spacing: 16)], spacing: 20) {
                    ForEach(model.visiblePhotos) { photo in
                        let eligible = model.matchingIDs.contains(photo.id)
                        Button { model.select(photo) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ThumbnailImage(photo: photo, eligible: eligible)
                                    .frame(height: 125).clipShape(RoundedRectangle(cornerRadius: 4))
                                Text(photo.name).font(.caption).lineLimit(1).truncationMode(.middle)
                                HStack {
                                    RatingSummary(rating: model.rating(for: photo), eligible: eligible)
                                    Spacer(minLength: 4)
                                    if !eligible { Text("Excluded").font(.caption2).foregroundStyle(.secondary) }
                                }.frame(height: 14)
                            }
                            .padding(6)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(model.selectedID == photo.id ? Color.accentColor : .clear, lineWidth: 2))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).focusable(false).id(photo.id)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { model.select(photo, open: true) })
                        .help(photo.relativePath + " · Double-click to open")
                        .accessibilityLabel("\(photo.name), \(model.rating(for: photo)) stars, \(eligible ? "matches filter" : "excluded by filter")")
                        .accessibilityAddTraits(model.selectedID == photo.id ? .isSelected : [])
                    }
                }.padding(20)
            }
            .onChange(of: model.selectedID) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}
