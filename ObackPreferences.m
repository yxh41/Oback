#import "ObackPreferences.h"

// 与设置面板 Root.plist 的 suite / key 保持一致
static NSString *const kDomain = @"com.zlhkf.oback";
// 全局偏好文件：PreferenceLoader（标准开关/滑块）写入此处，跨所有 App 共享。
// roothide 下，本 tweak 通过 NSUserDefaults(suiteName:) 读取可能落到「注入进程自身的容器副本」
// （尤其是黑名单这种不在标准 cell 机制内、由 ObackAppListController 手动 NSUserDefaults 写入的项），
// 导致「设置里勾选了、tweak 却读不到」——黑名单因此永远无效、永远注入。
// 故所有读取直接读本全局文件（raw 文件读，绕过 per-app 容器化），NSUserDefaults 域仅作兜底。
static NSString *const kGlobalPlistPath = @"/var/mobile/Library/Preferences/com.zlhkf.oback.plist";

@implementation ObackPreferences

#pragma mark - 合并偏好（全局文件优先 + NSUserDefaults 域兜底，带短时缓存）

static NSDictionary *__obMergedPrefs = nil;
static NSTimeInterval __obMergedPrefsTS = 0;
#define OB_MERGED_PREFS_TTL 2.0

+ (NSDictionary *)_mergedPrefs {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (__obMergedPrefs && (now - __obMergedPrefsTS) < OB_MERGED_PREFS_TTL) {
        return __obMergedPrefs;
    }
    // 1) 全局文件（跨 App 共享来源，PreferenceLoader/设置页写入处）
    NSDictionary *g = [NSDictionary dictionaryWithContentsOfFile:kGlobalPlistPath];
    if (!g) g = [NSDictionary dictionary];
    // 2) NSUserDefaults 域（兜底：非 roothide 或 suite 未被隔离的环境）
    NSUserDefaults *d = [[[NSUserDefaults alloc] initWithSuiteName:kDomain] autorelease];
    NSDictionary *suite = [d dictionaryRepresentation];
    if (!suite) suite = [NSDictionary dictionary];
    // 合并：全局文件优先（它才是跨 App 真相源）
    NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:suite];
    [m addEntriesFromDictionary:g];   // 同名 key 以全局文件为准
    NSDictionary *result = [m copy];   // MRC: copy 返回 retained(+1)，交给静态持有
    [__obMergedPrefs release];
    __obMergedPrefs = result;
    __obMergedPrefsTS = now;
    return __obMergedPrefs;
}

// 写回：同时写全局文件 + NSUserDefaults 域（保证「设置」与「tweak」两侧读写一致）
+ (void)_setObject:(id)value forKey:(NSString *)key {
    if (!key) return;
    NSUserDefaults *d = [[[NSUserDefaults alloc] initWithSuiteName:kDomain] autorelease];
    if (value) [d setObject:value forKey:key]; else [d removeObjectForKey:key];
    [d synchronize];
    // 全局文件（roothide 跨 App 共享来源）：读-改-写。写失败（部分 App 无写权限）静默忽略，
    // 不影响读取端——读取端本就优先读此文件，而「设置」App 有写权限会把它写对。
    NSMutableDictionary *g = [NSMutableDictionary dictionaryWithContentsOfFile:kGlobalPlistPath];
    if (!g) g = [NSMutableDictionary dictionary];
    if (value) g[key] = value; else [g removeObjectForKey:key];
    [g writeToFile:kGlobalPlistPath atomically:YES];
}

+ (ObackParams *)params {
    ObackParams *p = [ObackParams defaults];
    NSDictionary *d = [self _mergedPrefs];
    id v;
    if ((v = [d objectForKey:@"triggerWidth"]))     p.triggerWidth     = [v doubleValue];
    if ((v = [d objectForKey:@"parallaxOffset"]))   p.parallaxOffset   = [v doubleValue];
    if ((v = [d objectForKey:@"previousScaleMin"])) p.previousScaleMin = [v doubleValue];
    if ((v = [d objectForKey:@"shadowEnabled"]))    p.shadowEnabled    = [v boolValue];
    if ((v = [d objectForKey:@"shadowOpacity"]))    p.shadowOpacity    = [v doubleValue];
    if ((v = [d objectForKey:@"duration"]))         p.duration         = [v doubleValue];
    if ((v = [d objectForKey:@"commitRatio"]))      p.commitRatio      = [v doubleValue];
    if ((v = [d objectForKey:@"commitVelocity"]))   p.commitVelocity   = [v doubleValue];
    if ((v = [d objectForKey:@"leftEnabled"]))      p.leftEnabled      = [v boolValue];
    if ((v = [d objectForKey:@"rightEnabled"]))      p.rightEnabled     = [v boolValue];
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
    NSDictionary *d = [self _mergedPrefs];
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (!bid) return NO;

    id wm = [d objectForKey:@"whitelistMode"];
    BOOL whitelistMode = wm ? [wm boolValue] : NO;   // 未设置 → 默认全局生效（黑名单模式），符合"全局注入"设计

    if (whitelistMode) {
        NSArray *white = [d objectForKey:@"whitelistApps"];
        if (white) return [white containsObject:bid];
        // 兼容旧版字符串
        return [self _bundleId:bid inList:[d objectForKey:@"whitelistRaw"]];
    } else {
        NSArray *black = [d objectForKey:@"blacklistApps"];
        if (black) {
            if (black.count == 0) return YES;
            return ![self _bid:bid matchesList:black];
        }
        // 兼容旧版字符串
        NSString *raw = [d objectForKey:@"blacklistRaw"];
        if (!raw.length) return YES;
        return ![self _bundleId:bid inList:raw];
    }
}

