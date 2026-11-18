// SPDX-License-Identifier: GPL-3.0-only
#import "AudioDevices.h"

#include <math.h>
#include <unistd.h>

static AudioObjectPropertyAddress globalAddress(AudioObjectPropertySelector sel) {
    return (AudioObjectPropertyAddress){sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
}

static NSArray<NSNumber *> *allDevices(void) {
    AudioObjectPropertyAddress addr = globalAddress(kAudioHardwarePropertyDevices);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size)) return @[];
    UInt32 n = size / sizeof(AudioDeviceID);
    AudioDeviceID ids[n ? n : 1];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, ids)) return @[];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:n];
    for (UInt32 i = 0; i < n; i++) [out addObject:@(ids[i])];
    return out;
}

static BOOL hasOutput(AudioDeviceID dev) {
    AudioObjectPropertyAddress addr = {kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput,
                                       kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    return AudioObjectGetPropertyDataSize(dev, &addr, 0, NULL, &size) == 0 && size > 0;
}

static UInt32 transportOf(AudioDeviceID dev) {
    AudioObjectPropertyAddress addr = globalAddress(kAudioDevicePropertyTransportType);
    UInt32 t = 0, size = sizeof t;
    AudioObjectGetPropertyData(dev, &addr, 0, NULL, &size, &t);
    return t;
}

static NSString *stringProperty(AudioDeviceID dev, AudioObjectPropertySelector sel) {
    AudioObjectPropertyAddress addr = globalAddress(sel);
    CFStringRef s = NULL;
    UInt32 size = sizeof s;
    if (AudioObjectGetPropertyData(dev, &addr, 0, NULL, &size, &s) || !s) return nil;
    return CFBridgingRelease(s);
}

@implementation AudioDevices

+ (AudioDeviceID)defaultOutput {
    AudioObjectPropertyAddress addr = globalAddress(kAudioHardwarePropertyDefaultOutputDevice);
    AudioDeviceID dev = kAudioObjectUnknown;
    UInt32 size = sizeof dev;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &dev);
    return dev;
}

+ (BOOL)setDefaultOutput:(AudioDeviceID)device {
    AudioObjectPropertyAddress addr = globalAddress(kAudioHardwarePropertyDefaultOutputDevice);
    return AudioObjectSetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, sizeof device, &device) == 0;
}

+ (AudioDeviceID)builtInOutput {
    for (NSNumber *n in allDevices()) {
        AudioDeviceID dev = n.unsignedIntValue;
        if (hasOutput(dev) && transportOf(dev) == kAudioDeviceTransportTypeBuiltIn) return dev;
    }
    return kAudioObjectUnknown;
}

+ (AudioDeviceID)outputForBluetoothAddress:(NSString *)address {
    NSString *uid = [[address.uppercaseString stringByReplacingOccurrencesOfString:@":" withString:@"-"]
        stringByAppendingString:@":output"];
    for (NSNumber *n in allDevices()) {
        AudioDeviceID dev = n.unsignedIntValue;
        if ([stringProperty(dev, kAudioDevicePropertyDeviceUID) isEqualToString:uid]) return dev;
    }
    return kAudioObjectUnknown;
}

+ (double)nominalRateOf:(AudioDeviceID)device {
    AudioObjectPropertyAddress addr = globalAddress(kAudioDevicePropertyNominalSampleRate);
    Float64 rate = 0;
    UInt32 size = sizeof rate;
    AudioObjectGetPropertyData(device, &addr, 0, NULL, &size, &rate);
    return rate;
}

+ (BOOL)setNominalRate:(double)rate of:(AudioDeviceID)device {
    if (lround([self nominalRateOf:device]) == lround(rate)) return YES;
    AudioObjectPropertyAddress addr = globalAddress(kAudioDevicePropertyNominalSampleRate);
    Float64 r = rate;
    if (AudioObjectSetPropertyData(device, &addr, 0, NULL, sizeof r, &r)) return NO;
    // The change is applied asynchronously.
    for (int i = 0; i < 40 && lround([self nominalRateOf:device]) != lround(rate); i++) usleep(25 * 1000);
    return lround([self nominalRateOf:device]) == lround(rate);
}

@end
