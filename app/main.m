// SPDX-License-Identifier: GPL-3.0-only
// BTBridge: menu bar app that streams the Mac's audio to Bluetooth headphones over LDAC.

#import <AppKit/AppKit.h>

#include <signal.h>

#import "AppDelegate.h"

int main(int argc, const char *argv[]) {
    // Writes to a socket bluetoothd has closed must fail with EPIPE rather than kill
    // the app before it can hand the headphones back. (Sockets also set SO_NOSIGPIPE.)
    signal(SIGPIPE, SIG_IGN);
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        [app run];
    }
    return 0;
}
