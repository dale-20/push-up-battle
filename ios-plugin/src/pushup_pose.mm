// PushUpPose for iOS: on-device pose tracking for Push-Up Battle.
//
// iOS counterpart of android-plugin/ (CameraX + ML Kit). Owns one AVCapture
// session and runs Apple's Vision body-pose detector on every frame. Godot
// receives the same signals as on Android, so scripts/pose_provider.gd works
// unchanged:
//   pose_frame(points: PackedFloat32Array, width: int, height: int)
//       33 landmarks in ML Kit order as (x, y, confidence); x and y are
//       divided by the upright image height, y pointing down. Landmarks
//       Vision does not track (fingers, heels, ...) stay zero.
//   preview_frame(rgba: PackedByteArray, width: int, height: int)
//   camera_status(status: String)   "started", "permission_missing", "error: ..."
// Frames are never written to storage or sent anywhere.

#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <algorithm>
#include <cstring>

static const int kLandmarkCount = 33;
static const int kPreviewHeight = 240;

typedef void (^PUPPoseBlock)(NSData *points, int width, int height);
typedef void (^PUPPreviewBlock)(NSData *rgba, int width, int height);
typedef void (^PUPStatusBlock)(NSString *status);

// --- Camera + Vision (Objective-C) -------------------------------------------------

@interface PUPCamera : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic, copy) PUPPoseBlock onPose;
@property(nonatomic, copy) PUPPreviewBlock onPreview;
@property(nonatomic, copy) PUPStatusBlock onStatus;
@property(atomic) BOOL sendPreview;
@property(atomic) BOOL active;
- (void)startWithFrontCamera:(BOOL)front;
- (void)stop;
@end

@implementation PUPCamera {
	dispatch_queue_t _sessionQueue;
	dispatch_queue_t _videoQueue;
	AVCaptureSession *_session;
	VNDetectHumanBodyPoseRequest *_request;
	NSDictionary<VNHumanBodyPoseObservationJointName, NSNumber *> *_joints;
}

- (instancetype)init {
	if ((self = [super init])) {
		_sessionQueue = dispatch_queue_create("pushuppose.session", DISPATCH_QUEUE_SERIAL);
		_videoQueue = dispatch_queue_create("pushuppose.video", DISPATCH_QUEUE_SERIAL);
		_request = [[VNDetectHumanBodyPoseRequest alloc] init];
		// Vision joint -> ML Kit landmark index (the layout pose_provider.gd reads).
		_joints = @{
			VNHumanBodyPoseObservationJointNameNose : @0,
			VNHumanBodyPoseObservationJointNameLeftEye : @2,
			VNHumanBodyPoseObservationJointNameRightEye : @5,
			VNHumanBodyPoseObservationJointNameLeftEar : @7,
			VNHumanBodyPoseObservationJointNameRightEar : @8,
			VNHumanBodyPoseObservationJointNameLeftShoulder : @11,
			VNHumanBodyPoseObservationJointNameRightShoulder : @12,
			VNHumanBodyPoseObservationJointNameLeftElbow : @13,
			VNHumanBodyPoseObservationJointNameRightElbow : @14,
			VNHumanBodyPoseObservationJointNameLeftWrist : @15,
			VNHumanBodyPoseObservationJointNameRightWrist : @16,
			VNHumanBodyPoseObservationJointNameLeftHip : @23,
			VNHumanBodyPoseObservationJointNameRightHip : @24,
			VNHumanBodyPoseObservationJointNameLeftKnee : @25,
			VNHumanBodyPoseObservationJointNameRightKnee : @26,
			VNHumanBodyPoseObservationJointNameLeftAnkle : @27,
			VNHumanBodyPoseObservationJointNameRightAnkle : @28,
		};
	}
	return self;
}

- (void)emitStatus:(NSString *)status {
	PUPStatusBlock block = self.onStatus;
	if (block != nil) {
		block(status);
	}
}

- (void)startWithFrontCamera:(BOOL)front {
	self.active = YES;
	switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]) {
		case AVAuthorizationStatusAuthorized:
			[self configureWithFrontCamera:front];
			break;
		case AVAuthorizationStatusNotDetermined:
			[AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
									 completionHandler:^(BOOL granted) {
										 if (granted) {
											 [self configureWithFrontCamera:front];
										 } else {
											 [self emitStatus:@"permission_missing"];
										 }
									 }];
			break;
		default:
			[self emitStatus:@"permission_missing"];
			break;
	}
}

