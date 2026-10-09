CLANG := xcrun clang
# Without an explicit minimum the helpers inherit whatever macOS built them, so
# a build made on a newer Mac quietly refuses to run on the versions the app
# says it supports. Keep this in step with LSMinimumSystemVersion in build.sh.
MACOS_MIN := 13.0
CFLAGS := -fobjc-arc -O2 -Wall -Wextra -arch arm64 -arch x86_64 -mmacosx-version-min=$(MACOS_MIN)
FOUNDATION := -framework Foundation -framework CoreFoundation
MOBILEDEVICE := /System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice
AIRTRAFFIC := /System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost

.PHONY: all clean

all: build/device_helper build/airtraffic_host

build:
	mkdir -p $@

build/device_helper: Sources/device_helper.m Sources/airlift_target.h Sources/device_discovery.h Sources/os_trace.h | build
	$(CLANG) $(CFLAGS) $(FOUNDATION) $(MOBILEDEVICE) $< -o $@
	codesign --force --sign - $@

build/airtraffic_host: Sources/airtraffic_host.m | build
	$(CLANG) $(CFLAGS) $(FOUNDATION) $(AIRTRAFFIC) $< -o $@
	codesign --force --sign - $@

clean:
	rm -rf build
