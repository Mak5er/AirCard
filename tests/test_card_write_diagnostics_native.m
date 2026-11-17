#define main DeviceHelperMain
#include "../Sources/device_helper.m"
#undef main
#include <assert.h>

static NSMutableDictionary *Nodes, *Forced, *StatCounts;
static NSMutableArray *Removed, *OpenedDirectories, *Writes;
static NSString *ChangeOnStat, *ChangeOnRemove, *ChangeOtherOnRemove;
static NSUInteger ChangeAtStat;
static NSString *TestRoot;
static NSString *const Token = @"0123456789abcdef0123";

static NSData *Bytes(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }
static void File(NSString *path, NSString *text) {
    Nodes[path] = [@{ @"kind": @"S_IFREG", @"data": Bytes(text) } mutableCopy];
}
static void Dir(NSString *path) { Nodes[path] = [@{ @"kind": @"S_IFDIR" } mutableCopy]; }
static void Link(NSString *path) {
    Nodes[path] = [@{ @"kind": @"S_IFLNK", @"linkTarget": @"../../../var/tmp" } mutableCopy];
}
static void Reset(void) {
    Nodes = NSMutableDictionary.dictionary;
    Forced = NSMutableDictionary.dictionary;
    StatCounts = NSMutableDictionary.dictionary;
    Removed = NSMutableArray.array;
    OpenedDirectories = NSMutableArray.array;
    Writes = NSMutableArray.array;
    ChangeOnStat = nil;
    ChangeOnRemove = nil;
    ChangeOtherOnRemove = nil;
    ChangeAtStat = 2;
}

int AFCFileInfoOpen(AFCConnectionRef afc, const char *raw, AFCKeyValueRef *out) {
    (void)afc;
    NSString *path = @(raw);
    *out = NULL;
    NSUInteger count = [StatCounts[path] unsignedIntegerValue] + 1;
    StatCounts[path] = @(count);
    if ([path isEqual:ChangeOnStat] && count == ChangeAtStat) File(path, @"concurrent change");
    if (Forced[path]) return [Forced[path] intValue];
    NSDictionary *node = Nodes[path];
    if (!node) return (int)DiagnosticNotFound;
    NSMutableDictionary *fields = [@{ @"st_ifmt": node[@"kind"],
        @"st_size": [NSString stringWithFormat:@"%lu", (unsigned long)[node[@"data"] length]] } mutableCopy];
    if (node[@"linkTarget"]) fields[@"LinkTarget"] = node[@"linkTarget"];
    *out = (__bridge_retained void *)[@{ @"fields": fields,
        @"keys": [fields.allKeys sortedArrayUsingSelector:@selector(compare:)], @"index": @0 } mutableCopy];
    return 0;
}
int AFCKeyValueRead(AFCKeyValueRef ref, char **key, char **value) {
    NSMutableDictionary *dict = (__bridge id)ref;
    NSUInteger index = [dict[@"index"] unsignedIntegerValue];
    NSArray *keys = dict[@"keys"];
    if (index >= keys.count) { *key = NULL; *value = NULL; return 0; }
    NSString *field = keys[index];
    *key = (char *)field.UTF8String;
    *value = (char *)[dict[@"fields"][field] UTF8String];
    dict[@"index"] = @(index + 1);
    return 0;
}
int AFCKeyValueClose(AFCKeyValueRef ref) { (void)CFBridgingRelease(ref); return 0; }

int AFCFileRefOpen(AFCConnectionRef afc, const char *raw, unsigned long long mode, AFCFileRef *out) {
    (void)afc;
    NSString *path = @(raw);
    if (mode == 3) { File(path, @""); [Writes addObject:path]; }
    if (![Nodes[path][@"kind"] isEqual:@"S_IFREG"]) return (int)DiagnosticNotFound;
    *out = (__bridge_retained void *)[@{ @"path": path, @"offset": @0 } mutableCopy];
    return 0;
}
int AFCFileRefRead(AFCConnectionRef afc, AFCFileRef ref, void *bytes, long *length) {
    (void)afc;
    NSMutableDictionary *file = (__bridge id)ref;
    NSData *data = Nodes[file[@"path"]][@"data"];
    NSUInteger offset = [file[@"offset"] unsignedIntegerValue];
    NSUInteger count = MIN((NSUInteger)*length, data.length - offset);
    memcpy(bytes, (const uint8_t *)data.bytes + offset, count);
    *length = (long)count;
    file[@"offset"] = @(offset + count);
    return 0;
}
int AFCFileRefWrite(AFCConnectionRef afc, AFCFileRef ref, const void *bytes, long length) {
    (void)afc;
    NSDictionary *file = (__bridge id)ref;
    Nodes[file[@"path"]][@"data"] = [NSData dataWithBytes:bytes length:(NSUInteger)length];
    return 0;
}
int AFCFileRefClose(AFCConnectionRef afc, AFCFileRef ref) { (void)afc; (void)CFBridgingRelease(ref); return 0; }

