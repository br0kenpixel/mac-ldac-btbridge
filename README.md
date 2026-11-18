# BTBridge

Stream your Mac's audio to Bluetooth headphones over **LDAC**: a codec macOS doesn't
support. BTBridge is a small menu bar app; no kernel extension, no driver, System
Integrity Protection stays on.

Tested on an Intel MacBook Pro (MacBookPro16,3, macOS 15.8) with Sony WH-1000XM6.
It relies on private, undocumented macOS interfaces; see [Caveats](#caveats).

> ⚠️ AI Disclosure
> This project was made entirely with Claude Opus 5.5 with pretty much zero manual
> inspection for my own personal use. I do not guarantee that it will work on your
> Mac or with your headphones, nor will I give you any kind of support. Take everything
> as-is.

## How it works

macOS has no LDAC encoder, so BTBridge doesn't change macOS's Bluetooth audio; it takes
the audio stream over and runs it itself:

1. **Capture.** A Core Audio process tap (macOS 14.2+) captures everything the Mac
   plays and mutes it locally.
2. **Take over the headphones.** Through `bluetoothd`'s private classic-Bluetooth XPC
   service, BTBridge briefly disconnects the headphones, reconnects them, and opens the
   A2DP signaling channel (L2CAP PSM 25) about half a second before macOS's own A2DP
   service would. The link and the other profiles stay with macOS.
3. **Negotiate LDAC.** BTBridge speaks AVDTP itself: discovers the headphones' endpoints,
   configures their LDAC endpoint, opens the media channel and starts the stream.
4. **Encode and send.** Captured audio is encoded with libldac (AOSP) and sent as RTP
   packets, paced evenly in real time.

Stopping hands the headphones back: they reconnect normally and reappear as a macOS
audio device. While BTBridge streams they don't appear as an output; the Mac's speakers
are the (muted) default output that apps play into.

The private protocol details are in [docs/protocol.md](docs/protocol.md).

## Requirements

- macOS 14.2 or later (tested on 15.8, Intel)
- Headphones with LDAC (e.g. Sony WH/WF-1000X series)
- Xcode Command Line Tools (`xcode-select --install`)

## Build

```sh
git clone --recurse-submodules https://github.com/br0kenpixel/mac-ldac-btbridge.git
cd mac-ldac-btbridge
./scripts/make-signing-cert.sh   # optional, see below
make                             # build/release/BTBridge.app
make install                     # optional: copy to /Applications
```

macOS ties the "System Audio Recording" permission to the app's code signature. An
ad-hoc signature changes on every build, so macOS would ask again after each rebuild.
`scripts/make-signing-cert.sh` creates a self-signed certificate in your login keychain
that the Makefile then uses, so the permission sticks.

Release builds (the default) are compiled with `-O3` and LTO, carry no debug info, and
are stripped; source paths are recorded relative to the repo, so binaries don't contain
the builder's file paths. `make CONFIG=debug` builds an unoptimised build with a dSYM in
`build/debug/`.

Other targets: `make tools`, `make test`, `make test-asan`, `make clean`.

## Use

1. Open BTBridge. A headphones icon appears in the menu bar. On first launch, allow
   Bluetooth access and System Audio Recording.
2. Choose **Headphones**, **LDAC Quality** and **Sample Rate**.
3. Click **Start LDAC**. The headphones drop out for 3–5 seconds and come back on LDAC.
4. Click **Stop** (or quit) to hand them back to macOS.

| Quality | Bitrate | |
|---|---|---|
| High | 990 kbps | best quality, most sensitive to interference |
| Standard | 660 kbps | |
| Connection-first | 330 kbps | most robust |

96 kHz only helps with genuinely high-resolution sources and is best paired with High.
While streaming, the Mac's speakers run at the chosen rate; they're restored afterwards.

## Caveats

- **Private APIs.** The `bluetoothd` interface is undocumented and was reverse-engineered;
  any macOS update can break it.
- **No volume keys, mic or calls while streaming.** macOS doesn't see the headphones as
  an audio device during streaming; use the headphones' own controls.
- **990 kbps can glitch.** BTBridge's channel doesn't get the radio and Wi-Fi coexistence
  priority macOS gives its own A2DP stream. Use 660 or 330 kbps if you hear dropouts.
- **LDAC only.** There's no SBC/AAC/aptX fallback.

## Troubleshooting

- **Headphones stuck without audio** (e.g. after a crash): relaunch BTBridge. It restores
  them and the speakers' sample rate on launch. Otherwise reconnect them from the
  Bluetooth menu, or `make tools && build/release/reconnect <address>`.
- **No sound but "Streaming"**: check System Settings → Privacy & Security → Screen &
  System Audio Recording → System Audio Recording Only → BTBridge is on.

## Layout

```
app/              menu bar app (AppDelegate, Info.plist)
src/bluetooth/    bluetoothd XPC client, AVDTP signaling, A2DP stream setup
src/audio/        system audio capture, Core Audio device helpers, PCM ring buffer
src/codec/        libldac wrapper + RTP packetizer
src/engine/       BridgeEngine: ties capture, Bluetooth and encoding together
tools/            caps (list codecs), tone (LDAC test tone), reconnect
tests/            AVDTP parser tests
docs/             protocol notes
third_party/      libldac (git submodule)
```

## License

BTBridge is free software, licensed under the GNU General Public License v3.0 only
(`GPL-3.0-only`); see [LICENSE](LICENSE). libldac, in `third_party/libldac`, keeps its
own Apache-2.0 license, which is compatible with GPLv3.

## Credits

- [libldac](https://android.googlesource.com/platform/external/libldac) from the Android
  Open Source Project (Apache-2.0); see its `LICENSE` and `NOTICE`.
- The take-over approach was learned from studying the Lucid app's macOS 26 design and
  adapted for macOS 15.

LDAC is a trademark of Sony Corporation. This project is not affiliated with Sony or
Apple. The libldac NOTICE states that products using LDAC require certification by
Sony.
