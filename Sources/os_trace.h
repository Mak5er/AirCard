#ifndef AIRCARD_OS_TRACE_H
#define AIRCARD_OS_TRACE_H

#import <Foundation/Foundation.h>

// Wire format reference:
// https://github.com/libimobiledevice/libimobiledevice/blob/master/include/libimobiledevice/ostrace.h

// os_trace_relay frames use a type byte followed by a 32-bit payload length.
// Plist replies (type 1) use big endian; activity records (type 2) use little
// endian. Read through the service connection so secure sessions work too.
typedef long (*AirCardTraceReceive)(void *connection, void *bytes, long length);

static BOOL AirCardTraceReadExact(AirCardTraceReceive receive, void *connection,
                                 void *bytes, NSUInteger length) {
    NSUInteger offset = 0;
    while (offset < length) {
        long count = receive(connection, (uint8_t *)bytes + offset,
                             (long)(length - offset));
        if (count <= 0 || (NSUInteger)count > length - offset) return NO;
        offset += (NSUInteger)count;
    }
    return YES;
}

static uint32_t AirCardTraceUInt32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
           ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static uint16_t AirCardTraceUInt16(const uint8_t *bytes) {
    return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

// 帧读取失败时返回中文诊断；帧类型、长度校验和解码过程保持原有协议。
static NSData *AirCardTraceReadFrame(AirCardTraceReceive receive,
                                    void *connection, uint8_t *type,
                                    NSString **error) {
    uint8_t header[5];
    if (!AirCardTraceReadExact(receive, connection, header, sizeof(header))) {
        *error = @"设备日志流已断开或意外结束。";
        return nil;
    }
    *type = header[0];
    uint32_t length;
    if (*type == 1) {
        length = ((uint32_t)header[1] << 24) | ((uint32_t)header[2] << 16) |
                 ((uint32_t)header[3] << 8) | header[4];
    } else if (*type == 2) {
        length = AirCardTraceUInt32(header + 1);
    } else {
        *error = @"设备返回了不支持的日志帧类型。";
        return nil;
    }
    // Reject corrupt lengths before allocating or waiting for a payload.
    if (length == 0 || length > 16 * 1024 * 1024) {
        *error = @"设备返回了无效的日志帧长度。";
        return nil;
    }
    NSMutableData *payload = [NSMutableData dataWithLength:length];
    if (!AirCardTraceReadExact(receive, connection, payload.mutableBytes, length)) {
        *error = @"设备日志流在记录尚未接收完整时结束。";
        return nil;
    }
    return payload;
}

static NSString *AirCardTraceString(const uint8_t *bytes, NSUInteger length) {
    while (length && bytes[length - 1] == 0) length--;
    NSString *text = [[NSString alloc] initWithBytes:bytes length:length
                                          encoding:NSUTF8StringEncoding];
    return text ?: [[NSString alloc] initWithBytes:bytes length:length
                                          encoding:NSISOLatin1StringEncoding];
}

static NSString *AirCardTraceLogLine(NSData *record) {
    // The activity record has a 129-byte header, then length-delimited process,
    // image and message strings. Read fields explicitly to avoid alignment and
    // host-endian assumptions. Ignore non-log or incomplete activity records.
    if (record.length < 129) return nil;
    const uint8_t *bytes = record.bytes;
    if (bytes[0] != 2) return nil;
    NSUInteger headerLength = AirCardTraceUInt32(bytes + 5);
    NSUInteger processLength = AirCardTraceUInt16(bytes + 37);
    NSUInteger imageLength = AirCardTraceUInt16(bytes + 107);
    NSUInteger messageLength = AirCardTraceUInt32(bytes + 109);
    if (headerLength < 129 || headerLength > record.length ||
        !processLength || !messageLength ||
        processLength + imageLength + messageLength > record.length - headerLength)
        return nil;

    const uint8_t *text = bytes + headerLength;
    NSString *process = AirCardTraceString(text, processLength).lastPathComponent;
    NSString *image = AirCardTraceString(text + processLength, imageLength).lastPathComponent;
    NSString *message = AirCardTraceString(text + processLength + imageLength,
                                           messageLength);
    // Keep multiline messages intact: CoreFoundation's resource lookup logs
    // expose Wallet .pkpass paths on a continuation line on iOS 18.
    return [NSString stringWithFormat:@"%@(%@): %@\n", process, image, message];
}

#endif
