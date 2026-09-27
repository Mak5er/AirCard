#import <Foundation/Foundation.h>
#include <signal.h>
#include <unistd.h>

typedef void *ATHostConnectionRef;

extern ATHostConnectionRef ATHostConnectionCreate(CFStringRef deviceIdentifier);
extern void ATHostConnectionRelease(ATHostConnectionRef connection);
extern void ATHostConnectionSendHostInfo(ATHostConnectionRef connection,
                                         CFDictionaryRef hostInfo);
extern void ATHostConnectionSendSyncRequest(ATHostConnectionRef connection,
                                            CFArrayRef dataclasses,
                                            CFDictionaryRef anchors,
                                            CFDictionaryRef hostInfo);
extern void ATHostConnectionSendMetadataSyncFinished(
    ATHostConnectionRef connection,
    CFDictionaryRef syncTypes,
    CFDictionaryRef anchors);
extern void ATHostConnectionSendAssetCompleted(ATHostConnectionRef connection,
                                               CFStringRef assetIdentifier,
                                               CFStringRef dataclass,
                                               CFStringRef assetPath);
extern CFDictionaryRef ATHostConnectionReadMessage(ATHostConnectionRef connection);
extern CFStringRef ATCFMessageGetName(CFDictionaryRef message);
extern CFTypeRef ATCFMessageGetParam(CFDictionaryRef message, CFStringRef key);

static void TimeoutHandler(int signalNumber) {
    (void)signalNumber;
    const char message[] = "{\"ok\":false,\"error\":\"連線逾時\"}\n";
    (void)write(STDOUT_FILENO, message, sizeof(message) - 1);
    _exit(124);
}

static void PrintJSON(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:0
                                                     error:nil];
    if (!data) return;
    (void)write(STDOUT_FILENO, data.bytes, data.length);
    (void)write(STDOUT_FILENO, "\n", 1);
}

static NSDictionary *HostInfo(void) {
    return @{
        @"Type": @"iTunes",
        @"Version": @"13.7.0.161",
        @"MacOSVersion": NSProcessInfo.processInfo.operatingSystemVersionString,
        @"SyncHostName": @"airlift",
        @"LibraryID": NSUUID.UUID.UUIDString,
        @"SyncedDataclasses": @[ @"Book" ],
        @"SyncedAssetTypes": @[ @"Book" ],
        @"Wakeable": @NO,
    };
}

