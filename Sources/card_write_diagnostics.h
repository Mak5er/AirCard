#ifndef CARD_WRITE_DIAGNOSTICS_H
#define CARD_WRITE_DIAGNOSTICS_H

#include <errno.h>
#include <stdint.h>

// AFC can return its protocol status directly or the MobileDevice error-domain form.
static const uint32_t DiagnosticNotFound = 8;
static const uint32_t DiagnosticEncodedNotFound = 0xe8004008;

static NSDictionary *DiagnosticObject(AFCConnectionRef afc, NSString *path) {
    AFCKeyValueRef info = NULL;
    int status = AFCFileInfoOpen(afc, path.fileSystemRepresentation, &info);
    NSMutableDictionary *result = [@{ @"status": @(status) } mutableCopy];
    if (status != 0 || !info) {
        if (info) AFCKeyValueClose(info);
        BOOL missing = (uint32_t)status == DiagnosticNotFound ||
            (uint32_t)status == DiagnosticEncodedNotFound;
        result[@"state"] = missing ? @"missing" : @"error";
        if (status == 0) result[@"reason"] = @"missing AFC metadata";
        return result;
    }
    char *key = NULL, *value = NULL;
    BOOL ended = NO;
    for (NSUInteger index = 0; index < 256; index++) {
        int readStatus = AFCKeyValueRead(info, &key, &value);
        if (readStatus != 0) {
            result[@"readStatus"] = @(readStatus);
            break;
        }
        if (!key) { ended = YES; break; }
        if (!value) break;
        NSString *field = [NSString stringWithUTF8String:key];
        NSString *text = [NSString stringWithUTF8String:value];
        if ([field isEqual:@"st_ifmt"] && text) result[@"kind"] = text;
        if ([field isEqual:@"LinkTarget"] && text) result[@"linkTarget"] = text;
        if ([field isEqual:@"st_size"] && value[0] >= '0' && value[0] <= '9') {
            errno = 0;
            char *end = NULL;
            unsigned long long size = strtoull(value, &end, 10);
            if (!errno && end && !*end) result[@"size"] = @(size);
        }
        key = NULL;
        value = NULL;
    }
    int closeStatus = AFCKeyValueClose(info);
    result[@"state"] = ended && closeStatus == 0 && result[@"kind"]
        ? @"present" : @"error";
    if (closeStatus != 0) result[@"closeStatus"] = @(closeStatus);
    return result;
}

static BOOL DiagnosticIs(NSDictionary *object, NSString *state) {
    return [object[@"state"] isEqual:state];
}

static NSData *DiagnosticRead(AFCConnectionRef afc, NSString *path,
                              NSDictionary *object, NSMutableArray *errors) {
    if (!DiagnosticIs(object, @"present") ||
        ![object[@"kind"] isEqual:@"S_IFREG"] ||
        !object[@"size"] || [object[@"size"] unsignedLongLongValue] > 128 * 1024 * 1024) {
        [errors addObject:@{ @"path": path, @"reason": @"unexpected file metadata" }];
        return nil;
    }
    AFCFileRef file = NULL;
    int status = AFCFileRefOpen(afc, path.fileSystemRepresentation, 1, &file);
    if (status != 0 || !file) {
        [errors addObject:@{ @"path": path, @"openStatus": @(status) }];
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:[object[@"size"] unsignedIntegerValue]];
    NSUInteger offset = 0;
    while (offset < data.length) {
        long count = (long)(data.length - offset);
        status = AFCFileRefRead(afc, file, (uint8_t *)data.mutableBytes + offset, &count);
        if (status != 0 || count <= 0 || (NSUInteger)count > data.length - offset) break;
        offset += (NSUInteger)count;
    }
    int closeStatus = AFCFileRefClose(afc, file);
    if (status != 0 || offset != data.length || closeStatus != 0) {
        [errors addObject:@{ @"path": path, @"readStatus": @(status),
                            @"closeStatus": @(closeStatus), @"shortRead": @(offset != data.length) }];
        return nil;
    }
    return data;
}

