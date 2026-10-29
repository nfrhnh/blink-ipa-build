// SideloadFix shim — build-from-source replacement for the prebuilt dylib.
// Behaviour mirrors waruhachi/SideloadFix (which derives from IGSideloadFix,
// Bea, TwitchAdBlock, RedditSideloadFix):
//   1. force kSecAttrAccessGroup on keychain queries to the group this build
//      was actually signed with (entitlements we ship have no keychain groups),
//   2. give NSFileManager a writable stand-in for App Group containers,
//   3. keep NSBundle reporting the real identifier/name for callers inside the
//      main bundle.
// No networking, no file access outside the app sandbox, no dynamic loading.

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include "fishhook.h"

static NSString *gKeychainGroup = nil;
static NSURL *gFakeGroupContainer = nil;
static NSString *gOriginalBundleID = nil;
static NSString *gOriginalAppName = nil;

static OSStatus (*orig_SecItemAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*orig_SecItemUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus (*orig_SecItemDelete)(CFDictionaryRef);

static CFDictionaryRef SGWithGroup(CFDictionaryRef dict, NSString *group) {
    CFMutableDictionaryRef mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, dict);
    CFDictionarySetValue(mutable, kSecAttrAccessGroup, (__bridge const void *)group);
    CFDictionaryRef copy = CFDictionaryCreateCopy(kCFAllocatorDefault, mutable);
    CFRelease(mutable);
    return copy;
}

static OSStatus hook_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (gKeychainGroup && CFDictionaryContainsKey(attributes, kSecAttrAccessGroup)) {
        CFDictionaryRef fixed = SGWithGroup(attributes, gKeychainGroup);
        OSStatus status = orig_SecItemAdd(fixed, result);
        CFRelease(fixed);
        return status;
    }
    return orig_SecItemAdd(attributes, result);
}

static OSStatus hook_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (gKeychainGroup && CFDictionaryContainsKey(query, kSecAttrAccessGroup)) {
        CFDictionaryRef fixed = SGWithGroup(query, gKeychainGroup);
        OSStatus status = orig_SecItemCopyMatching(fixed, result);
        CFRelease(fixed);
        return status;
    }
    return orig_SecItemCopyMatching(query, result);
}

static OSStatus hook_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    if (gKeychainGroup && CFDictionaryContainsKey(query, kSecAttrAccessGroup)) {
        CFDictionaryRef fixed = SGWithGroup(query, gKeychainGroup);
        OSStatus status = orig_SecItemUpdate(fixed, attributesToUpdate);
        CFRelease(fixed);
        return status;
    }
    return orig_SecItemUpdate(query, attributesToUpdate);
}

static OSStatus hook_SecItemDelete(CFDictionaryRef query) {
    if (gKeychainGroup && CFDictionaryContainsKey(query, kSecAttrAccessGroup)) {
        CFDictionaryRef fixed = SGWithGroup(query, gKeychainGroup);
        OSStatus status = orig_SecItemDelete(fixed);
        CFRelease(fixed);
        return status;
    }
    return orig_SecItemDelete(query);
}

static void SGLoadKeychainGroup(void) {
    NSDictionary *dummy = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount : @"dummyItem",
        (__bridge id)kSecAttrService : @"dummyService",
        (__bridge id)kSecReturnAttributes : @YES,
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)dummy, &result);
    if (status == errSecItemNotFound) {
        status = SecItemAdd((__bridge CFDictionaryRef)dummy, &result);
    }
    if (status == errSecSuccess && result) {
        NSDictionary *attrs = (__bridge_transfer NSDictionary *)result;
        NSString *group = attrs[(__bridge id)kSecAttrAccessGroup];
        if ([group isKindOfClass:[NSString class]]) {
            gKeychainGroup = [group copy];
        }
    }
}

@interface NSFileManager (SGSideload)
- (NSURL *)sg_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier;
@end

@implementation NSFileManager (SGSideload)

