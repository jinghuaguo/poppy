//
//  WiggleViewController.m
//  wiggle_test
//
//  Created by Ethan Lowry on 2/3/14.
//  Copyright (c) 2014 Ethan Lowry. All rights reserved.
//

#import "WiggleViewController.h"
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>

@interface WiggleViewController ()
@property (nonatomic, strong) UIImageView *leftImgView;
@property (nonatomic, strong) UIImageView *rightImgView;
@property (nonatomic, strong) UIImageView *animatedView;
@property (nonatomic, strong) UIView *maskView;
@end

@implementation WiggleViewController

NSURL *fileURL;
UIImage *leftImg;
UIImage *rightImg;
float offset = 0.0;
MFMailComposeViewController *picker;
UIView *gifView;


-(void) makeAnimatedGifWithLeft: (UIImage *)imageL withRight: (UIImage *)imageR
{
    static NSUInteger const kFrameCount = 2;
    
    NSDictionary *fileProperties = @{
                                     (__bridge id)kCGImagePropertyGIFDictionary: @{
                                             (__bridge id)kCGImagePropertyGIFLoopCount: @0, // 0 means loop forever
                                             }
                                     };
    NSDictionary *frameProperties = @{
                                      (__bridge id)kCGImagePropertyGIFDictionary: @{
                                              (__bridge id)kCGImagePropertyGIFDelayTime: @.3f, // a float (not double!) in seconds, rounded to centiseconds in the GIF data
                                              }
                                      };
    
    NSURL *documentsDirectoryURL = [[NSFileManager defaultManager] URLForDirectory:NSDocumentDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    fileURL = [documentsDirectoryURL URLByAppendingPathComponent:@"animated.gif"];
    
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)fileURL, kUTTypeGIF, kFrameCount, NULL);
    CGImageDestinationSetProperties(destination, (__bridge CFDictionaryRef)fileProperties);
    
    @autoreleasepool {
        CGImageDestinationAddImage(destination, imageL.CGImage, (__bridge CFDictionaryRef)frameProperties);
    }
    @autoreleasepool {
        CGImageDestinationAddImage(destination, imageR.CGImage, (__bridge CFDictionaryRef)frameProperties);
    }
    
    if (!CGImageDestinationFinalize(destination)) {
        NSLog(@"failed to finalize image destination");
    }
    CFRelease(destination);
    
    //NSLog(@"url=%@", fileURL);
}



- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
        // Custom initialization
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
	// Do any additional setup after loading the view.
}

- (void)viewDidAppear:(BOOL)animated
{
    if(self.stereoImage) {
        [self splitImage:self.stereoImage];
        
        // set up the left and right images
        self.leftImgView = [[UIImageView alloc] initWithImage:leftImg];
        [self.leftImgView setFrame:self.view.frame];
        [self.leftImgView setContentMode:UIViewContentModeScaleAspectFill];
        self.rightImgView = [[UIImageView alloc] initWithImage:rightImg];
        [self.rightImgView setFrame:self.view.frame];
        [self.rightImgView setContentMode:UIViewContentModeScaleAspectFill];
        [self.view addSubview:self.leftImgView];
        [self.view addSubview:self.rightImgView];
        
        // mask out the parts of the background image that are cropped out of the foreground image
        self.maskView = [[UIView alloc] initWithFrame:CGRectMake(-self.view.frame.size.width, 0, self.view.frame.size.width, self.view.frame.size.height)];
        [self.maskView setBackgroundColor:[UIColor blackColor]];
        [self.view addSubview:self.maskView];
        
        // fake the appearance of an animated gif
        [self fadeInLeft];
        
        // add the slider
        CGRect frame = CGRectMake(60.0, 50.0, 200.0, 10.0);
        UISlider *slider = [[UISlider alloc] initWithFrame:frame];
        [slider addTarget:self action:@selector(sliderAction:) forControlEvents:UIControlEventValueChanged];
        [slider setBackgroundColor:[UIColor clearColor]];
        slider.minimumValue = -60.0;
        slider.maximumValue = 60.0;
        slider.continuous = YES;
        slider.value = 0.0;
        [self.view addSubview:slider];
        
        // add the save button
        CGRect saveButtonFrame = CGRectMake(40, self.view.frame.size.height - 70, 100, 50);
        UIView *saveShadowView = [[UIView alloc] initWithFrame:saveButtonFrame];
        [saveShadowView setBackgroundColor:[UIColor blackColor]];
        [saveShadowView setAlpha:0.3];
        UIButton *saveButton = [[UIButton alloc] initWithFrame:saveButtonFrame];
        [saveButton addTarget:self action:@selector(postGif) forControlEvents:UIControlEventTouchUpInside];
        [saveButton setTitle:@"Share" forState:UIControlStateNormal];
        [self.view addSubview:saveShadowView];
        [self.view addSubview:saveButton];
        
        // add the cancel button
        CGRect cancelButtonFrame = CGRectMake(180, self.view.frame.size.height - 70, 100, 50);
        UIView *cancelShadowView = [[UIView alloc] initWithFrame:cancelButtonFrame];
        [cancelShadowView setBackgroundColor:[UIColor blackColor]];
        [cancelShadowView setAlpha:0.3];
        UIButton *cancelButton = [[UIButton alloc] initWithFrame:cancelButtonFrame];
        [cancelButton addTarget:self action:@selector(dismissAction) forControlEvents:UIControlEventTouchUpInside];
        [cancelButton setTitle:@"Cancel" forState:UIControlStateNormal];
        [self.view addSubview:cancelShadowView];
        [self.view addSubview:cancelButton];
    }
}