static NSDictionary *DiagnosticBooksView(AFCConnectionRef afc) {
    NSMutableDictionary *directories = NSMutableDictionary.dictionary;
    NSMutableDictionary *files = NSMutableDictionary.dictionary;
    NSMutableArray *errors = NSMutableArray.array;
    unsigned long long totalBytes = 0;
    for (NSUInteger index = 0; index < sizeof(TrackedBooksDirectories) / sizeof(char *); index++) {
        NSString *path = [NSString stringWithUTF8String:TrackedBooksDirectories[index]];
        NSDictionary *object = DiagnosticObject(afc, path);
        directories[path] = object;
        if (DiagnosticIs(object, @"error") ||
            (DiagnosticIs(object, @"present") && ![object[@"kind"] isEqual:@"S_IFDIR"])) {
            [errors addObject:@{ @"path": path, @"object": object }];
            // Do not inspect descendants through a link or unreadable parent.
            return @{ @"directories": directories, @"files": files, @"errors": errors };
        }
    }
    for (NSUInteger index = 0; index < sizeof(TrackedBooksFiles) / sizeof(char *); index++) {
        NSString *path = [NSString stringWithUTF8String:TrackedBooksFiles[index]];
        NSMutableDictionary *object = [DiagnosticObject(afc, path) mutableCopy];
        if (DiagnosticIs(object, @"error")) [errors addObject:@{ @"path": path, @"object": object }];
        if (DiagnosticIs(object, @"present")) {
            unsigned long long size = [object[@"size"] unsignedLongLongValue];
            if (size > 256 * 1024 * 1024 - totalBytes)
                [errors addObject:@{ @"path": path, @"reason": @"Books state exceeds snapshot limit" }];
            else {
                totalBytes += size;
                NSData *data = DiagnosticRead(afc, path, object, errors);
                if (data) object[@"data"] = data;
            }
        }
        files[path] = object;
    }
    return @{ @"directories": directories, @"files": files, @"errors": errors };
}

static BOOL DiagnosticBooksMatch(NSDictionary *view, NSString *root,
                                  NSDictionary *snapshot, NSData *stagedBooks) {
    if ([view[@"errors"] count]) return NO;
    for (NSUInteger index = 0; index < sizeof(TrackedBooksDirectories) / sizeof(char *); index++) {
        NSString *path = [NSString stringWithUTF8String:TrackedBooksDirectories[index]];
        NSDictionary *object = view[@"directories"][path];
        BOOL exists = [snapshot[@"directories"][path] boolValue];
        BOOL stagedParent = stagedBooks && ([path isEqual:@"Books"] || [path isEqual:@"Books/Sync"]);
        if (exists && !(DiagnosticIs(object, @"present") && [object[@"kind"] isEqual:@"S_IFDIR"])) return NO;
        if (!exists && !DiagnosticIs(object, @"missing") &&
            !(stagedParent && DiagnosticIs(object, @"present") && [object[@"kind"] isEqual:@"S_IFDIR"])) return NO;
    }
    for (NSUInteger index = 0; index < sizeof(TrackedBooksFiles) / sizeof(char *); index++) {
        NSString *path = [NSString stringWithUTF8String:TrackedBooksFiles[index]];
        NSDictionary *object = view[@"files"][path];
        NSDictionary *row = snapshot[@"files"][path];
        NSData *original = [row[@"exists"] boolValue]
            ? [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:SnapshotFileName(index)]] : nil;
        if ([row[@"exists"] boolValue] && !original) return NO;
        BOOL originalMatches = original
            ? (DiagnosticIs(object, @"present") && [object[@"data"] isEqualToData:original])
            : DiagnosticIs(object, @"missing");
        BOOL stagedMatches = stagedBooks && [path isEqual:@"Books/Sync/Books.plist"] &&
            DiagnosticIs(object, @"present") && [object[@"data"] isEqualToData:stagedBooks];
        if (!originalMatches && !stagedMatches) return NO;
    }
    return YES;
}

