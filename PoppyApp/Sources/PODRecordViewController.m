//
//  PODRecordViewController.m
//  Poppy Dome
//
//  Created by Dominik Wagner on 16.12.13.
//  Copyright (c) 2013 Dominik Wagner. All rights reserved.
//

#define ENABLE_DEBUG_VIEW_RAW

#import "PODRecordViewController.h"
#import "TCMCaptureManager.h"
#import <GLKit/GLKit.h>
#import <CoreImage/CoreImage.h>
#import <AVFoundation/AVFoundation.h>
#import "RBVolumeButtons.h"
#import "PODFilterFactory.h"
#import "PODCaptureControlsView.h"
#import "PODDeviceSettingsManager.h"
#import "PODAssetsManager.h"

#ifdef ENABLE_DEBUG_VIEW_RAW
#import "PODTestFilterChainViewController.h"
#endif

// comment this in to save the raw image as well
#define SAVE_FULLSIZE_IMAGE

@interface PODRecordViewController () <AVCaptureVideoDataOutputSampleBufferDelegate, PODCaptureControlsViewDelegate, AVCaptureFileOutputRecordingDelegate>

@property (strong, nonatomic) IBOutlet UIImageView *savingIconImageView;
@property (strong, nonatomic) IBOutlet UILabel *recordingTimeLabel;

@property (strong, nonatomic) NSMutableArray *reusableFocusViews;

@property (nonatomic, strong) GLKView *GLKView;
@property (nonatomic, strong) CIContext *CIContext;
@property (nonatomic, strong) CIContext *CIContextForSaving;
@property (nonatomic, strong) EAGLContext *EAGLContext;
@property (nonatomic, strong) EAGLContext *EAGLContextForSaving;

@property (nonatomic, strong) dispatch_queue_t outputQueue;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;

@property (nonatomic, strong) RBVolumeButtons *buttonStealer;

@property (nonatomic) BOOL shouldSaveNextImage;

@property (nonatomic) BOOL isRecordingVideo;
@property (nonatomic) BOOL ignoreNextPlusButtonPress;
@property (nonatomic) BOOL ignoreNextMinusButtonPress;

@property (nonatomic, strong) ALAssetsGroup *poppyGroup;
@property (nonatomic, strong) ALAssetsGroup *poppyRawGroup;

@property (nonatomic, strong) NSMutableDictionary *settingsAdjustments;
@property (nonatomic, strong) NSString *adjustmentKey;

@property (nonatomic) PODCaptureControlMode currentCaptureControlMode;
@property (nonatomic,strong) PODDeviceSettings *currentDeviceSettings;

@property (nonatomic, strong) PODCaptureControlsView *controlsView;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *simplePreviewLayer;

@property (nonatomic) BOOL simplePreview;
@property (nonatomic, strong) AVCaptureMovieFileOutput *movieFileOutput;

@property (nonatomic,readonly) BOOL isSaving;
@property (nonatomic) NSInteger savingImagesReferenceCount;
@property (nonatomic) NSInteger savingVideoReferenceCount;
@property (nonatomic) NSInteger currentRecordingSeconds;

// only for direct recording path
@property (nonatomic) NSTimer *updateRecordingSecondsTimer;
@property (nonatomic) NSDate *recordingStartDate;

@end

@implementation PODRecordViewController


- (UIImageView *)reusableFocusView {
    if(!self.reusableFocusViews){
        self.reusableFocusViews =[[NSMutableArray alloc] init];
    }
	UIImageView *result = nil;
	if (self.reusableFocusViews.count > 0) {
		result = self.reusableFocusViews.lastObject;
		[self.reusableFocusViews removeLastObject];
	}
	else {
		result = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"focus"]];
	}
	return result;
}

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
		[TCMCaptureManager captureManager]; // make sure it exists
		self.settingsAdjustments = [NSMutableDictionary new];
    }
    return self;
}

- (void)setSimplePreview:(BOOL)aSimplePreview {
	if (_simplePreview != aSimplePreview) {
		_simplePreview = aSimplePreview;
	}
	[self adjustToSimplePreviewSettings];
}