-(void)dismissAction
{
    [self dismissViewControllerAnimated:YES completion:^{}];
}

/*
-(void)saveGif
{
    gifView = [[UIView alloc] initWithFrame:self.view.frame];
    float scale = 4.0;
    
    //crop -- currently assumes the image in aspect fill is full width
    float cropAmount = offset * leftImg.size.width/320 - offset/2;
    NSLog(@"OFFSET: %f", offset);
    NSLog(@"WIDTH: %f, HEIGHT: %f", leftImg.size.width, leftImg.size.height);
    NSLog(@"CROP AMT:%f", cropAmount);
    
    //crop the left image with scale
    CGRect leftCrop;
    if (cropAmount > 0) {
        leftCrop = CGRectMake(0, 0, leftImg.size.width - cropAmount, leftImg.size.height);
    } else {
        leftCrop = CGRectMake(-cropAmount, 0, leftImg.size.width + cropAmount, leftImg.size.height);
    }
    CGImageRef leftImageRef = CGImageCreateWithImageInRect([leftImg CGImage], leftCrop);
    UIImage *leftForAnimation = [UIImage imageWithCGImage:leftImageRef scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(leftImageRef);
    
    //crop the right image with scale
    CGRect rightCrop;
    if (cropAmount > 0) {
        rightCrop = CGRectMake(cropAmount, 0, rightImg.size.width - cropAmount, rightImg.size.height);
    } else {
        rightCrop = CGRectMake(0, 0, rightImg.size.width + cropAmount, rightImg.size.height);
    }
    CGImageRef rightImageRef = CGImageCreateWithImageInRect([rightImg CGImage], rightCrop);
    UIImage *rightForAnimation = [UIImage imageWithCGImage:rightImageRef scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(rightImageRef);
    
    NSLog(@"WIDTH: %f, HEIGHT: %f", leftForAnimation.size.width, leftForAnimation.size.height);
    
    //make the gif
    [self makeAnimatedGifWithLeft:leftForAnimation withRight:rightForAnimation];
    
    //display the gif
    UIImage *image = [UIImage animatedImageWithAnimatedGIFURL:fileURL];
    animatedView = [[UIImageView alloc] initWithImage:image];
    [animatedView setFrame:self.view.frame];
    [animatedView setContentMode:UIViewContentModeScaleAspectFill];
    [gifView addSubview:animatedView];
    
    // add the send button
    CGRect buttonFrame = CGRectMake(50, self.view.frame.size.height - 70, 100, 50);
    UIView *shadowView = [[UIView alloc] initWithFrame:buttonFrame];
    [shadowView setBackgroundColor:[UIColor blackColor]];
    [shadowView setAlpha:0.3];
    UIButton *sendButton = [[UIButton alloc] initWithFrame:buttonFrame];
    [sendButton addTarget:self action:@selector(displayComposerSheet) forControlEvents:UIControlEventTouchUpInside];
    [sendButton setTitle:@"Send" forState:UIControlStateNormal];
    [gifView addSubview:shadowView];
    [gifView addSubview:sendButton];
    
    // add the retake button
    CGRect buttonFrame2 = CGRectMake(170, self.view.frame.size.height - 70, 100, 50);
    UIView *shadowView2 = [[UIView alloc] initWithFrame:buttonFrame2];
    [shadowView2 setBackgroundColor:[UIColor blackColor]];
    [shadowView2 setAlpha:0.3];
    UIButton *retakeButton = [[UIButton alloc] initWithFrame:buttonFrame2];
    [retakeButton addTarget:self action:@selector(redoGif) forControlEvents:UIControlEventTouchUpInside];
    [retakeButton setTitle:@"Redo" forState:UIControlStateNormal];
    [gifView addSubview:shadowView2];
    [gifView addSubview:retakeButton];
    
    [self.view addSubview:gifView];
}
 */

-(void)redoGif
{
    [gifView removeFromSuperview];
}

