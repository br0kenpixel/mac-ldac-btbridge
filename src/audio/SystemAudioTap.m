// SPDX-License-Identifier: GPL-3.0-only
#import "SystemAudioTap.h"

#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>

static const uint32_t kMaxFrames = 8192;

static NSError *tapError(NSString *what, OSStatus st) {
    return [NSError errorWithDomain:@"SystemAudioTap"
                               code:st
                           userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"%@ failed (%d)", what, (int)st]}];
}

static NSString *defaultOutputUID(void) {
    AudioObjectPropertyAddress addr = {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal,
                                       kAudioObjectPropertyElementMain};
    AudioDeviceID dev = kAudioObjectUnknown;
    UInt32 size = sizeof dev;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &dev) || dev == kAudioObjectUnknown)
        return nil;
    addr.mSelector = kAudioDevicePropertyDeviceUID;
    CFStringRef uid = NULL;
    size = sizeof uid;
    if (AudioObjectGetPropertyData(dev, &addr, 0, NULL, &size, &uid) || !uid) return nil;
    return CFBridgingRelease(uid);
}

@interface SystemAudioTap ()
// initWithError:, optionally leaving local playback audible (for the permission probe).
- (instancetype)initMuting:(BOOL)mute error:(NSError **)error;
@end

@implementation SystemAudioTap {
    CATapDescription *_desc;
    AudioObjectID _tap;
    AudioObjectID _aggregate;
    AudioDeviceIOProcID _proc;
    AudioStreamBasicDescription _format;
    float *_interleaved;
}

+ (void)requestPermission {
    SystemAudioTap *probe = [[SystemAudioTap alloc] initMuting:NO error:NULL];
    if (![probe startWithHandler:^(const float *frames, uint32_t count) {
        }
                           error:NULL])
        return;
    usleep(300 * 1000);
    [probe stop];
}

- (instancetype)initWithError:(NSError **)error {
    return [self initMuting:YES error:error];
}

- (instancetype)initMuting:(BOOL)mute error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _tap = _aggregate = kAudioObjectUnknown;
    _desc = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
    _desc.name = @"btbridge";
    _desc.privateTap = YES;
    _desc.muteBehavior = mute ? CATapMutedWhenTapped : CATapUnmuted;
    OSStatus st = AudioHardwareCreateProcessTap(_desc, &_tap);
    if (st) {
        if (error) *error = tapError(@"AudioHardwareCreateProcessTap", st);
        return nil;
    }
    _interleaved = calloc(kMaxFrames * 2, sizeof(float));
    if (!_interleaved) {
        if (error) *error = tapError(@"allocating the capture buffer", -1);
        return nil; // dealloc destroys the tap
    }
    return self;
}

- (double)sampleRate {
    return _format.mSampleRate;
}

- (BOOL)startWithHandler:(SystemAudioHandler)handler error:(NSError **)error {
    if (![self startAggregate:handler error:error]) {
        [self stopAggregate]; // don't leave a half-built aggregate device behind
        return NO;
    }
    return YES;
}