static NSArray *Children(NSString *path) {
    NSMutableSet *names = NSMutableSet.set;
    NSString *prefix = [path stringByAppendingString:@"/"];
    for (NSString *candidate in Nodes) {
        if (![candidate hasPrefix:prefix]) continue;
        NSString *tail = [candidate substringFromIndex:prefix.length];
        if ([tail rangeOfString:@"/"].location == NSNotFound) [names addObject:tail];
    }
    return [names.allObjects sortedArrayUsingSelector:@selector(compare:)];
}
int AFCDirectoryOpen(AFCConnectionRef afc, const char *raw, AFCDirectoryRef *out) {
    (void)afc;
    NSString *path = @(raw);
    [OpenedDirectories addObject:path];
    if (![Nodes[path][@"kind"] isEqual:@"S_IFDIR"]) return (int)DiagnosticNotFound;
    *out = (__bridge_retained void *)[@{ @"children": Children(path), @"index": @0 } mutableCopy];
    return 0;
}
int AFCDirectoryRead(AFCConnectionRef afc, AFCDirectoryRef ref, char **out) {
    (void)afc;
    NSMutableDictionary *dir = (__bridge id)ref;
    NSUInteger index = [dir[@"index"] unsignedIntegerValue];
    NSArray *children = dir[@"children"];
    *out = index < children.count ? (char *)[children[index] UTF8String] : NULL;
    dir[@"index"] = @(index + 1);
    return 0;
}
int AFCDirectoryClose(AFCConnectionRef afc, AFCDirectoryRef ref) { (void)afc; (void)CFBridgingRelease(ref); return 0; }
int AFCRemovePath(AFCConnectionRef afc, const char *raw) {
    (void)afc;
    NSString *path = @(raw);
    [Removed addObject:path];
    if ([Nodes[path][@"kind"] isEqual:@"S_IFDIR"] && Children(path).count) return (int)0xe8004011;
    if (!Nodes[path]) return (int)DiagnosticNotFound;
    [Nodes removeObjectForKey:path];
    if ([path isEqual:ChangeOnRemove]) File(@"Books/Sync/Books.plist", @"concurrent change");
    if ([path isEqual:@"Books/Sync/Books.plist"] && ChangeOtherOnRemove)
        File(ChangeOtherOnRemove, @"concurrent index change");
    return 0;
}