static NSDictionary *DiagnosticSnapshot(AFCConnectionRef afc, NSString *root) {
    NSDictionary *before = DiagnosticBooksView(afc);
    if ([before[@"errors"] count])
        return @{ @"ok": @NO, @"errors": before[@"errors"] };
    NSDictionary *snapshotResult = SnapshotBooksState(afc, root);
    if (![snapshotResult[@"ok"] boolValue]) return snapshotResult;
    NSDictionary *snapshot = LoadBooksSnapshot(root);
    NSDictionary *after = DiagnosticBooksView(afc);
    BOOL matched = snapshot && DiagnosticBooksMatch(before, root, snapshot, nil) &&
        DiagnosticBooksMatch(after, root, snapshot, nil);
    return @{ @"ok": @(matched), @"snapshotVerified": @(matched),
              @"errors": after[@"errors"], @"conflict": @(!matched && ![after[@"errors"] count]) };
}

static NSDictionary *DiagnosticPaths(NSString *token) {
    if (!IsLowercaseHex(token, 20)) return nil;
    NSString *source = [AIRLIFT_SOURCE_PREFIX stringByAppendingString:token];
    return @{ @"source": source,
              @"stagedLink": [source stringByAppendingPathComponent:@"p0/p1/p2/link"],
              @"payload": [source stringByAppendingPathComponent:@"payload"],
              @"link": [AIRLIFT_LINK_PREFIX stringByAppendingString:token],
              @"control": [AIRLIFT_RECOVERED_PREFIX stringByAppendingString:token] };
}

static NSDictionary *DiagnosticDescendant(AFCConnectionRef afc, NSString *path) {
    NSArray *components = [path componentsSeparatedByString:@"/"];
    NSString *cursor = @"";
    for (NSUInteger index = 0; index + 1 < components.count; index++) {
        cursor = [cursor stringByAppendingPathComponent:components[index]];
        NSDictionary *parent = DiagnosticObject(afc, cursor);
        if (!DiagnosticIs(parent, @"present")) return parent;
        if (![parent[@"kind"] isEqual:@"S_IFDIR"])
            return @{ @"state": @"error", @"status": @0, @"reason": @"ancestor is not a directory" };
    }
    return DiagnosticObject(afc, path);
}

static NSDictionary *DiagnosticStatus(AFCConnectionRef afc, NSString *token) {
    NSDictionary *paths = DiagnosticPaths(token);
    if (!paths) return @{ @"ok": @NO, @"error": @"invalid diagnostic token" };
    NSMutableDictionary *objects = NSMutableDictionary.dictionary;
    BOOL ok = YES;
    for (NSString *key in paths) {
        NSDictionary *object = DiagnosticDescendant(afc, paths[key]);
        objects[key] = object;
        if (DiagnosticIs(object, @"error")) ok = NO;
    }
    return @{ @"ok": @(ok), @"objects": objects };
}

static BOOL DiagnosticRemove(AFCConnectionRef afc, NSString *path,
                              BOOL recursive, NSUInteger depth, NSMutableArray *errors) {
    NSDictionary *object = DiagnosticObject(afc, path);
    if (DiagnosticIs(object, @"missing")) return YES;
    if (DiagnosticIs(object, @"error") || depth > 32) {
        [errors addObject:@{ @"path": path, @"object": object }];
        return NO;
    }
    NSString *kind = object[@"kind"];
    if (![@[ @"S_IFREG", @"S_IFLNK", @"S_IFDIR" ] containsObject:kind]) {
        [errors addObject:@{ @"path": path, @"reason": @"unexpected object type" }];
        return NO;
    }
    if (recursive) {
        NSString *source = [path componentsSeparatedByString:@"/"].firstObject;
        NSString *tail = [path isEqual:source] ? @"" : [path substringFromIndex:source.length + 1];
        BOOL directory = [@[ @"", @"p0", @"p0/p1", @"p0/p1/p2", @"var", @"var/tmp", @"META-INF" ] containsObject:tail];
        BOOL file = [@[ @"payload", @"META-INF/com.apple.ZipMetadata.plist" ] containsObject:tail];
        BOOL link = [tail isEqual:@"p0/p1/p2/link"];
        BOOL allowed = (directory && [kind isEqual:@"S_IFDIR"]) ||
            (file && [kind isEqual:@"S_IFREG"]) || (link && [kind isEqual:@"S_IFLNK"]);
        if (!GeneratedToken(source, AIRLIFT_SOURCE_PREFIX) || !allowed) {
            [errors addObject:@{ @"path": path, @"reason": @"unexpected diagnostic archive entry" }];
            return NO;
        }
    }
    if (recursive && [kind isEqual:@"S_IFDIR"]) {
        AFCDirectoryRef directory = NULL;
        int status = AFCDirectoryOpen(afc, path.fileSystemRepresentation, &directory);
        if (status != 0 || !directory) {
            [errors addObject:@{ @"path": path, @"openStatus": @(status) }];
            return NO;
        }
        NSMutableArray *children = NSMutableArray.array;
        BOOL ended = NO;
        for (NSUInteger index = 0; index < 8192; index++) {
            char *raw = NULL;
            status = AFCDirectoryRead(afc, directory, &raw);
            if (status != 0) break;
            if (!raw) { ended = YES; break; }
            NSString *name = [NSString stringWithUTF8String:raw];
            if ([name isEqual:@"."] || [name isEqual:@".."]) continue;
            if (!name.length || [name rangeOfString:@"/"].location != NSNotFound) { status = -1; break; }
            [children addObject:name];
        }
        int closeStatus = AFCDirectoryClose(afc, directory);
        if (!ended || status != 0 || closeStatus != 0) {
            [errors addObject:@{ @"path": path, @"readStatus": @(status), @"closeStatus": @(closeStatus) }];
            return NO;
        }
        for (NSString *name in children)
            if (!DiagnosticRemove(afc, [path stringByAppendingPathComponent:name], YES, depth + 1, errors)) return NO;
    }
    // Remove the relocated link itself; never walk through it or its materialized directory.
    int status = AFCRemovePath(afc, path.fileSystemRepresentation);
    NSDictionary *after = DiagnosticObject(afc, path);
    BOOL removed = status == 0 && DiagnosticIs(after, @"missing");
    if (!removed) [errors addObject:@{ @"path": path, @"removeStatus": @(status), @"after": after }];
    return removed;
}