- (void)adjustToSimplePreviewSettings {
	TCMCaptureManager *captureManager = [TCMCaptureManager captureManager];
	
	BOOL needsVideoOutput = ((self.currentCaptureControlMode == kPODCaptureControlModeVideo) || !_simplePreview) && !(self.currentDeviceSettings.cameraSettings.directVideoCapture);
	
	if (needsVideoOutput) {
		if (!self.videoOutput) {
			self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
			[self.videoOutput setSampleBufferDelegate:self queue:self.outputQueue];
			[captureManager enqueueBlockToSessionQueue:^{
				[captureManager.captureSession beginConfiguration];
				[captureManager.captureSession addOutput:self.videoOutput];
				for (AVCaptureConnection *connection in self.videoOutput.connections) {
					if (connection.supportsVideoOrientation) {
						connection.videoOrientation = AVCaptureVideoOrientationLandscapeLeft;
					}
				}
				[captureManager.captureSession commitConfiguration];
			}];
		}
	} else {
		if (self.videoOutput) {
			[captureManager enqueueBlockToSessionQueue:^{
				[captureManager.captureSession beginConfiguration];
				[[captureManager captureSession] removeOutput:self.videoOutput];
				[captureManager.captureSession commitConfiguration];
			}];
		}
		self.videoOutput = nil;
	}
	
	if (_simplePreview) {
		if (!self.simplePreviewLayer) {
			// add
			self.simplePreviewLayer = ({
				AVCaptureVideoPreviewLayer *layer = [AVCaptureVideoPreviewLayer layerWithSession:[captureManager captureSession]];
				CALayer *layerBelow = self.GLKView.layer;
				layer.transform = CATransform3DMakeAffineTransform(CGAffineTransformMakeRotation(M_PI_2));
				layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
				layer.frame = layerBelow.bounds;
				[layerBelow.superlayer insertSublayer:layer above:layerBelow];
				layer;
			});
		}
	} else {
		if (self.simplePreviewLayer) {
			[self.simplePreviewLayer removeFromSuperlayer];
			self.simplePreviewLayer = nil;
		}
	}
	[self updateSimplePreviewFrame];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
	
	self.savingIconImageView.alpha = 0.0;
	self.currentRecordingSeconds = -1;

	[PODDeviceSettingsManager deviceSettingsManager];
    // Do any additional setup after loading the view from its nib.
	self.EAGLContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    
	GLKView *glkitView = [[GLKView alloc] initWithFrame:self.view.bounds context:self.EAGLContext];
    
	UIView *view = self.view;
	[view insertSubview:glkitView atIndex:0];
	view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	self.CIContext = [CIContext contextWithEAGLContext:self.EAGLContext];
	self.GLKView = glkitView;
	
	self.EAGLContextForSaving = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2 sharegroup:self.EAGLContext.sharegroup];
    
	self.CIContextForSaving = [CIContext contextWithEAGLContext:self.EAGLContextForSaving];
	
	self.outputQueue = dispatch_queue_create("display queue", DISPATCH_QUEUE_SERIAL);
	
	self.buttonStealer = [[RBVolumeButtons alloc] init];
	
	__weak __typeof__(self) weakSelf = self;
	self.buttonStealer.upBlock = ^{
		[weakSelf plusVolumeButtonPressedAction];
	};
	self.buttonStealer.downBlock = ^{
		[weakSelf minusVolumeButtonPressedAction];
	};

	// get poppy group for saving
	[[PODAssetsManager assetsManager] ensuredAssetsAlbumNamed:@"Poppy" completion:^(ALAssetsGroup *group, NSError *anError) {
		if (group) {
			self.poppyGroup = group;
		}
	}];

	// get poppy raw group for saving
    /*
	[[PODAssetsManager assetsManager] ensuredAssetsAlbumNamed:@"Poppy Raw" completion:^(ALAssetsGroup *group, NSError *anError) {
		if (group) {
			self.poppyRawGroup = group;
		}
	}];
     */
	// setup the gesture recognizers
	{
		
		UITapGestureRecognizer *tapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(singleTapAction:)];
		tapRecognizer.numberOfTapsRequired = 1;
		[self.view addGestureRecognizer:tapRecognizer];

		UITapGestureRecognizer *doubleTapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTapAction:)];
		doubleTapRecognizer.numberOfTapsRequired = 2;
		[self.view addGestureRecognizer:doubleTapRecognizer];

		UIPanGestureRecognizer *panRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panAction:)];
		[self.view addGestureRecognizer:panRecognizer];
	}
	
	// setup the regular UI
	self.controlsView = ({
        PODCaptureControlsView *controlsView;
        if(self.forCalibration){
            controlsView = [PODCaptureControlsView captureControlsForCalibrationView:self.view];
        } else {
            controlsView = [PODCaptureControlsView captureControlsForView:self.view];
        }
		
		[self.view addSubview:controlsView];
		controlsView.delegate = self;
		controlsView;
	});
	
	// setup the basics
	// TODO: grab mode from user defaults
	self.simplePreview = YES;
	//	self.currentCaptureControlMode = kPODCaptureControlModePhoto;
}

// this always sets the mode and takes the appropriate configure action - check if things change before calling this outside of the init code
- (void)setCurrentCaptureControlMode:(PODCaptureControlMode)currentCaptureControlMode {
	_currentCaptureControlMode = currentCaptureControlMode;
	[self.controlsView setCurrentControlMode:currentCaptureControlMode];
	self.currentDeviceSettings = [[PODDeviceSettingsManager deviceSettingsManager] deviceSettingsForMode:currentCaptureControlMode == kPODCaptureControlModePhoto ? kPODDeviceSettingsModePhoto : kPODDeviceSettingsModeVideo];
	self.simplePreview = self.currentDeviceSettings.cameraSettings.simplePreview;
	[self adjustToCurrentDeviceSettings];
}

