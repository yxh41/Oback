#import "ObackPreferences.h"

// 与设置面板 Root.plist 的 suite / key 保持一致
static NSString *const kDomain = @"com.zlhkf.oback";

@implementation ObackPreferences

+ (ObackParams *)params {
    ObackParams *p = [ObackParams defaults];
    NSUserDefaults *d = [[[NSUserDefaults alloc] initWithSuiteName:kDomain] autorelease];
    id v;
    if ((v = [d objectForKey:@"triggerWidth"]))     p.triggerWidth     = [v doubleValue];
    if ((v = [d objectForKey:@"parallaxOffset"]))   p.parallaxOffset   = [v doubleValue];
    if ((v = [d objectForKey:@"previousScaleMin"])) p.previousScaleMin = [v doubleValue];
    if ((v = [d objectForKey:@"dimAlpha"]))         p.dimAlpha         = [v doubleValue];
    if ((v = [d objectForKey:@"shadowEnabled"]))    p.shadowEnabled    = [v boolValue];
    if ((v = [d objectForKey:@"shadowOpacity"]))    p.shadowOpacity    = [v doubleValue];
    if ((v = [d objectForKey:@"duration"]))         p.duration         = [v doubleValue];
    if ((v = [d objectForKey:@"commitRatio"]))      p.commitRatio      = [v doubleValue];
    if ((v = [d objectForKey:@"commitVelocity"]))   p.commitVelocity   = [v doubleValue];
    if ((v = [d objectForKey:@"leftEnabled"]))      p.leftEnabled      = [v boolValue];
    if ((v = [d objectForKey:@"rightEnabled"]))     p.rightEnabled     = [v boolValue];
    if ((v = [d objectForKey:@"hapticEnabled"]))    p.hapticEnabled    = [v boolValue];
    if ((v = [d objectForKey:@"springEnabled"]))    p.springEnabled    = [v boolValue];
    if ((v = [d objectForKey:@"cardCornerEnabled"])) p.cardCornerEnabled = [v boolValue];
    if ((v = [d objectForKey:@"cardCornerValue"]))  p.cardCornerValue  = [v doubleValue];
    return p;
}

// 解析逗号/换行分隔的 bundle id 列表，命中返回 YES
+ (BOOL)_bundleId:(NSString *)bid inList:(NSString *)raw {
    if (!raw.length || !bid) return NO;
    NSArray *parts = [raw componentsSeparatedByCharactersInSet:
                      [NSCharacterSet characterSetWithCharactersInString:@",\n"]];
    for (NSString *s in parts) {
        NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length && [t isEqualToString:bid]) return YES;
    }
    return NO;
}

// 黑名单/白名单匹配：大小写不敏感 + 前缀兜底（黑名单项是 bid 的「点分隔前缀」时亦命中，
// 用于同 App 的不同构建/变体，如 com.xunmeng.merchant 亦命中 com.xunmeng.merchant.phone）。
+ (BOOL)_bid:(NSString *)bid matchesList:(NSArray *)list {
    if (!list.count || !bid.length) return NO;
    NSString *lb = [bid lowercaseString];
    for (NSString *entry in list) {
        if (![entry isKindOfClass:[NSString class]] || !entry.length) continue;
        NSString *le = [entry lowercaseString];
        if ([le isEqualToString:lb]) return YES;
        if ([lb hasPrefix:le] && [lb length] > [le length] && [lb characterAtIndex:[le length]] == '.') return YES;
    }
    return NO;
}

// 是否允许当前 App 生效：
//  - whitelistMode 未设置或 YES：只有白名单内的 App 生效（空白名单 = 全部不生效）
//  - whitelistMode == NO：回到全局生效 + 黑名单排除（原逻辑）
//  新版用 whitelistApps / blacklistApps 数组（设置页 App 选择器写入）；
//  旧版用 whitelistRaw / blacklistRaw 逗号分隔字符串，做了兼容。
+ (BOOL)isAllowed {
    NSUserDefaults *d = [[[NSUserDefaults alloc] initWithSuiteName:kDomain] autorelease];
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (!bid) return NO;

    id wm = [d objectForKey:@"whitelistMode"];
    BOOL whitelistMode = wm ? [wm boolValue] : NO;   // 未设置 → 默认全局生效（黑名单模式），符合"全局注入"设计

    if (whitelistMode) {
        NSArray *white = [d arrayForKey:@"whitelistApps"];
        if (white) return [white containsObject:bid];
        // 兼容旧版字符串
        return [self _bundleId:bid inList:[d stringForKey:@"whitelistRaw"]];
    } else {
        NSArray *black = [d arrayForKey:@"blacklistApps"];
        if (black) {
            if (black.count == 0) return YES;
            return ![self _bid:bid matchesList:black];
        }
        // 兼容旧版字符串
        NSString *raw = [d stringForKey:@"blacklistRaw"];
        if (!raw.length) return YES;
        return ![self _bundleId:bid inList:raw];
    }
}