- (void)configureWithFrontCamera:(BOOL)front {
	dispatch_async(_sessionQueue, ^{
		if (!self.active) {
			return;
		}
		if (self->_session != nil) {
			if (!self->_session.isRunning) {
				[self->_session startRunning];
			}
			[self emitStatus:@"started"];
			return;
		}
		AVCaptureDevicePosition position = front ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
		AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
																	 mediaType:AVMediaTypeVideo
																	  position:position];
		if (device == nil) {
			device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
		}
		if (device == nil) {
			[self emitStatus:@"error: no camera found"];
			return;
		}
		NSError *error = nil;
		AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
		if (input == nil) {
			[self emitStatus:[NSString stringWithFormat:@"error: %@", error.localizedDescription]];
			return;
		}
		AVCaptureSession *session = [[AVCaptureSession alloc] init];
		[session beginConfiguration];
		if ([session canSetSessionPreset:AVCaptureSessionPreset640x480]) {
			session.sessionPreset = AVCaptureSessionPreset640x480;
		}
		AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
		output.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};
		output.alwaysDiscardsLateVideoFrames = YES;
		[output setSampleBufferDelegate:self queue:self->_videoQueue];
		if (![session canAddInput:input] || ![session canAddOutput:output]) {
			[session commitConfiguration];
			[self emitStatus:@"error: camera configuration failed"];
			return;
		}
		[session addInput:input];
		[session addOutput:output];
		// Deliver upright portrait frames (the app is portrait-only), mirrored for
		// the front camera like the Android build, so Vision sees an upright body.
		AVCaptureConnection *connection = [output connectionWithMediaType:AVMediaTypeVideo];
		if (@available(iOS 17.0, *)) {
			if ([connection isVideoRotationAngleSupported:90]) {
				connection.videoRotationAngle = 90;
			}
		} else if (connection.isVideoOrientationSupported) {
			connection.videoOrientation = AVCaptureVideoOrientationPortrait;
		}
		if (connection.isVideoMirroringSupported) {
			connection.automaticallyAdjustsVideoMirroring = NO;
			connection.videoMirrored = device.position == AVCaptureDevicePositionFront;
		}
		[session commitConfiguration];
		self->_session = session;
		[session startRunning];
		[self emitStatus:@"started"];
	});
}

- (void)stop {
	self.active = NO;
	dispatch_async(_sessionQueue, ^{
		[self->_session stopRunning];
		self->_session = nil;
	});
}

- (void)captureOutput:(AVCaptureOutput *)output
		didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
			   fromConnection:(AVCaptureConnection *)connection {
	if (!self.active) {
		return;
	}
	CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sampleBuffer);
	if (pixels == NULL) {
		return;
	}
	const int width = (int)CVPixelBufferGetWidth(pixels);
	const int height = (int)CVPixelBufferGetHeight(pixels);
	if (width <= 0 || height <= 0) {
		return;
	}

	NSMutableData *points = [NSMutableData dataWithLength:kLandmarkCount * 3 * sizeof(float)];
	float *p = (float *)points.mutableBytes;
	VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixels
																			  orientation:kCGImagePropertyOrientationUp
																				  options:@{}];
	NSError *error = nil;
	if ([handler performRequests:@[ _request ] error:&error]) {
		VNHumanBodyPoseObservation *body = (VNHumanBodyPoseObservation *)_request.results.firstObject;
		if (body != nil) {
			[_joints enumerateKeysAndObjectsUsingBlock:^(VNHumanBodyPoseObservationJointName name, NSNumber *index, BOOL *stop) {
				VNRecognizedPoint *point = [body recognizedPointForJointName:name error:nil];
				if (point == nil || point.confidence <= 0) {
					return;
				}
				const int i = index.intValue;
				// Vision: normalized, origin bottom-left. Godot: units of image height, y down.
				p[i * 3] = (float)(point.location.x * width / height);
				p[i * 3 + 1] = (float)(1.0 - point.location.y);
				p[i * 3 + 2] = point.confidence;
			}];
		}
	}

	if (self.sendPreview) {
		int previewWidth = 0;
		NSData *rgba = [self thumbnailFrom:pixels width:width height:height outWidth:&previewWidth];
		PUPPreviewBlock onPreview = self.onPreview;
		if (onPreview != nil) {
			onPreview(rgba, previewWidth, kPreviewHeight);
		}
	}
	PUPPoseBlock onPose = self.onPose;
	if (onPose != nil) {
		onPose(points, width, height);
	}
}

/// Nearest-neighbour downscale of a BGRA frame to a small RGBA thumbnail.
- (NSData *)thumbnailFrom:(CVPixelBufferRef)pixels width:(int)width height:(int)height outWidth:(int *)outWidth {
	const int th = kPreviewHeight;
	const int tw = std::max(1, (int)lround((double)width * th / height));
	NSMutableData *rgba = [NSMutableData dataWithLength:(NSUInteger)tw * th * 4];
	uint8_t *dst = (uint8_t *)rgba.mutableBytes;
	CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
	const uint8_t *src = (const uint8_t *)CVPixelBufferGetBaseAddress(pixels);
	const size_t stride = CVPixelBufferGetBytesPerRow(pixels);
	for (int y = 0; y < th; y++) {
		const uint8_t *row = src + stride * (size_t)(y * height / th);
		for (int x = 0; x < tw; x++) {
			const uint8_t *s = row + 4 * (size_t)(x * width / tw);
			uint8_t *d = dst + 4 * ((size_t)y * tw + x);
			d[0] = s[2];
			d[1] = s[1];
			d[2] = s[0];
			d[3] = 255;
		}
	}
	CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
	*outWidth = tw;
	return rgba;
}