- (void)adjustToCurrentDeviceSettings {
	self.simplePreview = self.currentDeviceSettings.cameraSettings.simplePreview;
	[[TCMCaptureManager captureManager] setDesiredDeviceSettings:self.currentDeviceSettings];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)displayCIImage:(CIImage *)aCIImage {
	CGSize maxSize = self.view.bounds.size;
	// retina power
	maxSize.width *= 2.0;
	maxSize.height *= 2.0;
	CIImage *scaledImage = [PODFilterFactory scaleImage:aCIImage toFitInSize:maxSize downscaleOnly:YES];

	[EAGLContext setCurrentContext:self.EAGLContext];
	glClearColor(0.0, 0.0, 0.0, 0.0);
	glClear(GL_COLOR_BUFFER_BIT);
	CGRect sourceRect = scaledImage.extent;
	CGRect targetRect = self.GLKView.bounds;
	CGFloat scaleFactor = [self.GLKView contentScaleFactor];
	targetRect = CGRectApplyAffineTransform(targetRect, CGAffineTransformMakeScale(scaleFactor, scaleFactor));
	CGFloat desiredHeight = CGRectGetWidth(targetRect) / CGRectGetWidth(sourceRect) * CGRectGetHeight(sourceRect);
	targetRect = CGRectInset(targetRect,0,(desiredHeight - CGRectGetHeight(targetRect)) / -2.0);
	[self.CIContext drawImage:scaledImage inRect:targetRect fromRect:sourceRect];
	[self.GLKView setNeedsDisplay];
	//	[self grabImage];
}

- (void)setShowsSavingIcon:(BOOL)aShouldShow {
    NSLog(@"SHOULD SHOW? %@", aShouldShow ? @"YES" : @"NO");
	[UIView animateWithDuration:0.15 delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
		self.savingIconImageView.alpha = aShouldShow ? 1.0 : 0.0;
	} completion:^(BOOL finished) {
		if (aShouldShow && self.savingIconImageView.alpha > 0.0) {
			CABasicAnimation *pulseAnimation = [CABasicAnimation animation];
			pulseAnimation.duration = 0.4;
			pulseAnimation.autoreverses = YES;
			pulseAnimation.repeatCount = HUGE_VALF;
			pulseAnimation.fromValue = @1.0;
			pulseAnimation.toValue = @0.6;
			pulseAnimation.keyPath = @"opacity";
			pulseAnimation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];

			[self.savingIconImageView.layer addAnimation:pulseAnimation forKey:@"alphaPulse"];
		}
	}];
	[self.savingIconImageView.layer removeAnimationForKey:@"alphaPulse"];
}


- (void)showFocusAtPoint:(CGPoint)aPoint isLeft:(BOOL)aIsLeftFlag {
	UIImageView *focusView = [self reusableFocusView];
	
	focusView.center = aPoint;
	focusView.transform = CGAffineTransformTranslate(CGAffineTransformMakeScale(1.9, 1.9), (aIsLeftFlag ? -1 : 1) * 3,0);
	focusView.alpha = 0.0;
	[self.view insertSubview:focusView belowSubview:self.controlsView];
    [self.reusableFocusViews addObject:focusView];
	[UIView animateWithDuration:0.3 animations:^{
		focusView.alpha = 1.0;
		focusView.transform = CGAffineTransformIdentity;
	} completion:^(BOOL finished) {
		[UIView animateWithDuration:0.2 delay:0.8 options:0 animations:^{
			focusView.alpha = 0.0;
			focusView.transform = CGAffineTransformMakeScale(0.7, 0.7);
		} completion:^(BOOL finished) {
			[focusView removeFromSuperview];
		}];
	}];
	
}

- (void)setFocusAtTouchPoint:(CGPoint)aPoint {
	CGRect fullRect = self.view.bounds;
	if (self.simplePreviewLayer) {
		fullRect = self.simplePreviewLayer.frame;
	}
	
	CGPoint leftPoint = aPoint;
	CGPoint rightPoint = aPoint;
	CGRect leftRect = fullRect;
	leftRect.size.width /= 2;
	CGFloat width = CGRectGetWidth(leftRect);
	BOOL isLeft = NO;
	if (CGRectContainsPoint(leftRect, aPoint)) {
		rightPoint.x += width;
		isLeft = YES;
	} else {
		leftPoint.x -= width;
		isLeft = NO;
	}

	if (isLeft) {
		[self showFocusAtPoint:leftPoint isLeft:YES];
	} else {
		[self showFocusAtPoint:rightPoint isLeft:NO];
	}
	// normalized 0,0 is the center of the image x range is from -0.5 to 0.5
	CGPoint centerNormalizedPoint = CGPointMake(((leftPoint.x + leftRect.origin.x) - CGRectGetMidX(leftRect)) / width,
												((leftPoint.y + leftRect.origin.y) - CGRectGetMidY(leftRect)) / width);
	[[TCMCaptureManager captureManager] focusOnCenterNormalizedPoint:centerNormalizedPoint isLeft:isLeft];
}

- (BOOL)isSaving {
	BOOL result = (_savingImagesReferenceCount + _savingVideoReferenceCount > 0);
	return result;
}

// called after increasing the reference counts
- (void)updateSavingIconStateForShowing {
	if (!self.isSaving) {
		[self setShowsSavingIcon:YES];
	}
}

