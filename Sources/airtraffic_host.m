#import <Foundation/Foundation.h>
#include <signal.h>
#include <string.h>
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
    const char message[] = "{\"ok\":false,\"error\":\"timeout\"}\n";
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

static BOOL ManifestHasPNGForPDF(NSDictionary *manifest, NSString *pdfIdentifier) {
    NSString *parent = [pdfIdentifier stringByDeletingLastPathComponent];
    for (NSString *leaf in @[ @"cardBackgroundCombined@3x.png",
                              @"cardBackgroundCombined@2x.png" ]) {
        NSString *candidate = [parent stringByAppendingPathComponent:leaf];
        if (ManifestContains(manifest, candidate)) return YES;
    }
    return NO;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // --fallback-pdf skips assets the pass does not contain, so a pass
        // without PDF artwork still syncs its PNG artwork and pass.json.
        BOOL fallbackPDF = argc > 2 &&
            strcmp(argv[argc - 1], "--fallback-pdf") == 0;
        int assetsEnd = fallbackPDF ? argc - 1 : argc;
        if (assetsEnd < 6 || (assetsEnd - 2) % 2 != 0) {
            PrintJSON(@{ @"ok": @NO,
                         @"error": @"usage: airtraffic_host udid id path [id path ...]" });
            return 64;
        }

        NSUInteger pairCount = (NSUInteger)(assetsEnd - 2) / 2;
        if (pairCount > 2048) {
            PrintJSON(@{ @"ok": @NO, @"error": @"too many assets" });
            return 64;
        }

        NSString *deviceIdentifier = [NSString stringWithUTF8String:argv[1]];
        NSMutableArray<NSDictionary *> *assets = NSMutableArray.array;
        for (int index = 2; index < assetsEnd; index += 2) {
            NSString *identifier = [NSString stringWithUTF8String:argv[index]];
            NSString *destination =
                [NSString stringWithUTF8String:argv[index + 1]];
            if (!identifier.length || !destination.length) {
                PrintJSON(@{ @"ok": @NO, @"error": @"empty argument" });
                return 64;
            }
            [assets addObject:@{ @"identifier": identifier,
                                 @"destination": destination }];
        }
        if (!deviceIdentifier.length) {
            PrintJSON(@{ @"ok": @NO, @"error": @"empty device identifier" });
            return 64;
        }

        signal(SIGPIPE, SIG_IGN);
        signal(SIGALRM, TimeoutHandler);
        alarm(300);
        ATHostConnectionRef connection =
            ATHostConnectionCreate((__bridge CFStringRef)deviceIdentifier);
        if (!connection) {
            PrintJSON(@{ @"ok": @NO,
                         @"error": @"AirTraffic connection failed" });
            return 2;
        }

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
                         @"error": @"SyncAllowed not observed" });
            return 3;
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
                         @"error": @"ReadyForSync not observed" });
            return 4;
        }

        ATHostConnectionSendMetadataSyncFinished(
            connection,
            (__bridge CFDictionaryRef)@{ @"Book": @1 },
            (__bridge CFDictionaryRef)@{});

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

        NSMutableArray<NSDictionary *> *availableAssets = NSMutableArray.array;
        NSUInteger missing = 0;
        for (NSDictionary *asset in assets) {
            NSString *identifier = asset[@"identifier"];
            BOOL present = ManifestContains(manifest, identifier);
            BOOL skipFallbackPDF = fallbackPDF &&
                [[identifier lastPathComponent] isEqual:@"cardBackgroundCombined.pdf"] &&
                ManifestHasPNGForPDF(manifest, identifier);
            if (present && !skipFallbackPDF)
                [availableAssets addObject:asset];
            else if (!present)
                missing++;
        }
        if (missing && !fallbackPDF) {
            ATHostConnectionRelease(connection);
            PrintJSON(@{ @"ok": @NO,
                         @"error": @"expected assets absent from manifest",
                         @"missingCount": @(missing) });
            return 5;
        }

        for (NSUInteger index = 0; index < availableAssets.count; index++) {
            NSDictionary *asset = availableAssets[index];
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
            if (index + 1 < availableAssets.count) {
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
                     @"fileCompleteMessages": @(availableAssets.count),
                     @"missing": @(missing) });
        return 0;
    }
}
