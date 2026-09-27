CLANG := xcrun clang
CFLAGS := -mmacosx-version-min=14.0 -fobjc-arc -O2 -Wall -Wextra -arch arm64 -arch x86_64
FOUNDATION := -framework Foundation -framework CoreFoundation
MOBILEDEVICE := /System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice
AIRTRAFFIC := /System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost

.PHONY: all clean

all: build/device_helper build/airtraffic_host

build:
	mkdir -p $@

build/device_helper: Sources/device_helper.m Sources/airlift_target.h Makefile | build
	$(CLANG) $(CFLAGS) $(FOUNDATION) $(MOBILEDEVICE) $< -o $@
	codesign --force --sign - $@

build/airtraffic_discovery.dylib: Sources/airtraffic_discovery.m Makefile | build
	$(CLANG) $(CFLAGS) -dynamiclib $(FOUNDATION) $(MOBILEDEVICE) -install_name @executable_path/airtraffic_discovery.dylib $< -o $@
	codesign --force --sign - $@

build/airtraffic_host: Sources/airtraffic_host.m build/airtraffic_discovery.dylib Makefile | build
	$(CLANG) $(CFLAGS) $(FOUNDATION) $(AIRTRAFFIC) -Wl,-needed_library,build/airtraffic_discovery.dylib $< -o $@
	codesign --force --sign - $@

clean:
	rm -rf build