// called after decreasing the reference counts
- (void)updateSavingIconStateForHiding {
	if (!self.isSaving) {
		[self setShowsSavingIcon:NO];
	}
}

- (void)increaseSavingImagesReferenceCount {
	@synchronized (self) {
		if (_savingImagesReferenceCount == 0) {
			[self updateSavingIconStateForShowing];
		}
		_savingImagesReferenceCount++;
	}
}

- (void)decreaseSavingImagesReferenceCount {
	@synchronized (self) {
		_savingImagesReferenceCount--;
		if (_savingImagesReferenceCount == 0) {
			[self updateSavingIconStateForHiding];
		}
	}
}

- (void)increaseSavingVideoReferenceCount {
	@synchronized (self) {
		if (_savingVideoReferenceCount == 0) {
			// show UI
			[self updateSavingIconStateForShowing];
		}
		_savingVideoReferenceCount++;
	}
}

- (void)decreaseSavingVideoReferenceCount {
	@synchronized (self) {
		_savingVideoReferenceCount--;
		if (_savingVideoReferenceCount == 0) {
			[self updateSavingIconStateForHiding];
			// call cleanup if this is keeping the view controller from releasing
		}
	}
}

- (void)storeCIImage:(CIImage *)aCIImage {
	ALAssetsLibrary *library = [[PODAssetsManager assetsManager] assetsLibrary];
	CGFloat JPEGQuality = 0.90;
	if (aCIImage) {
		[self increaseSavingImagesReferenceCount];
        // save a copy to a file for the calibration system
        if(self.forCalibration) {
            CGImageRef cgImage = [self.CIContextForSaving createCGImage:aCIImage fromRect:[aCIImage extent]];
            if (cgImage) {
                
                UIImage *image = [UIImage imageWithCGImage:cgImage];
                // TODO: use image IO directly
                NSData *imageData = UIImageJPEGRepresentation(image, JPEGQuality);
                CFRelease(cgImage);
                NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
                NSString *documentsPath = [paths objectAtIndex:0]; //Get the docs directory
                NSString *filePath = [documentsPath stringByAppendingPathComponent:@"calibrationimage.jpg"]; //Add the file name
                [imageData writeToFile:filePath atomically:YES]; //Write the file
                NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                [defaults setObject:filePath forKey:@"calibrationImagePath"];
                [defaults synchronize];
            }
        }

#ifdef SAVE_FULLSIZE_IMAGE

		CGImageRef cgImage = [self.CIContextForSaving createCGImage:aCIImage fromRect:[aCIImage extent]];
		if (cgImage) {
			
			UIImage *image = [UIImage imageWithCGImage:cgImage];
			// TODO: use image IO directly
			NSData *imageData = UIImageJPEGRepresentation(image, JPEGQuality);
			CFRelease(cgImage);
			
			[library writeImageDataToSavedPhotosAlbum:imageData metadata:@{} completionBlock:^(NSURL *assetURL, NSError *error) {
				NSLog(@"%s wroteFile: %@ %@",__FUNCTION__,assetURL,error);
				if (self.poppyRawGroup && assetURL) {
					[[PODAssetsManager assetsManager] addAssetURL:assetURL toGroup:self.poppyRawGroup completion:NULL];
				}

				
#endif

				//{
					// TODO: put on a separate serial queue - so the EAGL context doesn't get used simultaniously for different images
					NSArray *filterChain = [PODFilterFactory filterChainWithSettings:self.currentDeviceSettings.filterChainSettings inputImage:aCIImage];
					CIImage *transformedImage = [filterChain.lastObject outputImage];
					
					CGImageRef cgImage = [self.CIContextForSaving createCGImage:transformedImage fromRect:transformedImage.extent];
					UIImage *otherImage = [UIImage imageWithCGImage:cgImage];
					NSData *otherImageData = UIImageJPEGRepresentation(otherImage, JPEGQuality);
					[library writeImageDataToSavedPhotosAlbum:otherImageData metadata:@{} completionBlock:^(NSURL *assetURL, NSError *error) {
						NSLog(@"%s wroteFile: %@ %@",__FUNCTION__,assetURL,error);
						CFRelease(cgImage);
						ALAssetsGroup *poppyGroup = self.poppyGroup;
						if (poppyGroup && assetURL) {
							[[PODAssetsManager assetsManager] addAssetURL:assetURL toGroup:poppyGroup completion:NULL];
						}
						[self decreaseSavingImagesReferenceCount];
					}];
				//}

#ifdef SAVE_FULLSIZE_IMAGE

			}];
			
		} else {
			[self decreaseSavingImagesReferenceCount];
		}

#endif

	}
}

