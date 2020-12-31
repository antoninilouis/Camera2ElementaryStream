//
//  Camera2ElementaryStreamCapturePipeline.m
//  Camera2ElementaryStream
//
//  Created by Antonini Louis on 2020-12-25.
//

#import <libavformat/avformat.h>

#import "Camera2ElementaryStreamCapturePipeline.h"

/*
  Manages the capture session
 */
@implementation Camera2ElementaryStreamCapturePipeline {
  __weak id<Camera2ElementaryStreamCapturePipelineDelegate> _delegate;
  dispatch_queue_t _delegateCallbackQueue;

  AVCaptureSession *_captureSession;
  AVCaptureDevice *_videoDevice;
  AVCaptureConnection *_videoConnection;
  dispatch_queue_t _videoDataOutputQueue;

  VTCompressionSessionRef _compressionSession;
  NSFileHandle *_fileHandle;  
}

- (instancetype)initWithDelegate:(id<Camera2ElementaryStreamCapturePipelineDelegate>)delegate callbackQueue:(dispatch_queue_t)queue {
  self = [ super init ];

  _delegate = delegate;

  // Queue passed by client for asynchronous error handling
  _delegateCallbackQueue = queue;

  // Initialize serial queue on which sample buffer delegate callback is called
  _videoDataOutputQueue = dispatch_queue_create( "camera2elementarystream.capturepipeline.video", DISPATCH_QUEUE_SERIAL );
  dispatch_set_target_queue( _videoDataOutputQueue, dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_HIGH, 0 ) );
  
  return self;
}

- (void)start
{
  [self setupCaptureSession];
  [self setupCompressionSession];
  [self setupRecording];
  [self setupMuxing];
  [_delegate startRendering:_captureSession];
  [_captureSession startRunning];
}

