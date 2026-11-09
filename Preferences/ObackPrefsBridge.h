//
//  ObackPrefsBridge.h
//  跨 App 偏好桥：roothide 下 NSUserDefaults(suiteName:) 的【手动写入】会落到「设置」App 自身的
//  容器副本，tweak 注入到其它 App 时读不到（黑名单/白名单因此永远无效）。本桥直接读写
//  PreferenceLoader 写入的全局 plist 文件，绕过 per-app 容器化，确保「设置」写入与「tweak」读取
//  命中同一物理文件。函数体为 static inline（ARC 安全），tweak 与设置 bundle 各自编一份、互不影响。
//
//  [prefs-src4 2026-11-09] 对齐 tweak 侧 ObackPreferences 的三候选路径：
//   旧版只读写单一直通路径 /var/mobile/Library/Preferences/com.zlhkf.oback.plist ——
//   在「设置」App（重定向生效）里它解析到 jbroot 镜像 M，于是所有面板写入只落在 M：
//     · 候选 ②（jbroot/rootfs 真实根 R）永远收不到面板写入；
//     · 「恢复默认」只清 M，R 残留旧值 ⇒ 合并读（只增不删）下商店版 App 旧偏好复活；
//     · 面板「调试日志」按钮只写 M，而 tweak 侧 debugLogEnabledLive 旧版直读 ③（商店版 App 里=R）
//       ⇒ R 里永远没有 debugLog ⇒ 微信/QQ 文件日志开不出来。
//   现在：读 = 三候选取 mtime 最新；写/清 = 三处全写/全清 + cfprefsd 域同步，与 tweak 侧逐一对称。
//
#import <Foundation/Foundation.h>
#import <dlfcn.h>

static NSString *const kOBGlobalPlist = @"/var/mobile/Library/Preferences/com.zlhkf.oback.plist";
static NSString *const kOBPrefsRel = @"var/mobile/Library/Preferences/com.zlhkf.oback.plist";

// jbroot 前缀运行时探测（与 tweak 侧 obPrefsJbrootPrefix 同构：dladdr 本镜像路径 → .jbroot-*；
// 兜底扫 /var/containers/Bundle/Application/.jbroot-* 用 usr/bin/dpkg 认门）。非 roothide 环境返回 nil。
static inline NSString *oback_jbrootPrefix(void) {
    static NSString *cached = nil;
    static BOOL probed = NO;
    if (probed) return cached;
    probed = YES;
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        Dl_info info;
        if (dladdr((const void *)&oback_jbrootPrefix, &info) && info.dli_fname) {
            NSString *p = [NSString stringWithUTF8String:info.dli_fname];
            NSMutableString *acc = [NSMutableString string];
            for (NSString *c in [p componentsSeparatedByString:@"/"]) {
                if (!c.length) continue;
                [acc appendFormat:@"/%@", c];
                if ([c hasPrefix:@".jbroot"]) {
                    if ([fm fileExistsAtPath:acc]) cached = [acc copy];
                    break;
                }
            }
        }
        if (!cached) {
            NSString *base = @"/var/containers/Bundle/Application";
            for (NSString *e in [fm contentsOfDirectoryAtPath:base error:nil]) {
                if (![e hasPrefix:@".jbroot"]) continue;
                NSString *cand = [base stringByAppendingPathComponent:e];
                if ([fm fileExistsAtPath:[cand stringByAppendingPathComponent:@"usr/bin/dpkg"]]) {
                    cached = [cand copy];
                    break;
                }
            }
        }
    } @catch (NSException *e) { (void)e; }
    return cached;
}

// 候选偏好文件：① jbroot 镜像（重定向落点）② jbroot 内 rootfs 挂载的真实根 ③ 直通
static inline NSArray *oback_candidatePaths(void) {
    NSMutableArray *a = [NSMutableArray array];
    NSString *jb = oback_jbrootPrefix();
    if (jb.length) {
        [a addObject:[jb stringByAppendingPathComponent:kOBPrefsRel]];
        [a addObject:[jb stringByAppendingPathComponent:
                      @"rootfs/var/mobile/Library/Preferences/com.zlhkf.oback.plist"]];
    }
    [a addObject:kOBGlobalPlist];
    return a;
}

// 读取全局偏好字典：三候选取 mtime 最新的一份（无命中时返回空字典，调用方须判空）
static inline NSDictionary *oback_globalPrefs(void) {
    NSDictionary *best = nil;
    NSDate *bt = nil;
    for (NSString *p in oback_candidatePaths()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (![d isKindOfClass:[NSDictionary class]] || d.count == 0) continue;
        NSDate *mt = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil] fileModificationDate];
        if (!bt || [mt compare:bt] == NSOrderedDescending) { bt = mt; best = d; }
    }
    return best ? best : @{};
}

// 写入单个 key（value 为 nil 表示删除）：三处候选全写 + cfprefsd 域同步。
// 写失败（个别路径只读/不存在）静默忽略 —— 读取端三处全读，任一落盘即可见。
static inline void oback_setGlobalPref(NSString *key, id value) {
    if (!key) return;
    for (NSString *p in oback_candidatePaths()) {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:p];
        if (!d) d = [NSMutableDictionary dictionary];
        if (value) d[key] = value; else [d removeObjectForKey:key];
        [d writeToFile:p atomically:YES];
    }
    if (value) CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFTypeRef)value,
                                        CFSTR("com.zlhkf.oback"));
    else       CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL, CFSTR("com.zlhkf.oback"));
    CFPreferencesAppSynchronize(CFSTR("com.zlhkf.oback"));
}

// 清空全部全局偏好（重置设置时使用）：三处候选全部写空 + 清 cfprefsd 域全部键。
// 必须三处全清：否则残留文件里的旧键在合并读（只增不删）下会把已重置的设置「复活」。
static inline void oback_removeGlobalPrefs(void) {
    for (NSString *p in oback_candidatePaths()) {
        [@{} writeToFile:p atomically:YES];
    }
    CFDictionaryRef cfd = CFPreferencesCopyMultiple(NULL, CFSTR("com.zlhkf.oback"),
                                                    kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
    if (cfd) {
        NSDictionary *cf = CFBridgingRelease(cfd);
        for (NSString *k in cf) {
            CFPreferencesSetAppValue((__bridge CFStringRef)k, NULL, CFSTR("com.zlhkf.oback"));
        }
        CFPreferencesAppSynchronize(CFSTR("com.zlhkf.oback"));
    }
}
