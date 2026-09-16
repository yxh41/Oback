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
    if ((v = [d objectForKey:@"duration"]))         p.duration         = [v doubleValue];
    if ((v = [d objectForKey:@"commitRatio"]))      p.commitRatio      = [v doubleValue];
    if ((v = [d objectForKey:@"commitVelocity"]))   p.commitVelocity   = [v doubleValue];
    if ((v = [d objectForKey:@"leftEnabled"]))      p.leftEnabled      = [v boolValue];
    if ((v = [d objectForKey:@"rightEnabled"]))      p.rightEnabled     = [v boolValue];
    if ((v = [d objectForKey:@"hapticEnabled"]))    p.hapticEnabled    = [v boolValue];
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

// [已移除 2026-09-15，用户拍板] 内置排除列表（原 T4 / 2026-08-23）：QQ(com.tencent.mqq) / TIM(com.tencent.tim)。
// 原逻辑：这两个 App 用 NTPushPopLib 等自研转场库整体接管交互返回，与 Oback 长期抢手势（瞬返 /
// 文本选择手柄拖不动 / 全屏返回失效），为其定制的两套专用子系统已在 T4 从源码移除，此处再在黑名单
// 模式下对其短路 return NO（等价于内置黑名单）。
// 移除原因：面板里能勾上却永远不生效，属「看不见的规则」，与「用户自己配置」的设计冲突。
// 现与其他 App 完全一致，需要规避时请用户自行选用（均对用户可见、可撤销）：
//   - 整 App 不注入 → 选黑名单程序；
//   - 左缘交还系统、保留右缘+弹窗 → 选左缘排除程序；
//   - 返回无动画/瞬切 → 选无动画修复程序（走非交互 pop，正是历史上 QQ/TIM 唯一有效的一条路）；
//   - 单页左缘冲突 → 左缘·按页排除（VC 类名）。

// 当前进程是否为系统「设置」App。bundle id 大小写在不同版本不固定，故大小写不敏感比较。
// 精确匹配（不做「点前缀兜底」）：避免误命中设置进程的 extension（如 com.apple.Preferences.xxx）。
+ (BOOL)isSettingsApp {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (!bid.length) return NO;
    return [bid caseInsensitiveCompare:@"com.apple.Preferences"] == NSOrderedSame;
}

