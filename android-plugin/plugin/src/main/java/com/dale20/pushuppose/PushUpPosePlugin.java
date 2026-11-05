package com.dale20.pushuppose;

import android.Manifest;
import android.app.Activity;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Matrix;
import android.graphics.PointF;
import android.util.Log;
import android.util.Size;

import androidx.annotation.NonNull;
import androidx.camera.core.CameraSelector;
import androidx.camera.core.ImageAnalysis;
import androidx.camera.core.ImageProxy;
import androidx.camera.core.resolutionselector.ResolutionSelector;
import androidx.camera.core.resolutionselector.ResolutionStrategy;
import androidx.camera.lifecycle.ProcessCameraProvider;
import androidx.core.content.ContextCompat;
import androidx.lifecycle.Lifecycle;
import androidx.lifecycle.LifecycleOwner;
import androidx.lifecycle.LifecycleRegistry;

import com.google.android.gms.tasks.Tasks;
import com.google.common.util.concurrent.ListenableFuture;
import com.google.mlkit.vision.common.InputImage;
import com.google.mlkit.vision.pose.Pose;
import com.google.mlkit.vision.pose.PoseDetection;
import com.google.mlkit.vision.pose.PoseDetector;
import com.google.mlkit.vision.pose.PoseLandmark;
import com.google.mlkit.vision.pose.defaults.PoseDetectorOptions;

import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.SignalInfo;
import org.godotengine.godot.plugin.UsedByGodot;

import java.nio.ByteBuffer;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * On-device pose tracking for Push-Up Battle.
 *
 * <p>Owns a single CameraX session (analysis only) and runs the bundled ML Kit pose model on
 * every frame. Godot receives landmark coordinates and, optionally, a small RGBA thumbnail for
 * the local preview. Frames are never written to storage or sent anywhere.
 *
 * <p>Signals:
 * <ul>
 *   <li>{@code pose_frame(points: PackedFloat32Array, width: int, height: int)} - 33 landmarks as
 *       (x, y, inFrameLikelihood); x and y are divided by the upright image height. All zeros
 *       when no body is detected.</li>
 *   <li>{@code preview_frame(rgba: PackedByteArray, width: int, height: int)}</li>
 *   <li>{@code camera_status(status: String)} - "started", "permission_missing" or "error: ..."</li>
 * </ul>
 */
public class PushUpPosePlugin extends GodotPlugin {
    private static final String TAG = "PushUpPose";
    private static final int LANDMARK_COUNT = 33;
    private static final int PREVIEW_HEIGHT = 240;
    private static final Size ANALYSIS_SIZE = new Size(640, 480);

    private final ExecutorService analysisExecutor = Executors.newSingleThreadExecutor();
    private final CameraLifecycle cameraLifecycle = new CameraLifecycle();
    private PoseDetector detector;
    private ProcessCameraProvider cameraProvider;
    private volatile boolean running;
    private volatile boolean sendPreview;
    private volatile boolean wantFrontCamera;
    private volatile boolean mirror;

    public PushUpPosePlugin(Godot godot) {
        super(godot);
    }

    @NonNull
    @Override
    public String getPluginName() {
        return "PushUpPose";
    }

    @NonNull
    @Override
    public Set<SignalInfo> getPluginSignals() {
        Set<SignalInfo> signals = new HashSet<>();
        signals.add(new SignalInfo("pose_frame", float[].class, Integer.class, Integer.class));
        signals.add(new SignalInfo("preview_frame", byte[].class, Integer.class, Integer.class));
        signals.add(new SignalInfo("camera_status", String.class));
        return signals;
    }