- (NSURL *)sg_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    if (!gFakeGroupContainer) return nil;
    NSURL *fake = [gFakeGroupContainer URLByAppendingPathComponent:groupIdentifier];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *library = [fake URLByAppendingPathComponent:@"Library"];
    [fm createDirectoryAtURL:fake withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtURL:library withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtURL:[library URLByAppendingPathComponent:@"Caches"]
  withIntermediateDirectories:YES attributes:nil error:nil];
    return fake;
}

@end

static NSString *(*orig_bundleIdentifier)(id, SEL);
static id (*orig_objectForInfoDictionaryKey)(id, SEL, NSString *);

static NSString *sg_bundleIdentifier(id self, SEL _cmd) {
    NSArray *addresses = [NSThread callStackReturnAddresses];
    if (addresses.count > 2 && gOriginalBundleID) {
        Dl_info info;
        if (dladdr((void *)[addresses[2] longLongValue], &info) != 0 && info.dli_fname) {
            NSString *path = [NSString stringWithUTF8String:info.dli_fname];
            NSString *mainPath = [NSBundle mainBundle].bundlePath;
            if (mainPath && [path hasPrefix:mainPath]) return gOriginalBundleID;
        }
    }
    return orig_bundleIdentifier(self, _cmd);
}

static id sg_objectForInfoDictionaryKey(id self, SEL _cmd, NSString *key) {
    if ([key isEqualToString:@"CFBundleIdentifier"] && gOriginalBundleID) return gOriginalBundleID;
    if (([key isEqualToString:@"CFBundleDisplayName"] || [key isEqualToString:@"CFBundleName"]) && gOriginalAppName) {
        return gOriginalAppName;
    }
    return orig_objectForInfoDictionaryKey(self, _cmd, key);
}

__attribute__((constructor)) static void SGInit(void) {
    @autoreleasepool {
        NSDictionary *info = [NSBundle mainBundle].infoDictionary;
        gOriginalBundleID = [info[@"CFBundleIdentifier"] copy];
        gOriginalAppName = [(info[@"CFBundleName"] ?: info[@"CFBundleDisplayName"]) copy];
        gFakeGroupContainer = [NSURL fileURLWithPath:
            [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/FakeGroupContainers"]
                                              isDirectory:YES];

        SGLoadKeychainGroup();

        struct rebinding bindings[] = {
            {"SecItemAdd", (void *)hook_SecItemAdd, (void **)&orig_SecItemAdd},
            {"SecItemCopyMatching", (void *)hook_SecItemCopyMatching, (void **)&orig_SecItemCopyMatching},
            {"SecItemUpdate", (void *)hook_SecItemUpdate, (void **)&orig_SecItemUpdate},
            {"SecItemDelete", (void *)hook_SecItemDelete, (void **)&orig_SecItemDelete},
        };
        rebind_symbols(bindings, 4);

        Method real = class_getInstanceMethod([NSFileManager class],
                            @selector(containerURLForSecurityApplicationGroupIdentifier:));
        Method mine = class_getInstanceMethod([NSFileManager class],
                            @selector(sg_containerURLForSecurityApplicationGroupIdentifier:));
        if (real && mine) method_exchangeImplementations(real, mine);

        Method bid = class_getInstanceMethod([NSBundle class], @selector(bundleIdentifier));
        if (bid) {
            orig_bundleIdentifier = (void *)method_getImplementation(bid);
            method_setImplementation(bid, (IMP)sg_bundleIdentifier);
        }
        Method oik = class_getInstanceMethod([NSBundle class], @selector(objectForInfoDictionaryKey:));
        if (oik) {
            orig_objectForInfoDictionaryKey = (void *)method_getImplementation(oik);
            method_setImplementation(oik, (IMP)sg_objectForInfoDictionaryKey);
        }

        NSLog(@"[SideloadFix] initialized (bundle=%@ group=%@)", gOriginalBundleID,
              gKeychainGroup ? gKeychainGroup : @"<none>");
    }
}
