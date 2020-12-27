//
//  Camera2ElementaryStreamCapturePipeline.m
//  Camera2ElementaryStream
//
//  Created by Antonini Louis on 2020-12-25.
//

#import "Camera2ElementaryStreamCapturePipeline.h"

/*
  Manages the capture session
  Uses formal delegation for capture session lifecycle
 */
@implementation Camera2ElementaryStreamCapturePipeline {
  AVCaptureSession *_captureSession;
  AVCaptureDevice *_videoDevice;
  AVCaptureConnection *_videoConnection;
  BOOL _running;
  BOOL _rendering;

  dispatch_queue_t _sessionQueue;
  dispatch_queue_t _videoDataOutputQueue;
  __weak id<Camera2ElementaryStreamCapturePipelineDelegate> _delegate;
  dispatch_queue_t _delegateCallbackQueue;

  VTCompressionSessionRef _compressionSession;
}

- (instancetype)initWithDelegate:(id<Camera2ElementaryStreamCapturePipelineDelegate>)delegate callbackQueue:(dispatch_queue_t)queue {
  self = [ super init ];

  // Initialize serial queue on which capture session runs
  _sessionQueue = dispatch_queue_create( "camera2elementarystream.capturepipeline.session", DISPATCH_QUEUE_SERIAL );

  // Initialize serial queue on which sample buffer delegate callback is called
  _videoDataOutputQueue = dispatch_queue_create( "camera2elementarystream.capturepipeline.video", DISPATCH_QUEUE_SERIAL );
  dispatch_set_target_queue( _videoDataOutputQueue, dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_HIGH, 0 ) );

  _delegate = delegate;
  
  // Queue passed by client for asynchronous errors
  _delegateCallbackQueue = queue;

  return self;
}

- (void)startRunning
{
  dispatch_sync( _sessionQueue, ^{
    [self setupCaptureSession];
    [self setupCompressionSession];

    if ( _captureSession ) {
      [_captureSession startRunning];
      _running = YES;
    }
  } );
}

#pragma mark - Capture Session

- (void)setupCaptureSession
{
  if ( _captureSession ) {
    return;
  }
  
  _captureSession = [[AVCaptureSession alloc] init];
  
  // Setup the capture session input
  AVCaptureDevice *videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  NSError *videoDeviceError = nil;
  AVCaptureDeviceInput *videoIn = [[AVCaptureDeviceInput alloc] initWithDevice:videoDevice error:&videoDeviceError];
  [_captureSession addInput:videoIn];
  _videoDevice = videoDevice;

  // Setup the capture session output
  AVCaptureVideoDataOutput *videoOut = [[AVCaptureVideoDataOutput alloc] init];
//  videoOut.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(_renderer.inputPixelFormat) };
  [videoOut setSampleBufferDelegate:self queue:_videoDataOutputQueue];
  videoOut.alwaysDiscardsLateVideoFrames = NO;
  [_captureSession addOutput:videoOut];
  _videoConnection = [videoOut connectionWithMediaType:AVMediaTypeVideo];

  // Setup the capture session quality level or bitrate
  _captureSession.sessionPreset = AVCaptureSessionPresetHigh;

  // Use fixed frame rate
  CMTime frameDuration = CMTimeMake( 1, 30 );
  NSError *error = nil;
  if ( [videoDevice lockForConfiguration:&error] ) {
    videoDevice.activeVideoMaxFrameDuration = frameDuration;
    videoDevice.activeVideoMinFrameDuration = frameDuration;
    [videoDevice unlockForConfiguration];
  }
  else {
    NSLog( @"videoDevice lockForConfiguration returned error %@", error );
  }
  
  self.outputVideoFormatDescription = videoDevice.activeFormat.formatDescription;

  return;
}

#pragma mark - Compression Session

- (void)setupCompressionSession
{
  CMVideoDimensions videoDimensions = CMVideoFormatDescriptionGetDimensions( self.outputVideoFormatDescription );

  // Do not forget to call VTCompressionSessionInvalidate to invalidate it and CFRelease to free its memory
  VTCompressionSessionCreate( NULL, videoDimensions.width, videoDimensions.width, kCMVideoCodecType_H264, NULL, NULL, NULL, &compressionOutputCallback, (__bridge void *)(self), &_compressionSession );
  VTSessionSetProperty( _compressionSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue );
}

