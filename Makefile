SHELL := /bin/sh
CC := xcrun --sdk macosx clang
PKG_CONFIG ?= pkg-config
VID ?= 0x20d6
PID ?= 0xa01a
APP := build/SonicController.app
BINARY := $(APP)/Contents/MacOS/SonicController
SOURCE := src/SonicController.m
USB_CFLAGS = $(shell $(PKG_CONFIG) --cflags libusb-1.0)
USB_LIBS = $(shell $(PKG_CONFIG) --libs libusb-1.0)

.PHONY: all check-deps test clean
all: $(BINARY)

check-deps:
	@test "$$(uname -s)" = Darwin || { echo "This app requires macOS." >&2; exit 1; }
	@command -v $(PKG_CONFIG) >/dev/null || { echo "Install dependencies: brew install libusb pkgconf" >&2; exit 1; }
	@$(PKG_CONFIG) --exists libusb-1.0 || { echo "libusb is missing: brew install libusb pkgconf" >&2; exit 1; }
	@xcrun --find clang >/dev/null

$(BINARY): $(SOURCE) resources/Info.plist Makefile | check-deps
	mkdir -p "$(APP)/Contents/MacOS"
	$(CC) -std=gnu11 -fobjc-arc -O2 -Wall -Wextra -Werror \
		-mmacosx-version-min=14.0 $(USB_CFLAGS) \
		-DCONTROLLER_VID=$(VID) -DCONTROLLER_PID=$(PID) \
		$(SOURCE) $(USB_LIBS) -framework Cocoa -framework ApplicationServices \
		-o "$(BINARY)"
	cp resources/Info.plist "$(APP)/Contents/Info.plist"
	codesign --force --sign - "$(APP)"
	codesign --verify --strict "$(APP)"

test: $(BINARY)
	"$(BINARY)" --self-test

clean:
	rm -rf build
