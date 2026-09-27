// Use the real callback with a fake device identifier; no device sessions open.
#define AMDeviceCopyDeviceIdentifier TestCopyDeviceIdentifier
#define main DeviceHelperMain
#include "../Sources/device_helper.m"
#undef main
#undef AMDeviceCopyDeviceIdentifier
#include <assert.h>

CFStringRef TestCopyDeviceIdentifier(AMDeviceRef device) {
    return CFRetain((CFStringRef)device);
}

static void *SendNotifications(void *unused) {
    (void)unused;
    AMDeviceNotificationCallbackInfo info = {0};
    info.device = CFSTR("test-device");
    info.message = 1;
    for (int i = 0; i < 1000; i++) DeviceCallback(&info, NULL);
    return NULL;
}

int main(void) {
    @autoreleasepool {
        for (int iteration = 0; iteration < 100; iteration++) {
            TargetIdentifier = CFStringCreateCopy(NULL, CFSTR("test-device"));
            TargetDiscoveryActive = YES;
            TargetDevice = NULL;
            // A matching notification must still find a target.
            SendNotifications(NULL);
            assert(TargetDevice != NULL);
            pthread_t workers[2];
            for (int i = 0; i < 2; i++) assert(pthread_create(&workers[i], NULL, SendNotifications, NULL) == 0);
            pthread_mutex_lock(&TargetLock);
            TargetDiscoveryActive = NO;
            CFRelease(TargetDevice);
            TargetDevice = NULL;
            CFRelease(TargetIdentifier);
            TargetIdentifier = NULL;
            pthread_mutex_unlock(&TargetLock);
            for (int i = 0; i < 2; i++) pthread_join(workers[i], NULL);
            // Queued notifications after unsubscribe cannot resurrect state.
            SendNotifications(NULL);
            assert(TargetDevice == NULL);
        }
    }
    puts("callback teardown checks passed");
    return 0;
}
