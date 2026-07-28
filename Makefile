V2D_VERSION := 0.1.0
SIGN_IDENTITY := Developer ID Application: Left Shift Logical, LLC (KNBPD99JQM)
BUNDLE_ID := com.leftshift.ventoy

CC := cc
CFLAGS := -O2 -Wall -std=c11 -DV2D_VERSION=\"$(V2D_VERSION)\" \
          -DFATFS_INC_FORMAT_SUPPORT=0 \
          -Isrc -Ivendor/ff14/source -Ivendor/fat_io_lib -Ivendor/xz
ARCHS := -arch arm64 -arch x86_64

BUILD := build
BIN := $(BUILD)/ventoy2disk

SRCS := \
    src/main.c \
    src/install.c \
    src/disk_macos.c \
    src/partition.c \
    src/format.c \
    src/ff_diskio.c \
    src/secureboot.c \
    src/fatpart.c \
    src/payload.c \
    src/xzdec.c \
    src/crc32.c \
    vendor/ff14/source/ff.c \
    vendor/ff14/source/ffsystem.c \
    vendor/ff14/source/ffunicode.c \
    vendor/fat_io_lib/fat_access.c \
    vendor/fat_io_lib/fat_cache.c \
    vendor/fat_io_lib/fat_filelib.c \
    vendor/fat_io_lib/fat_misc.c \
    vendor/fat_io_lib/fat_string.c \
    vendor/fat_io_lib/fat_table.c \
    vendor/fat_io_lib/fat_write.c \
    vendor/xz/xz_crc32.c \
    vendor/xz/xz_dec_lzma2.c \
    vendor/xz/xz_dec_stream.c

OBJS := $(patsubst %.c,$(BUILD)/%.o,$(SRCS))

APP := $(BUILD)/Ventoy2Disk.app
APP_ID := com.leftshift.ventoy.app
SWIFT_SRCS := $(wildcard app/Sources/*.swift)

all: $(BIN) sign

HDRS := $(wildcard src/*.h vendor/ff14/source/*.h vendor/fat_io_lib/*.h vendor/xz/*.h)

$(BUILD)/%.o: %.c $(HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(ARCHS) -c $< -o $@

$(BIN): $(OBJS)
	$(CC) $(ARCHS) $(OBJS) -o $@

sign: $(BIN)
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q "$(SIGN_IDENTITY)"; then \
	    codesign --force --options runtime --timestamp \
	        --identifier $(BUNDLE_ID) --sign "$(SIGN_IDENTITY)" $(BIN); \
	    echo "signed $(BIN) as $(BUNDLE_ID)"; \
	else \
	    echo "signing identity not found; leaving $(BIN) unsigned"; \
	fi

SPARKLE_VERSION := 2.9.4
SPARKLE_DIR := $(BUILD)/Sparkle
SPARKLE_FW := $(SPARKLE_DIR)/Sparkle.framework

$(SPARKLE_FW):
	mkdir -p $(SPARKLE_DIR)
	curl -sfL https://github.com/sparkle-project/Sparkle/releases/download/$(SPARKLE_VERSION)/Sparkle-$(SPARKLE_VERSION).tar.xz | tar -xJ -C $(SPARKLE_DIR)

ICON := $(BUILD)/AppIcon.icns

$(ICON): app/icon.swift
	rm -rf $(BUILD)/AppIcon.iconset
	mkdir -p $(BUILD)/AppIcon.iconset
	swift app/icon.swift $(BUILD)/AppIcon.iconset
	iconutil -c icns $(BUILD)/AppIcon.iconset -o $(ICON)

app: $(BIN) sign $(SWIFT_SRCS) app/Info.plist $(ICON) $(SPARKLE_FW)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/Frameworks
	swiftc -O -parse-as-library -target arm64-apple-macos14.0 -F $(SPARKLE_DIR) \
	    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
	    $(SWIFT_SRCS) -o $(BUILD)/gui-arm64
	swiftc -O -parse-as-library -target x86_64-apple-macos14.0 -F $(SPARKLE_DIR) \
	    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
	    $(SWIFT_SRCS) -o $(BUILD)/gui-x86_64
	lipo -create -output $(APP)/Contents/MacOS/Ventoy2Disk $(BUILD)/gui-arm64 $(BUILD)/gui-x86_64
	sed 's/@VERSION@/$(V2D_VERSION)/g' app/Info.plist > $(APP)/Contents/Info.plist
	cp $(BIN) $(APP)/Contents/Resources/ventoy2disk
	cp $(ICON) $(APP)/Contents/Resources/AppIcon.icns
	ditto $(SPARKLE_FW) $(APP)/Contents/Frameworks/Sparkle.framework
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q "$(SIGN_IDENTITY)"; then \
	    codesign --force --options runtime --timestamp --deep \
	        --sign "$(SIGN_IDENTITY)" $(APP)/Contents/Frameworks/Sparkle.framework; \
	    codesign --force --options runtime --timestamp \
	        --identifier $(APP_ID) --sign "$(SIGN_IDENTITY)" $(APP); \
	    echo "signed $(APP) as $(APP_ID)"; \
	else \
	    echo "signing identity not found; leaving $(APP) unsigned"; \
	fi

dist: app
	ditto -c -k --sequesterRsrc --keepParent $(APP) $(BUILD)/Ventoy2Disk-$(V2D_VERSION).zip
	@echo "release archive: $(BUILD)/Ventoy2Disk-$(V2D_VERSION).zip"
	@$(SPARKLE_DIR)/bin/sign_update $(BUILD)/Ventoy2Disk-$(V2D_VERSION).zip

clean:
	rm -rf $(BUILD)

.PHONY: all sign app dist clean
