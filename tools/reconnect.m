// SPDX-License-Identifier: GPL-3.0-only
// reconnect: ask macOS to reconnect a paired device with all its normal profiles.
// Recovery for headphones left without audio, e.g. after a crash of a build that
// predates BTBridge's own crash recovery.
//
//   reconnect <aa:bb:cc:dd:ee:ff>

#import <IOBluetooth/IOBluetooth.h>

#include <unistd.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: %s <aa:bb:cc:dd:ee:ff>\n", argv[0]);
            return 2;
        }
        // IOBluetooth wants "aa-bb-cc-dd-ee-ff".
        NSString *address = [@(argv[1]) stringByReplacingOccurrencesOfString:@":" withString:@"-"];
        IOBluetoothDevice *d = [IOBluetoothDevice deviceWithAddressString:address];
        if (!d || !d.isPaired) {
            fprintf(stderr, "FAIL: %s is not a paired device\n", argv[1]);
            return 1;
        }
        // A link without audio profiles has to be dropped first, or openConnection is a no-op.
        if (d.isConnected) {
            [d closeConnection];
            sleep(1);
        }
        IOReturn r = [d openConnection];
        if (r != kIOReturnSuccess) {
            fprintf(stderr, "FAIL: openConnection returned 0x%x\n", r);
            return 1;
        }
        printf("reconnected %s\n", d.name.UTF8String ?: argv[1]);
    }
    return 0;
}
