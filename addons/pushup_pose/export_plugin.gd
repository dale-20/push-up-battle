@tool
extends EditorPlugin

## Adds the PushUpPose Android plugin (built from android-plugin/) to Android
## exports. Requires "Use Gradle Build" in the Android export preset.

var _export_plugin: AndroidExportPlugin

func _enter_tree() -> void:
	_export_plugin = AndroidExportPlugin.new()
	add_export_plugin(_export_plugin)

func _exit_tree() -> void:
	remove_export_plugin(_export_plugin)
	_export_plugin = null

class AndroidExportPlugin extends EditorExportPlugin:
	const PLUGIN_NAME := "PushUpPose"
	# Keep in sync with android-plugin/plugin/build.gradle.
	const DEPENDENCIES := [
		"androidx.camera:camera-core:1.4.2",
		"androidx.camera:camera-camera2:1.4.2",
		"androidx.camera:camera-lifecycle:1.4.2",
		"com.google.mlkit:pose-detection:18.0.0-beta5",
	]

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_android_libraries(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		return PackedStringArray(["pushup_pose/bin/PushUpPose-%s.aar" % ("debug" if debug else "release")])

	func _get_android_dependencies(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		return PackedStringArray(DEPENDENCIES)

	func _get_name() -> String:
		return PLUGIN_NAME