- (BOOL)startAggregate:(SystemAudioHandler)handler error:(NSError **)error {
    if (_aggregate != kAudioObjectUnknown) {
        if (error) *error = tapError(@"starting an already running tap", -1);
        return NO;
    }
    NSString *outputUID = defaultOutputUID();
    if (!outputUID) {
        if (error) *error = tapError(@"finding the default output device", -1);
        return NO;
    }
    NSDictionary *agg = @{
        @kAudioAggregateDeviceNameKey : @"btbridge capture",
        @kAudioAggregateDeviceUIDKey : [NSUUID UUID].UUIDString,
        @kAudioAggregateDeviceMainSubDeviceKey : outputUID,
        @kAudioAggregateDeviceIsPrivateKey : @YES,
        @kAudioAggregateDeviceIsStackedKey : @NO,
        @kAudioAggregateDeviceTapAutoStartKey : @YES,
        @kAudioAggregateDeviceSubDeviceListKey : @[ @{@kAudioSubDeviceUIDKey : outputUID} ],
        @kAudioAggregateDeviceTapListKey :
            @[ @{@kAudioSubTapDriftCompensationKey : @YES, @kAudioSubTapUIDKey : _desc.UUID.UUIDString} ],
    };
    OSStatus st = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)agg, &_aggregate);
    if (st) {
        if (error) *error = tapError(@"AudioHardwareCreateAggregateDevice", st);
        return NO;
    }

    // The IO proc receives the aggregate's input stream format. Its rate is the
    // aggregate's, which can differ from the tap's own format: a tap keeps the rate of
    // whatever device was the default output when it was created.
    AudioObjectPropertyAddress addr = {kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput,
                                       kAudioObjectPropertyElementMain};
    AudioStreamID stream = kAudioObjectUnknown;
    UInt32 size = sizeof stream;
    st = AudioObjectGetPropertyData(_aggregate, &addr, 0, NULL, &size, &stream);
    if (!st && stream != kAudioObjectUnknown) {
        addr = (AudioObjectPropertyAddress){kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal,
                                            kAudioObjectPropertyElementMain};
        size = sizeof _format;
        st = AudioObjectGetPropertyData(stream, &addr, 0, NULL, &size, &_format);
    } else {
        addr = (AudioObjectPropertyAddress){kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal,
                                            kAudioObjectPropertyElementMain};
        size = sizeof _format;
        st = AudioObjectGetPropertyData(_tap, &addr, 0, NULL, &size, &_format);
    }
    if (st || _format.mFormatID != kAudioFormatLinearPCM || !(_format.mFormatFlags & kAudioFormatFlagIsFloat)) {
        if (error) *error = tapError(@"reading a float PCM tap format", st ?: -1);
        return NO;
    }

    BOOL nonInterleaved = (_format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 channels = _format.mChannelsPerFrame;
    float *scratch = _interleaved;
    st = AudioDeviceCreateIOProcIDWithBlock(
        &_proc, _aggregate, NULL,
        ^(const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *inTime, AudioBufferList *out,
          const AudioTimeStamp *outTime) {
            if (!in || !in->mNumberBuffers || !in->mBuffers[0].mData) return;
            const AudioBuffer *b0 = &in->mBuffers[0];
            if (!nonInterleaved && channels == 2) {
                handler((const float *)b0->mData, b0->mDataByteSize / (2 * sizeof(float)));
                return;
            }
            // Mono, non-interleaved or multichannel: fold into interleaved stereo.
            uint32_t frames = nonInterleaved ? b0->mDataByteSize / sizeof(float)
                                             : b0->mDataByteSize / (channels * sizeof(float));
            if (frames > kMaxFrames) frames = kMaxFrames;
            for (uint32_t i = 0; i < frames; i++) {
                float l, r;
                if (nonInterleaved) {
                    l = ((const float *)b0->mData)[i];
                    r = in->mNumberBuffers > 1 && in->mBuffers[1].mData ? ((const float *)in->mBuffers[1].mData)[i] : l;
                } else {
                    l = ((const float *)b0->mData)[i * channels];
                    r = channels > 1 ? ((const float *)b0->mData)[i * channels + 1] : l;
                }
                scratch[2 * i] = l;
                scratch[2 * i + 1] = r;
            }
            handler(scratch, frames);
        });
    if (st) {
        if (error) *error = tapError(@"AudioDeviceCreateIOProcIDWithBlock", st);
        return NO;
    }
    st = AudioDeviceStart(_aggregate, _proc);
    if (st) {
        if (error) *error = tapError(@"AudioDeviceStart", st);
        return NO;
    }
    return YES;
}

- (void)stop {
    [self stopAggregate];
    if (_tap != kAudioObjectUnknown) {
        AudioHardwareDestroyProcessTap(_tap);
        _tap = kAudioObjectUnknown;
    }
}

- (void)stopAggregate {
    if (_aggregate != kAudioObjectUnknown) {
        if (_proc) {
            AudioDeviceStop(_aggregate, _proc);
            AudioDeviceDestroyIOProcID(_aggregate, _proc);
            _proc = NULL;
        }
        AudioHardwareDestroyAggregateDevice(_aggregate);
        _aggregate = kAudioObjectUnknown;
    }
}

- (void)dealloc {
    [self stop];
    free(_interleaved);
}

@end
