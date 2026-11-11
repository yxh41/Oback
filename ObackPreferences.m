#import "ObackPreferences.h"
#import <dlfcn.h>

// 与设置面板 Root.plist 的 suite / key 保持一致
static NSString *const kDomain = @"com.zlhkf.oback";
// 全局偏好文件：PreferenceLoader（标准开关/滑块）写入此处，跨所有 App 共享。
// roothide 下，本 tweak 通过 NSUserDefaults(suiteName:) 读取可能落到「注入进程自身的容器副本」
// （尤其是黑名单这种不在标准 cell 机制内、由 ObackAppListController 手动 NSUserDefaults 写入的项），
// 导致「设置里勾选了、tweak 却读不到」——黑名单因此永远无效、永远注入。
// 故所有读取直接读本全局文件（raw 文件读，绕过 per-app 容器化），NSUserDefaults 域仅作兜底。
static NSString *const kGlobalPlistPath = @"/var/mobile/Library/Preferences/com.zlhkf.oback.plist";

// [prefs-src2 2026-11-08] 读取来源优先级（低 → 高）：suite 域 < cfprefsd < 全局 plist 文件。
// 背景：App Store 版 App（标准沙盒）里 /var/mobile 的直通读写会被沙盒接管，全局文件直读返回 nil；
// 而「系统 App / 越狱 App / 巨魔 App」的 suite 域恰好就解析到同一个全局文件 ⇒ 长期把这条失败掩盖成「正常」。
// 一旦直读失败，只有 App Store App 暴露：胶囊回落经典(0) + 黑名单空 ⇒ isAllowed fail-open 放行。
// cfprefsd 的文件打开发生在系统守护进程（沙盒外），客户端侧的容器视图管不到它 ⇒ 沙盒进程也能拿到真实值。
static NSString *__obPrefsDiag = nil;   // "src=file+cf gk=12 cfk=11 sk=0"，供诊断横幅显示

static NSDictionary *OBCfPrefsCopy(CFStringRef user, CFStringRef host) {
    CFDictionaryRef cf = CFPreferencesCopyMultiple(NULL, CFSTR("com.zlhkf.oback"), user, host);
    if (!cf) return nil;
    NSDictionary *d = [(NSDictionary *)cf copy];
    CFRelease(cf);
    return [d autorelease];
}


// ──────────────────────────────────────────────────────────────────────────────
// [prefs-src3 2026-11-08] roothide 路径重定向（见 Apple Wiki / RootHide 设计）
//   RootHide 把 /var/mobile/Library/Preferences 重定向到随机 jbroot 路径，并设置 CFFIXED_USER_HOME。
//   ⇒ 同一个「路径」在不同进程里可能落在两个不同文件上：
//      · 重定向生效的进程（系统/越狱/巨魔 App）→ jbroot 镜像 M；
//      · 重定向不生效的进程（App Store 版 App）→ 真实文件 R（空/陈旧）。
//   这就是「设置里看着对、设置 App 里生效、微信里胶囊变样 + 黑名单失效」的机制。
//   修法：三条候选路径全读（jbroot 镜像 / jbroot 内 rootfs 挂载的真实根 / 直通 /var/mobile），
//   按文件 mtime 升序合并（越新越优先）；写侧三处全写。jbroot 前缀运行时探测、不硬编码随机路径。
// ──────────────────────────────────────────────────────────────────────────────
static char *obPrefsJbAnchor = NULL;   // 仅为给 dladdr 提供一个落在本镜像内的地址