void compressionOutputCallback(void *outputCallbackRefCon, void* sourceFrameRefCon, OSStatus status, VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer)
{
  // Check if there were any errors encoding
  if (status != noErr) {
     NSLog(@"Error encoding video, err=%lld", (int64_t)status);
     return;
  }

  NSMutableData *elementaryStream = [NSMutableData data];
 
  // Find out if the sample buffer contains an I-Frame.
  // If so we will write the SPS and PPS NAL units to the elementary stream.
  BOOL isIFrame = NO;
  CFArrayRef attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, 0);
  if (CFArrayGetCount(attachmentsArray)) {
      CFBooleanRef notSync;
      CFDictionaryRef dict = CFArrayGetValueAtIndex(attachmentsArray, 0);
      BOOL keyExists = CFDictionaryGetValueIfPresent(dict,
                                                     kCMSampleAttachmentKey_NotSync,
                                                     (const void **)&notSync);
      // An I-Frame is a sync frame
      isIFrame = !keyExists || !CFBooleanGetValue(notSync);
  }
 
  // This is the start code that we will write to
  // the elementary stream before every NAL unit
  static const size_t startCodeLength = 4;
  static const uint8_t startCode[] = {0x00, 0x00, 0x00, 0x01};
 
  // Write the SPS and PPS NAL units to the elementary stream before every I-Frame
  if (isIFrame) {
      CMFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sampleBuffer);
     
      // Find out how many parameter sets there are
      size_t numberOfParameterSets;
      CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description,
                                                         0, NULL, NULL,
                                                         &numberOfParameterSets,
                                                         NULL);
     
      // Write each parameter set to the elementary stream
      for (int i = 0; i < numberOfParameterSets; i++) {
          const uint8_t *parameterSetPointer;
          size_t parameterSetLength;
          CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description,
                                                             i,
                                                             &parameterSetPointer,
                                                             &parameterSetLength,
                                                             NULL, NULL);
         
          // Write the parameter set to the elementary stream
          [elementaryStream appendBytes:startCode length:startCodeLength];
          [elementaryStream appendBytes:parameterSetPointer length:parameterSetLength];
      }
  }
 
  // Get a pointer to the raw AVCC NAL unit data in the sample buffer
  size_t blockBufferLength;
  uint8_t *bufferDataPointer = NULL;
  CMBlockBufferGetDataPointer(CMSampleBufferGetDataBuffer(sampleBuffer),
                              0,
                              NULL,
                              &blockBufferLength,
                              (char **)&bufferDataPointer);
 
  // Loop through all the NAL units in the block buffer
  // and write them to the elementary stream with
  // start codes instead of AVCC length headers
  size_t bufferOffset = 0;
  static const int AVCCHeaderLength = 4;
  while (bufferOffset < blockBufferLength - AVCCHeaderLength) {
    // Read the NAL unit length
    uint32_t NALUnitLength = 0; memcpy(&NALUnitLength, bufferDataPointer + bufferOffset, AVCCHeaderLength);
    // Convert the length value from Big-endian to Little-endian
    NALUnitLength = CFSwapInt32BigToHost(NALUnitLength);
    // Write start code to the elementary stream
    [elementaryStream appendBytes:startCode length:startCodeLength];
    // Write the NAL unit without the AVCC length header to the elementary stream
    [elementaryStream appendBytes:bufferDataPointer + bufferOffset + AVCCHeaderLength length:NALUnitLength];
    // Move to the next NAL unit in the block buffer
    bufferOffset += AVCCHeaderLength + NALUnitLength;
  }
  //Before decompress we will write elementry data to .h264 file in document directory
  //you can get that file using iTunes => Apps = > FileSharing => AVEncoderDemo
//  [FileLogger logToFile:elementaryStream];

  NSString *docDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
  NSString *dirName = [docDir stringByAppendingPathComponent:@"Camera2ElementaryStream"];

  NSFileManager *fm = [NSFileManager defaultManager];

  // Create directory if it doesn't exist
  if(![fm fileExistsAtPath:dirName])
  {
      if([fm createDirectoryAtPath:dirName withIntermediateDirectories:YES attributes:nil error:nil])
          NSLog(@"Directory Created");
      else
          NSLog(@"Directory Creation Failed");
  }

  NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
  [formatter setDateFormat:@"dd-MM-yyyy_HH-mm"];

  NSDate *currentDate = [NSDate date];
  NSString *dateString = [formatter stringFromDate:currentDate];
  
  NSString *fileName = [docDir stringByAppendingPathComponent: [NSString stringWithFormat:@"%@%@%@", @"test_", dateString, @".h264"]];
    
  // Create file if it doesn't exist
  if(![fm fileExistsAtPath:fileName])
  {
    if([fm createFileAtPath:fileName contents: nil attributes:nil])
          NSLog(@"File Created");
      else
          NSLog(@"File Creation Failed");
  }
  
  if (!((__bridge Camera2ElementaryStreamCapturePipeline *)outputCallbackRefCon).testBlockWriting)
  {
    [elementaryStream writeToFile:fileName atomically:NO];
    ((__bridge Camera2ElementaryStreamCapturePipeline *)outputCallbackRefCon).testBlockWriting = YES;
  }
}

- (void)teardownCompressionSession
{
  VTCompressionSessionInvalidate(_compressionSession);
  CFRelease(_compressionSession);
}

#pragma mark - Capture Pipeline

- (void)setupVideoPipelineWithInputFormatDescription:(CMFormatDescriptionRef)inputFormatDescription
{
  NSLog( @"-[%@ %@] called", [self class], NSStringFromSelector(_cmd) );
  self.outputVideoFormatDescription = inputFormatDescription;
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
//  CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription( sampleBuffer );
//
//  if ( connection == _videoConnection )
//  {
//    if ( self.outputVideoFormatDescription == NULL ) {
//      // Don't render the first sample buffer.
//      // This gives us one frame interval (33ms at 30fps) for setupVideoPipelineWithInputFormatDescription: to complete.
//      // Ideally this would be done asynchronously to ensure frames don't back up on slower devices.
//      [self setupVideoPipelineWithInputFormatDescription:formatDescription];
//    }
//  }
  CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer( sampleBuffer );
  VTCompressionSessionEncodeFrame( _compressionSession, imageBuffer, CMSampleBufferGetPresentationTimeStamp( sampleBuffer ), CMSampleBufferGetDuration( sampleBuffer ), NULL, NULL, NULL );
}

- (void)startRendering
{
  if ( _rendering == YES ) {
    return;
  }
  // Create preview layer with captureSession
  AVCaptureVideoPreviewLayer *previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:_captureSession];
  [previewLayer setVideoGravity:AVLayerVideoGravityResizeAspectFill];
  [_delegate startRendering:previewLayer];
  _rendering = YES;
}

@end