- (void)storeJPEGImageData:(NSData *)aJPEGData {
	ALAssetsLibrary *library = [[PODAssetsManager assetsManager] assetsLibrary];
	CGFloat JPEGQuality = 0.90;
	if (aJPEGData) {
		[self increaseSavingImagesReferenceCount];


#ifdef SAVE_FULLSIZE_IMAGE

		
		[library writeImageDataToSavedPhotosAlbum:aJPEGData metadata:@{} completionBlock:^(NSURL *assetURL, NSError *error) {
			NSLog(@"%s wroteFile: %@ %@",__FUNCTION__,assetURL,error);
			if (self.poppyRawGroup && assetURL) {
				[[PODAssetsManager assetsManager] addAssetURL:assetURL toGroup:self.poppyRawGroup completion:NULL];
			}

#endif
			{
				// we potentially need to scale it down to fit into one texture
				CIImage *ciImage = nil;
				{
					CGSize maxSize = [PODFilterFactory maxOpenGLTextureSize];
					UIImage *image = [UIImage imageWithData:aJPEGData];
                    
					CGSize imageSize = image.size;
					if (imageSize.width > maxSize.width) {
						CGRect targetRect = CGRectZero;
						targetRect.size.width = maxSize.width;
						targetRect.size.height = round(imageSize.height / imageSize.width * maxSize.width);
						
						UIGraphicsBeginImageContext(targetRect.size);
						[image drawInRect:targetRect];
						UIImage *scaledImage = UIGraphicsGetImageFromCurrentImageContext();
						UIGraphicsEndImageContext();
						ciImage = [CIImage imageWithCGImage:scaledImage.CGImage];
					} else {
						ciImage = [CIImage imageWithData:aJPEGData];
						if (image.imageOrientation != UIImageOrientationUp) {
							// rotate the image
							CGFloat rotation = image.imageOrientation == UIImageOrientationDown ?
								TCMRadiansFromDegrees(180) :
								image.imageOrientation == UIImageOrientationLeft ?
								TCMRadiansFromDegrees(90) : TCMRadiansFromDegrees(270);
							CGAffineTransform transform = CGAffineTransformMakeRotation(rotation);
							CIImage *result = [CIFilter filterWithName:@"CIAffineTransform" keysAndValues:kCIInputImageKey, ciImage, kCIInputTransformKey, [NSValue valueWithCGAffineTransform:transform],nil].outputImage;
							ciImage = result;
						}
					}
				}
				// TODO: put on a separate serial queue - so the EAGL context doesn't get used simultaniously for different images
				NSArray *filterChain = [PODFilterFactory filterChainWithSettings:self.currentDeviceSettings.filterChainSettings inputImage:ciImage];
				CIImage *transformedImage = [filterChain.lastObject outputImage];
				CGImageRef cgImage = [self.CIContextForSaving createCGImage:transformedImage fromRect:transformedImage.extent];
				UIImage *otherImage = [UIImage imageWithCGImage:cgImage];
				NSData *otherImageData = UIImageJPEGRepresentation(otherImage, JPEGQuality);
				[library writeImageDataToSavedPhotosAlbum:otherImageData metadata:@{} completionBlock:^(NSURL *assetURL, NSError *error) {
					NSLog(@"%s wroteFile: %@ %@",__FUNCTION__,assetURL,error);
					CFRelease(cgImage);
					ALAssetsGroup *poppyGroup = self.poppyGroup;
					if (poppyGroup && assetURL) {
						[[PODAssetsManager assetsManager] addAssetURL:assetURL toGroup:poppyGroup completion:NULL];
					}
					[self decreaseSavingImagesReferenceCount];
				}];
			}
#ifdef SAVE_FULLSIZE_IMAGE

		}];

#endif
	}

}

- (void)updateRecordingSecondsDisplay {
	NSString *string = @"";
	NSInteger seconds = self.currentRecordingSeconds;
	if (seconds > 0) {
		string = [NSString stringWithFormat:@"🔴 %02ld:%02d", (long)(seconds / 60), (int)seconds % 60];
	}
	self.recordingTimeLabel.text = string;
}

- (void)setCurrentRecordingSeconds:(NSInteger)aCurrentRecordingSeconds {
	if (_currentRecordingSeconds != aCurrentRecordingSeconds) {
		_currentRecordingSeconds = aCurrentRecordingSeconds;
		[NSOperationQueue TCM_performBlockOnMainQueue:^{
			[self updateRecordingSecondsDisplay];
		} afterDelay:0.0];
	}
}

