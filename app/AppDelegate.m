// SPDX-License-Identifier: GPL-3.0-only
// Test hooks, compiled in only with `make TEST_HOOKS=1` (all optional):
//   --autostart <aa:bb:cc:dd:ee:ff>   start streaming to this device at launch
//   --quality <0|1|2>                 HQ / SQ / MQ for --autostart
//   --rate <48000|96000>              sample rate for --autostart
//   --duration <seconds>              stop and quit after this long
//   --stats <path>                    append a statistics line every second

#import "AppDelegate.h"

#import <IOBluetooth/IOBluetooth.h>

#import "BridgeEngine.h"
#import "SystemAudioTap.h"

static NSString *const kDeviceKey = @"deviceAddress";
static NSString *const kQualityKey = @"quality";
static NSString *const kRateKey = @"sampleRate";

@interface AppDelegate () <NSMenuDelegate>
@end

@implementation AppDelegate {
    NSStatusItem *_item;
    NSMenu *_menu;
    NSMenuItem *_statusLine;
    NSMenuItem *_toggle;
    NSMenu *_devicesMenu;
    NSMenu *_qualityMenu;
    NSMenu *_rateMenu;
    BridgeEngine *_engine;
    BridgeState _state;
    NSString *_message;
    NSFileHandle *_stats;
    NSTimer *_statsTimer;
}

- (NSString *)argument:(NSString *)flag {
#if BTBRIDGE_TEST_HOOKS
    NSArray *args = NSProcessInfo.processInfo.arguments;
    NSUInteger i = [args indexOfObject:flag];
    return i != NSNotFound && i + 1 < args.count ? args[i + 1] : nil;
#else
    return nil;
#endif
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    _engine = [BridgeEngine new];
    _message = @"Idle";
    __weak AppDelegate *weakSelf = self;
    _engine.onStateChange = ^(BridgeState state, NSString *message) {
        [weakSelf engineState:state message:message];
    };
    [self buildMenu];
    [_engine recoverFromPreviousRun];

    // The Bluetooth link doesn't survive sleep; hand the headphones back cleanly first.
    // Blocking here is intended: macOS waits (up to ~30 s) for this handler to return.
    [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceWillSleepNotification
                                                                object:nil
                                                                 queue:NSOperationQueue.mainQueue
                                                            usingBlock:^(NSNotification *n) {
                                                                AppDelegate *strongSelf = weakSelf;
                                                                if (strongSelf && strongSelf->_engine.state != BridgeStateIdle)
                                                                    [strongSelf->_engine stopAndWait];
                                                            }];

    NSString *statsPath = [self argument:@"--stats"];
    if (statsPath) {
        [[NSFileManager defaultManager] createFileAtPath:statsPath contents:nil attributes:nil];
        _stats = [NSFileHandle fileHandleForWritingAtPath:statsPath];
        _statsTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) {
            [weakSelf writeStats];
        }];
    }
    // Get the audio-capture prompt out of the way before anything touches the headphones.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [SystemAudioTap requestPermission];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf autostartIfRequested];
        });
    });
}

- (void)autostartIfRequested {
    NSString *autostart = [self argument:@"--autostart"];
    if (!autostart) return;
    NSString *q = [self argument:@"--quality"], *r = [self argument:@"--rate"];
    [_engine startWithAddress:autostart quality:q ? q.intValue : [self quality] sampleRate:r ? r.intValue : [self sampleRate]];
    NSString *duration = [self argument:@"--duration"];
    if (duration)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           [NSApp terminate:nil];
                       });
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (_engine.state == BridgeStateIdle) {
        [self writeStats];
        return NSTerminateNow;
    }
    // Give the headphones back to macOS first (off the main thread), then quit again.
    // NSTerminateLater isn't used: its reply block never got serviced on the main queue.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self->_engine stopAndWait];
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp terminate:nil];
        });
    });
    return NSTerminateCancel;
}

