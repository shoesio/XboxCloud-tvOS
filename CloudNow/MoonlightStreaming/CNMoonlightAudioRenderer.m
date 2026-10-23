#import "CNMoonlightAudioRenderer.h"

@import AVFoundation;

#include "opus/opus_multistream.h"

@interface CNMoonlightAudioRenderer ()
@property (nonatomic, strong, nullable) AVAudioEngine *engine;
@property (nonatomic, strong, nullable) AVAudioPlayerNode *playerNode;
@property (nonatomic, strong, nullable) AVAudioFormat *format;
@property (nonatomic, assign) OpusMSDecoder *decoder;
@property (nonatomic, assign) OPUS_MULTISTREAM_CONFIGURATION audioConfig;
@property (nonatomic, assign) int16_t *decodeBuffer;
@property (nonatomic, assign) size_t decodeBufferBytes;
@property (nonatomic, assign) NSInteger queuedBuffers;
@end

@implementation CNMoonlightAudioRenderer

- (void)dealloc {
    [self cleanup];
}

- (int)setupWithAudioConfiguration:(int)audioConfiguration
                        opusConfig:(const POPUS_MULTISTREAM_CONFIGURATION)opusConfig
                           arFlags:(int)arFlags {
    (void)audioConfiguration;
    (void)arFlags;
    [self cleanup];

    if (!opusConfig || opusConfig->sampleRate <= 0 || opusConfig->channelCount <= 0 || opusConfig->samplesPerFrame <= 0) {
        NSLog(@"[MoonlightAudio] invalid Opus config");
        return -1;
    }

    NSError *sessionError = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionMixWithOthers
                   error:&sessionError];
    if (sessionError) {
        NSLog(@"[MoonlightAudio] failed to set audio session category: %@", sessionError.localizedDescription);
    }
    sessionError = nil;
    [session setActive:YES error:&sessionError];
    if (sessionError) {
        NSLog(@"[MoonlightAudio] failed to activate audio session: %@", sessionError.localizedDescription);
    }

    self.audioConfig = *opusConfig;
    self.format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                   sampleRate:opusConfig->sampleRate
                                                     channels:(AVAudioChannelCount)opusConfig->channelCount
                                                  interleaved:YES];
    if (!self.format) {
        NSLog(@"[MoonlightAudio] failed to create PCM format");
        [self cleanup];
        return -1;
    }

    self.decodeBufferBytes = (size_t)opusConfig->samplesPerFrame * (size_t)opusConfig->channelCount * sizeof(int16_t);
    self.decodeBuffer = malloc(self.decodeBufferBytes);
    if (!self.decodeBuffer) {
        NSLog(@"[MoonlightAudio] failed to allocate decode buffer");
        [self cleanup];
        return -1;
    }

    int opusError = OPUS_OK;
    self.decoder = opus_multistream_decoder_create(opusConfig->sampleRate,
                                                   opusConfig->channelCount,
                                                   opusConfig->streams,
                                                   opusConfig->coupledStreams,
                                                   opusConfig->mapping,
                                                   &opusError);
    if (!self.decoder || opusError != OPUS_OK) {
        NSLog(@"[MoonlightAudio] failed to create Opus decoder: %d", opusError);
        [self cleanup];
        return -1;
    }

    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioPlayerNode *playerNode = [[AVAudioPlayerNode alloc] init];
    [engine attachNode:playerNode];
    [engine connect:playerNode to:engine.mainMixerNode format:self.format];
    [engine prepare];

    NSError *engineError = nil;
    if (![engine startAndReturnError:&engineError]) {
        NSLog(@"[MoonlightAudio] failed to start audio engine: %@", engineError.localizedDescription);
        [self cleanup];
        return -1;
    }

    self.engine = engine;
    self.playerNode = playerNode;
    self.queuedBuffers = 0;
    NSLog(@"[MoonlightAudio] ready: %d Hz, %d channels, %d samples/frame",
          opusConfig->sampleRate,
          opusConfig->channelCount,
          opusConfig->samplesPerFrame);
    return 0;
}

- (void)start {
    [self.playerNode play];
    NSLog(@"[MoonlightAudio] stream started");
}

- (void)stop {
    [self.playerNode stop];
    self.queuedBuffers = 0;
    NSLog(@"[MoonlightAudio] stream stopped");
}

- (void)cleanup {
    [self.playerNode stop];
    [self.engine stop];
    self.playerNode = nil;
    self.engine = nil;
    self.format = nil;
    if (self.decoder) {
        opus_multistream_decoder_destroy(self.decoder);
        self.decoder = NULL;
    }
    if (self.decodeBuffer) {
        free(self.decodeBuffer);
        self.decodeBuffer = NULL;
    }
    self.decodeBufferBytes = 0;
    self.queuedBuffers = 0;
}

- (void)decodeAndPlaySample:(char *)sampleData length:(int)sampleLength {
    if (!self.decoder || !self.playerNode || !self.format || !self.decodeBuffer) {
        return;
    }

    if (self.queuedBuffers > 12) {
        return;
    }

    int decodedFrames = opus_multistream_decode(self.decoder,
                                                (const unsigned char *)sampleData,
                                                sampleLength,
                                                self.decodeBuffer,
                                                self.audioConfig.samplesPerFrame,
                                                0);
    if (decodedFrames <= 0) {
        if (decodedFrames < 0) {
            NSLog(@"[MoonlightAudio] Opus decode failed: %d", decodedFrames);
        }
        return;
    }

    AVAudioPCMBuffer *pcmBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.format
                                                                 frameCapacity:(AVAudioFrameCount)decodedFrames];
    if (!pcmBuffer) {
        return;
    }
    pcmBuffer.frameLength = (AVAudioFrameCount)decodedFrames;

    AudioBufferList *audioBufferList = pcmBuffer.mutableAudioBufferList;
    if (audioBufferList->mNumberBuffers < 1 || !audioBufferList->mBuffers[0].mData) {
        return;
    }

    size_t bytesToCopy = (size_t)decodedFrames * (size_t)self.audioConfig.channelCount * sizeof(int16_t);
    memcpy(audioBufferList->mBuffers[0].mData, self.decodeBuffer, bytesToCopy);
    audioBufferList->mBuffers[0].mDataByteSize = (UInt32)bytesToCopy;

    self.queuedBuffers += 1;
    __weak typeof(self) weakSelf = self;
    [self.playerNode scheduleBuffer:pcmBuffer completionHandler:^{
        CNMoonlightAudioRenderer *strongSelf = weakSelf;
        if (strongSelf && strongSelf.queuedBuffers > 0) {
            strongSelf.queuedBuffers -= 1;
        }
    }];
    if (!self.playerNode.isPlaying) {
        [self.playerNode play];
    }
}

@end