// 调试日志总开关：设置面板「调试日志」(key=debugLog)。
// 默认关（日用机省电省盘）；开启后常驻开，需用户在设置面板手动关闭（已移除「30 分钟自动过期写回」，避免开着开着突然没日志的困惑）。
// 内存缓存 5s，避免每次同步 NSUserDefaults IO（OBLog 调用频率不低，即便关闭仍走此检查）。
static NSNumber *__obDebugLogCache = nil;
static NSTimeInterval __obDebugLogCacheTS = 0;
#define OB_DEBUG_LOG_CACHE_TTL 5.0

+ (BOOL)debugLogEnabled {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (__obDebugLogCache && (now - __obDebugLogCacheTS) < OB_DEBUG_LOG_CACHE_TTL) {
        return [__obDebugLogCache boolValue];
    }
    NSDictionary *d = [self _mergedPrefs];
    id v = [d objectForKey:@"debugLog"];
    BOOL enabled = v ? [v boolValue] : NO;   // 未设置 → 默认关
    // 不再做自动过期写回：调试期间用户常驻开，自动关闭会导致「开了一会就没日志」的困惑；
    // 由用户手动关闭即可（开关默认关，日用机省电）。
    NSNumber *nc = [@(enabled) retain];   // MRC：静态变量持有，必须 retain（autorelease 会在 drain 后野指针）
    [__obDebugLogCache release];
    __obDebugLogCache = nc;
    __obDebugLogCacheTS = now;
    return enabled;
}

// 导航视差「安全名单」：名单内 App 默认启用自定义 nav 视差（无感获得 premium 视差），名单外 App 仍走
// 系统原生 pop（方案A，最稳）。未知 App 不翻车。名单保持保守（结构简单的标准 nav App），新增需逐 App 真机验证。
+ (BOOL)_inParallaxSafelist {
    static NSArray *safe = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 种子名单：Apple 系统 App（标准 UINavigationController，结构稳定，视差风险低）。
        // 如需第三方 App，请逐个加入并真机验证稳定性后保留。
        safe = [@[ @"com.apple.Preferences", @"com.apple.MobileSMS", @"com.apple.Mail",
                   @"com.apple.mobilecal", @"com.apple.reminders", @"com.apple.Notes",
                   @"com.apple.Music", @"com.apple.Maps" ] retain];   // MRC：静态变量需 retain（autorelease 会在 drain 后野指针）
    });
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (!bid) return NO;
    if ([safe containsObject:bid]) return YES;   // 种子系统 App 永远在名单（无需勾选）
    // 用户在设置「选视差程序」里手动勾选的 App（跨 App 全局文件真相源，ObackAppListController 写入 parallaxApps）。
    id v = [[self _mergedPrefs] objectForKey:@"parallaxApps"];
    if ([v isKindOfClass:[NSArray class]]) {
        return [(NSArray *)v containsObject:bid];
    }
    return NO;
}

// 导航视差实验开关：设置面板「导航视差（实验）」(key=navParallax)，默认关。
// 开 → 所有 App nav pop 走自定义 ObackAnimator 视差转场；关（默认）→ 仅「安全名单」内 App 走自定义视差，
// 其余走系统原生 pop（方案A，最稳）。实验功能，需多 App 真机验证。
+ (BOOL)navParallaxEnabled {
    if ([self _inParallaxSafelist]) return YES;   // 安全名单内 App 默认启用（无感获得 premium 视差）
    NSDictionary *d = [self _mergedPrefs];
    id v = [d objectForKey:@"navParallax"];
    return v ? [v boolValue] : NO;   // 未设置 → 默认关
}

// 双返回诊断开关：设置面板「双返回诊断」(key=doubleReturnDiag)，默认关。
// 开启后，每次边缘起滑补链时把本 window 所有边缘返回手势的精确类名打进日志，
// 便于定位「一次滑动返回两层」中的「第二层」是系统原生还是某插件私有手势。
+ (BOOL)doubleReturnDiagEnabled {
    NSDictionary *d = [self _mergedPrefs];
    id v = [d objectForKey:@"doubleReturnDiag"];
    return v ? [v boolValue] : NO;   // 未设置 → 默认关
}

// 诊断横幅独立隐藏开关：key=diagBanner，默认关（设置面板「诊断横幅」开关控制，无需手动写 plist）。
// 开 → 每次注入在 start 打印 [Oback-diag] 横幅（真实 bid / 名单状态 / isAllowed），用于排查黑名单命中、装包来源；
// 关（默认）→ 完全不打印，日用机零日志噪声。此前该横幅为常开且绕过「调试日志」开关，
// 现改为受本独立开关控制：默认关 = 不给用户添噪声；需要时临时开 = 仍可绕过 roothide 容器隔离抓到真实 bid。
+ (BOOL)diagBannerEnabled {
    NSDictionary *d = [self _mergedPrefs];
    id v = [d objectForKey:@"diagBanner"];
    return v ? [v boolValue] : NO;   // 未设置 → 默认关
}

// 胶囊特效：设置面板「胶囊风格」(key=capsuleEffect)。
// 取值含义（见 ObackManager.m 的 ObackCapsuleEffect 枚举）：0=经典（默认）/1=发光/2=霓虹/3=流光/4=毛玻璃/5=呼吸。
// 越界值回落经典(0)。此处用字面量边界(0..5)以避免跨文件依赖该枚举定义。
+ (NSInteger)capsuleEffect {
    NSDictionary *d = [self _mergedPrefs];
    id v = [d objectForKey:@"capsuleEffect"];
    NSInteger e = v ? [v integerValue] : 0;   // 未设置 → 默认经典
    if (e < 0 || e > 5) e = 0;
    return e;
}

@end
