#import <Foundation/Foundation.h>

// AirTrafficHost still calls the legacy subscription API, which omits
// RemoteXPC devices on current macOS. Use the same discovery options as
// device_helper while retaining AirTraffic's callback and subscription lifetime.
// This dylib is linked only into our airtraffic_host helper.
typedef void (*DeviceCallback)(void *, void *);
extern int AMDeviceNotificationSubscribe(DeviceCallback, int, unsigned int,
                                         void *, void **);
extern int AMDeviceNotificationSubscribeWithOptions(DeviceCallback, int,
    unsigned int, void *, void **, CFDictionaryRef);

static int SubscribeWithRemoteDevices(DeviceCallback callback, int unused,
    unsigned int connectionType, void *context, void **subscription) {
    return AMDeviceNotificationSubscribeWithOptions(
        callback, unused, connectionType, context, subscription,
        (__bridge CFDictionaryRef)@{
            @"NotificationOptionSearchForPairedDevices": @YES,
            @"NotificationOptionSearchForPairedDevicesViaDirectConnectionsOnly": @YES,
            @"NotificationOptionSearchForWiFiPairableDevices": @NO,
            @"NotificationOptionEnableRemoteXPC": @YES,
            @"NotificationOptionEnableUSBMux": @YES,
        });
}

// Interposition must live in a dylib: placing this in the main executable does
// not redirect AirTrafficHost's imported subscription call on current macOS.
__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } discovery = {
    (const void *)SubscribeWithRemoteDevices,
    (const void *)AMDeviceNotificationSubscribe,
};