- (void)displaySampleBuffer:(CMSampleBufferRef)aSampleBufferRef {
	CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(aSampleBufferRef);
	CMTime sampleTime = CMSampleBufferGetPresentationTimeStamp(aSampleBufferRef);
	CVBufferRetain(imageBuffer);
	CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, aSampleBufferRef, kCMAttachmentMode_ShouldPropagate);
	CIImage *image = [CIImage imageWithCVPixelBuffer:imageBuffer options:CFBridgingRelease(attachments)];
	dispatch_async(dispatch_get_main_queue(), ^{
		// we could save the images inline without getting a new one from the still image capture - would be quicker - don't know if it has downsides yet, but currently I don't do it
		if (self.shouldSaveNextImage) {
			self.shouldSaveNextImage = NO;
			[self storeCIImage:image];
		}
		
		CIImage *imageToDisplay = image;
		NSArray *filterChain = [PODFilterFactory filterChainWithSettings:self.currentDeviceSettings.filterChainSettings inputImage:image];
		
		imageToDisplay = [filterChain.lastObject outputImage];

		if (!self.currentDeviceSettings.cameraSettings.simplePreview) {
			[self displayCIImage:imageToDisplay];
		}

		// dispatch to recording
		if (self.isRecordingVideo) {
			TCMCaptureManager *captureManager = [TCMCaptureManager captureManager];
			
			CMTime startTime = captureManager.currentAssetWriterStartTime;
			if (CMTIME_IS_VALID(startTime)) {
				NSInteger seconds = round(CMTimeGetSeconds(CMTimeSubtract(sampleTime, startTime)));
				self.currentRecordingSeconds = MAX(0,seconds);
			}
			
			[captureManager enqueueBlockToWriterQueue:^{
				
				CVPixelBufferRef pixelBuffer = [captureManager createPixelBufferFromOutputPoolAtTime:sampleTime];
				if (pixelBuffer) {
					// scale the image to fit in the resolution of the buffer
					CIImage *scaledImage = [PODFilterFactory scaleImage:imageToDisplay toFitInSize:self.currentDeviceSettings.cameraSettings.outputResolution downscaleOnly:NO];
					
					CVPixelBufferLockBaseAddress( pixelBuffer, 0 );
					[self.CIContextForSaving render:scaledImage toCVPixelBuffer:pixelBuffer];
					CVPixelBufferUnlockBaseAddress( pixelBuffer, 0 );
			
					
					if (![captureManager writerEncodePixelBuffer:pixelBuffer sampleTime:sampleTime]) {
						NSLog(@"%s error writing frame: %ld %@",__FUNCTION__,(long)[captureManager assetWriter].status, [captureManager assetWriter].error);
					}
					CVBufferRelease(pixelBuffer);
				}
			}];
		}
		CVPixelBufferRelease(imageBuffer);
	});
}

- (void)saveCurrentFilterSettings {
	/*
	NSMutableDictionary *filterSettings = [NSMutableDictionary new];
	[[self currentFilterSettings] enumerateKeysAndObjectsUsingBlock:^(id key, id object, BOOL *stop) {
		if (![key isEqual:@"panTemp"]) {
			id value = object;
			if ([key isEqualToString:kPODFilterLeftRightCropSizeKey]) {
				value = NSStringFromCGSize([object CGSizeValue]);
			} else if ([key isEqualToString:kPODFilterCenterKey]) {
				value = NSStringFromCGPoint([object CGPointValue]);
			}
			filterSettings[key] = value;
		}
	}];
	NSData *filterJSON = [NSJSONSerialization dataWithJSONObject:filterSettings options:NSJSONWritingPrettyPrinted error:nil];
	NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
	NSDateFormatter *dateFormatter = [NSDateFormatter new];
	dateFormatter.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
	path = [path stringByAppendingPathComponent:[NSString stringWithFormat:@"Settings_%@.json",[dateFormatter stringFromDate:[NSDate date]]]];
	[filterJSON writeToFile:path options:0 error:nil];
	 */
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
	[self displaySampleBuffer:sampleBuffer];
}

- (void)grabImage {
	AVCaptureStillImageOutput *output = [[TCMCaptureManager captureManager] stillImageOutput];
	
	[output captureStillImageAsynchronouslyFromConnection:output.connections.firstObject completionHandler:^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
		if (self.currentDeviceSettings.cameraSettings.jpegStillCapture) {
			NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
			[self storeJPEGImageData:imageData];
		} else {
			CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(imageDataSampleBuffer);
			CIImage *image = [CIImage imageWithCVPixelBuffer:imageBuffer];
			CIFilter *filter = [CIFilter filterWithName:@"CIAffineTransform"];
			CGAffineTransform transform = CGAffineTransformMakeRotation(M_PI);
			[filter setValue:[NSValue valueWithCGAffineTransform:transform] forKey:kCIInputTransformKey];
			[filter setValue:image forKey:kCIInputImageKey];
			CGRect extent = filter.outputImage.extent;
			filter = [CIFilter filterWithName:@"CIAffineTransform" keysAndValues:kCIInputImageKey,filter.outputImage,kCIInputTransformKey, [NSValue valueWithCGAffineTransform:CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)], nil];
			[self storeCIImage:[filter outputImage]];
		}
	}];
	
//	[output captureStillImageAsynchronouslyFromConnection:output.connections.firstObject completionHandler:^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
//		CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(imageDataSampleBuffer);
//		CIImage *image = [CIImage imageWithCVPixelBuffer:imageBuffer];
//		CIFilter *filter = [CIFilter filterWithName:@"CIAffineTransform"];
//		CGAffineTransform transform = CGAffineTransformMakeRotation(M_PI);
//		[filter setValue:[NSValue valueWithCGAffineTransform:transform] forKey:kCIInputTransformKey];
//		[filter setValue:image forKey:kCIInputImageKey];
//		CGRect extent = filter.outputImage.extent;
//		filter = [CIFilter filterWithName:@"CIAffineTransform" keysAndValues:kCIInputImageKey,filter.outputImage,kCIInputTransformKey, [NSValue valueWithCGAffineTransform:CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)], nil];
//		[self storeCIImage:[filter outputImage]];
//	}];
}

