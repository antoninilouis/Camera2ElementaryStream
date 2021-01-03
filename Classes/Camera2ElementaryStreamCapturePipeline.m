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
 The data flow is the following:
 - capture session
 - compression session
 - muxing into mpeg-ts
 
 Each part is using a form of delegation, using protocol/delegate or callbacks
 - the capture session uses this object as delegate on the video data output queue (serial)
   its settings are: inputs and outputs that controll device parameters and the delegation
   the delegate method makes calls to VTCompressionSessionEncodeFrame
 - the compression session passes compressed frames to the compressionOutputCallback
   its settings are: encoder used for the compression
   the callback method makes calls to appendElementaryStreamToTransportStream
 - the muxing "session" passes muxed packets to the wPacket callback
   its settings are: FFmpeg format context used for the muxing
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
  
  AVFormatContext *_formatContext;
  CMSampleBufferRef firstSampleBuffer;
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

  // Setup the capture session quality level or bitrate
  _captureSession.sessionPreset = AVCaptureSessionPresetHigh;

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

  /*
   Obtaining the array of timing info (containing the sample TimingInfo)
   */
  
  CMItemCount tInfoCount;
  CMSampleTimingInfo *timingInfos = NULL;
  NSMutableData* timingInfosData = [NSMutableData dataWithLength:sizeof(CMSampleTimingInfo)];

  timingInfos = (CMSampleTimingInfo *)timingInfosData.mutableBytes;
  CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, 1, timingInfos, &tInfoCount);
  
  if (timingInfos == NULL && tInfoCount > 0) {
    [timingInfosData setLength:sizeof(CMSampleTimingInfo) * tInfoCount];
    CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, tInfoCount, timingInfos, &tInfoCount);
  }
  
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
  NSMutableData *elementaryStream = [NSMutableData data];

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

  [this appendElementaryStreamToTransportStream:elementaryStream withTimingInfo:timingInfos];
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
  
  _formatContext = avformat_alloc_context();

  // output format (mpegts)
  oformat = av_guess_format("mpegts", NULL, NULL);
  _formatContext->oformat = oformat;

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
  AVIOContext *avio;
  
  buffer = av_malloc(AVIO_BUFFER_SIZE);
  avio = avio_alloc_context(buffer, AVIO_BUFFER_SIZE, 1, (__bridge void *)self, NULL, &wPacket, NULL);
  
  // bytestream IO context, used for muxer output
  _formatContext->pb = avio;

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

  AVCodecParameters *codecParameters = avcodec_parameters_alloc();
  codecParameters->codec_type = AVMEDIA_TYPE_VIDEO;
  codecParameters->codec_id   = AV_CODEC_ID_H264;
  codecParameters->width      = 1920;
  codecParameters->height     = 1080;

  AVStream *outputStream;

  // Usage of codec member in AVStream is deprecated so we set it to NULL
  outputStream = avformat_new_stream(_formatContext, NULL);
  outputStream->id = _formatContext->nb_streams - 1;
  outputStream->codecpar = codecParameters;
  outputStream->avg_frame_rate = av_make_q(30, 1);

  int ret = avformat_write_header(_formatContext, NULL);
    
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

  av_dump_format(_formatContext, 0, [@"RAM" UTF8String], 1);

  // time_base 1/90000
  NSLog(@"time_base %d/%d", outputStream->time_base.num, outputStream->time_base.den);
}

int wPacket(void *opaque, uint8_t *buf, int buf_size)
{
  Camera2ElementaryStreamCapturePipeline *this = (__bridge Camera2ElementaryStreamCapturePipeline *)opaque;

  [this->_fileHandle writeData: [NSData dataWithBytes:buf length:buf_size]];

  return buf_size;
}

- (void)appendElementaryStreamToTransportStream:(NSData *)elementaryStream withTimingInfo: (CMSampleTimingInfo *)timingInfo
{
  AVPacket packet;
  uint8_t buf[(int)elementaryStream.length];
  
  av_init_packet(&packet);

  memcpy(buf, elementaryStream.bytes, elementaryStream.length);
  packet.data = (uint8_t*)buf;
  packet.size = (int)elementaryStream.length;
  packet.stream_index = _formatContext->nb_streams - 1;

  /*
   From documentation in avformat.h:
   The timestamps (@ref AVPacket.pts "pts", @ref AVPacket.dts "dts")
   must be set to correct values in the stream's timebase (unless the
   output format is flagged with the AVFMT_NOTIMESTAMPS flag, then
   they can be set to AV_NOPTS_VALUE).
   */

  /*
   Do note that the timing
   information on the packets sent to the muxer must be in the corresponding
   AVStream's timebase. That timebase is set by the muxer (in the
   avformat_write_header() step) and may be different from the timebase
   requested by the caller.
   */
  
  if (timingInfo) {
    CMTime dts = CMTimeSubtract(timingInfo->decodeTimeStamp, CMSampleBufferGetPresentationTimeStamp(firstSampleBuffer));
    CMTime pts = CMTimeSubtract(timingInfo->presentationTimeStamp, CMSampleBufferGetPresentationTimeStamp(firstSampleBuffer));

    dts = CMTimeConvertScale(dts, 90000, kCMTimeRoundingMethod_RoundTowardZero);
    pts = CMTimeConvertScale(pts, 90000, kCMTimeRoundingMethod_RoundTowardZero);

    // Add one frame to all presentation timestamps to account for late dts in timingInfo
    pts = CMTimeAdd(pts, CMTimeMake(90000 / 30, 90000));

    packet.dts = dts.value;
    packet.pts = pts.value;

    CMTimeShow( dts );
    NSLog(@"DTS in seconds %f",  CMTimeGetSeconds( dts ));
    CMTimeShow( pts );
    NSLog(@"PTS in seconds %f",  CMTimeGetSeconds( pts ));
  }

  av_write_frame(_formatContext, &packet);
}

#pragma mark - Capture Pipeline

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
  if (firstSampleBuffer == NULL) {
    firstSampleBuffer = sampleBuffer;
    CFRetain(firstSampleBuffer);
  }

  CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer( sampleBuffer );
  VTCompressionSessionEncodeFrame( _compressionSession, imageBuffer, CMSampleBufferGetPresentationTimeStamp( sampleBuffer ), CMSampleBufferGetDuration( sampleBuffer ), NULL, NULL, NULL );
}

- (void)setupRecording
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *docDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
  NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
  [formatter setDateFormat:@"dd-MM-yyyy_HH-mm-ss"];
  NSDate *currentDate = [NSDate date];
  NSString *dateString = [formatter stringFromDate:currentDate];
  NSString *tsFile = [docDir stringByAppendingPathComponent: [NSString stringWithFormat:@"%@%@%@", @"test_", dateString, @".ts"]];
    
  // Create file if it doesn't exist
  if(![fm fileExistsAtPath:tsFile])
  {
    if([fm createFileAtPath:tsFile contents: nil attributes:nil])
          NSLog(@"File Created");
      else
          NSLog(@"File Creation Failed");
  }
  
  _fileHandle = [NSFileHandle fileHandleForWritingAtPath:tsFile];
}

- (void)teardownRecording
{
  [_fileHandle closeFile];
  _fileHandle = nil;
}

@end