- (void)stop
{
  [self teardownCaptureSession];
  [self teardownCompressionSession];
  [self teardownRecording];
  [_delegate stopRendering];
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

- (void)teardownCaptureSession
{
  [_captureSession stopRunning];
  _captureSession = nil;
}

#pragma mark - Compression Session

- (void)setupCompressionSession
{
  CMVideoDimensions videoDimensions = CMVideoFormatDescriptionGetDimensions( self.outputVideoFormatDescription );

  VTCompressionSessionCreate( NULL, videoDimensions.width, videoDimensions.height, kCMVideoCodecType_H264, NULL, NULL, NULL, &compressionOutputCallback, (__bridge void *) self, &_compressionSession );
  VTSessionSetProperty( _compressionSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue );
  VTCompressionSessionPrepareToEncodeFrames( _compressionSession );
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
  CFArrayRef attachmentsArray = CMSampleBufferGetSampleAttachmentsArray( sampleBuffer, 0 );
  if (CFArrayGetCount(attachmentsArray)) {
      CFBooleanRef notSync;
      CFDictionaryRef dict = CFArrayGetValueAtIndex( attachmentsArray, 0 );
      BOOL keyExists = CFDictionaryGetValueIfPresent( dict,
                                                     kCMSampleAttachmentKey_NotSync,
                                                     (const void **)&notSync );
      // An I-Frame is a sync frame
      isIFrame = !keyExists || !CFBooleanGetValue( notSync );
  }
 
  // This is the start code that we will write to
  // the elementary stream before every NAL unit
  static const size_t startCodeLength = 4;
  static const uint8_t startCode[] = {0x00, 0x00, 0x00, 0x01};
 
  // Write the SPS and PPS NAL units to the elementary stream before every I-Frame
  if (isIFrame) {
      CMFormatDescriptionRef description = CMSampleBufferGetFormatDescription( sampleBuffer );
     
      // Find out how many parameter sets there are
      size_t numberOfParameterSets;
      CMVideoFormatDescriptionGetH264ParameterSetAtIndex( description,
                                                         0, NULL, NULL,
                                                         &numberOfParameterSets,
                                                         NULL );
     
      // Write each parameter set to the elementary stream
      for (int i = 0; i < numberOfParameterSets; i++) {
          const uint8_t *parameterSetPointer;
          size_t parameterSetLength;
          CMVideoFormatDescriptionGetH264ParameterSetAtIndex( description,
                                                             i,
                                                             &parameterSetPointer,
                                                             &parameterSetLength,
                                                             NULL, NULL );
         
          // Write the parameter set to the elementary stream
          [elementaryStream appendBytes:startCode length:startCodeLength];
          [elementaryStream appendBytes:parameterSetPointer length:parameterSetLength];
      }
  }
 
  // Get a pointer to the raw AVCC NAL unit data in the sample buffer
  size_t blockBufferLength;
  uint8_t *bufferDataPointer = NULL;
  CMBlockBufferGetDataPointer( CMSampleBufferGetDataBuffer( sampleBuffer ),
                              0,
                              NULL,
                              &blockBufferLength,
                              (char **)&bufferDataPointer );
 
  // Loop through all the NAL units in the block buffer
  // and write them to the elementary stream with
  // start codes instead of AVCC length headers
  size_t bufferOffset = 0;
  static const int AVCCHeaderLength = 4;
  while (bufferOffset < blockBufferLength - AVCCHeaderLength) {
    // Read the NAL unit length
    uint32_t NALUnitLength = 0; memcpy(&NALUnitLength, bufferDataPointer + bufferOffset, AVCCHeaderLength);
    // Convert the length value from Big-endian to Little-endian
    NALUnitLength = CFSwapInt32BigToHost( NALUnitLength );
    // Write start code to the elementary stream
    [elementaryStream appendBytes:startCode length:startCodeLength];
    // Write the NAL unit without the AVCC length header to the elementary stream
    [elementaryStream appendBytes:bufferDataPointer + bufferOffset + AVCCHeaderLength length:NALUnitLength];
    // Move to the next NAL unit in the block buffer
    bufferOffset += AVCCHeaderLength + NALUnitLength;
  }

  Camera2ElementaryStreamCapturePipeline *this = (__bridge Camera2ElementaryStreamCapturePipeline *)outputCallbackRefCon;
  
  // Flush all content to file
  [this->_fileHandle writeData: [NSData dataWithBytes:[elementaryStream bytes] length:[elementaryStream length]]];
  
  // Mux content into a Transport Stream
  [this appendElementaryStreamToTransportStream:elementaryStream];
}

- (void)teardownCompressionSession
{
  VTCompressionSessionCompleteFrames(_compressionSession, kCMTimeZero);
  VTCompressionSessionInvalidate(_compressionSession);
  CFRelease(_compressionSession);
}

#pragma mark - MPEG-TS

/*
 Starting from what I understand of the usage of ffmpeg library for muxing
 The global problematic is related to IO, and how set ffmpeg output to memory
 */
- (void)setupMuxing
{
  AVFormatContext *formatContext;
  AVOutputFormat *oformat;

  /*
   Does the job despite being flagged as deprecated
   Must be replaced by av_demuxer_iterate/av_muxer_iterate()
   */
  
  av_register_all();
  
  /*
   From documentation in avformat.h:
   At the beginning of the muxing process, the caller must first call
   avformat_alloc_context() to create a muxing context. The caller then sets up
   the muxer by filling the various fields in this context
   */
  
  formatContext = avformat_alloc_context();

  // output format (mpegts)
  oformat = av_guess_format("mpegts", NULL, NULL);
  formatContext->oformat = oformat;

  /*
   From documentation in avformat.h:
   In some cases you might want to preallocate an AVFormatContext yourself with
   avformat_alloc_context() and do some tweaking on it before passing it to
   avformat_open_input(). One such case is when you want to use custom functions
   for reading input data instead of lavf internal I/O layer.
   To do that, create your own AVIOContext with avio_alloc_context(), passing
   your reading callbacks to it. Then set the @em pb field of your
   AVFormatContext to newly created AVIOContext.
   */
  
  unsigned char *buffer;
  const size_t AVIO_BUFFER_SIZE = 4096;
  const size_t STREAM_FRAME_RATE = 30;
  AVIOContext *avio;

  buffer = av_malloc(AVIO_BUFFER_SIZE);
  avio = avio_alloc_context(buffer, AVIO_BUFFER_SIZE, 1, NULL, &rPacket, &wPacket, NULL);
  
  // bytestream IO context, used for muxer output
  formatContext->pb = avio;

  /*
   From documentation in avformat.h:
   - Unless the format is of the AVFMT_NOSTREAMS type, at least one stream must
     be created with the avformat_new_stream() function. The caller should fill
     the @ref AVStream.codecpar "stream codec parameters" information, such as the
     codec @ref AVCodecParameters.codec_type "type", @ref AVCodecParameters.codec_id
     "id" and other parameters (e.g. width / height, the pixel or sample format,
     etc.) as known. The @ref AVStream.time_base "stream timebase" should
     be set to the timebase that the caller desires to use for this stream (note
     that the timebase actually used by the muxer can be different, as will be
     described later).
   */

  // Instead of creating an AVCodecContext ourselves, we use AVCodecParameters *codecpar parameter to AVStream
  // AVCodecContext *codecContext;
  // codecContext->gop_size    = 12;
  // codecContext->time_base   = (AVRational){ 1, STREAM_FRAME_RATE };
  
  AVCodecParameters *codecParameters = avcodec_parameters_alloc();
  codecParameters->codec_type = AVMEDIA_TYPE_VIDEO;
  codecParameters->codec_id   = AV_CODEC_ID_H264;
  codecParameters->bit_rate   = 2000000;
  codecParameters->width      = 1920;
  codecParameters->height     = 1080;
  
  AVStream *outputStream;

  // Usage of codec member in AVStream is deprecated so we set it to NULL
  outputStream = avformat_new_stream(formatContext, NULL);
  outputStream->id = formatContext->nb_streams - 1;
  outputStream->codecpar = codecParameters;
  
  // outputStream->time_base = codecContext->time_base;
  
  av_dump_format(formatContext, 0, [@"RAM" UTF8String], 1);
  
  int ret = avformat_write_header(formatContext, NULL);
  
  switch (ret) {
    case AVSTREAM_INIT_IN_WRITE_HEADER:
      NSLog(@"AVSTREAM_INIT_IN_WRITE_HEADER");
      break;

    case AVSTREAM_INIT_IN_INIT_OUTPUT:
      NSLog(@"AVSTREAM_INIT_IN_INIT_OUTPUT");
      break;

    default:
      NSLog(@"AVERROR");
      break;
  }
}

int rPacket(void *opaque, uint8_t *buf, int buf_size)
{
  NSLog(@"rPacket");
  return 1;
}

int wPacket(void *opaque, uint8_t *buf, int buf_size)
{
  NSLog(@"wPacket");
  return 1;
}

- (void)appendElementaryStreamToTransportStream:(NSData *)elementaryStream
{
  
}

#pragma mark - Capture Pipeline

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
  CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer( sampleBuffer );
  VTCompressionSessionEncodeFrame( _compressionSession, imageBuffer, CMSampleBufferGetPresentationTimeStamp( sampleBuffer ), CMSampleBufferGetDuration( sampleBuffer ), NULL, NULL, NULL );
}

- (void)setupRecording
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *docDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
  NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
  [formatter setDateFormat:@"dd-MM-yyyy_HH-mm"];
  NSDate *currentDate = [NSDate date];
  NSString *dateString = [formatter stringFromDate:currentDate];
  NSString *h264file = [docDir stringByAppendingPathComponent: [NSString stringWithFormat:@"%@%@%@", @"test_", dateString, @".h264"]];
    
  // Create file if it doesn't exist
  if(![fm fileExistsAtPath:h264file])
  {
    if([fm createFileAtPath:h264file contents: nil attributes:nil])
          NSLog(@"File Created");
      else
          NSLog(@"File Creation Failed");
  }
  
  _fileHandle = [NSFileHandle fileHandleForWritingAtPath:h264file];
}

- (void)teardownRecording
{
  [_fileHandle closeFile];
  _fileHandle = nil;
}

@end