static NSString *obPrefsJbrootPrefix(void) {
    static NSString *cached = nil;
    static BOOL probed = NO;
    if (probed) return cached;
    probed = YES;
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        Dl_info info;
        if (dladdr((const void *)&obPrefsJbAnchor, &info) && info.dli_fname) {
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
        if (!cached) {   // 兜底：在 jbroot 实现位置找 .jbroot-*，用 dpkg 认门
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

static NSString *const kPrefsRel = @"var/mobile/Library/Preferences/com.zlhkf.oback.plist";

// 候选偏好文件（顺序 = 优先级从低到高的兜底次序；实际合并按 mtime 定夺）
static NSArray *obPrefsCandidatePaths(void) {
    NSMutableArray *a = [NSMutableArray array];
    NSString *jb = obPrefsJbrootPrefix();
    if (jb.length) {
        [a addObject:[jb stringByAppendingPathComponent:kPrefsRel]];                       // ① jbroot 镜像（重定向落点）
        [a addObject:[jb stringByAppendingPathComponent:@"rootfs/var/mobile/Library/Preferences/com.zlhkf.oback.plist"]]; // ② jbroot 内 bind mount 的真实根
    }
    [a addObject:kGlobalPlistPath];                                                       // ③ 直通
    return a;
}

@implementation ObackPreferences

#pragma mark - 合并偏好（候选文件按 mtime 取新 + cfprefsd + NSUserDefaults 域兜底，带短时缓存）

static NSDictionary *__obMergedPrefs = nil;
static NSTimeInterval __obMergedPrefsTS = 0;
#define OB_MERGED_PREFS_TTL 2.0

+ (NSString *)_prefsDiagInfo {
    return __obPrefsDiag ? __obPrefsDiag : @"src=none gk=0 cfk=0 sk=0 fc=0";
}

+ (NSDictionary *)_mergedPrefs {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (__obMergedPrefs && (now - __obMergedPrefsTS) < OB_MERGED_PREFS_TTL) {
        return __obMergedPrefs;
    }
    NSMutableDictionary *m = [NSMutableDictionary dictionary];

    // ③-a suite 域（最低优先级；沙盒进程里它是自己容器的空副本）
    NSUserDefaults *d = [[[NSUserDefaults alloc] initWithSuiteName:kDomain] autorelease];
    NSDictionary *suite = [d dictionaryRepresentation];
    NSUInteger sk = suite ? suite.count : 0;
    if (sk) [m addEntriesFromDictionary:suite];

    // ③-b cfprefsd（沙盒进程的 home 被 CFFIXED_USER_HOME 重定向时它也只返回容器副本，故仅作兜底）
    NSDictionary *cf = OBCfPrefsCopy(kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
    if (!cf.count) cf = OBCfPrefsCopy(kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
    if (!cf.count) cf = OBCfPrefsCopy(kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    NSUInteger cfk = cf ? cf.count : 0;
    if (cfk) [m addEntriesFromDictionary:cf];

    // ① / ② 候选文件：全读，按 mtime 升序合并（越新越优先）。
    //     roothide 下同一份偏好可能同时存在于 jbroot 镜像与真实根，且两边由不同写入通道更新
    //     （PSSwitchCell 走 cfprefsd 写真实根；我们的 _setObject: 走 writeToFile 写镜像）⇒ 只能按时间取新。
    NSArray *cands = obPrefsCandidatePaths();
    NSMutableArray *found = [NSMutableArray array];
    NSUInteger fc = 0;
    for (NSString *p in cands) {
        NSDictionary *fd = [NSDictionary dictionaryWithContentsOfFile:p];
        if (![fd isKindOfClass:[NSDictionary class]] || fd.count == 0) continue;
        fc++;
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
        NSDate *mt = [attrs fileModificationDate];
        [found addObject:@[ mt ? mt : [NSDate distantPast], fd ]];
    }
    [found sortUsingComparator:^NSComparisonResult(id a, id b) {
        return [(NSDate *)[a objectAtIndex:0] compare:(NSDate *)[b objectAtIndex:0]];
    }];
    for (NSArray *e in found) [m addEntriesFromDictionary:[e objectAtIndex:1]];
    NSUInteger gk = found.count ? m.count : 0;   // 仅用于诊断：有文件命中时的合并后键数

    // 诊断串：src 标明哪几类来源有货（f 后数字 = 命中的候选文件个数）
    NSString *src = gk ? @"file" : (cfk ? @"cf" : (sk ? @"suite" : @"none"));
    [__obPrefsDiag release];
    __obPrefsDiag = [[NSString alloc] initWithFormat:@"src=%@ gk=%lu cfk=%lu sk=%lu fc=%lu",
                     src, (unsigned long)gk, (unsigned long)cfk, (unsigned long)sk, (unsigned long)fc];

    NSDictionary *result = [m copy];   // MRC: copy 返回 retained(+1)，交给静态持有
    [__obMergedPrefs release];
    __obMergedPrefs = result;
    __obMergedPrefsTS = now;
    if (result.count == 0) {
        static BOOL __obPrefsWarned = NO;   // 每进程只报一次
        if (!__obPrefsWarned) {
            __obPrefsWarned = YES;
            NSLog(@"[Oback-prefs] 偏好四源全空(bid=%@ jbroot=%@)：胶囊/名单/日志开关全部回落默认",
                  [[NSBundle mainBundle] bundleIdentifier], obPrefsJbrootPrefix());
        }
    }
    return __obMergedPrefs;
}

// 写回：同时写全局文件 + NSUserDefaults 域（保证「设置」与「tweak」两侧读写一致）
+ (void)_setObject:(id)value forKey:(NSString *)key {
    if (!key) return;
    NSUserDefaults *d = [[[NSUserDefaults alloc] initWithSuiteName:kDomain] autorelease];
    if (value) [d setObject:value forKey:key]; else [d removeObjectForKey:key];
    [d synchronize];
    // [prefs-src2] 同步写一份到 cfprefsd：App Store 版 App 读不到全局文件（沙盒接管 /var/mobile），
    // 但能通过 cfprefsd 读到本域 ⇒ 这是沙盒进程唯一的可用通道。写失败（沙盒拒绝写非自身域）静默忽略，
    // 下方 raw 文件写仍是权威源，两者并存不冲突。
    if (value) CFPreferencesSetAppValue((CFStringRef)key, (CFTypeRef)value, CFSTR("com.zlhkf.oback"));
    else       CFPreferencesSetAppValue((CFStringRef)key, NULL, CFSTR("com.zlhkf.oback"));
    CFPreferencesAppSynchronize(CFSTR("com.zlhkf.oback"));
    // 全局文件（roothide 跨 App 共享来源）：读-改-写。写失败（部分 App 无写权限）静默忽略，
    // 不影响读取端——读取端本就优先读此文件，而「设置」App 有写权限会把它写对。
    // [prefs-src3] 三处候选全写：roothide 下 /var/mobile/Library/Preferences 被重定向到随机 jbroot 路径，
    // 单写一个路径在「另一半进程」里看不到；三处都写才能保证两类进程读到同一份。写失败静默忽略。
    for (NSString *p in obPrefsCandidatePaths()) {
        NSMutableDictionary *g = [NSMutableDictionary dictionaryWithContentsOfFile:p];
        if (!g) g = [NSMutableDictionary dictionary];
        if (value) g[key] = value; else [g removeObjectForKey:key];
        [g writeToFile:p atomically:YES];
    }
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
// 文本选择手柄拖不动 / 返回失效），为其定制的两套专用子系统已在 T4 从源码移除，此处再在黑名单
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
    // [prefs-boundary1] 三候选按 mtime 取最新：roothide 下 %ctor 里直读 ③ 会命中真实根 R（陈旧/空），
    // 而熔断键由面板写在 ①（jbroot 镜像）⇒ 单路径会让应急回退通道失效。
    // 仍只用 dictionaryWithContentsOfFile / NSFileManager（%ctor 早期安全），不走 NSUserDefaults / cfprefsd。
    NSDate *best = nil;
    id val = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in obPrefsCandidatePaths()) {
        NSDictionary *g = [NSDictionary dictionaryWithContentsOfFile:p];
        id v = [g objectForKey:@"settingsAppEnabled"];
        if (![v respondsToSelector:@selector(boolValue)]) continue;
        NSDate *mt = [[fm attributesOfItemAtPath:p error:nil] fileModificationDate];
        NSDate *t = mt ? mt : [NSDate distantPast];
        if (!best || [t compare:best] == NSOrderedDescending) { best = t; val = v; }
    }
    return val ? [val boolValue] : YES;   // 从未写过 / 未设置 → 默认开
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

    // [prefs-boundary1] 名单值必须校验类型：plist 被其它工具写入脏数据（字符串/数字）时，
    // 旧代码对非 NSArray 发 containsObject: / .count 会直接抛异常 ⇒ 注入进程崩溃。
    // 类型不符时回落到旧版逗号分隔字符串兼容路径，行为保守而非崩溃。
    if (whitelistMode) {
        id w = [d objectForKey:@"whitelistApps"];
        if ([w isKindOfClass:[NSArray class]]) return [(NSArray *)w containsObject:bid];
        id rw = [d objectForKey:@"whitelistRaw"];
        return [self _bundleId:bid inList:([rw isKindOfClass:[NSString class]] ? rw : nil)];
    } else {
        id b = [d objectForKey:@"blacklistApps"];
        if ([b isKindOfClass:[NSArray class]]) {
            NSArray *black = (NSArray *)b;
            if (black.count == 0) return YES;
            return ![self _bid:bid matchesList:black];
        }
        id rb = [d objectForKey:@"blacklistRaw"];
        NSString *raw = [rb isKindOfClass:[NSString class]] ? rb : nil;
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

// 无动画修复列表：命中此列表的 App，其左缘强制走 rightSimplePop 非交互标准滑出返回
// （系统交互转场不渲染/无动画的自定义 nav，如酷安 com.coolapk.app），避免方案A 空转瞬切无动画。
// 与微信硬编码特例（_navPopShouldDriveSystemNav:）同源行为，但改为按 App 用户勾选（设置页「选无动画修复程序」写入 navPopFallbackApps）。
// 默认空（列表空）→ 不影响任何 App；仅勾选 App 的左缘改走 rightSimplePop（有动画、不跟手），右缘/弹窗不受影响。
+ (BOOL)isNavPopFallback {
    NSDictionary *d = [self _mergedPrefs];
    NSArray *list = [d objectForKey:@"navPopFallbackApps"];
    if (![list isKindOfClass:[NSArray class]] || list.count == 0) return NO;
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (!bid) return NO;
    return [self _bid:bid matchesList:list];
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
// [prefs-src4] 旧版直读单一路径 kGlobalPlistPath（③ 直通）会漏：商店版 App 里 ③=真实根 R，
// 而设置面板经 ObackPrefsBridge 写的是 jbroot 镜像 M ⇒ R 里永远没有 debugLog
// ⇒ 微信/QQ 等商店版 App 的文件日志永远开不出来。改为三候选取 mtime 最新一份；
// 无任何候选文件可读时回落 _mergedPrefs（suite/cfprefsd 兜底）。
+ (BOOL)debugLogEnabledLive {
    NSDictionary *best = nil;
    NSDate *bt = nil;
    for (NSString *p in obPrefsCandidatePaths()) {
        NSDictionary *fd = [NSDictionary dictionaryWithContentsOfFile:p];
        if (![fd isKindOfClass:[NSDictionary class]] || fd.count == 0) continue;
        NSDate *mt = [[[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil] fileModificationDate];
        if (!bt || [mt compare:bt] == NSOrderedDescending) { bt = mt; best = fd; }
    }
    NSDictionary *d = best ? best : [self _mergedPrefs];
    id v = [d objectForKey:@"debugLog"];
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

// [A'] 「接管即独占」开关（设置面板「接管即独占」key=exclusivePop），默认关。
// 开 → Oback 一旦确认接管本次返回手势（手势 Began），就在本次手势期间临时禁用 App 自带的返回手势：
//     含系统/插件的边缘返回 pan、挂在 nav.view 树上的全屏返回 pan、以及类名含返回语义词
//     （PushPop/SlideBack/SwipeBack/PopGesture/BackGesture/PanPop）的自研全屏返回 pan
//     —— 覆盖「挂在独立 overlay window 上、抢同一次滑动」的 QQ NTPushPopLib 这类手势；
//     滚动、文本选择/光标、列表左滑操作一律放行，绝不禁用。松手/取消后 0.12s 自动恢复。
// 关（默认）→ 完全不改任何 App 手势的 enabled 状态，行为与加本开关之前逐字一致。
// [R13 2026-09-18] 「独占排除」名单（key=exclusivePopExcludeApps，默认空 = 全局生效）。
// 语义刻意选**排除列表**而非白名单：默认空 ⇒ 不开名单者行为与 R13 之前逐字一致，只增能力、不改现网默认。
// 命中 App ⇒ exclusivePopEnabled 返回 NO ⇒ 独占功能的 7 个调用点（左缘链接 / 接管期压制 / 常驻对账含还原 /
// push 对账早退 / 自愈收编 / pop-firer 诊断自愈门控 / touchesBegan 重压）全部走「开关已关」分支：
// 既不再压制该 App 的任何手势，也会把此前已常驻禁用的对手手势还原 ⇒ 「这个 App 不要独占」是**可撤销**的。
// ⚠️ 只作用于独占功能：Oback 的基础边缘返回、胶囊、黑/白名单、左缘排除等一律不受影响。
// ⚠️ 与「整 App 黑名单」的区别：黑名单是不注入（连基础返回/胶囊都没有）；本名单只退掉独占。
+ (BOOL)isExclusivePopExcluded {
    NSDictionary *d = [self _mergedPrefs];
    NSArray *list = [d objectForKey:@"exclusivePopExcludeApps"];
    if (![list isKindOfClass:[NSArray class]] || list.count == 0) return NO;
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (!bid) return NO;
    return [self _bid:bid matchesList:list];
}

+ (BOOL)exclusivePopEnabled {
    NSDictionary *d = [self _mergedPrefs];
    id v = [d objectForKey:@"exclusivePop"];
    if (!(v ? [v boolValue] : NO)) return NO;   // 未设置 → 默认关
    // [R13 2026-09-18] 按 App 排除（key=exclusivePopExcludeApps，默认空）：命中者视同「开关未开」。
    // 本函数是独占的**唯一总闸**（7 个调用点全经此处取开关值）⇒ 一处判断即 7 处生效，零调用点改动。
    // 语义 = 排除列表而非白名单：默认空时此处恒不成立，行为与加本能力之前逐字一致。
    if ([self isExclusivePopExcluded]) return NO;
    return YES;
}

// ── [兜底返回 2026-09-27] ────────────────────────────────────────────────────────────────
// 动机：nav 栈深 1（不可 pop）且无弹窗的页面（全屏播放器 / 图片查看器 / 自绘返回的自定义容器）
// 上，Oback 现有三级动作派发全部找不到目标 ⇒ 左缘手势只能空转。本能力在这类页面上改为
// 「查找并触发该页左上角的返回 / 关闭按钮」。
// 安全设计（见 ObackManager 的 _obFallbackBackControlIn:）：只认「返回 / 关闭」语义的控件，
// 未命中一律不点 —— 宁可漏，不可错（页面上任何一次错误点击的代价都远高于「滑了没反应」）。
// 默认关（key=fallbackBack）：不开则本能力完全不存在，行为与加本能力之前逐字一致。
+ (BOOL)isFallbackBackExcluded {
    NSDictionary *d = [self _mergedPrefs];
    NSArray *list = [d objectForKey:@"fallbackBackExcludeApps"];
    if (![list isKindOfClass:[NSArray class]] || list.count == 0) return NO;
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (!bid) return NO;
    return [self _bid:bid matchesList:list];
}

+ (BOOL)fallbackBackEnabled {
    NSDictionary *d = [self _mergedPrefs];
    id v = [d objectForKey:@"fallbackBack"];
    if (!(v ? [v boolValue] : NO)) return NO;   // 未设置 → 默认关
    // 按 App 排除（key=fallbackBackExcludeApps，默认空）：命中者视同「开关未开」。
    // 本函数是兜底返回的**唯一总闸**（shouldBegin 一处调用）⇒ 一处判断即全局生效。
    // 语义 = 排除列表而非白名单：默认空时此处恒不成立，行为与加本能力之前逐字一致。
    if ([self isFallbackBackExcluded]) return NO;
    return YES;
}

// 语义词表是否包含「关闭 / 取消 / ✕」：默认开。开 = 覆盖全屏播放器 / 图片查看器 / 弹窗式编辑页
// （左上角是 ✕）；关 = 只认 返回 / back / ‹ / ←，更安全，但左上角是 ✕ 的页面依然返回不了。
// 注意：编辑类页面的「取消」会丢弃未保存内容 —— 误触时请关掉本项或把该 App 加入兜底排除。
+ (BOOL)fallbackBackCloseEnabled {
    NSDictionary *d = [self _mergedPrefs];
    id v = [d objectForKey:@"fallbackBackClose"];
    return v ? [v boolValue] : YES;   // 未设置 → 默认开
}

// [P0-1 2026-10-16] WebView 内返回。默认关。
// 为什么单独一个开关而不是并进 fallbackBack：纯 H5 壳 App（整个 App 一个 WKWebView）上，
// 「返回网页上一页」和「退出这个页面」是两个语义，用户不一定想要前者。有 canGoBack 守卫
// 所以不会死循环，但要不要这个行为交给用户。上游总闸 fallbackBackEnabled 已含排除名单。
+ (BOOL)fallbackBackWebEnabled {
    NSDictionary *d = [self _mergedPrefs];
    id v = [d objectForKey:@"fallbackBackWeb"];
    return v ? [v boolValue] : NO;   // 未设置 → 默认关
}

// [2b-1 2026-10-16] 控件搜索范围扩展到 top VC 的 view 树左上区。默认关。
// 为什么默认关而不是默认开：搜索面从「导航栏」扩大到「整页」，即使仍受左区 + 词表 +
// 唯一候选 + 小图标四重约束，暴露面也实实在在变大了（左上角可能是「扫一扫」「我的」）。
// 这与 fallbackBack 总开关的哲学一致：宁可漏，不可错；要覆盖自绘返回的用户自己开。
// 上游总闸 fallbackBackEnabled 已含排除名单。
+ (BOOL)fallbackBackViewTreeEnabled {
    NSDictionary *d = [self _mergedPrefs];
    id v = [d objectForKey:@"fallbackBackViewTree"];
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