static NSDictionary *DiagnosticCleanup(AFCConnectionRef afc, NSString *token,
                                        NSString *root, NSString *expectedBooksPath) {
    NSDictionary *paths = DiagnosticPaths(token);
    NSDictionary *snapshot = LoadBooksSnapshot(root);
    NSData *expectedBooks = [NSData dataWithContentsOfFile:expectedBooksPath];
    NSMutableArray *errors = NSMutableArray.array;
    NSString *media = @"unknown", *books = @"unknown";
    BOOL conflict = NO;
    if (!paths || !snapshot || !expectedBooks) {
        [errors addObject:@{ @"reason": @"invalid diagnostic recovery inputs" }];
    } else {
        NSDictionary *before = DiagnosticBooksView(afc);
        if ([before[@"errors"] count]) [errors addObjectsFromArray:before[@"errors"]];
        else if (!DiagnosticBooksMatch(before, root, snapshot, expectedBooks)) conflict = YES;
        // Media ownership is independent of permission to restore Books.
        DiagnosticRemove(afc, paths[@"link"], NO, 0, errors);
        DiagnosticRemove(afc, paths[@"control"], NO, 0, errors);
        DiagnosticRemove(afc, paths[@"source"], YES, 0, errors);
        NSDictionary *status = DiagnosticStatus(afc, token);
        BOOL absent = YES, unknown = NO;
        for (NSString *key in @[ @"source", @"link", @"control" ]) {
            NSDictionary *object = status[@"objects"][key];
            if (!DiagnosticIs(object, @"missing")) absent = NO;
            if (DiagnosticIs(object, @"error")) unknown = YES;
        }
        media = absent ? @"verified" : (unknown ? @"unknown" : @"failed");
        if (![before[@"errors"] count] && !conflict) {
            NSDictionary *current = DiagnosticBooksView(afc);
            if ([current[@"errors"] count]) [errors addObjectsFromArray:current[@"errors"]];
            else if (![current isEqualToDictionary:before]) conflict = YES;
            else {
                // The only permitted file change is this run's Sync/Books.plist.
                NSString *syncPath = @"Books/Sync/Books.plist";
                NSDictionary *row = snapshot[@"files"][syncPath];
                if (!DiagnosticBooksMatch(current, root, snapshot, nil)) {
                    if ([row[@"exists"] boolValue]) {
                        NSData *original = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:row[@"localName"]]];
                        if (!original || !AFCWriteFile(afc, syncPath, original))
                            [errors addObject:@{ @"path": syncPath, @"reason": @"restore write failed" }];
                    } else DiagnosticRemove(afc, syncPath, NO, 0, errors);
                    for (NSString *path in @[ @"Books/Sync", @"Books" ])
                        if (![snapshot[@"directories"][path] boolValue])
                            DiagnosticRemove(afc, path, NO, 0, errors);
                }
                NSDictionary *after = DiagnosticBooksView(afc);
                if ([after[@"errors"] count]) [errors addObjectsFromArray:after[@"errors"]];
                else books = DiagnosticBooksMatch(after, root, snapshot, nil) ? @"verified" : @"failed";
            }
        }
    }
    BOOL ok = [media isEqual:@"verified"] && [books isEqual:@"verified"] && errors.count == 0 && !conflict;
    return @{ @"ok": @(ok), @"mediaCleanup": media, @"booksRestore": books,
              @"recoveryRequired": @(!ok), @"conflict": @(conflict), @"errors": errors };
}

