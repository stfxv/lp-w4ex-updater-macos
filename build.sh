#!/bin/zsh
set -euo pipefail

swift build -c release --arch arm64
swift build -c release --arch x86_64

arm_binary=".build/arm64-apple-macosx/release/lpw4ex-updater"
x86_binary=".build/x86_64-apple-macosx/release/lpw4ex-updater"
gui_arm_binary=".build/arm64-apple-macosx/release/lpw4ex-updater-gui"
gui_x86_binary=".build/x86_64-apple-macosx/release/lpw4ex-updater-gui"

lipo -create "$arm_binary" "$x86_binary" -output lpw4ex-updater-universal

app_dir="LPW4EXUpdater.app/Contents"
mkdir -p "$app_dir/MacOS"
cp App/Info.plist "$app_dir/Info.plist"
lipo -create "$gui_arm_binary" "$gui_x86_binary" -output "$app_dir/MacOS/LPW4EXUpdater"
cp lpw4ex-updater-universal "$app_dir/MacOS/lpw4ex-updater-cli"
chmod +x "$app_dir/MacOS/LPW4EXUpdater" "$app_dir/MacOS/lpw4ex-updater-cli"

print "Built: lpw4ex-updater-universal"
print "Built: LPW4EXUpdater.app"
