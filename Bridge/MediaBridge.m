// MediaBridge — streams "Now Playing" state from the private MediaRemote framework.
//
// Since macOS 15.4, MediaRemote only answers processes whose bundle identifier
// starts with "com.apple.". /usr/bin/perl qualifies, so MyNotch loads this dylib
// into perl (via DynaLoader) and talks to it over stdin/stdout:
//
//   stdout: one JSON object per line  {"type":"state", ...}
//   stdin : commands, one per line     toggle | play | pause | next | prev | seek <seconds> | refresh
//
// The process exits as soon as stdin closes (i.e. when MyNotch quits).

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef Boolean (*MRSendCommandFn)(int, CFDictionaryRef);
typedef void (*MRSetElapsedFn)(double);
typedef void (*MRGetClientFn)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*MRClientStringFn)(id);

static MRGetInfoFn pGetInfo;
static MRGetIsPlayingFn pGetIsPlaying;
static MRGetPIDFn pGetPID;
static MRRegisterFn pRegister;
static MRSendCommandFn pSend;
static MRSetElapsedFn pSetElapsed;
static MRGetClientFn pGetClient;
static MRClientStringFn pClientBundle;
static MRClientStringFn pClientParentBundle;

static dispatch_queue_t gQueue;
static NSUInteger gLastArtHash = 0;
static NSString *gLastPayload = nil;
static BOOL gRefreshPending = NO;
static NSMutableData *gStdinBuffer;
static dispatch_source_t gTimer;
static dispatch_source_t gInput;

static void emit(NSDictionary *dict) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static id plainValue(id v) {
    if (!v || v == [NSNull null]) return nil;
    if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) return v;
    if ([v isKindOfClass:[NSDate class]]) return @([(NSDate *)v timeIntervalSince1970]);
    return nil;
}

static NSUInteger artHash(NSData *d) {
    if (d.length == 0) return 0;
    // Cheap but stable fingerprint: length + a few sampled bytes.
    const uint8_t *b = d.bytes;
    NSUInteger h = d.length * 2654435761u;
    NSUInteger step = d.length / 64 + 1;
    for (NSUInteger i = 0; i < d.length; i += step) h = (h * 31) ^ b[i];
    return h == 0 ? 1 : h;
}

static void refreshNow(void) {
    pGetInfo(gQueue, ^(CFDictionaryRef cfInfo) {
        NSDictionary *info = cfInfo ? [(__bridge NSDictionary *)cfInfo copy] : @{};
        pGetIsPlaying(gQueue, ^(Boolean playing) {
            pGetPID(gQueue, ^(int pid) {
                void (^finish)(NSString *, NSString *) = ^(NSString *bundle, NSString *parent) {
                    NSMutableDictionary *o = [NSMutableDictionary dictionary];
                    o[@"type"] = @"state";
                    o[@"playing"] = @(playing ? YES : NO);
                    o[@"pid"] = @(pid);
                    if (bundle) o[@"bundle"] = bundle;
                    if (parent) o[@"parentBundle"] = parent;
                    NSDictionary *keys = @{
                        @"title": @"kMRMediaRemoteNowPlayingInfoTitle",
                        @"artist": @"kMRMediaRemoteNowPlayingInfoArtist",
                        @"album": @"kMRMediaRemoteNowPlayingInfoAlbum",
                        @"duration": @"kMRMediaRemoteNowPlayingInfoDuration",
                        @"elapsed": @"kMRMediaRemoteNowPlayingInfoElapsedTime",
                        @"rate": @"kMRMediaRemoteNowPlayingInfoPlaybackRate",
                        @"timestamp": @"kMRMediaRemoteNowPlayingInfoTimestamp",
                        @"mime": @"kMRMediaRemoteNowPlayingInfoArtworkMIMEType",
                    };
                    for (NSString *k in keys) {
                        id v = plainValue(info[keys[k]]);
                        if (v) o[k] = v;
                    }
                    NSString *payload = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:o options:NSJSONWritingSortedKeys error:nil] encoding:NSUTF8StringEncoding];

                    NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                    if (![art isKindOfClass:[NSData class]]) art = nil;
                    NSUInteger h = artHash(art);
                    BOOL artChanged = (h != gLastArtHash);
                    if (!artChanged && payload && [payload isEqualToString:gLastPayload]) return; // nothing new
                    gLastPayload = payload;
                    if (artChanged) {
                        gLastArtHash = h;
                        o[@"artwork"] = art ? [art base64EncodedStringWithOptions:0] : @"";
                    }
                    emit(o);
                };
                if (pGetClient && pClientBundle) {
                    pGetClient(gQueue, ^(id client) {
                        NSString *bundle = nil, *parent = nil;
                        if (client) {
                            CFStringRef b = pClientBundle(client);
                            if (b) bundle = [(__bridge NSString *)b copy];
                            if (pClientParentBundle) {
                                CFStringRef p = pClientParentBundle(client);
                                if (p) parent = [(__bridge NSString *)p copy];
                            }
                        }
                        finish(bundle, parent);
                    });
                } else {
                    finish(nil, nil);
                }
            });
        });
    });
}

