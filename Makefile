# SPDX-License-Identifier: GPL-3.0-only
# BTBridge build. Needs only the Xcode Command Line Tools.
#
#   make                build build/release/BTBridge.app (-O3, LTO, stripped)
#   make CONFIG=debug   build build/debug/BTBridge.app (-O0, debug info, dSYM)
#   make tools          build the developer tools (caps, tone, reconnect)
#   make test           run the unit tests (test-asan: with sanitizers)
#   make install        copy the release app to /Applications
#   make TEST_HOOKS=1   compile in the --autostart/--duration/--stats test hooks

CC = clang
MIN_MACOS = 14.2
CONFIG ?= release
TEST_HOOKS ?= 0

BUILD = build/$(CONFIG)
APP = $(BUILD)/BTBridge.app

# Rewrite this checkout's absolute path to "./" in everything the compiler records
# (__FILE__, debug info), so no build embeds the builder's home directory.
PREFIX_MAP = -ffile-prefix-map=$(CURDIR)/=./

ifeq ($(CONFIG),release)
# Release: no debug info at all; -Wl,-S drops the debug map (which names the object
# files' absolute and temporary paths) and -Wl,-x local symbols.
OPT = -O3 -flto -DNDEBUG
LDFLAGS = -flto -Wl,-dead_strip -Wl,-S -Wl,-x
# Then strip everything the loader doesn't need (Xcode's "All Symbols").
STRIP = strip
else ifeq ($(CONFIG),debug)
OPT = -O0 -g
LDFLAGS =
STRIP = true
else
$(error CONFIG must be release or debug)
endif

WARNINGS = -Wall -Wextra -Wno-unused-parameter
CFLAGS = $(WARNINGS) $(OPT) $(PREFIX_MAP) -mmacosx-version-min=$(MIN_MACOS)
OBJCFLAGS = $(CFLAGS) -fobjc-arc

# A stable signing identity keeps macOS's audio-capture permission across rebuilds
# (an ad-hoc signature changes with every build). Create one with
# scripts/make-signing-cert.sh; without it the app is signed ad hoc.
SIGN_ID ?= $(shell security find-identity -p codesigning 2>/dev/null | grep -q '"BTBridge Local Signing"' \
	&& echo "BTBridge Local Signing" || echo -)

LDAC_DIR = third_party/libldac
LDAC_LIB = $(BUILD)/libldac.a
# libldac (AOSP, Apache-2.0) is built as-is, with its own warnings silenced.
LDAC_CFLAGS = -w $(OPT) $(PREFIX_MAP) -mmacosx-version-min=$(MIN_MACOS) -I$(LDAC_DIR)/inc

INCLUDES = -Isrc/bluetooth -Isrc/audio -Isrc/codec -Isrc/engine -I$(LDAC_DIR)/inc

BLUETOOTH = src/bluetooth/ClassicSession.m src/bluetooth/A2DPLink.m src/bluetooth/avdtp.c
AUDIO = src/audio/SystemAudioTap.m src/audio/AudioDevices.m
CODEC = src/codec/ldac_rtp.c
ENGINE = src/engine/BridgeEngine.m
APP_SRCS = app/main.m app/AppDelegate.m
HEADERS = $(wildcard src/*/*.h app/*.h)

FRAMEWORKS = -framework Foundation
APP_FRAMEWORKS = $(FRAMEWORKS) -framework AppKit -framework IOBluetooth -framework CoreAudio

all: $(APP)

$(BUILD):
	mkdir -p $@

$(BUILD)/ldaclib.o: $(LDAC_DIR)/src/ldaclib.c | $(BUILD)
	$(CC) $(LDAC_CFLAGS) -c $< -o $@

$(BUILD)/ldacBT.o: $(LDAC_DIR)/src/ldacBT.c | $(BUILD)
	$(CC) $(LDAC_CFLAGS) -c $< -o $@

# libtool (not ar) so the archive's symbol table covers LTO bitcode objects too.
$(LDAC_LIB): $(BUILD)/ldaclib.o $(BUILD)/ldacBT.o
	libtool -static -no_warning_for_no_symbols -o $@ $^

$(APP): $(APP_SRCS) app/Info.plist $(BLUETOOTH) $(AUDIO) $(CODEC) $(ENGINE) $(HEADERS) $(LDAC_LIB) | $(BUILD)
	rm -rf $@ $(BUILD)/BTBridge.dSYM
	mkdir -p $@/Contents/MacOS
	cp app/Info.plist $@/Contents/Info.plist
	$(CC) $(OBJCFLAGS) $(INCLUDES) -Iapp -DBTBRIDGE_TEST_HOOKS=$(TEST_HOOKS) \
		$(APP_SRCS) $(BLUETOOTH) $(AUDIO) $(CODEC) $(ENGINE) $(LDAC_LIB) \
		-o $@/Contents/MacOS/BTBridge $(LDFLAGS) $(APP_FRAMEWORKS)
	if [ -d $@/Contents/MacOS/BTBridge.dSYM ]; then mv $@/Contents/MacOS/BTBridge.dSYM $(BUILD)/; fi
	$(STRIP) $@/Contents/MacOS/BTBridge
	codesign --force --sign "$(SIGN_ID)" $@

# Developer tools.
tools: $(BUILD)/caps $(BUILD)/tone $(BUILD)/reconnect

$(BUILD)/caps: tools/caps.m src/bluetooth/ClassicSession.m src/bluetooth/avdtp.c $(HEADERS) | $(BUILD)
	$(CC) $(OBJCFLAGS) $(INCLUDES) tools/caps.m src/bluetooth/ClassicSession.m src/bluetooth/avdtp.c \
		-o $@ $(LDFLAGS) $(FRAMEWORKS)
	$(STRIP) $@

$(BUILD)/tone: tools/tone.m $(BLUETOOTH) $(CODEC) $(HEADERS) $(LDAC_LIB) | $(BUILD)
	$(CC) $(OBJCFLAGS) $(INCLUDES) tools/tone.m $(BLUETOOTH) $(CODEC) $(LDAC_LIB) -o $@ $(LDFLAGS) $(FRAMEWORKS)
	$(STRIP) $@

$(BUILD)/reconnect: tools/reconnect.m | $(BUILD)
	$(CC) $(OBJCFLAGS) $< -o $@ $(LDFLAGS) $(FRAMEWORKS) -framework IOBluetooth
	$(STRIP) $@

# Tests.
$(BUILD)/test_avdtp: tests/test_avdtp.c src/bluetooth/avdtp.c src/bluetooth/avdtp.h | $(BUILD)
	$(CC) $(CFLAGS) $(INCLUDES) tests/test_avdtp.c src/bluetooth/avdtp.c -o $@ $(LDFLAGS)

test: $(BUILD)/test_avdtp
	./$(BUILD)/test_avdtp

test-asan: tests/test_avdtp.c src/bluetooth/avdtp.c src/bluetooth/avdtp.h | $(BUILD)
	$(CC) -g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer $(PREFIX_MAP) $(INCLUDES) \
		tests/test_avdtp.c src/bluetooth/avdtp.c -o $(BUILD)/test_avdtp_asan
	./$(BUILD)/test_avdtp_asan

install:
	$(MAKE) CONFIG=release
	rm -rf /Applications/BTBridge.app
	cp -R build/release/BTBridge.app /Applications/

clean:
	rm -rf build

.PHONY: all tools test test-asan install clean
