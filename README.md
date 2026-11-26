# Viewer

A native macOS photo browser built with SwiftUI and AppKit. Requires macOS 14 or later and Xcode 16 or later to build. No third-party dependencies.

## Build and run

```sh
bash scripts/build.sh
open dist/Viewer.app
```

The script builds a release executable, creates the app bundle and icon, and signs it locally. Open `Package.swift` in Xcode to develop the app. Use the bundled app to test Finder integration.

To open images with a double-click in Finder, move `Viewer.app` to Applications if desired, select an image, and choose **Get Info → Open with → Viewer → Change All…**. macOS saves this preference per file type; repeat for JPEG, PNG, and other types you use. Viewer registers as an available image viewer without changing your defaults automatically.

## Usage

- **⌘O:** open one or more images. **⇧⌘O:** open a folder, recursively including subfolders.
- Drop image files or a folder into the window. Finder's **Open With → Viewer** also works.
- **← / →:** previous or next photo matching the current rating filter, in the current sort order. Navigation stops at either end.
- **1–5:** assign a rating. **0:** clear it. You can also click the stars.
- Rating filters support a minimum rating, an exact rating, and unrated photos.
- All thumbnails in the current folder scope stay visible. Excluded photos are dimmed and marked; clicking one lets you inspect and rate it. Arrow keys resume at the nearest matching photo in that direction.
- Changing the filter or lowering a photo's rating below the filter selects the next match, then the previous match if at the end. If none match, the main view shows an empty state and the thumbnails stay accessible.
- **⌘G:** toggle grid/photo view. **Return** or double-click a grid thumbnail opens it. **Escape:** return to the grid.
- **F:** toggle native full screen. **Escape** exits full screen first. **⌃⌘F**, the toolbar button, and macOS's green window button also toggle full screen. Entering full screen switches to photo view and hides the sidebar and toolbar; leaving restores the sidebar. The filmstrip, rating stars, **← / →** filtered navigation, and **1–5 / 0** rating shortcuts remain available.
- **T** or **⇧⌘T:** show or hide the filmstrip in photo view, in both windowed and full-screen mode. The toolbar button and **View → Show Filmstrip** provide the same toggle. The preference is shared between both modes and remembered after restarting Viewer. Navigation and ratings keep working while it is hidden.
- Selecting a subfolder in the sidebar includes that folder's descendants. Sorting supports filename, folder, and newest first.

## Ratings and files

Ratings are stored atomically in `~/Library/Application Support/Viewer/ratings.json`. Original images and metadata are never edited. Ratings currently follow absolute file paths; moving or renaming an image changes its identity. A future version can add move tracking and optional XMP sidecars.

The scanner skips hidden files, package contents, and symbolic links. Images are decoded with ImageIO, including orientation handling. Format support follows the macOS image decoders; animated images display their first frame. Main previews are limited to 4,000 pixels on the longest edge, and thumbnails are cached separately. This first version fits photos to the window; zoom, rotation, and slideshows are future additions.

Folder enumeration and image decoding run off the main thread. Only visible thumbnails are requested, and thumbnail/preview caches have separate memory limits. Missing or undecodable images display a placeholder so browsing can continue.

Photo view shows a cached thumbnail immediately while the sharper preview loads. If neither size is cached, thumbnail and preview decoding start together, so whichever is ready first appears. Cached sharp previews take precedence, late thumbnails never replace sharper images, and results for a previously selected photo are discarded. If only the thumbnail can be decoded, it remains visible with a “Preview only” indication. This also works with the filmstrip hidden and in full screen.

Image decoding uses a priority queue with at most two running decodes per pipeline (two previews and two thumbnails across the app). The selected photo's thumbnail and preview take priority over queued filmstrip/grid thumbnails; when saturated, the latest selected request is scheduled first. Duplicate requests for the same file, modification time, and size share one decode. Cancelling a subscriber removes its queued work immediately when no other subscribers need it. Running ImageIO calls finish and remain counted against the limit, and their result can still be cached or reused if you return to that photo. If both slots are occupied, a new selection waits for a slot to finish.

For profiling, record the `dev.viewer.mac` subsystem in Instruments' signpost instrument. `PhotoPreview` records the request-to-sharp-preview interval and first-image publication; `ImageDecoding` records queue time, worker duration, decoded byte counts, cache hits, shared requests, and discarded queued work. Use Allocations alongside these events to measure peak memory on representative large images; no fixed speedup is assumed.

## Tests

```sh
bash scripts/test.sh
```

Tests cover filtered navigation, excluded-photo inspection, selection after a rating change, zero matches, rating persistence/failure handling, recursive scanning, folder counts, and natural sorting.

Preview-loading tests control decode completion order to verify thumbnail-first display, cache hits, sharp-image precedence, failure fallback, and rejection of stale results during rapid navigation. A real ImageIO decode also verifies thumbnail cache reuse and modification-time invalidation.

Scheduler tests hold workers open to verify the concurrency cap, selected-photo priority, cancellation of obsolete queued requests, independent cancellation of shared subscribers, reuse of still-running decodes, and separation of requests for different image sizes.

The generated app is locally signed for this Mac. Distribution to other Macs requires a Developer ID signature and notarization.