static void scheduleRefresh(void) {
    if (gRefreshPending) return;
    gRefreshPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), gQueue, ^{
        gRefreshPending = NO;
        refreshNow();
    });
}

static void handleCommand(NSString *line) {
    NSString *cmd = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cmd.length == 0) return;
    if ([cmd isEqualToString:@"play"]) pSend(0, NULL);
    else if ([cmd isEqualToString:@"pause"]) pSend(1, NULL);
    else if ([cmd isEqualToString:@"toggle"]) pSend(2, NULL);
    else if ([cmd isEqualToString:@"next"]) pSend(4, NULL);
    else if ([cmd isEqualToString:@"prev"]) pSend(5, NULL);
    else if ([cmd hasPrefix:@"seek "] && pSetElapsed) pSetElapsed([[cmd substringFromIndex:5] doubleValue]);
    else if ([cmd isEqualToString:@"refresh"]) { gLastPayload = nil; gLastArtHash = 0; }
    scheduleRefresh();
}

static void *sym(void *h, const char *name) { return dlsym(h, name); }

static NSString *notificationName(void *h, const char *symbol, NSString *fallback) {
    CFStringRef *p = (CFStringRef *)dlsym(h, symbol);
    if (p && *p) return (__bridge NSString *)*p;
    return fallback;
}

__attribute__((visibility("default")))
void mn_stream(void) {
    @autoreleasepool {
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!h) { emit(@{@"type": @"error", @"message": @"MediaRemote unavailable"}); exit(2); }
        pGetInfo = (MRGetInfoFn)sym(h, "MRMediaRemoteGetNowPlayingInfo");
        pGetIsPlaying = (MRGetIsPlayingFn)sym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        pGetPID = (MRGetPIDFn)sym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
        pRegister = (MRRegisterFn)sym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
        pSend = (MRSendCommandFn)sym(h, "MRMediaRemoteSendCommand");
        pSetElapsed = (MRSetElapsedFn)sym(h, "MRMediaRemoteSetElapsedTime");
        pGetClient = (MRGetClientFn)sym(h, "MRMediaRemoteGetNowPlayingClient");
        pClientBundle = (MRClientStringFn)sym(h, "MRNowPlayingClientGetBundleIdentifier");
        pClientParentBundle = (MRClientStringFn)sym(h, "MRNowPlayingClientGetParentAppBundleIdentifier");
        if (!pGetInfo || !pGetIsPlaying || !pGetPID || !pRegister || !pSend) {
            emit(@{@"type": @"error", @"message": @"MediaRemote symbols missing"});
            exit(3);
        }
        gQueue = dispatch_get_main_queue();
        gStdinBuffer = [NSMutableData data];

        pRegister(gQueue);
        NSArray *names = @[
            notificationName(h, "kMRMediaRemoteNowPlayingInfoDidChangeNotification", @"kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            notificationName(h, "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification", @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
            notificationName(h, "kMRMediaRemoteNowPlayingApplicationDidChangeNotification", @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"),
        ];
        for (NSString *n in names) {
            [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *note) {
                dispatch_async(gQueue, ^{ scheduleRefresh(); });
            }];
        }

        // Safety net: re-check every 3 seconds (cheap; only emits on change).
        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
        dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), 3 * NSEC_PER_SEC, 500 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(gTimer, ^{ refreshNow(); });
        dispatch_resume(gTimer);

        // Commands from MyNotch.
        gInput = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, gQueue);
        dispatch_source_set_event_handler(gInput, ^{
            char buf[4096];
            ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));
            if (n <= 0) exit(0); // parent went away
            [gStdinBuffer appendBytes:buf length:(NSUInteger)n];
            while (YES) {
                const char *bytes = gStdinBuffer.bytes;
                NSUInteger len = gStdinBuffer.length;
                const char *nl = memchr(bytes, '\n', len);
                if (!nl) break;
                NSUInteger lineLen = (NSUInteger)(nl - bytes);
                NSString *line = [[NSString alloc] initWithBytes:bytes length:lineLen encoding:NSUTF8StringEncoding];
                [gStdinBuffer replaceBytesInRange:NSMakeRange(0, lineLen + 1) withBytes:NULL length:0];
                if (line) handleCommand(line);
            }
        });
        dispatch_resume(gInput);

        emit(@{@"type": @"hello"});
        refreshNow();
    }
    dispatch_main();
}