static BOOL DiagnosticExpectedBooks(NSData *data, NSString *token) {
    if (!DiagnosticPaths(token) || !data.length || data.length > 4096) return NO;
    id value = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:nil error:nil];
    NSString *source = [AIRLIFT_SOURCE_PREFIX stringByAppendingString:token];
    NSDictionary *expected = @{ @"Books": @[
        @{ @"Persistent ID": [NSString stringWithFormat:@"../../%@/p0/p1/p2/link", source],
           @"Item ID": @"1", @"DSID": @"1" },
        @{ @"Persistent ID": [NSString stringWithFormat:@"../../%@/payload", source],
           @"Item ID": @"2", @"DSID": @"1" } ] };
    return [value isKindOfClass:NSDictionary.class] && [value isEqual:expected];
}

static BOOL DiagnosticOtherBooksUnchanged(NSDictionary *before, NSDictionary *after) {
    if ([before[@"errors"] count] || [after[@"errors"] count]) return NO;
    for (NSUInteger index = 0; index < sizeof(TrackedBooksFiles) / sizeof(char *); index++) {
        NSString *path = [NSString stringWithUTF8String:TrackedBooksFiles[index]];
        if ([path isEqual:@"Books/Sync/Books.plist"]) continue;
        NSDictionary *left = before[@"files"][path], *right = after[@"files"][path];
        if (![left[@"state"] isEqual:right[@"state"]]) return NO;
        if (DiagnosticIs(left, @"present") &&
            (![left[@"kind"] isEqual:right[@"kind"]] ||
             ![left[@"data"] isEqualToData:right[@"data"]])) return NO;
    }
    for (NSUInteger index = 0; index < sizeof(TrackedBooksDirectories) / sizeof(char *); index++) {
        NSString *path = [NSString stringWithUTF8String:TrackedBooksDirectories[index]];
        NSDictionary *left = before[@"directories"][path], *right = after[@"directories"][path];
        if (![left[@"state"] isEqual:right[@"state"]]) return NO;
        // Removing the owned file changes its parent directory's size.
        if (DiagnosticIs(left, @"present") && ![left[@"kind"] isEqual:right[@"kind"]]) return NO;
    }
    return YES;
}

static BOOL DiagnosticBackupOwnedBooks(NSData *data, NSString *directory, NSMutableArray *errors) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSDictionary *attributes = [manager attributesOfItemAtPath:directory error:nil];
    if (![attributes[NSFileType] isEqual:NSFileTypeDirectory]) {
        [errors addObject:@{ @"reason": @"backup directory is not an existing directory" }];
        return NO;
    }
    NSString *path = [directory stringByAppendingPathComponent:@"owned-sync-books.plist"];
    attributes = [manager attributesOfItemAtPath:path error:nil];
    if (attributes) {
        if (![attributes[NSFileType] isEqual:NSFileTypeRegular] ||
            ![[NSData dataWithContentsOfFile:path] isEqualToData:data]) {
            [errors addObject:@{ @"reason": @"existing backup is not this run's exact content" }];
            return NO;
        }
    } else {
        NSError *error = nil;
        if (![data writeToFile:path options:NSDataWritingWithoutOverwriting error:&error]) {
            [errors addObject:@{ @"reason": @"owned Books backup write failed",
                                @"localError": error.localizedDescription ?: @"unknown" }];
            return NO;
        }
    }
    NSError *error = nil;
    BOOL privateFile = [manager setAttributes:@{ NSFilePosixPermissions: @0600 }
                                 ofItemAtPath:path error:&error];
    attributes = [manager attributesOfItemAtPath:path error:nil];
    BOOL verified = privateFile && [attributes[NSFileType] isEqual:NSFileTypeRegular] &&
        [[NSData dataWithContentsOfFile:path] isEqualToData:data];
    if (!verified) [errors addObject:@{ @"reason": @"owned Books backup could not be verified" }];
    return verified;
}