- (void)captureSessionDidStop {
	NSLog(@"%s successfully stopped the capture session",__FUNCTION__);
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	[self.buttonStealer stopStealingVolumeButtonEvents];
	
	[[TCMCaptureManager captureManager] enqueueBlockToSessionQueue:^{
		[[TCMCaptureManager captureManager].captureSession removeOutput:self.videoOutput];
		[self.videoOutput setSampleBufferDelegate:nil queue:NULL];
		self.videoOutput = nil;
	}];
	[[TCMCaptureManager captureManager] stopSession];
	// make sure we live long enough to recieve all delegate methods
	[[TCMCaptureManager captureManager] enqueueBlockToSessionQueue:^{
		[self captureSessionDidStop];
	}];
}

- (void)updateSimplePreviewFrame {
	CALayer *layer = self.simplePreviewLayer;
	if (layer) {
		// scale around the center anchorpoint of the layer, but set the frame, not just scale, so the bounds and size of video texture also change
		layer.frame = layer.superlayer.bounds;
		CGFloat scale = self.currentDeviceSettings.cameraSettings.simplePreviewZoom;
		CATransform3D layerTransform = layer.transform;
		layer.transform = CATransform3DConcat(layerTransform, CATransform3DMakeAffineTransform(CGAffineTransformMakeScale(scale,scale)));
		CGRect newFrame = layer.frame;
		layer.transform = layerTransform;
		layer.frame = newFrame;
	}
	
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self updateSimplePreviewFrame];
	if (self.GLKView) {
		self.GLKView.frame = self.view.bounds;
	}
	[[TCMCaptureManager captureManager] startSession];
	[self setCurrentCaptureControlMode:self.controlsView.currentControlMode];
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	[self.buttonStealer startStealingVolumeButtonEvents];
}

- (void)panAction:(UIPanGestureRecognizer *)panRecognizer {
}

- (void)singleTapAction:(UITapGestureRecognizer *)tapRecognizer {
	[self setFocusAtTouchPoint:[tapRecognizer locationInView:self.view]];
}

- (void)doubleTapAction:(UITapGestureRecognizer *)tapRecognizer {
}

- (void)dealloc {
	self.buttonStealer.upBlock = nil;
	self.buttonStealer.downBlock = nil;
	NSLog(@"%s",__FUNCTION__);
}


- (void)startRecordingToVideoFile {
	if (!self.isRecordingVideo) {
		if (self.currentDeviceSettings.cameraSettings.directVideoCapture) {
			AVCaptureMovieFileOutput *movieFileOutput = [[AVCaptureMovieFileOutput alloc] init];
			self.movieFileOutput = movieFileOutput;
			TCMCaptureManager *captureManager = [TCMCaptureManager captureManager];
			[captureManager enqueueBlockToSessionQueue:^{
				[captureManager.captureSession beginConfiguration];
				[captureManager.captureSession addOutput:movieFileOutput];
				for (AVCaptureConnection *connection in self.movieFileOutput.connections) {
					if (connection.supportsVideoOrientation) {
						connection.videoOrientation = AVCaptureVideoOrientationLandscapeLeft;
					}
				}
				AVCaptureDevice *microphone = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
				AVCaptureDeviceInput *audioInput = [AVCaptureDeviceInput deviceInputWithDevice:microphone error:nil];
				[captureManager.captureSession addInput:audioInput];
				[captureManager.captureSession commitConfiguration];
				[NSOperationQueue TCM_performBlockOnMainQueue:^{
					[movieFileOutput startRecordingToOutputFileURL:[TCMCaptureManager tempMovieURL] recordingDelegate:self];
				} afterDelay:1.0];
			}];
		} else {
			self.ignoreNextPlusButtonPress = YES;
			self.ignoreNextMinusButtonPress = YES;
			[[TCMCaptureManager captureManager] prepareVideoAssetWriter];
		}
		self.isRecordingVideo = YES;
		self.controlsView.isRecording = YES;
	}
}

- (void)moveRecordedVideoToAssetLibrary:(NSURL *)aVideoURL {
	ALAssetsLibrary *library = [[PODAssetsManager assetsManager] assetsLibrary];
	[library writeVideoAtPathToSavedPhotosAlbum:aVideoURL completionBlock:^(NSURL *assetURL, NSError *error) {
		if (!error) {
			if (assetURL) {
				ALAssetsGroup *poppyGroup = self.poppyGroup;
				if (poppyGroup) {
					[[PODAssetsManager assetsManager] addAssetURL:assetURL toGroup:poppyGroup completion:NULL];
				}
				// remove our file
				[[NSFileManager defaultManager] removeItemAtURL:aVideoURL
														  error:nil];
			}
		}
		[NSOperationQueue TCM_performBlockOnMainQueue:^{
			[self decreaseSavingVideoReferenceCount];
            
		} afterDelay:0.0];
	}];
}

