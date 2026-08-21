IOS_SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC := clang

CFLAGS := \
	-arch arm64 \
	-isysroot $(IOS_SDK) \
	-fobjc-arc \
	-fmodules \
	-miphoneos-version-min=15.0 \
	-O2 \
	-Wno-deprecated-declarations \
	-Wno-unused-variable \
	-Wno-unused-function

LDFLAGS := \
	-dynamiclib \
	-framework UIKit \
	-framework Foundation \
	-framework Security \
	-framework CoreFoundation \
	-framework QuartzCore \
	-Wl,-no_fixup_chains \
	-install_name @rpath/WWRedGrab.dylib

TARGET := WWRedGrab.dylib
SRCS   := WWRedGrab.m

all: $(TARGET)

$(TARGET): $(SRCS)
	$(CC) $(CFLAGS) $(SRCS) -o $@ $(LDFLAGS)
	@echo "[*] Build OK: $(TARGET)"
	@file $@
	@ls -lh $@
	@otool -L $@ | head -20
	@command -v ldid >/dev/null 2>&1 && ldid -S $@ || echo "[!] ldid not found, skip adhoc sign"

clean:
	rm -f $(TARGET)