- (void)writeStats {
    if (!_stats) return;
    NSString *line = [NSString stringWithFormat:@"%@ state=%ld %@ | %@\n", [NSDate date], (long)_state, _message,
                                                [_engine statistics]];
    [_stats writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
}

#pragma mark - Settings

- (NSString *)deviceAddress {
    return [NSUserDefaults.standardUserDefaults stringForKey:kDeviceKey];
}

- (int)quality {
    return (int)[NSUserDefaults.standardUserDefaults integerForKey:kQualityKey];
}

- (int)sampleRate {
    NSInteger rate = [NSUserDefaults.standardUserDefaults integerForKey:kRateKey];
    return rate == 96000 ? 96000 : 48000;
}

#pragma mark - Menu

- (void)buildMenu {
    _item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    _menu = [NSMenu new];
    _menu.delegate = self;

    _statusLine = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    _statusLine.enabled = NO;
    [_menu addItem:_statusLine];
    [_menu addItem:NSMenuItem.separatorItem];

    _toggle = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(toggle:) keyEquivalent:@""];
    _toggle.target = self;
    [_menu addItem:_toggle];

    NSMenuItem *devices = [[NSMenuItem alloc] initWithTitle:@"Headphones" action:nil keyEquivalent:@""];
    _devicesMenu = [NSMenu new];
    devices.submenu = _devicesMenu;
    [_menu addItem:devices];

    NSMenuItem *quality = [[NSMenuItem alloc] initWithTitle:@"LDAC Quality" action:nil keyEquivalent:@""];
    _qualityMenu = [NSMenu new];
    NSArray *names = @[ @"High (990 kbps)", @"Standard (660 kbps)", @"Connection-first (330 kbps)" ];
    for (NSUInteger i = 0; i < names.count; i++) {
        NSMenuItem *q = [[NSMenuItem alloc] initWithTitle:names[i] action:@selector(pickQuality:) keyEquivalent:@""];
        q.target = self;
        q.tag = (NSInteger)i;
        [_qualityMenu addItem:q];
    }
    quality.submenu = _qualityMenu;
    [_menu addItem:quality];

    NSMenuItem *rate = [[NSMenuItem alloc] initWithTitle:@"Sample Rate" action:nil keyEquivalent:@""];
    _rateMenu = [NSMenu new];
    for (NSNumber *hz in @[ @48000, @96000 ]) {
        NSMenuItem *r = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%d kHz", hz.intValue / 1000]
                                                   action:@selector(pickRate:)
                                            keyEquivalent:@""];
        r.target = self;
        r.tag = hz.integerValue;
        [_rateMenu addItem:r];
    }
    rate.submenu = _rateMenu;
    [_menu addItem:rate];

    [_menu addItem:NSMenuItem.separatorItem];
    [_menu addItemWithTitle:@"Quit BTBridge" action:@selector(terminate:) keyEquivalent:@"q"];
    _item.menu = _menu;
    [self refresh];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [self refresh];
}

- (void)refresh {
    BOOL streaming = _state == BridgeStateStreaming;
    BOOL busy = _state == BridgeStateConnecting || _state == BridgeStateStopping;
    NSString *symbol = streaming ? @"headphones.circle.fill" : @"headphones";
    _item.button.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:@"BTBridge"];
    _statusLine.title = _message;
    _toggle.title = streaming ? @"Stop" : @"Start LDAC";
    _toggle.enabled = !busy && (streaming || self.deviceAddress != nil);

    [_devicesMenu removeAllItems];
    NSString *selected = self.deviceAddress;
    for (IOBluetoothDevice *d in IOBluetoothDevice.pairedDevices) {
        if (d.deviceClassMajor != kBluetoothDeviceClassMajorAudio) continue;
        NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:d.name ?: d.addressString
                                                    action:@selector(pickDevice:)
                                             keyEquivalent:@""];
        mi.target = self;
        mi.representedObject = d.addressString;
        mi.state = [d.addressString caseInsensitiveCompare:selected ?: @""] == NSOrderedSame ? NSControlStateValueOn
                                                                                             : NSControlStateValueOff;
        mi.enabled = !streaming && !busy;
        [_devicesMenu addItem:mi];
    }
    if (!_devicesMenu.numberOfItems) [_devicesMenu addItemWithTitle:@"No paired headphones" action:nil keyEquivalent:@""];

    for (NSMenuItem *q in _qualityMenu.itemArray) {
        q.state = q.tag == self.quality ? NSControlStateValueOn : NSControlStateValueOff;
        q.enabled = !streaming && !busy;
    }
    for (NSMenuItem *r in _rateMenu.itemArray) {
        r.state = r.tag == self.sampleRate ? NSControlStateValueOn : NSControlStateValueOff;
        r.enabled = !streaming && !busy;
    }
}

- (void)engineState:(BridgeState)state message:(NSString *)message {
    _state = state;
    _message = message;
    [self refresh];
}

- (void)toggle:(id)sender {
    if (_state == BridgeStateStreaming) [_engine stop];
    else if (self.deviceAddress)
        [_engine startWithAddress:self.deviceAddress quality:self.quality sampleRate:self.sampleRate];
}

- (void)pickDevice:(NSMenuItem *)sender {
    [NSUserDefaults.standardUserDefaults setObject:sender.representedObject forKey:kDeviceKey];
    [self refresh];
}

- (void)pickQuality:(NSMenuItem *)sender {
    [NSUserDefaults.standardUserDefaults setInteger:sender.tag forKey:kQualityKey];
    [self refresh];
}

- (void)pickRate:(NSMenuItem *)sender {
    [NSUserDefaults.standardUserDefaults setInteger:sender.tag forKey:kRateKey];
    [self refresh];
}

@end