- (void)stopRecordingToVideoFile {
	if (self.isRecordingVideo) {
		self.isRecordingVideo = NO;
		self.controlsView.isRecording = NO;
		self.currentRecordingSeconds = -1;
		[self increaseSavingVideoReferenceCount];
		if (self.currentDeviceSettings.cameraSettings.directVideoCapture) {
			[self.movieFileOutput stopRecording];
		} else {
			[[TCMCaptureManager captureManager] finishWriterWithCompletionHandler:^(AVAssetWriter *aWriter) {
				NSLog(@"%s finished writing: %@",__FUNCTION__,aWriter);
				// TODO: transfer to video library
				NSURL *fileURL = aWriter.outputURL;
				[self moveRecordedVideoToAssetLibrary:fileURL];
			}];
		}
	}
}

- (void)updateRecordingSecondsViaTimer {
	self.currentRecordingSeconds = round(ABS([self.recordingStartDate timeIntervalSinceNow]));
}

- (void)startRecordingTimer {
	[self.updateRecordingSecondsTimer invalidate];
	self.updateRecordingSecondsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(updateRecordingSecondsViaTimer) userInfo:nil repeats:YES];
	self.recordingStartDate = [NSDate date];
	[self updateRecordingSecondsViaTimer];
}

- (void)stopRecordingTimer {
	[self.updateRecordingSecondsTimer invalidate];
	self.updateRecordingSecondsTimer = nil;
	self.currentRecordingSeconds = -1;
}

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didStartRecordingToOutputFileAtURL:(NSURL *)fileURL fromConnections:(NSArray *)connections {
	[self startRecordingTimer];
}

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray *)connections error:(NSError *)error {
	[self stopRecordingTimer];
	if (!error) {
		[self moveRecordedVideoToAssetLibrary:outputFileURL];
		TCMCaptureManager *captureManager = [TCMCaptureManager captureManager];
		AVCaptureMovieFileOutput *movieOutput = self.movieFileOutput;
	
		self.movieFileOutput = nil;
		[captureManager enqueueBlockToSessionQueue:^{
			[captureManager.captureSession beginConfiguration];
			[captureManager.captureSession removeOutput:movieOutput];
			AVCaptureDeviceInput *audioInput = nil;
			for (AVCaptureDeviceInput *input in [captureManager.captureSession inputs]) {
				if ([input.device hasMediaType:AVMediaTypeAudio]) {
					audioInput = input;
					break;
				}
			}
			if (audioInput) {
				[captureManager.captureSession removeInput:audioInput];
			}
			[captureManager.captureSession commitConfiguration];
		}];
	}
}


- (void)shutterPressedAction {
	if (self.controlsView.currentControlMode == kPODCaptureControlModePhoto) {
		[self grabImage];
        if(self.forCalibration){
            [self dismissAction];
        }
	} else {
		// toggle video on or off depeding on the state
		if (!self.isRecordingVideo) {
			[self startRecordingToVideoFile];
		} else {
			[self stopRecordingToVideoFile];
		}
	}
}

- (void)dismissAction {
	[self dismissViewControllerAnimated:YES completion:nil];
}


#pragma mark - Capture control delegate methods

- (void)captureControlsViewDidPressHome:(PODCaptureControlsView *)aView {
	if (!self.isSaving) {
		[self dismissAction];
	}
}
- (void)captureControlsViewDidPressModeChange:(PODCaptureControlsView *)aView {
	if (self.controlsView.currentControlMode == kPODCaptureControlModePhoto) {
		if (self.isRecordingVideo) {
			[self stopRecordingToVideoFile];
		}
	}
	if (self.currentCaptureControlMode != self.controlsView.currentControlMode) {
		[self setCurrentCaptureControlMode:self.controlsView.currentControlMode];
	}
}
- (void)captureControlsViewDidTouchDownShutter:(PODCaptureControlsView *)aView {
	// nothing for now - might be useful if we decide to add a burst mode
}
- (void)captureControlsViewDidTouchUpShutter:(PODCaptureControlsView *)aView {
	[self shutterPressedAction];
}


#pragma mark -

- (void)minusVolumeButtonPressedAction {
	if (self.ignoreNextMinusButtonPress) {
		// starting the recording session triggers the plus button action due to volume changes so it seems
		self.ignoreNextMinusButtonPress = NO;
		return;
	}
	if (!self.isSaving) {
#ifdef ENABLE_DEBUG_VIEW_RAW
		[self presentViewController:[[PODTestFilterChainViewController alloc] initWithNibName:nil bundle:nil] animated:NO completion:NULL];
#else
		[self dismissAction];
#endif
	}
}

- (void)plusVolumeButtonPressedAction {
	if (self.ignoreNextPlusButtonPress) {
		// starting the recording session triggers the plus button action due to volume changes so it seems
		self.ignoreNextPlusButtonPress = NO;
		return;
	}
	[self shutterPressedAction];
}


#pragma mark -


- (NSUInteger)supportedInterfaceOrientations {
	return UIInterfaceOrientationMaskLandscapeLeft;
}

- (BOOL)prefersStatusBarHidden {
	return YES;
}


@end