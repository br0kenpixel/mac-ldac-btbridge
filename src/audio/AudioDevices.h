// SPDX-License-Identifier: GPL-3.0-only
// Small helpers over the Core Audio device list.

#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioDevices : NSObject

+ (AudioDeviceID)defaultOutput;
+ (BOOL)setDefaultOutput:(AudioDeviceID)device;

// The Mac's own speakers / headphone jack, or kAudioObjectUnknown if there is none.
+ (AudioDeviceID)builtInOutput;

// The output device macOS creates for Bluetooth headphones while it owns their audio
// (UID "AA-BB-CC-DD-EE-FF:output"), or kAudioObjectUnknown if it doesn't exist now.
+ (AudioDeviceID)outputForBluetoothAddress:(NSString *)address;

+ (double)nominalRateOf:(AudioDeviceID)device;
+ (BOOL)setNominalRate:(double)rate of:(AudioDeviceID)device;

@end

NS_ASSUME_NONNULL_END