    /** Starts the camera and pose detection. Camera permission must already be granted. */
    @UsedByGodot
    public boolean start(boolean useFrontCamera, boolean withPreview) {
        Activity activity = getActivity();
        if (activity == null) {
            return false;
        }
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA)
                != PackageManager.PERMISSION_GRANTED) {
            emitStatus("permission_missing");
            return false;
        }
        wantFrontCamera = useFrontCamera;
        sendPreview = withPreview;
        if (detector == null) {
            detector = PoseDetection.getClient(new PoseDetectorOptions.Builder()
                    .setDetectorMode(PoseDetectorOptions.STREAM_MODE)
                    .build());
        }
        running = true;
        activity.runOnUiThread(() -> bindCamera(activity));
        return true;
    }

    @UsedByGodot
    public void stop() {
        running = false;
        Activity activity = getActivity();
        if (activity != null) {
            activity.runOnUiThread(this::unbindCamera);
        }
    }

    @UsedByGodot
    public boolean isRunning() {
        return running;
    }

    @Override
    public void onMainPause() {
        super.onMainPause();
        // Release the camera while the app is in the background.
        cameraLifecycle.pause();
    }

    @Override
    public void onMainResume() {
        super.onMainResume();
        if (running) {
            cameraLifecycle.resume();
        }
    }

    @Override
    public void onMainDestroy() {
        running = false;
        unbindCamera();
        cameraLifecycle.destroy();
        if (detector != null) {
            detector.close();
            detector = null;
        }
        analysisExecutor.shutdown();
        super.onMainDestroy();
    }

    private void bindCamera(Activity activity) {
        ListenableFuture<ProcessCameraProvider> future = ProcessCameraProvider.getInstance(activity);
        future.addListener(() -> {
            try {
                cameraProvider = future.get();
                if (!running) {
                    return;
                }
                cameraProvider.unbindAll();
                ImageAnalysis analysis = new ImageAnalysis.Builder()
                        .setResolutionSelector(new ResolutionSelector.Builder()
                                .setResolutionStrategy(new ResolutionStrategy(ANALYSIS_SIZE,
                                        ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER))
                                .build())
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                        .build();
                analysis.setAnalyzer(analysisExecutor, this::analyze);

                CameraSelector selector = wantFrontCamera
                        ? CameraSelector.DEFAULT_FRONT_CAMERA : CameraSelector.DEFAULT_BACK_CAMERA;
                boolean front = wantFrontCamera;
                if (!cameraProvider.hasCamera(selector)) {
                    front = !front;
                    selector = front
                            ? CameraSelector.DEFAULT_FRONT_CAMERA : CameraSelector.DEFAULT_BACK_CAMERA;
                }
                mirror = front;
                cameraLifecycle.resume();
                cameraProvider.bindToLifecycle(cameraLifecycle, selector, analysis);
                emitStatus("started");
            } catch (Exception e) {
                running = false;
                Log.e(TAG, "Could not start camera", e);
                emitStatus("error: " + e.getMessage());
            }
        }, ContextCompat.getMainExecutor(activity));
    }

    private void unbindCamera() {
        if (cameraProvider != null) {
            cameraProvider.unbindAll();
        }
        cameraLifecycle.pause();
    }

    private void analyze(@NonNull ImageProxy image) {
        Bitmap raw = null;
        Bitmap upright = null;
        try {
            PoseDetector currentDetector = detector;
            if (!running || currentDetector == null) {
                return;
            }
            raw = image.toBitmap();
            Matrix matrix = new Matrix();
            matrix.postRotate(image.getImageInfo().getRotationDegrees());
            if (mirror) {
                // Mirror the front camera so the preview behaves like a mirror.
                matrix.postScale(-1f, 1f);
            }
            upright = Bitmap.createBitmap(raw, 0, 0, raw.getWidth(), raw.getHeight(), matrix, true);
            Pose pose = Tasks.await(currentDetector.process(InputImage.fromBitmap(upright, 0)));

            final int width = upright.getWidth();
            final int height = upright.getHeight();
            final float[] points = new float[LANDMARK_COUNT * 3];
            for (PoseLandmark landmark : pose.getAllPoseLandmarks()) {
                int index = landmark.getLandmarkType();
                if (index < 0 || index >= LANDMARK_COUNT) {
                    continue;
                }
                PointF position = landmark.getPosition();
                points[index * 3] = position.x / height;
                points[index * 3 + 1] = position.y / height;
                points[index * 3 + 2] = landmark.getInFrameLikelihood();
            }

            byte[] previewBytes = null;
            int previewWidth = 0;
            if (sendPreview) {
                previewWidth = Math.max(1, Math.round(width * (float) PREVIEW_HEIGHT / height));
                Bitmap small = Bitmap.createScaledBitmap(upright, previewWidth, PREVIEW_HEIGHT, true);
                ByteBuffer buffer = ByteBuffer.allocate(previewWidth * PREVIEW_HEIGHT * 4);
                small.copyPixelsToBuffer(buffer); // ARGB_8888 is stored as RGBA bytes.
                previewBytes = buffer.array();
                if (small != upright) {
                    small.recycle();
                }
            }

            final byte[] rgba = previewBytes;
            final int rgbaWidth = previewWidth;
            runOnRenderThread(() -> {
                if (!running) {
                    return;
                }
                if (rgba != null) {
                    emitSignal("preview_frame", rgba, Integer.valueOf(rgbaWidth), Integer.valueOf(PREVIEW_HEIGHT));
                }
                emitSignal("pose_frame", points, Integer.valueOf(width), Integer.valueOf(height));
            });
        } catch (Exception e) {
            Log.w(TAG, "Pose analysis failed", e);
        } finally {
            if (upright != null && upright != raw) {
                upright.recycle();
            }
            if (raw != null) {
                raw.recycle();
            }
            image.close();
        }
    }

    private void emitStatus(String status) {
        runOnRenderThread(() -> emitSignal("camera_status", status));
    }

    /** Lifecycle owned by the plugin so the camera does not depend on Godot's activity type. */
    private static final class CameraLifecycle implements LifecycleOwner {
        private final LifecycleRegistry registry = new LifecycleRegistry(this);

        void resume() {
            if (registry.getCurrentState() != Lifecycle.State.DESTROYED) {
                registry.setCurrentState(Lifecycle.State.RESUMED);
            }
        }

        void pause() {
            Lifecycle.State state = registry.getCurrentState();
            if (state.isAtLeast(Lifecycle.State.STARTED)) {
                registry.setCurrentState(Lifecycle.State.CREATED);
            }
        }

        void destroy() {
            Lifecycle.State state = registry.getCurrentState();
            if (state != Lifecycle.State.INITIALIZED && state != Lifecycle.State.DESTROYED) {
                registry.setCurrentState(Lifecycle.State.DESTROYED);
            }
        }

        @NonNull
        @Override
        public Lifecycle getLifecycle() {
            return registry;
        }
    }
}