-(void)postGif
{
    UIImage *image = [UIImage imageNamed:@"image.jpg"];
    NSData *imageData = UIImageJPEGRepresentation(image, 0);
    
    NSURL *url = [NSURL URLWithString:@"http://poppy3d.com/app/upload_wiggle"];
    //NSURL *url = [NSURL URLWithString:@"http://localhost:9292/app/upload_wiggle"];
    //NSURL *url = [NSURL URLWithString:@"http://localhost:4000"];
    //NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData
                                                       timeoutInterval:30.0];
    /*
     [request setHTTPMethod:@"POST"];
     
     NSString *boundary = @"---XXX---";
     NSString *contentType = [NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary];
     [request addValue:contentType forHTTPHeaderField:@"Content-Type"];
     
     [NSURLConnection sendAsynchronousRequest:request
     queue:[NSOperationQueue mainQueue]
     completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
     // TO DO: Look at the response. Currently this is fire and forget
     if(error){
     NSLog(@"ERROR: %@", error);
     }
     }];
     
     */
    [request setHTTPMethod:@"POST"];
    
    NSString *boundary = @"XXX";
    NSString *contentType = [NSString stringWithFormat:@"multipart/form-data; boundary=--%@", boundary];
    [request addValue:contentType forHTTPHeaderField:@"Content-Type"];
    
    NSMutableData *body = [NSMutableData data];
    
    [body appendData:[[NSString stringWithFormat:@"\r\n--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"content[file]\"; filename=\"stereo.jpg\"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    //[body appendData:[@"Content-Type: application/octet-stream\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Type: image/jpeg\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[NSData dataWithData:imageData]];
    
    [body appendData:[[NSString stringWithFormat:@"\r\n--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"UUID\"\r\n\r\n%@", [[[UIDevice currentDevice] identifierForVendor] UUIDString]] dataUsingEncoding:NSUTF8StringEncoding]];
    
    [body appendData:[[NSString stringWithFormat:@"\r\n--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"wiggle_offset\"\r\n\r\n%f", offset/320] dataUsingEncoding:NSUTF8StringEncoding]];
    
    [body appendData:[[NSString stringWithFormat:@"\r\n--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    
    [request setHTTPBody:body];
    
    NSLog(@"DATA: %@", [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding]);
    NSURLResponse *response;
    NSError *error;
    
    [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
    NSLog(@"%@", [request allHTTPHeaderFields]);
    
    NSLog(@"RESPONSE: %@", response);
    
    
}

-(void)splitImage:(UIImage *)image
{
    CGRect leftCrop = CGRectMake(0, 0, image.size.width/2, image.size.height);
    CGImageRef leftImageRef = CGImageCreateWithImageInRect([image CGImage], leftCrop);
    leftImg = [UIImage imageWithCGImage:leftImageRef];
    CGImageRelease(leftImageRef);
    CGRect rightCrop = CGRectMake(image.size.width/2, 0, image.size.width/2, image.size.height);
    CGImageRef rightImageRef = CGImageCreateWithImageInRect([image CGImage], rightCrop);
    rightImg = [UIImage imageWithCGImage:rightImageRef];
    CGImageRelease(rightImageRef);
}

-(void)sliderAction:(id)sender
{
    
    UISlider *slider = (id)sender;
    offset = slider.value;
    CGRect newFrame = self.leftImgView.frame;
    newFrame.origin.x = offset;
    [self.leftImgView setFrame:newFrame];
    
    CGRect maskFrame = self.maskView.frame;
    if (offset > 0 ) {
        maskFrame.origin.x = offset - self.view.frame.size.width;
    } else {
        maskFrame.origin.x = self.view.frame.size.width + offset;
    }
    [self.maskView setFrame:maskFrame];
}

-(void)fadeInLeft
{
    [UIView animateWithDuration:0.3 delay:0.0 options:UIViewAnimationOptionCurveEaseIn animations:^{ [self.rightImgView setAlpha:0.0];} completion:^(BOOL finished){
        [self fadeInRight];
    }];
}

-(void)fadeInRight
{
    [UIView animateWithDuration:0.3 delay:0.0 options:UIViewAnimationOptionCurveEaseIn animations:^{ [self.rightImgView setAlpha:1.0]; } completion:^(BOOL finished){
        [self fadeInLeft];
    }];
}

-(void)displayComposerSheet
{
    picker = [[MFMailComposeViewController alloc] init];
    picker.mailComposeDelegate = self;
    [picker setSubject:@"Check out my wiggle gif!"];
    
    // Attach the image to the email
    NSData *gifData = [NSData dataWithContentsOfURL: fileURL];
    [picker addAttachmentData:gifData mimeType:@"image/gif" fileName:@"animated.gif"];
    
    // Fill out the email body text
    NSString *emailBody = @"My wiggle gif is attached";
    [picker setMessageBody:emailBody isHTML:NO];
    [self presentViewController:picker animated:YES completion:nil];
    
}

- (void)mailComposeController:(MFMailComposeViewController*)controller didFinishWithResult:(MFMailComposeResult)result error:(NSError*)error
{
    switch (result)
    {
        case MFMailComposeResultCancelled:
            NSLog(@"Mail cancelled: you cancelled the operation and no email message was queued.");
            break;
        case MFMailComposeResultSaved:
            NSLog(@"Mail saved: you saved the email message in the drafts folder.");
            break;
        case MFMailComposeResultSent:
            NSLog(@"Mail send: the email message is queued in the outbox. It is ready to send.");
            break;
        case MFMailComposeResultFailed:
            NSLog(@"Mail failed: the email message was not saved or queued, possibly due to an error.");
            break;
        default:
            NSLog(@"Mail not sent.");
            break;
    }
    // Remove the mail view
    [picker dismissViewControllerAnimated:NO completion:^{}];
}

- (BOOL)prefersStatusBarHidden
{
    return YES;
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

@end