+ (BOOL)isBlacklisted {
    NSUserDefaults *d = [[[NSUserDefaults alloc] initWithSuiteName:kDomain] autorelease];
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (!bid) return NO;
    NSArray *black = [d arrayForKey:@"blacklistApps"];
    if (black) return [self _bid:bid matchesList:black];
    // 兼容旧版字符串
    NSString *raw = [d stringForKey:@"blacklistRaw"];
    if (!raw.length) return NO;
    return [self _bundleId:bid inList:raw];
}

// 调试日志总开关：设置面板「调试日志」(key=debugLog)。
// 默认关（日用机省电省盘）；开启后 30 分钟自动过期写回关闭，防止忘记关一直刷 syslog 偷电。
// 内存缓存 5s，避免每次同步 NSUserDefaults IO（OBLog 调用频率不低，即便关闭仍走此检查）。
static NSNumber *__obDebugLogCache = nil;
static NSTimeInterval __obDebugLogCacheTS = 0;
static NSTimeInterval __obDebugLogOpenedAt = 0;
#define OB_DEBUG_LOG_CACHE_TTL 5.0
#define OB_DEBUG_LOG_EXPIRE   1800.0   // 30 分钟

+ (BOOL)debugLogEnabled {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (__obDebugLogCache && (now - __obDebugLogCacheTS) < OB_DEBUG_LOG_CACHE_TTL) {
        return [__obDebugLogCache boolValue];
    }
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    id v = [d objectForKey:@"debugLog"];
    BOOL enabled = v ? [v boolValue] : NO;   // 未设置 → 默认关
    if (enabled) {
        // 刚从关闭切到开启：记录开启时刻，用于自动过期
        if (!(__obDebugLogCache && [__obDebugLogCache boolValue])) {
            __obDebugLogOpenedAt = now;
        }
        // 开启超过 30 分钟自动过期：写回关闭，避免忘记关持续偷电
        if (__obDebugLogOpenedAt > 0 && (now - __obDebugLogOpenedAt) > OB_DEBUG_LOG_EXPIRE) {
            enabled = NO;
            [d setBool:NO forKey:@"debugLog"];
            [d synchronize];
            __obDebugLogOpenedAt = 0;
        }
    } else {
        __obDebugLogOpenedAt = 0;
    }
    [d release];
    NSNumber *nc = [@(enabled) retain];   // MRC：静态变量持有，必须 retain（autorelease 会在 drain 后野指针）
    [__obDebugLogCache release];
    __obDebugLogCache = nc;
    __obDebugLogCacheTS = now;
    return enabled;
}

// 导航视差实验开关：设置面板「导航视差（实验）」(key=navParallax)，默认关。
// 开 → nav pop 走自定义 ObackAnimator 视差转场（当前页平移+投影，灵敏度滑块对导航返回也生效）；
// 关（默认）→ 系统原生 pop（方案A，最稳）。实验功能，需多 App 真机验证。
+ (BOOL)navParallaxEnabled {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    id v = [d objectForKey:@"navParallax"];
    [d release];
    return v ? [v boolValue] : NO;   // 未设置 → 默认关
}

// 双返回诊断开关：设置面板「双返回诊断」(key=doubleReturnDiag)，默认关。
// 开启后，每次边缘起滑补链时把本 window 所有边缘返回手势的精确类名打进日志，
// 便于定位「一次滑动返回两层」中的「第二层」是系统原生还是某插件私有手势。
+ (BOOL)doubleReturnDiagEnabled {
    NSUserDefaults *d = [[[NSUserDefaults alloc] initWithSuiteName:kDomain] autorelease];
    id v = [d objectForKey:@"doubleReturnDiag"];
    return v ? [v boolValue] : NO;   // 未设置 → 默认关
}

@end