// 「设置 App 内生效」熔断键（plist key=settingsAppEnabled，默认开）。
// ⚠️ 这是**隐藏熔断键，设置面板里没有对应开关**（用户要求面板保持精简）——日常无需关心，
// 仅当「设置」App 因 Oback 注入出现异常时应急使用。
// 熔断方式：Filza 编辑 /var/mobile/Library/Preferences/com.zlhkf.oback.plist，把 settingsAppEnabled
// 置 0 → 约 2 秒（_mergedPrefs TTL）内停止接管手势；上滑杀掉设置 App 重开则彻底不装 hook。
// 背景：Tweak.xm 的 %ctor 一律跳过 com.apple.* 系统进程（防系统 UI 异常），但用户需要在系统设置里
// 也能用 Oback 的跟手返回，故对「设置」App 单独开洞，并由此键控制是否真正生效。
// ⚠️ 直读全局文件、不走 _mergedPrefs / NSUserDefaults：本方法要在 %ctor（dylib 加载早期，
// NSUserDefaults 尚未就绪）被调用，任何高层 API 都可能在此阶段出问题；dictionaryWithContentsOfFile 是安全的。
+ (BOOL)settingsAppEnabled {
    NSDictionary *g = [NSDictionary dictionaryWithContentsOfFile:kGlobalPlistPath];
    if (!g) return YES;                 // 从未写过偏好 → 默认开
    id v = [g objectForKey:@"settingsAppEnabled"];
    if (!v) return YES;                 // 未设置 → 默认开
    if ([v respondsToSelector:@selector(boolValue)]) return [v boolValue];
    return YES;
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

    // [已移除 2026-09-15] 此处原为 QQ/TIM 内置排除（!whitelistMode && _isBuiltinExcluded → return NO）。
    // 面板里勾得上却永远不生效属隐形规则，已按用户拍板删除；QQ/TIM 现与其他 App 完全一致，
    // 需要规避时由用户自行选用黑名单 / 左缘排除 / 无动画修复 / 按页排除（VC 类名）。

    // 「设置」App 例外开关（key=settingsAppEnabled，默认开）：关掉后 2 秒内（_mergedPrefs TTL）
    // 即从所有入口（start / attachToWindow / linkNav / shouldBegin）停止接管，无需杀设置 App。
    // 这是注入系统进程的秒级回退通道：万一设置 App 内出现异常，拨掉开关即可恢复原生行为。
    if ([self isSettingsApp] && ![self settingsAppEnabled]) return NO;

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

// 左缘排除列表：命中此列表的 App，左缘不再由 Oback 接管（交还系统原生 interactivePop），
// 但右缘返回 + 弹窗 dismiss 仍由 Oback 提供。≠ 全局黑名单（黑名单是整 App 不注入）。
+ (BOOL)isLeftEdgeExcluded {
    NSDictionary *d = [self _mergedPrefs];
    NSArray *list = [d objectForKey:@"leftEdgeExcludeApps"];
    if (![list isKindOfClass:[NSArray class]] || list.count == 0) return NO;
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (!bid) return NO;
    return [self _bid:bid matchesList:list];
}

// [优化③] 左缘按页（VC）排除：在已允许左缘返回的 App 内，命中 leftEdgeExcludedVCs（VC 类名子串，
// 大小写不敏感）的顶层 VC，该页左缘交还页面自身手势，Oback 不接管（右缘返回 + 弹窗 dismiss 仍由 Oback 提供）。
// ≠ 按 App 排除(leftEdgeExcludeApps)：按 App 是整 App 不接管左缘；按页是同一 App 内仅个别页面让出左缘。
// 设置面板 PSTextFieldCell 以逗号/换行分隔字符串写入；兼容数组写入。
+ (BOOL)isLeftEdgeExcludedVC:(NSString *)className {
    if (!className.length) return NO;
    NSDictionary *d = [self _mergedPrefs];
    id raw = [d objectForKey:@"leftEdgeExcludedVCs"];
    NSMutableArray *list = [NSMutableArray array];
    if ([raw isKindOfClass:[NSString class]] && [raw length]) {
        NSArray *parts = [raw componentsSeparatedByCharactersInSet:
                          [NSCharacterSet characterSetWithCharactersInString:@",\n"]];
        for (NSString *s in parts) {
            NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (t.length) [list addObject:t];
        }
    } else if ([raw isKindOfClass:[NSArray class]]) {
        for (id e in (NSArray *)raw) if ([e isKindOfClass:[NSString class]] && [e length]) [list addObject:e];
    }
    if (!list.count) return NO;
    NSString *lc = [className lowercaseString];
    for (NSString *sub in list) {
        if ([lc containsString:[sub lowercaseString]]) return YES;
    }
    return NO;
}

// 全局返回列表：命中此列表的 App 启用「全屏/任意位置返回」——Oback 左缘 edge pan 不接管
// （交全屏 pan 统一接管左→右 nav pop），系统 interactivePop 仍禁用防双触发；右缘 modal dismiss
// 仍由 Oback 提供。≠ 黑名单（整 App 不注入）、≠ 左缘排除（左缘交还系统原生 interactivePop）。
// 默认关（列表空）；仅勾选 App 开启，其他 App 行为零变化。
+ (BOOL)isGlobalBackEnabled {
    NSDictionary *d = [self _mergedPrefs];
    NSArray *list = [d objectForKey:@"globalBackApps"];
    if (![list isKindOfClass:[NSArray class]] || list.count == 0) return NO;
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (!bid) return NO;
    return [self _bid:bid matchesList:list];
}

// 无动画修复列表：命中此列表的 App，其左缘/全局返回强制走 rightSimplePop 非交互标准滑出返回
// （系统交互转场不渲染/无动画的自定义 nav，如酷安 com.coolapk.app），避免方案A 空转瞬切无动画。
// 与微信硬编码特例（_navPopShouldDriveSystemNav:）同源行为，但改为按 App 用户勾选（设置页「选无动画修复程序」写入 navPopFallbackApps）。
// 默认空（列表空）→ 不影响任何 App；仅勾选 App 的左缘+全局返回改走 rightSimplePop（有动画、不跟手），右缘/弹窗不受影响。
+ (BOOL)isNavPopFallback {
    NSDictionary *d = [self _mergedPrefs];
    NSArray *list = [d objectForKey:@"navPopFallbackApps"];
    if (![list isKindOfClass:[NSArray class]] || list.count == 0) return NO;
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (!bid) return NO;
    return [self _bid:bid matchesList:list];
}

// 全局返回触发侧：开=右侧薄热区 + 左滑返回（右手单握，拇指不用伸到左边）；关=左侧热区 + 右滑返回
// （左手单握，默认）。仅影响「全局返回列表」内 App 的全屏 pan 起滑位置与手势方向；其他 App 零变化。
// 右侧路径走 currentEdge=ObackEdgeRight 非交互 pop（rightSimplePop：松手提交才 popViewControllerAnimated:，动画交还系统原生）。
+ (BOOL)isGlobalBackRightSide {
    NSDictionary *d = [self _mergedPrefs];
    id v = [d objectForKey:@"globalBackRightSide"];
    return v ? [v boolValue] : NO;   // 未设置 → 默认左(关)
}

// 调试日志总开关：设置面板「调试日志」(key=debugLog)。
// 默认关（日用机省电省盘）；开启后常驻开，需用户在设置面板手动关闭（已移除「30 分钟自动过期写回」，避免开着开着突然没日志的困惑）。
// 读取统一走 _mergedPrefs（TTL 2s），不再额外加 5s 独立缓存——否则「开关改了要等 5s 才生效/才停止」会表现为时灵时不灵。
+ (BOOL)debugLogEnabled {
    NSDictionary *d = [self _mergedPrefs];
    id v = [d objectForKey:@"debugLog"];
    return v ? [v boolValue] : NO;   // 未设置 → 默认关
}

// [v11] 实时读 debugLog（绕过 _mergedPrefs 的 2s TTL 缓存），确保设置面板开关翻转后下次手势即生效，
// 消除「开着没日志 / 时灵时不灵」。仅此低频开关实时读，不增加高频调用负担。
+ (BOOL)debugLogEnabledLive {
    NSDictionary *g = [NSDictionary dictionaryWithContentsOfFile:kGlobalPlistPath];
    if (!g) return NO;
    id v = [g objectForKey:@"debugLog"];
    return v ? [v boolValue] : NO;
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
// 取值含义（见 ObackManager.m 的 ObackCapsuleEffect 枚举）：0=经典（默认）/1=发光/2=霓虹/3=流光/4=毛玻璃/5=呼吸
// /6=液态液滴（深色细长柳叶形，贴屏幕边缘平直、外侧鼓起、上下端收尖，随拖动从边缘「长」出来）。
// 越界值回落经典(0)。此处用字面量边界(0..6)以避免跨文件依赖该枚举定义。
+ (NSInteger)capsuleEffect {
    NSDictionary *d = [self _mergedPrefs];
    id v = [d objectForKey:@"capsuleEffect"];
    NSInteger e = v ? [v integerValue] : 0;   // 未设置 → 默认经典
    if (e < 0 || e > 6) e = 0;
    return e;
}

@end