@end

// --- Godot singleton -----------------------------------------------------------------

namespace godot {

class PushUpPose : public Object {
	GDCLASS(PushUpPose, Object);

	PUPCamera *camera = nil;
	bool running = false;

protected:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("start", "use_front_camera", "with_preview"), &PushUpPose::start);
		ClassDB::bind_method(D_METHOD("stop"), &PushUpPose::stop);
		ClassDB::bind_method(D_METHOD("isRunning"), &PushUpPose::is_running);
		ADD_SIGNAL(MethodInfo("pose_frame", PropertyInfo(Variant::PACKED_FLOAT32_ARRAY, "points"),
				PropertyInfo(Variant::INT, "width"), PropertyInfo(Variant::INT, "height")));
		ADD_SIGNAL(MethodInfo("preview_frame", PropertyInfo(Variant::PACKED_BYTE_ARRAY, "rgba"),
				PropertyInfo(Variant::INT, "width"), PropertyInfo(Variant::INT, "height")));
		ADD_SIGNAL(MethodInfo("camera_status", PropertyInfo(Variant::STRING, "status")));
	}

public:
	PushUpPose() {
		camera = [[PUPCamera alloc] init];
		// Frames arrive on a capture queue; signals are emitted on Godot's main
		// thread via call_deferred, looked up by ID in case the object is gone.
		const uint64_t instance_id = get_instance_id();
		camera.onPose = ^(NSData *data, int width, int height) {
			PackedFloat32Array points;
			points.resize((int64_t)(data.length / sizeof(float)));
			std::memcpy(points.ptrw(), data.bytes, data.length);
			Object *target = ObjectDB::get_instance(instance_id);
			if (target != nullptr) {
				target->call_deferred("emit_signal", "pose_frame", points, width, height);
			}
		};
		camera.onPreview = ^(NSData *data, int width, int height) {
			PackedByteArray rgba;
			rgba.resize((int64_t)data.length);
			std::memcpy(rgba.ptrw(), data.bytes, data.length);
			Object *target = ObjectDB::get_instance(instance_id);
			if (target != nullptr) {
				target->call_deferred("emit_signal", "preview_frame", rgba, width, height);
			}
		};
		camera.onStatus = ^(NSString *status) {
			String message = String::utf8(status.UTF8String);
			Object *target = ObjectDB::get_instance(instance_id);
			if (target != nullptr) {
				target->call_deferred("emit_signal", "camera_status", message);
			}
		};
	}

	~PushUpPose() {
		camera.onPose = nil;
		camera.onPreview = nil;
		camera.onStatus = nil;
		[camera stop];
		camera = nil;
	}

	/// Starts the camera and pose detection. Asks for camera access if needed;
	/// a refusal arrives later as camera_status("permission_missing").
	bool start(bool use_front_camera, bool with_preview) {
		camera.sendPreview = with_preview;
		running = true;
		[camera startWithFrontCamera:use_front_camera];
		return true;
	}

	void stop() {
		running = false;
		[camera stop];
	}

	bool is_running() const {
		return running;
	}
};

static PushUpPose *pushup_pose_singleton = nullptr;

static void initialize_pushup_pose(ModuleInitializationLevel level) {
	if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(PushUpPose);
	pushup_pose_singleton = memnew(PushUpPose);
	Engine::get_singleton()->register_singleton("PushUpPose", pushup_pose_singleton);
}

static void uninitialize_pushup_pose(ModuleInitializationLevel level) {
	if (level != MODULE_INITIALIZATION_LEVEL_SCENE || pushup_pose_singleton == nullptr) {
		return;
	}
	Engine::get_singleton()->unregister_singleton("PushUpPose");
	memdelete(pushup_pose_singleton);
	pushup_pose_singleton = nullptr;
}

} // namespace godot

extern "C" GDExtensionBool GDE_EXPORT pushup_pose_library_init(GDExtensionInterfaceGetProcAddress get_proc_address,
		GDExtensionClassLibraryPtr library, GDExtensionInitialization *initialization) {
	godot::GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
	init.register_initializer(godot::initialize_pushup_pose);
	init.register_terminator(godot::uninitialize_pushup_pose);
	init.set_minimum_library_initialization_level(godot::MODULE_INITIALIZATION_LEVEL_SCENE);
	return init.init();
}