static NSDictionary *DiagnosticRestoreOwnedBooks(AFCConnectionRef afc, NSString *token,
                                                 NSString *root, NSString *expectedBooksPath,
                                                 NSString *backupDirectory) {
    NSString *const target = @"Books/Sync/Books.plist";
    NSDictionary *snapshot = LoadBooksSnapshot(root);
    NSData *expected = [NSData dataWithContentsOfFile:expectedBooksPath];
    NSMutableArray *errors = NSMutableArray.array;
    NSString *owned = @"unknown";
    id otherUnchanged = NSNull.null;
    BOOL backupVerified = NO;
    NSDictionary *before = nil;
    if (!snapshot || !DiagnosticExpectedBooks(expected, token)) {
        [errors addObject:@{ @"reason": @"invalid owned Books recovery inputs" }];
    } else if ([snapshot[@"files"][target][@"exists"] boolValue]) {
        // This narrow rollback only removes a newly created input file.
        [errors addObject:@{ @"reason": @"restoring an originally present Books input is unsupported" }];
    } else {
        before = DiagnosticBooksView(afc);
        if ([before[@"errors"] count]) [errors addObjectsFromArray:before[@"errors"]];
        else {
            NSDictionary *object = before[@"files"][target];
            if (DiagnosticIs(object, @"missing")) {
                owned = @"verified";
            } else if (!DiagnosticIs(object, @"present") ||
                       ![object[@"kind"] isEqual:@"S_IFREG"] ||
                       ![object[@"data"] isEqualToData:expected]) {
                [errors addObject:@{ @"reason": @"current Books input is not this run's exact content" }];
            } else if ((backupVerified = DiagnosticBackupOwnedBooks(expected, backupDirectory, errors))) {
                NSDictionary *current = DiagnosticBooksView(afc);
                if ([current[@"errors"] count]) [errors addObjectsFromArray:current[@"errors"]];
                else if (![current isEqualToDictionary:before])
                    [errors addObject:@{ @"reason": @"Books changed before owned input rollback" }];
                else {
                    NSDictionary *lastObject = DiagnosticDescendant(afc, target);
                    NSData *lastBytes = DiagnosticRead(afc, target, lastObject, errors);
                    if (!lastBytes || ![lastBytes isEqualToData:expected]) {
                        [errors addObject:@{ @"reason": @"owned Books input changed at rollback" }];
                    } else {
                        // AFC has no compare-and-swap; recheck immediately before this single unlink.
                        int status = AFCRemovePath(afc, target.fileSystemRepresentation);
                        if (status != 0)
                            [errors addObject:@{ @"path": target, @"removeStatus": @(status) }];
                        else owned = @"verified";
                    }
                }
            }
            NSDictionary *after = DiagnosticBooksView(afc);
            if ([after[@"errors"] count]) {
                [errors addObjectsFromArray:after[@"errors"]];
                owned = @"unknown";
            } else {
                otherUnchanged = @(DiagnosticOtherBooksUnchanged(before, after));
                if ([owned isEqual:@"verified"] && !DiagnosticIs(after[@"files"][target], @"missing")) {
                    owned = @"failed";
                    [errors addObject:@{ @"reason": @"owned Books input absence was not verified" }];
                }
            }
        }
    }
    BOOL ok = [owned isEqual:@"verified"] && [otherUnchanged isEqual:@YES] && errors.count == 0;
    return @{ @"ok": @(ok), @"ownedBooksRestore": owned,
              @"otherBooksUnchanged": otherUnchanged, @"backupVerified": @(backupVerified),
              @"errors": errors };
}

#endif
