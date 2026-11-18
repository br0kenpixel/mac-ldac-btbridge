# bluetoothd classic XPC protocol (as used by BTBridge)

Private and undocumented. Recovered from Lucid's `LPCClassicSession` (MonitorEngine)
and verified against `bluetoothd` on macOS 15.8, Intel (MacBookPro16,3, BCM4377).
Any macOS update can change it.

## Connection

Mach service `com.apple.server.bluetooth.classic.xpc`. Every message is a dictionary
`{ kCBMsgId: int64, kCBMsgArgs: dictionary }`. Unsigned, unentitled x86_64 clients are
accepted; Bluetooth TCC permission is requested for the client app.

## Messages we send

| Id | Name (bluetoothd log) | Args |
|----|------|------|
| 1  | CBClassicMsgIdCheckIn | `kCBMsgArgName`, `kCBMsgArgType` = 3, `kCBMsgArgVersion` = 20161219, `kCBMsgArgOptions` = {} |
| 10 | CBClassicMsgIdPairingAgentRegistered | {} |
| 12 | CBClassicMsgIdPairingAgentRetrievePairedDevices | none (with reply) |
| 29 | CBClassicMsgIdOpenL2CAPChannel | `kCBMsgArgDeviceUUID`, `kCBMsgArgPSM`, `kCBMsgArgOptions` = {} |
| 30 | CBClassicMsgIdCloseL2CAPChannel | `kCBMsgArgDeviceUUID`, `kCBMsgArgPSM` |
| 44 | CBMsgIdRetrievePeerWithAddress | `kCBMsgArgAddressString` = "aa:bb:cc:dd:ee:ff" (colons only), with reply |
| 45 | CBMsgIdConnectPeer | `kCBMsgArgDeviceUUID`, options `kCBConnectOptionConnectionOptionResetDisconnectionHistory` = 1 |
| 46 | CBMsgIdCancelPeerConnection | `kCBMsgArgDeviceUUID`, options `kCBCancelConnectOptionForce` = 1 |

The reply to 44 is `{ kCBMsgArgDevices: { kCBMsgArgDeviceUUID, kCBMsgArgPairingState
(1 = paired), kCBMsgArgInternalState (2 = connected), … } }`. bluetoothd creates a
record for any address asked about, so the pairing state must be checked.

Without `ResetDisconnectionHistory`, a connect shortly after a forced disconnect is
refused (event 55, result 3).

## Events we handle

| Id | Meaning | Args |
|----|---------|------|
| 6  | state | `kCBMsgArgState` (5 = powered on) |
| 27 | channel opened | `kCBMsgArgResult` (0 = ok), `kCBMsgArgPSM`, `kCBMsgArgCID`, `kCBMsgArgOutMTU`, `kCBMsgArgSocket` (fd), `kCBMsgArgDeviceUUID` |
| 28 | channel closed | `kCBMsgArgPSM`, `kCBMsgArgDeviceUUID`, `kCBMsgArgResult` |
| 55 | peer connected | `kCBMsgArgDeviceUUID`, `kCBMsgArgResult` |
| 57 | peer disconnected | `kCBMsgArgDeviceUUID`, `kCBMsgArgResult` |

Events arrive for every device a session has seen, so they must be filtered by
`kCBMsgArgDeviceUUID`. An XPC error event means bluetoothd went away; the session and
all its channels are dead.

Channel-open results seen: 0 = ok; 1804 = no ACL to the device yet; 454 = refused
(PSM 25 already owned by macOS's A2DP).

## Sockets

The fd from event 27 is an `AF_UNIX` `SOCK_STREAM` socket that bluetoothd bridges to the
L2CAP channel (`packetBased:0`). bluetoothd re-cuts the byte stream into L2CAP SDUs as
it reads, so message boundaries are not preserved:

- AVDTP signaling has no length field; messages are split by grammar (`avdtp.c`).
- Media packets must not be written back to back (they can be merged); BTBridge paces
  them on its own clock.

Ignored for classic channels: `kCBL2CAPChannelPriority`,
`kCBManagerRequiresPacketBasedLEL2CAPInterface`, `kCBOptionServicesKey`,
`kCBMsgArgServiceMask` (macOS 15.8).

## Taking over A2DP

macOS's A2DP service reconnects ~0.5 s after the ACL comes up and owns PSM 25. On
macOS 15 there is no way to connect without it (Lucid's `kCBOptionServicesKey = [0x1000]`
is a macOS 26 feature). BTBridge therefore:

1. force-disconnects the device (46) and waits for event 57,
2. connects it (45),
3. sends an open for PSM 25 every ~15 ms. Each fails with 1804 until the ACL exists; the
   first one after that gets the AVDTP signaling channel before macOS does.

The media transport is a second PSM 25 channel, opened from a separate session after
AVDTP OPEN. Handing back = force-disconnect + connect, after which macOS restores
A2DP/HFP/AVRCP itself; `IOBluetoothDevice -openConnection` is the fallback.