static BOOL ManifestContains(NSDictionary *manifest, NSString *identifier) {
    NSArray *books = [manifest[@"Book"] isKindOfClass:NSArray.class]
        ? manifest[@"Book"] : nil;
    for (id entry in books) {
        if ([entry isKindOfClass:NSDictionary.class] &&
            [entry[@"AssetID"] isEqual:identifier] &&
            [entry[@"IsDownload"] boolValue]) return YES;
    }
    return NO;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL removeCache = argc > 2 && strcmp(argv[1], "--remove-cache") == 0;
        if (removeCache) { argv++; argc--; }
        BOOL probeOnly = argc == 3 && strcmp(argv[1], "--probe") == 0;
        if (!probeOnly && (argc < 6 || argc % 2 != 0)) {
            PrintJSON(@{ @"ok": @NO,
                         @"error": @"用法：airtraffic_host udid id path [id path ...]" });
            return 64;
        }

        NSUInteger pairCount = probeOnly ? 0 : (NSUInteger)(argc - 2) / 2;
        if (pairCount > 2048) {
            PrintJSON(@{ @"ok": @NO, @"error": @"素材數量過多" });
            return 64;
        }

        NSString *deviceIdentifier = [NSString stringWithUTF8String:argv[probeOnly ? 2 : 1]];
        NSMutableArray<NSDictionary *> *assets = NSMutableArray.array;
        for (int index = 2; !probeOnly && index < argc; index += 2) {
            NSString *identifier = [NSString stringWithUTF8String:argv[index]];
            NSString *destination =
                [NSString stringWithUTF8String:argv[index + 1]];
            if (!identifier.length || !destination.length) {
                PrintJSON(@{ @"ok": @NO, @"error": @"參數為空" });
                return 64;
            }
            [assets addObject:@{ @"identifier": identifier,
                                 @"destination": destination }];
        }
        if (!deviceIdentifier.length) {
            PrintJSON(@{ @"ok": @NO, @"error": @"裝置識別碼為空" });
            return 64;
        }

        signal(SIGPIPE, SIG_IGN);
        signal(SIGALRM, TimeoutHandler);
        alarm(probeOnly ? 15 : 300);
        PrintJSON(@{ @"type": @"atc_status", @"message": @"正在連線 AirTraffic…" });
        ATHostConnectionRef connection =
            ATHostConnectionCreate((__bridge CFStringRef)deviceIdentifier);
        if (!connection) {
            PrintJSON(@{ @"ok": @NO,
                         @"error": @"AirTraffic 連線失敗" });
            return 2;
        }

        PrintJSON(@{ @"type": @"atc_status", @"message": @"正在等待同步許可（SyncAllowed）…" });
        BOOL syncAllowed = NO;
        for (NSUInteger index = 0; index < 8 && !syncAllowed; index++) {
            CFDictionaryRef raw = ATHostConnectionReadMessage(connection);
            if (!raw) {
                usleep(100000);
                continue;
            }
            NSString *name = (__bridge NSString *)ATCFMessageGetName(raw);
            syncAllowed = [name isEqual:@"SyncAllowed"];
            CFRelease(raw);
        }
        if (!syncAllowed) {
            ATHostConnectionRelease(connection);
            PrintJSON(@{ @"ok": @NO,
                         @"error": @"未收到同步許可 SyncAllowed" });
            return 3;
        }

        if (probeOnly) {
            ATHostConnectionRelease(connection);
            alarm(0);
            PrintJSON(@{ @"ok": @YES, @"syncAllowed": @YES });
            return 0;
        }

        NSDictionary *hostInfo = HostInfo();
        ATHostConnectionSendHostInfo(
            connection, (__bridge CFDictionaryRef)hostInfo);
        usleep(200000);
        ATHostConnectionSendSyncRequest(
            connection,
            (__bridge CFArrayRef)@[ @"Book" ],
            (__bridge CFDictionaryRef)@{},
            (__bridge CFDictionaryRef)hostInfo);

        PrintJSON(@{ @"type": @"atc_status", @"message": @"正在等待同步就緒（ReadyForSync）…" });
        BOOL ready = NO;
        for (NSUInteger index = 0; index < 12 && !ready; index++) {
            CFDictionaryRef raw = ATHostConnectionReadMessage(connection);
            if (!raw) {
                usleep(100000);
                continue;
            }
            NSString *name = (__bridge NSString *)ATCFMessageGetName(raw);
            ready = [name isEqual:@"ReadyForSync"];
            CFRelease(raw);
        }
        if (!ready) {
            ATHostConnectionRelease(connection);
            PrintJSON(@{ @"ok": @NO,
                         @"error": @"未收到同步就緒訊息 ReadyForSync" });
            return 4;
        }

        ATHostConnectionSendMetadataSyncFinished(
            connection,
            (__bridge CFDictionaryRef)@{ @"Book": @1 },
            (__bridge CFDictionaryRef)@{});

        PrintJSON(@{ @"type": @"atc_status", @"message": @"正在等待資源清單…" });
        NSDictionary *manifest = nil;
        for (NSUInteger index = 0; index < 20 && !manifest; index++) {
            CFDictionaryRef raw = ATHostConnectionReadMessage(connection);
            if (!raw) {
                usleep(100000);
                continue;
            }
            NSString *name = (__bridge NSString *)ATCFMessageGetName(raw);
            if ([name isEqual:@"AssetManifest"]) {
                id value = (__bridge id)ATCFMessageGetParam(
                    raw, CFSTR("AssetManifest"));
                if ([value isKindOfClass:NSDictionary.class])
                    manifest = [value copy];
            } else if ([name isEqual:@"SyncFailed"] ||
                       [name isEqual:@"SyncFinished"]) {
                CFRelease(raw);
                break;
            }
            CFRelease(raw);
        }

        // Cache files may already be absent; the relocated link must be present.
        // All other operations still require the complete manifest before any move.
        if (removeCache) {
            NSMutableArray *present = NSMutableArray.array;
            for (NSUInteger index = 0; index < assets.count; index++) {
                NSDictionary *asset = assets[index];
                if (index == 0 || ManifestContains(manifest, asset[@"identifier"]))
                    [present addObject:asset];
            }
            assets = present;
        }
        NSMutableArray<NSString *> *missingIdentifiers = NSMutableArray.array;
        for (NSDictionary *asset in assets)
            if (!ManifestContains(manifest, asset[@"identifier"]))
                [missingIdentifiers addObject:asset[@"identifier"]];
        NSUInteger missing = missingIdentifiers.count;
        if (missing) {
            ATHostConnectionRelease(connection);
            PrintJSON(@{ @"ok": @NO,
                         @"error": @"同步清單缺少預期素材",
                         @"missingCount": @(missing),
                         @"missingIdentifiers": missingIdentifiers });
            return 5;
        }

        for (NSUInteger index = 0; index < assets.count; index++) {
            NSDictionary *asset = assets[index];
            ATHostConnectionSendAssetCompleted(
                connection,
                (__bridge CFStringRef)asset[@"identifier"],
                CFSTR("Book"),
                (__bridge CFStringRef)asset[@"destination"]);
            if (index > 0) {
                NSString *leaf = [asset[@"destination"] lastPathComponent];
                PrintJSON(@{
                    @"type": @"atc_progress",
                    @"index": @(index),
                    @"total": @(assets.count - 1),
                    @"leaf": leaf ?: @"",
                });
            }
            if (index + 1 < assets.count) {
                if (index == 0) {
                    usleep(400000);
                } else {
                    usleep(60000);
                }
            }
        }
        sleep(2);
        ATHostConnectionRelease(connection);
        alarm(0);
        PrintJSON(@{ @"ok": @YES,
                     @"syncAllowed": @YES,
                     @"readyForSync": @YES,
                     @"fileCompleteMessages": @(assets.count) });
        return 0;
    }
}
