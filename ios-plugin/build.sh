#!/usr/bin/env bash
# Builds the PushUpPose iOS GDExtension into addons/pushup_pose_ios/.
# macOS only (needs Xcode). Used by .github/workflows/ios.yml.
#
#   ios-plugin/build.sh /path/to/Godot.app/Contents/MacOS/Godot
#
# godot-cpp is built against the API dumped from that exact Godot binary, so
# the extension always matches the engine version used to export the app.
set -euo pipefail

GODOT="${1:?usage: build.sh <path-to-godot-editor>}"
GODOT_CPP_REF="${GODOT_CPP_REF:-master}"
MIN_IOS="14.0"  # VNDetectHumanBodyPoseRequest needs iOS 14.

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$HERE/.build"
OUT="$ROOT/addons/pushup_pose_ios"
mkdir -p "$WORK"
cd "$WORK"

echo "== Dumping extension API from $("$GODOT" --version)"
"$GODOT" --headless --dump-extension-api
test -f extension_api.json

if [ ! -d godot-cpp ]; then
	git clone --depth 1 --branch "$GODOT_CPP_REF" https://github.com/godotengine/godot-cpp.git
fi

echo "== Building godot-cpp ($GODOT_CPP_REF) for iOS arm64"
(cd godot-cpp && scons platform=ios arch=arm64 target=template_release \
	ios_min_version="$MIN_IOS" custom_api_file="$WORK/extension_api.json" \
	-j"$(sysctl -n hw.ncpu)")
LIB="$(ls godot-cpp/bin/libgodot-cpp.ios.template_release.arm64*.a | head -n 1)"
echo "   $LIB"

echo "== Compiling PushUpPose.framework"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
FW="$WORK/PushUpPose.framework"
rm -rf "$FW"
mkdir -p "$FW"
xcrun --sdk iphoneos clang++ -arch arm64 -isysroot "$SDK" -miphoneos-version-min="$MIN_IOS" \
	-std=c++17 -fobjc-arc -O2 -fPIC -DNDEBUG -DTHREADS_ENABLED \
	-Igodot-cpp/include -Igodot-cpp/gen/include -Igodot-cpp/gdextension \
	-dynamiclib -install_name @rpath/PushUpPose.framework/PushUpPose \
	"$HERE/src/pushup_pose.mm" "$LIB" \
	-framework Foundation -framework AVFoundation -framework CoreMedia \
	-framework CoreVideo -framework Vision \
	-o "$FW/PushUpPose"

cat > "$FW/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>PushUpPose</string>
	<key>CFBundleIdentifier</key><string>com.dale20.pushupbattle.pushuppose</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>PushUpPose</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
	<key>MinimumOSVersion</key><string>$MIN_IOS</string>
</dict>
</plist>
PLIST

echo "== Packaging $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"
xcodebuild -create-xcframework -framework "$FW" -output "$OUT/PushUpPose.xcframework"
cp "$HERE/pushup_pose.gdextension" "$OUT/pushup_pose.gdextension"
ls -R "$OUT"