static NSString *Snapshot(void) {
    NSString *root = [TestRoot stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:NO attributes:nil error:nil]);
    NSDictionary *result = DiagnosticSnapshot(NULL, root);
    assert([result[@"ok"] boolValue]);
    return root;
}
static NSString *Expected(NSString *root) {
    NSString *path = [root stringByAppendingPathComponent:@"Books.plist"];
    assert([Bytes(@"run's Books metadata") writeToFile:path atomically:YES]);
    return path;
}
static NSString *OwnedExpected(NSString *root, NSString *token) {
    NSString *source = [AIRLIFT_SOURCE_PREFIX stringByAppendingString:token];
    NSDictionary *books = @{ @"Books": @[
        @{ @"Persistent ID": [NSString stringWithFormat:@"../../%@/p0/p1/p2/link", source],
           @"Item ID": @"1", @"DSID": @"1" },
        @{ @"Persistent ID": [NSString stringWithFormat:@"../../%@/payload", source],
           @"Item ID": @"2", @"DSID": @"1" } ] };
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:books
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    NSString *path = [root stringByAppendingPathComponent:@"owned-expected.plist"];
    assert([data writeToFile:path options:NSDataWritingWithoutOverwriting error:nil]);
    return path;
}
static NSString *OwnedBackup(NSString *root) {
    NSString *path = [root stringByAppendingPathComponent:@"owned-backup"];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:NO
        attributes:@{ NSFilePosixPermissions: @0700 } error:nil]);
    return path;
}
static void OwnedInput(NSString *expected) {
    Nodes[@"Books/Sync/Books.plist"] = [@{ @"kind": @"S_IFREG",
        @"data": [NSData dataWithContentsOfFile:expected] } mutableCopy];
}
static void OwnNodes(void) {
    NSDictionary *paths = DiagnosticPaths(Token);
    NSString *source = paths[@"source"];
    for (NSString *tail in @[ @"", @"p0", @"p0/p1", @"p0/p1/p2", @"var", @"var/tmp" ])
        Dir(tail.length ? [source stringByAppendingPathComponent:tail] : source);
    Link(paths[@"stagedLink"]);
    File(paths[@"payload"], @"control");
    Link(paths[@"link"]);
    File(paths[@"control"], @"control");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        assert(argc == 2);
        TestRoot = @(argv[1]);
        Reset();
        assert(DiagnosticIs(DiagnosticObject(NULL, @"missing"), @"missing"));
        Forced[@"denied"] = @((int)0xe800400a);
        assert(DiagnosticIs(DiagnosticObject(NULL, @"denied"), @"error"));
        Forced[@"raw-denied"] = @10;
        assert(DiagnosticIs(DiagnosticObject(NULL, @"raw-denied"), @"error"));
        Forced[@"raw-disconnected"] = @11;
        assert(DiagnosticIs(DiagnosticObject(NULL, @"raw-disconnected"), @"error"));
        Forced[@"encoded-missing"] = @((int)DiagnosticEncodedNotFound);
        assert(DiagnosticIs(DiagnosticObject(NULL, @"encoded-missing"), @"missing"));
        assert(![DiagnosticStatus(NULL, @"../outside")[@"ok"] boolValue]);
        assert(StatCounts.count == 5);

        Reset();
        OwnNodes();
        NSDictionary *status = DiagnosticStatus(NULL, Token);
        assert([status[@"ok"] boolValue]);
        assert([status[@"objects"] count] == 5);
        assert([status[@"objects"][@"stagedLink"][@"kind"] isEqual:@"S_IFLNK"]);
        assert([status[@"objects"][@"stagedLink"][@"linkTarget"] isEqual:@"../../../var/tmp"]);
        NSString *root = Snapshot();
        NSString *expected = Expected(root);
        File(@"var/tmp/do-not-follow", @"outside marker");
        NSDictionary *clean = DiagnosticCleanup(NULL, Token, root, expected);
        assert([clean[@"ok"] boolValue]);
        assert([clean[@"mediaCleanup"] isEqual:@"verified"]);
        assert(Nodes[@"var/tmp/do-not-follow"]);
        assert(![OpenedDirectories containsObject:DiagnosticPaths(Token)[@"link"]]);

        Reset();
        root = Snapshot(); expected = Expected(root);
        OwnNodes();
        NSString *link = DiagnosticPaths(Token)[@"link"];
        Dir(link);
        NSString *child = [link stringByAppendingPathComponent:@"unexpected"];
        File(child, @"preserve");
        clean = DiagnosticCleanup(NULL, Token, root, expected);
        assert(![clean[@"ok"] boolValue]);
        assert([clean[@"recoveryRequired"] boolValue]);
        assert(Nodes[child]);
        assert(![OpenedDirectories containsObject:link]);

        Reset();
        root = Snapshot(); expected = Expected(root);
        OwnNodes();
        NSString *unknown = [DiagnosticPaths(Token)[@"source"] stringByAppendingPathComponent:@"unrelated"];
        File(unknown, @"preserve concurrent content");
        clean = DiagnosticCleanup(NULL, Token, root, expected);
        assert(![clean[@"ok"] boolValue]);
        assert(Nodes[unknown]);

        Reset();
        Dir(@"Books"); Dir(@"Books/Sync"); Dir(@"Books/Sync/Database");
        root = Snapshot(); expected = Expected(root);
        OwnNodes();
        File(@"Books/Books.plist", @"system metadata");
        File(@"Books/Sync/Books.plist", @"run's Books metadata");
        File(@"Books/Sync/Database/OutstandingAssets_4.sqlite", @"system database");
        File(@"Books/Sync/Database/OutstandingAssets_4.sqlite-shm", @"system shared memory");
        File(@"Books/Sync/Database/OutstandingAssets_4.sqlite-wal", @"system journal");
        NSDictionary *booksBefore = Nodes.copy;
        clean = DiagnosticCleanup(NULL, Token, root, expected);
        assert([clean[@"conflict"] boolValue]);
        assert([clean[@"mediaCleanup"] isEqual:@"verified"]);
        assert([clean[@"booksRestore"] isEqual:@"unknown"]);
        assert([clean[@"recoveryRequired"] boolValue]);
        assert(Removed.count > 0 && Writes.count == 0);
        for (NSString *path in Removed) assert(![path hasPrefix:@"Books"]);
        for (NSString *path in booksBefore)
            if ([path hasPrefix:@"Books"]) assert([Nodes[path] isEqualToDictionary:booksBefore[path]]);

        Reset();
        root = Snapshot(); expected = Expected(root);
        OwnNodes(); Dir(@"Books"); Dir(@"Books/Sync");
        File(@"Books/Sync/Books.plist", @"unrelated Books metadata");
        unknown = [DiagnosticPaths(Token)[@"source"] stringByAppendingPathComponent:@"unrelated"];
        File(unknown, @"preserve concurrent content");
        clean = DiagnosticCleanup(NULL, Token, root, expected);
        assert([clean[@"conflict"] boolValue]);
        assert([clean[@"mediaCleanup"] isEqual:@"failed"]);
        assert(Nodes[unknown]);
        assert(Writes.count == 0);
        for (NSString *path in Removed) assert(![path hasPrefix:@"Books"]);

        Reset();
        root = Snapshot(); expected = Expected(root);
        OwnNodes();
        Forced[@"Books"] = @10;
        clean = DiagnosticCleanup(NULL, Token, root, expected);
        assert([clean[@"mediaCleanup"] isEqual:@"verified"]);
        assert([clean[@"booksRestore"] isEqual:@"unknown"]);
        assert([clean[@"recoveryRequired"] boolValue]);
        assert([clean[@"errors"] count] > 0);
        assert(Writes.count == 0);
        for (NSString *path in Removed) assert(![path hasPrefix:@"Books"]);

        Reset();
        root = Snapshot(); expected = Expected(root);
        OwnNodes(); Dir(@"Books"); Dir(@"Books/Sync");
        File(@"Books/Sync/Books.plist", @"run's Books metadata");
        clean = DiagnosticCleanup(NULL, Token, root, expected);
        assert([clean[@"ok"] boolValue]);
        assert(!Nodes[@"Books"] && !Nodes[@"Books/Sync/Books.plist"]);

        Reset();
        Dir(@"Books"); Dir(@"Books/Sync"); File(@"Books/Sync/Books.plist", @"original metadata");
        root = Snapshot(); expected = Expected(root);
        OwnNodes(); File(@"Books/Sync/Books.plist", @"run's Books metadata");
        clean = DiagnosticCleanup(NULL, Token, root, expected);
        assert([clean[@"ok"] boolValue]);
        assert([Nodes[@"Books/Sync/Books.plist"][@"data"] isEqualToData:Bytes(@"original metadata")]);
        assert(Writes.count == 1);

        Reset();
        Dir(@"Books"); File(@"Books/Books.plist", @"existing");
        root = Snapshot(); expected = Expected(root);
        File(@"Books/Books.plist", @"concurrent");
        clean = DiagnosticCleanup(NULL, Token, root, expected);
        assert([clean[@"conflict"] boolValue]);
        assert(Removed.count == 0 && Writes.count == 0);

        Reset();
        root = Snapshot(); expected = Expected(root);
        OwnNodes(); Dir(@"Books"); Dir(@"Books/Sync");
        File(@"Books/Sync/Books.plist", @"run's Books metadata");
        ChangeOnRemove = DiagnosticPaths(Token)[@"control"];
        clean = DiagnosticCleanup(NULL, Token, root, expected);
        assert([clean[@"conflict"] boolValue]);
        assert([Nodes[@"Books/Sync/Books.plist"][@"data"] isEqualToData:Bytes(@"concurrent change")]);
        assert(Writes.count == 0);

        Reset();
        Forced[@"Books"] = @((int)0xe800400a);
        root = [TestRoot stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        assert([[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:NO attributes:nil error:nil]);
        assert(![DiagnosticSnapshot(NULL, root)[@"ok"] boolValue]);
        assert(![[NSFileManager defaultManager] fileExistsAtPath:SnapshotManifestPath(root)]);

        Reset();
        Dir(@"Books"); File(@"Books/Books.plist", @"existing");
        ChangeOnStat = @"Books/Books.plist";
        root = [TestRoot stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        assert([[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:NO attributes:nil error:nil]);
        NSDictionary *snapshot = DiagnosticSnapshot(NULL, root);
        assert(![snapshot[@"ok"] boolValue]);
        assert([snapshot[@"conflict"] boolValue]);

        Reset();
        Dir(@"Books"); Dir(@"Books/Sync"); Dir(@"Books/Sync/Database");
        root = Snapshot(); expected = OwnedExpected(root, Token);
        NSString *backup = OwnedBackup(root);
        OwnedInput(expected);
        File(@"Books/Books.plist", @"system metadata");
        File(@"Books/Sync/Database/OutstandingAssets_4.sqlite", @"system database");
        File(@"Books/Sync/Database/OutstandingAssets_4.sqlite-shm", @"system shared memory");
        File(@"Books/Sync/Database/OutstandingAssets_4.sqlite-wal", @"system journal");
        booksBefore = [Nodes copy];
        NSDictionary *restored = DiagnosticRestoreOwnedBooks(NULL, Token, root, expected, backup);
        assert([restored[@"ok"] boolValue]);
        assert([restored[@"ownedBooksRestore"] isEqual:@"verified"]);
        assert([restored[@"otherBooksUnchanged"] isEqual:@YES]);
        assert([restored[@"backupVerified"] boolValue]);
        assert(!Nodes[@"Books/Sync/Books.plist"]);
        assert([Removed isEqualToArray:@[ @"Books/Sync/Books.plist" ]] && Writes.count == 0);
        for (NSString *path in booksBefore)
            if (![path isEqual:@"Books/Sync/Books.plist"])
                assert([Nodes[path] isEqualToDictionary:booksBefore[path]]);
        NSString *backupFile = [backup stringByAppendingPathComponent:@"owned-sync-books.plist"];
        assert([[NSData dataWithContentsOfFile:backupFile]
            isEqualToData:[NSData dataWithContentsOfFile:expected]]);
        [Removed removeAllObjects];
        restored = DiagnosticRestoreOwnedBooks(NULL, Token, root, expected, backup);
        assert([restored[@"ok"] boolValue] && Removed.count == 0 && Writes.count == 0);

        Reset();
        Dir(@"Books"); Dir(@"Books/Sync"); File(@"Books/Sync/Books.plist", @"original metadata");
        root = Snapshot(); expected = OwnedExpected(root, Token); backup = OwnedBackup(root);
        OwnedInput(expected);
        restored = DiagnosticRestoreOwnedBooks(NULL, Token, root, expected, backup);
        assert(![restored[@"ok"] boolValue]);
        assert([restored[@"ownedBooksRestore"] isEqual:@"unknown"]);
        assert([restored[@"otherBooksUnchanged"] isEqual:NSNull.null]);
        assert(Removed.count == 0 && Writes.count == 0);
        assert([Nodes[@"Books/Sync/Books.plist"][@"data"] isEqualToData:[NSData dataWithContentsOfFile:expected]]);

        Reset();
        Dir(@"Books"); Dir(@"Books/Sync"); root = Snapshot();
        expected = OwnedExpected(root, Token); backup = OwnedBackup(root);
        File(@"Books/Sync/Books.plist", @"not our input");
        restored = DiagnosticRestoreOwnedBooks(NULL, Token, root, expected, backup);
        assert(![restored[@"ok"] boolValue] && Removed.count == 0 && Writes.count == 0);
        assert(![[NSFileManager defaultManager] fileExistsAtPath:
            [backup stringByAppendingPathComponent:@"owned-sync-books.plist"]]);

        Reset();
        root = Snapshot(); expected = Expected(root); backup = OwnedBackup(root);
        [StatCounts removeAllObjects];
        restored = DiagnosticRestoreOwnedBooks(NULL, Token, root, expected, backup);
        assert(![restored[@"ok"] boolValue] && StatCounts.count == 0);
        assert(Removed.count == 0 && Writes.count == 0);
        expected = OwnedExpected(root, @"ffffffffffffffffffff");
        restored = DiagnosticRestoreOwnedBooks(NULL, Token, root, expected, backup);
        assert(![restored[@"ok"] boolValue] && StatCounts.count == 0);

        Reset();
        Dir(@"Books"); Dir(@"Books/Sync"); root = Snapshot(); expected = OwnedExpected(root, Token);
        OwnedInput(expected);
        restored = DiagnosticRestoreOwnedBooks(NULL, Token, root, expected, expected);
        assert(![restored[@"ok"] boolValue] && ![restored[@"backupVerified"] boolValue]);
        assert(Removed.count == 0 && Writes.count == 0);

        backup = OwnedBackup(root);
        backupFile = [backup stringByAppendingPathComponent:@"owned-sync-books.plist"];
        assert([Bytes(@"unknown local backup") writeToFile:backupFile atomically:YES]);
        restored = DiagnosticRestoreOwnedBooks(NULL, Token, root, expected, backup);
        assert(![restored[@"ok"] boolValue] && ![restored[@"backupVerified"] boolValue]);
        assert(Removed.count == 0 && Writes.count == 0);
        assert([[NSData dataWithContentsOfFile:backupFile] isEqualToData:Bytes(@"unknown local backup")]);

        Reset();
        Dir(@"Books"); Dir(@"Books/Sync"); root = Snapshot(); expected = OwnedExpected(root, Token);
        backup = OwnedBackup(root); OwnedInput(expected);
        [StatCounts removeAllObjects]; ChangeOnStat = @"Books/Sync/Books.plist";
        restored = DiagnosticRestoreOwnedBooks(NULL, Token, root, expected, backup);
        assert(![restored[@"ok"] boolValue] && [restored[@"backupVerified"] boolValue]);
        assert(Removed.count == 0 && Writes.count == 0);
        assert([Nodes[@"Books/Sync/Books.plist"][@"data"] isEqualToData:Bytes(@"concurrent change")]);

        Reset();
        Dir(@"Books"); Dir(@"Books/Sync"); root = Snapshot(); expected = OwnedExpected(root, Token);
        backup = OwnedBackup(root); OwnedInput(expected);
        [StatCounts removeAllObjects]; ChangeOnStat = @"Books/Sync/Books.plist"; ChangeAtStat = 3;
        restored = DiagnosticRestoreOwnedBooks(NULL, Token, root, expected, backup);
        assert(![restored[@"ok"] boolValue] && [restored[@"backupVerified"] boolValue]);
        assert(Removed.count == 0 && Writes.count == 0);

        Reset();
        Dir(@"Books"); Dir(@"Books/Sync"); Dir(@"Books/Sync/Database"); root = Snapshot();
        expected = OwnedExpected(root, Token); backup = OwnedBackup(root); OwnedInput(expected);
        File(@"Books/Sync/Database/OutstandingAssets_4.sqlite", @"system database");
        ChangeOtherOnRemove = @"Books/Sync/Database/OutstandingAssets_4.sqlite";
        restored = DiagnosticRestoreOwnedBooks(NULL, Token, root, expected, backup);
        assert(![restored[@"ok"] boolValue]);
        assert([restored[@"ownedBooksRestore"] isEqual:@"verified"]);
        assert([restored[@"otherBooksUnchanged"] isEqual:@NO]);

        Reset();
        Dir(@"Books"); Dir(@"Books/Sync"); root = Snapshot(); expected = OwnedExpected(root, Token);
        backup = OwnedBackup(root); OwnedInput(expected); Forced[@"Books"] = @10;
        restored = DiagnosticRestoreOwnedBooks(NULL, Token, root, expected, backup);
        assert(![restored[@"ok"] boolValue]);
        assert([restored[@"otherBooksUnchanged"] isEqual:NSNull.null]);
        assert(Removed.count == 0 && Writes.count == 0);
        puts("Native diagnostic status, snapshot and guarded cleanup checks passed");
    }
    return 0;
}
