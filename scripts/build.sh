#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# Keep compiler and package caches in the project, including in restricted workspaces.
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/module-cache"
PACKAGE_OPTIONS=(--disable-sandbox --scratch-path "$PROJECT_ROOT/.build" --cache-path "$PROJECT_ROOT/.build/cache" --config-path "$PROJECT_ROOT/.build/config" --security-path "$PROJECT_ROOT/.build/security")
swift build -c release -debug-info-format none "${PACKAGE_OPTIONS[@]}"
BINARY_DIR="$(swift build -c release "${PACKAGE_OPTIONS[@]}" --show-bin-path)"
APP="$PROJECT_ROOT/dist/Viewer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY_DIR/Viewer" "$APP/Contents/MacOS/Viewer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swift scripts/make-icon.swift "$PROJECT_ROOT/.build/Viewer.iconset" "$PROJECT_ROOT/.build/AppIcon.icns"
cp "$PROJECT_ROOT/.build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
printf '\nBuilt %s\nLaunch with: open "%s"\n' "$APP" "$APP"
