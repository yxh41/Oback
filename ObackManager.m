#import "ObackManager.h"
#import "ObackPreferences.h"
#import <objc/runtime.h>

// [v11] 私有方法前向声明：obShowLogCallback 是 C 函数，需显式声明否则 -Werror 报方法找不到
@interface ObackManager ()
- (void)_armShowLogOnForeground;
- (void)_obShowLogNow;
- (void)_obPresentLogVC:(NSString *)text;
- (void)_obDismissLogVC;
- (UIViewController *)_obKeyRootVC;
- (NSString *)_obBuildLogText;
- (void)_obShareLog:(UIBarButtonItem *)sender;
- (void)_obCopyLog;
- (NSArray<UIWindow *> *)_allVisibleWindows;   // [P3] 集中枚举可见 window，替代 5 处重复实现
- (void)_obInterruptActiveInteraction;   // [P8] 进后台/自愈看门狗强制收尾进行中交互（防 QQ 快照 watchdog 闪退）
- (void)_obEnterForeground;              // [2026-09-16 watchdog 修复] 回前台解除后台禁令并补一次链接
- (void)_linkNavPopGesturesInWindow:(UIWindow *)win;  // 全窗口链接（超时早退/后台早退）
- (void)_suppressOpponentPansForPan:(UIPanGestureRecognizer *)pan;  // [A'] 接管即独占：本次手势期间压制 App 自带返回手势（面板开关 exclusivePop，默认关）
- (void)_restoreOpponentPansDeferred;                               // [A'] 松手/取消后延后恢复（防对手基于残留 touch 瞬判返回 → 瞬闪）
- (void)_restoreOpponentPans;                                      // [A'] 立即恢复（进后台强制收尾时用）
- (void)_restoreOpponentPansIfIdle;                                // [A'] 安全阀：未真正接管时恢复（shouldBegin YES 却从未 Began 的兜底）
- (NSHashTable *)_suppressedPanTable;                              // [A'] 被压制手势的弱引用表（MRC 下由关联对象持有）
- (NSHashTable *)_exclusiveDisabledPanTable;                       // [R7 方案A] 独占常驻禁用的对手手势（弱引用；开关关时统一还原）
- (BOOL)_isSwipeRightPopOpponentPan:(UIPanGestureRecognizer *)g;    // [R7 方案A] 是否「右滑返回」类对手手势（方案A 打击面）
- (void)_obReconcileExclusivePersistentSuppress:(UIWindow *)win;    // [R7 方案A] 独占常驻压制：开→持久禁右滑返回类；关→统一还原
- (void)_obReconcileExclusivePersistentSuppressForNav:(UINavigationController *)nav;  // [R8] push 时对账（push 后 0.35s 再补扫一次，抓懒建的对手手势）
- (void)_obReconcileExclusiveSuppressDeferred;                       // [R8] push 后的延后补扫（幂等）
- (BOOL)_obAdoptExclusiveSuppressForPan:(UIPanGestureRecognizer *)g reason:(NSString *)reason;  // [R8 自愈] 漏网 pop 凶手即时收编
- (BOOL)_isNavInteractivePop:(UIGestureRecognizer *)g;             // [A'] 是否为某 nav 的系统原生 interactivePop（放行不碰）
- (BOOL)_isAllowlistedOpponentPan:(UIPanGestureRecognizer *)g view:(UIView *)v;  // [A'] 放行清单
- (BOOL)_isPopLikeOpponentPan:(UIPanGestureRecognizer *)g view:(UIView *)v nav:(UINavigationController *)nav;  // [A'] 命中「返回语义」
- (void)_obDiagArenaSnapshotForPan:(UIPanGestureRecognizer *)pan window:(UIWindow *)win nav:(UINavigationController *)nav edge:(ObackEdge)edge point:(CGPoint)loc;  // [R3 诊断] 仲裁现场快照（谁已经赢了 / 对手是谁 / 有没有被咨询）
- (void)_obLinkLeftEdgeOpponentPansInWindow:(UIWindow *)win;   // [R4 甲] 左缘对手链接器（镜像右缘）：对手须等我们的左缘 pan 失败
- (void)_obLinkLeftEdgeOpponentPansIfStale:(UIWindow *)win;   // [R4 甲] 左缘懒补链（2s 节流，抓晚到的新手势）
@property (nonatomic, retain) UIActivityViewController *logActivityVC;  // [v11c] retain 防活动视图控制器提前释放(MRC 陷阱)
@end

// [构建标记] 人工标签写在这里，**commit 短哈希由 CI 自动追加**（.github/workflows/build.yml 的
// "Patch package version with git hash" 步骤会把本行改写成 @"<标签>+<短哈希>"），故不必手改哈希。
// 日志开启时打印，用于一锤定音确认装的是哪个代码版本（解决"装的是不是最新"的争议）。
#define OBACK_BUILD_TAG @"qq-excl10"

// [v11] 内存 ring buffer：OBLog 同步写入，供「App 内弹窗看日志」用，彻底绕开 roothide 沙盒文件隔离
// （App 进程写 /var/mobile/*.log 实际落在自身容器，Filza/设置面板读的是另一容器视图，导致日志时有时无）。
static NSMutableArray *__obLogBuf = nil;
static const NSUInteger kOBLogBufMax = 600;
static BOOL __obShowLogArmed = NO;

static void obShowLogCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    @autoreleasepool {
        [(ObackManager *)observer _armShowLogOnForeground];
    }
}

#pragma mark - 诊断日志（落地文件 + syslog，便于真机定位手势为何不触发）

static NSString *OBLogPath(void) {
    // 优先写到所有 App 共享的 /var/mobile（roothide 下 App 可写，可被 Filza 一次抓取）
    NSString *shared = @"/var/mobile/oback_debug.log";
    if ([[NSFileManager defaultManager] isWritableFileAtPath:@"/var/mobile"]) return shared;
    // 兜底：退回各自沙盒 Documents
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES) firstObject];
    return dir ? [dir stringByAppendingPathComponent:@"oback_debug.log"] : shared;
}

static BOOL _obLogWasOn = NO;   // 跟踪上次开关状态，用于「关→开」翻转时打分隔标记（明确日志起点边界）

// [P1] debugLog 开关状态微缓存：避免每条日志都读盘整个 plist（见 OBLog 内使用）
static BOOL __obLogEnabledCache = NO;            // 缓存的开关值
static NSTimeInterval __obLogEnabledCacheTS = 0;  // 缓存时间戳（timeIntervalSinceReferenceDate）
#define OB_LOG_ENABLED_TTL 0.3                     // 缓存窗口(秒)：少读盘 vs 开关近即时生效

void OBLog(NSString *fmt, ...) {
    // [P1] 热路径微缓存：debugLog 开关缓存 0.3s，避免每条日志都 dictionaryWithContentsOfFile 读整个 plist
    // （此前每次触摸十余次主线程磁盘 IO，低端机可感微卡；现每 0.3s 最多读一次，开关翻转延迟≤0.3s 仍近即时）。
    NSTimeInterval __obLogNow = [NSDate timeIntervalSinceReferenceDate];
    BOOL enabled;
    if ((__obLogNow - __obLogEnabledCacheTS) < OB_LOG_ENABLED_TTL) {
        enabled = __obLogEnabledCache;
    } else {
        enabled = [ObackPreferences debugLogEnabledLive];
        __obLogEnabledCache = enabled;
        __obLogEnabledCacheTS = __obLogNow;
    }
    if (!enabled) {
        // 开→关翻转：追加「关闭」分隔标记，明确日志边界，消除「关了还有日志」的困惑
        // （那其实是旧文件累积；有边界标记就能一眼看出哪段是有效日志、哪段是历史）。仅打一次，不持续写。
        if (_obLogWasOn) {
            _obLogWasOn = NO;
            NSString *sep = [NSString stringWithFormat:@"[%@] Oback: === 调试日志已关闭（以下为无效日志/历史）===\n", [NSDate date]];
            NSString *sp = OBLogPath();
            NSFileHandle *sfh = [NSFileHandle fileHandleForWritingAtPath:sp];
            if (sfh) { [sfh seekToEndOfFile]; [sfh writeData:[sep dataUsingEncoding:NSUTF8StringEncoding]]; [sfh closeFile]; }
        }
        return;   // 调试日志关闭 → 完全不写正常日志（最省）
    }
    // [2026-08-26 T3] 日志文件 >1MB 自动截断，防无限增长（此前该上限只活在已退役的自愈器 trace 里）。
    // 截断放在写盘前，确保本函数所有落盘（含下方开关分隔行）都进有界文件。
    {
        NSFileManager *cfm = [NSFileManager defaultManager];
        NSDictionary *cattrs = [cfm attributesOfItemAtPath:OBLogPath() error:nil];
        if (cattrs && [cattrs fileSize] > (1024ULL * 1024ULL)) {
            NSFileHandle *tfh = [NSFileHandle fileHandleForWritingAtPath:OBLogPath()];
            if (tfh) { [tfh truncateFileAtOffset:0]; [tfh closeFile]; }
        }
    }
    // 开关从「关→开」翻转：追加一行分隔，明确标识「以下为开关生效后日志」，
    // 消除「这份日志到底是开关开还是关时写的」困惑（配合抓前删旧日志，分析更准）。
    if (!_obLogWasOn) {
        _obLogWasOn = YES;
        NSString *sep = [NSString stringWithFormat:@"[%@] Oback: === 调试日志已开启 [build=%@]（以下为开关生效后日志）===\n", [NSDate date], OBACK_BUILD_TAG];
        NSString *sp = OBLogPath();
        NSFileHandle *sfh = [NSFileHandle fileHandleForWritingAtPath:sp];
        if (sfh) { [sfh seekToEndOfFile]; [sfh writeData:[sep dataUsingEncoding:NSUTF8StringEncoding]]; [sfh closeFile]; }
        else { [sep writeToFile:sp atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
    }
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] Oback: %@\n",
                      [NSDate date], msg];
    // 落文件（共享路径，便于一次抓取）
    NSString *path = OBLogPath();
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    // [v11] 同步写内存 ring buffer（App 内弹窗显示用，绕开沙盒文件隔离）
    if (!__obLogBuf) __obLogBuf = [[NSMutableArray alloc] initWithCapacity:kOBLogBufMax];
    [__obLogBuf addObject:line];
    if (__obLogBuf.count > kOBLogBufMax) [__obLogBuf removeObjectAtIndex:0];
    // 同时进 syslog（可用 syslog 工具实时看）
    NSLog(@"%@", line);
    [msg release];
}

#pragma mark - [方案A] VC 类名记录（供设置页「按页排除」点选，免手抄类名）

// 左缘起滑时把当前页面 VC 及其父链的类名去重写入共享文件，设置页「排除的 VC 类名」子页面
// 读取该文件列出「检测到的页面」，用户点一下即加入排除——不必开调试日志、不必 Filza 手抄。
// 写入策略：内存 Set 去重 → 仅【新出现的类名】才 read-modify-write 一次（每个类名基本只写一次），
// 故即便每次左缘起滑都调用，实际磁盘 IO 次数 ≈ 见过的不同类名个数，开销可忽略。
static NSString *OBVCSeeNPath(void) {
    if ([[NSFileManager defaultManager] isWritableFileAtPath:@"/var/mobile"])
        return @"/var/mobile/oback_vc_seen.plist";
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return dir ? [dir stringByAppendingPathComponent:@"oback_vc_seen.plist"] : @"/var/mobile/oback_vc_seen.plist";
}
static const NSUInteger kOBVCSeeNMax = 300;   // 上限：防文件无限增长
static NSMutableSet *__obVCSeeNSet = nil;

// 条目格式：@{ @"vc": 类名, @"bid": 来源 App bundle id, @"c": @(是否冲突) }
// 冲突 = 该页左缘被页面自身占用（起滑点下存在横向可滚 scrollView，会被①让路），
// 即「会导致左缘异常」的页面，设置页据此标红。
static NSString *_obVCSeeNKey(NSString *vc, NSString *bid) {
    return [NSString stringWithFormat:@"%@|%@", vc, bid];
}

static void OBRecordVCClasses(NSArray *names, BOOL conflict) {
    if (!names.count) return;
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (![bid isKindOfClass:[NSString class]]) bid = @"";
        if (!__obVCSeeNSet) {
            __obVCSeeNSet = [[NSMutableSet alloc] init];
            NSArray *existing = [NSArray arrayWithContentsOfFile:OBVCSeeNPath()];
            if ([existing isKindOfClass:[NSArray class]]) {
                for (id e in existing) {
                    if (![e isKindOfClass:[NSDictionary class]]) continue;   // 旧格式(纯字符串)在此迁移时丢弃
                    NSString *v = [(NSDictionary *)e objectForKey:@"vc"];
                    NSString *b = [(NSDictionary *)e objectForKey:@"bid"];
                    if (![v isKindOfClass:[NSString class]] || !v.length) continue;
                    if (![b isKindOfClass:[NSString class]]) b = @"";
                    [__obVCSeeNSet addObject:_obVCSeeNKey(v, b)];
                }
            }
        }
        NSMutableArray *fresh = [NSMutableArray array];
        for (id n in names) {
            if (![n isKindOfClass:[NSString class]] || ![n length]) continue;
            NSString *key = _obVCSeeNKey(n, bid);
            if ([__obVCSeeNSet containsObject:key]) continue;
            [__obVCSeeNSet addObject:key];
            [fresh addObject:@{@"vc": n, @"bid": bid, @"c": @(conflict)}];
        }
        if (!fresh.count) return;
        // 多进程各自独立（tweak 注入各 App），以文件为真相源做 read-modify-write
        NSMutableArray *all = [NSMutableArray array];
        NSArray *raw = [NSArray arrayWithContentsOfFile:OBVCSeeNPath()];
        if ([raw isKindOfClass:[NSArray class]]) {
            for (id e in raw) {
                // 只保留新字典格式：旧纯字符串条目(无 App 归属/无冲突标记)在此一次性迁移丢弃，滑一次即可重建
                if ([e isKindOfClass:[NSDictionary class]]) [all addObject:e];
            }
        }
        [all addObjectsFromArray:fresh];
        if (all.count > kOBVCSeeNMax) {
            [all setArray:[all subarrayWithRange:NSMakeRange(all.count - kOBVCSeeNMax, kOBVCSeeNMax)]];
            [__obVCSeeNSet removeAllObjects];
            for (id e in all) {
                if (![e isKindOfClass:[NSDictionary class]]) continue;
                NSString *v = [(NSDictionary *)e objectForKey:@"vc"];
                NSString *b = [(NSDictionary *)e objectForKey:@"bid"];
                if (![v isKindOfClass:[NSString class]] || !v.length) continue;
                if (![b isKindOfClass:[NSString class]]) b = @"";
                [__obVCSeeNSet addObject:_obVCSeeNKey(v, b)];
            }
        }
        [all writeToFile:OBVCSeeNPath() atomically:YES];
    }
}

// 记录某 VC 及其父链（parentViewController / presentingViewController）的类名。
// 记录父链：容器 VC（nav/tab/自定义容器）也会被列出，用户排除整个容器更省力。
static void OBRecordVCChain(UIViewController *vc, BOOL conflict) {
    if (!vc) return;
    NSMutableArray *names = [NSMutableArray array];
    UIViewController *cur = vc;
    NSUInteger guard = 0;
    while (cur && guard++ < 20) {   // 深度护栏：防异常父链（循环引用）死循环
        NSString *cn = NSStringFromClass([cur class]);
        if (cn.length) [names addObject:cn];
        UIViewController *nxt = cur.parentViewController;
        if (!nxt) nxt = cur.presentingViewController;
        if (nxt == cur) break;
        cur = nxt;
    }
    OBRecordVCClasses(names, conflict);
}

#pragma mark - [P6] 诊断日志宏（编译期收敛）

// 所有 [diag-*] 诊断日志统一走本宏。当前在 Makefile 定义 OBACK_DIAG=1（真机调试需要），故照常输出；
// 若需极简 release 包，去掉 Makefile 的 -DOBACK_DIAG 即可把全部诊断日志整体编译剔除（含参数计算），进一步减负。
#ifdef OBACK_DIAG
#define OBDIAG(fmt, ...) OBLog(fmt, ##__VA_ARGS__)
#else
#define OBDIAG(fmt, ...) do {} while (0)
#endif

// =====================================================================================
// [R3 诊断 2026-09-17] 仲裁探针：统计 UIKit 是否真的把「我们的边缘 pan vs 对手手势」递进三个仲裁回调。
// 用途：区分「对手不是边缘手势（我们静默 return NO）」与「UIKit 压根没问过我们」。
// 历史教训（必须照抄）：单凭「某诊断行 0 次出现」下结论曾绕 5 个版本（2026-08-09 手柄专项 —— 判「手柄从未
// 进仲裁」，后被铁证推翻：真因是手柄在独立 overlay window）。故本探针改为打「累计计数 + 最近对手」，
// 一次实测即三态可分：没装对版本(build tag 不带 R3) / 对手类型不符 / UIKit 真没问(计数=0)。
// =====================================================================================
static NSUInteger _obArbReqFail   = 0;   // shouldRequireFailureOfGestureRecognizer: 被调用次数
static NSUInteger _obArbReqFailBy = 0;   // shouldBeRequiredToFailByGestureRecognizer: 被调用次数
static NSUInteger _obArbSimul     = 0;   // shouldRecognizeSimultaneouslyWithGestureRecognizer: 被调用次数
static NSString  *_obArbLastOpp   = nil; // 最近一次仲裁里 other 的「类名@宿主类名」（MRC 自持，每次替换前 release）

static void _obArbRec(NSUInteger *ctr, UIGestureRecognizer *other) {
    if (ctr) (*ctr)++;
    NSString *s = [NSString stringWithFormat:@"%@@%@",
                   other ? NSStringFromClass([other class]) : @"nil",
                   (other && other.view) ? NSStringFromClass([other.view class]) : @"nil"];
    [_obArbLastOpp release];
    _obArbLastOpp = [s copy];
}

// =====================================================================================
// [R3 2026-09-17] 「手指仍在屏幕上」探针 —— 安全阀恢复时机守卫。
// 只用我们自己的 pan 收到的触摸事件时间戳：touchesBegan/touchesMoved 刷新、touchesEnded/Cancelled 清零。
// 取 1.5s 失联兜底（若某次 touchesEnded 因被抢走而未送达 → 时间戳不再刷新 → 自动视为已离屏），
// 保证「对手手势被永久禁死」不可能发生（这是历史 6614322 花了大代价才修掉的双返回家族风险）。
// =====================================================================================
static NSTimeInterval __obLastTouchTS = 0;   // 引用基准时间；0 = 无在途触摸

static BOOL _obTouchInFlight(void) {
    if (__obLastTouchTS <= 0) return NO;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    return ((now - __obLastTouchTS) < 1.5);
}

#pragma mark - 仅识别横向的 pan（避免纵向滑动误触发返回）
@interface ObackPanGestureRecognizer : UIScreenEdgePanGestureRecognizer
@property (nonatomic, assign) CGPoint startPoint;
@end

static void *kAttachedKey = &kAttachedKey;
static void *kObackTDKey = &kObackTDKey;   // 让被 dismiss 的 VC 自己 retain 其 transition 转发器，避免野指针
void *kPanKey = &kPanKey;                  // 暴露给 Tweak.xm：window 上挂载的 Oback 边缘 pan（NSArray，左/右各一，用于让原生 interactivePop 失败于它们）
static void *kPanKindKey = &kPanKindKey;    // 标记 pan 种类：@"nav"(挂在 nav.view 驱动 nav pop) / @"modal"(挂在 window 驱动 modal dismiss)
static void *kNavPansKey = &kNavPansKey;    // 挂在某个 UINavigationController 上的 Oback 边缘 pan（NSArray），用于幂等去重
static void *kObackNavKey = &kObackNavKey;   // 把 pan 所属的 UINavigationController 绑到 pan 上（swizzle 时写入），gesture 判定/驱动 pop 时直接读，绕过容器枚举
// [2026-09-17 双层 nav 修复] 真正「执行 pop」的那个 nav（可能与 kObackNavKey 不同）：
// 设置 App(com.apple.Preferences) 是 nav 套 nav —— 外层 UINavigationController(childCount=2)
// -> 内层 PSUIPrefsRootController(本身是 UINavigationController 子类，childCount 恒为 1)。
// 我们的边缘 pan 挂在内层 nav.view 上（UIKit 让最深层视图先收到触摸），按内层判定「栈只有 1 个 → 不可 pop」
// 直接 return NO ⇒ 从设置首页点进的各 App 设置页完全没反应；而继续往下钻的页面(通用/关于本机等)内层栈 ≥2 ⇒ 正常。
// 系统原生返回的做法正是「内层不可 pop 就沿父链向上找可 pop 的外层」，此处复刻该行为。
// 仅本次手势期间写入（shouldBegin 解析、手势结束清空），ASSIGN 不持有。
static void *kObackPopNavKey = &kObackPopNavKey;
// [2026-08-09] kYieldActiveKey 机制已彻底移除（多次引发回归），声明一并删除——无任何引用。
static void *kDiagLastLogKey = &kDiagLastLogKey;  // 双返回诊断：同一 window 日志节流（每 2s 最多打一次手势清单）
static void *kGlobalPanKey = &kGlobalPanKey;        // 全屏 pan 引用（绑到 window，gestureRecognizerShouldBegin 识别用）
static void *kObackSuppressedPansKey = &kObackSuppressedPansKey;  // [A'] 本次接管期间被临时禁用的对手返回手势（NSHashTable 弱引用）
// [R7 方案A] 「独占常驻压制」集合：exclusivePop 开启期间被**持久**禁用的对手 pop 手势（仅右滑返回类）。
// 与 kObackSuppressedPansKey 的分工：后者随本次接管 end/abort 恢复；本集合在开关开启期间**不恢复**，
// 只在开关关闭时统一还原（治「中屏 QQ 自己非交互 pop」）。同样必须用 NSHashTable 弱引用（历史野指针坑）。
static void *kObackExclusiveDisabledPansKey = &kObackExclusiveDisabledPansKey;
static CGFloat const kIndicatorMaxTravel = 110.0;   // 胶囊最多跟随手指移动的距离 (pt)
// 【2026-09-16 修正：液滴不做任何横向平移】
// 用户报「贴不了边缘，一定要距离边缘有距离？」——根因就是这里给了 40pt 跟手位移：
// 贴边侧虽然起手压在屏幕边线上（inset=0），但 _indicatorTarget.x = home.x + travel 会把整块形状
// 向屏内推最多 40pt → 贴边侧离开边线，露出最大 40pt 的缝。
// 照实拍视频：指示器**全程钉在屏幕边缘**，跟手感完全由「从边缘长出来」的形变（setSlimeProgress:）
// 表达，不靠平移。故此处归零；日后若想恢复少量位移，只改这一个数即可（贴边性会同步变差）。
static CGFloat const kSlimeMaxTravel = 0.0;

// ── 液态液滴指示器几何（ObackCapsuleEffectSlime）──
// 【2026-09-16 定案：照用户提供的 ColorOS 实拍视频还原】
// 视频证据（720×1280 / 7.83s，指示器出现在 t≈6.2–6.7s 的侧滑返回过程）：
//   ① 填充是**深色近黑半透明**（帧采样亮度低至 9/255，明显暗于浅蓝内容底），箭头是**白色**；
//   ② 贴边侧是一条绝对平直的线（压在屏幕边线上），外侧向屏内鼓出；
//   ③ 最宽处在垂直中点，**上下两端收成尖**；
//   ④ 实测轮廓：沿边展开 ≈ 220pt、最大鼓出 ≈ 36pt → **高宽比 ≈ 6:1（细长如柳叶，不是圆胖）**；
//   ⑤ 轮廓宽度沿高度的分布拟合得幂指数 ≈ 1.4（>1 比正弦更收，两端收得更快、更尖）；
//      ⚠️ 曾尝试改成「中段直线」（824da60），用户明确否掉：**弧形是对的**，要改的是「出来的方式」（见 ⑩）。
//   ⑥ 动画：起手几乎为零（视频 t=6.2s 时完全看不见）→ 随拖动「长」出来 → 松手收回，**全程表面无波纹**；
//   ⑦ **全程钉在屏幕边缘**：视频里指示器始终贴着侧边，只「长」不「移」——故 kSlimeMaxTravel = 0，
//      并保证缩放（dismiss）也以屏幕边缘为支点（见 _slimeEdgeAnchoredCenterForScale:y:window:edge:）。
//   ⑧ **箭头是「长出来」的、不是「蹦出来」的**：视频里白色箭头随液体浮现而渐显。
//      ⇒ 箭头尺寸按液滴当前尺寸比例给出（aReach/aStep）+ 线宽与不透明度起手趋零。
//   ⑨ **手指上下移动时液体要「流」起来**（用户 2026-09-16 追加要求）：
//      手指向上 → 深色液体也向上运动 → **上大下小**，看得出是被「推」着走的。
//      实现 = 把轮廓最宽处（峰值）从固定 u=0.5 改成随垂直速度上下偏移的 uP，
//      并让整体沿 y 做一点微移（有粘滞/惯性感）。速度→bias 归一化、bias 再做平滑，
//      故**松手或手指停住时液体自动回到对称**（不做自走的表面波纹）。
// 坐标系：x = 屏幕横向（向屏内为 +x）；y = 屏幕纵向（沿屏幕边缘延伸）。
// ⚠️ 轮廓参数 u 的方向：**u=0 对应屏幕上方端点，u=1 对应屏幕下方端点**（y = cy - halfH + 2·halfH·u）。
static CGFloat const kSlimeFrameW   = 44.0;   // 包围盒宽（容纳 36pt 最大鼓出 + 余量）
static CGFloat const kSlimeFrameH   = 240.0;  // 包围盒高（容纳 220pt 沿边展开 + 余量）
static CGFloat const kSlimeRootX    = 0.0;    // 贴边侧的 x：0 = 紧贴包围盒边缘（渲染时再贴到屏幕边）
static CGFloat const kSlimeGrowIn0  = 1.0;    // 起手时的鼓出：≈0 ⇒ 静态就是「平贴屏幕的直线」（完全看不见）
                                              // ⚠️ 数值上必须 < 1.37，否则起手那一帧会比 25% 进度「胖」，
                                              //    宽高比曲线出现回落（先胖后瘦再变胖），破坏「先铺线后弯曲」的单调性
static CGFloat const kSlimeGrowIn1  = 36.0;   // 完全拉出时的鼓出
static CGFloat const kSlimeHalfH0   = 24.0;   // 起手时的沿边半高（很短一截）
static CGFloat const kSlimeHalfH1   = 110.0;  // 完全拉出时的沿边半高 → 高 220pt，高宽比 ≈ 6:1
static CGFloat const kSlimeEndPow   = 1.35;   // 轮廓幂指数：>1 → 比正弦更收、两端更快收尖（照视频轮廓拟合）
// ── 「出来的方式」参数（用户 2026-09-16 定案：③ 先铺线后弯曲）──
// 用户澄清：「形状还是原来的弧形，是说边出来的方式得改一下……里边的相当于是一条平贴屏幕的直线，
//   拉起来的时候是弯起来」。
// ⇒ 概念模型：静态下是**一条平贴屏幕的直线**（鼓出≈0 ⇒ 完全看不见），拉的时候才**弯**出鼓包。
//   所以「沿边长度」与「鼓起」必须走**两条不同的曲线**（此前两者都线性 ⇒ 观感是一个点各向等比胀大）：
//     · 沿边长度 halfH：ease-**out**（kSlimeReachEase）→ 线先快速铺开；
//     · 鼓起     gIn  ：ease-**in** （kSlimeBendEase） → 弯是后长出来的。
//   判据是「宽高比 gIn/(2·halfH)」：等比胀大时它一路 12%→16%（始终同一胖瘦），
//   先铺线后弯曲时它 4%→16%（起手是一条细线，随后才被拉弯）。
static CGFloat const kSlimeReachEase = 2.0;    // 沿边铺线的 ease-out 指数：>1 → 长度先到位
static CGFloat const kSlimeBendEase  = 2.0;    // 鼓起的 ease-in 指数：>1 → 弯后长出来
// ── 整体大小（用户 2026-09-16「可以整体小一些」）──
// ⚠️ 刻意做成**单一系数乘在鼓出与沿边长度上**，而不是去改上面那一组照视频拟合出来的基准值：
//   ① 高宽比（6:1）与「出来的方式」的宽高比曲线都不受缩放影响（等比缩放，比值不变）；
//   ② 日后想再大/再小只改这一个数，基准值（视频实测 36×220）仍留在注释里作参照。
//   贴边性不受影响：贴边侧 baseX 恒为 0，缩放只让鼓出与沿边长度变小，形状依旧压在屏幕边线上。
static CGFloat const kSlimeScale     = 0.80;   // 整体缩放：1.0 = 照视频原尺寸（36×220）；0.80 = 28.8×176
// ── 垂直「流动」参数（用户要求：上下移动手指时液体要有被推动的流动感）──
static CGFloat const kSlimeFlowMax   = 0.28;    // 峰值位置最大偏移比例（uP 在 0.22~0.78 间移动）
static CGFloat const kSlimeFlowShift = 8.0;     // 液体整体沿 y 的微移（pt）：向上流动时整体也上浮一点
static CGFloat const kSlimeFlowRefV  = 1200.0;  // 速度归一化参考（pt/s）：达到该速度即视为「全力流动」

#pragma mark - 边缘方向指示胶囊（OPPO 风格：跟随手指、带方向箭头）

typedef NS_ENUM(NSInteger, ObackCapsuleEffect) {
    ObackCapsuleEffectClassic   = 0,   // 经典：白药丸 + 柔和阴影 + 深色箭头
    ObackCapsuleEffectGlow      = 1,   // 发光：彩色外发光
    ObackCapsuleEffectNeon      = 2,   // 霓虹：霓虹描边 + 强发光
    ObackCapsuleEffectGradient  = 3,   // 流光：动态渐变填充
    ObackCapsuleEffectFrosted   = 4,   // 毛玻璃：半透明磨砂
    ObackCapsuleEffectBreathing = 5,   // 呼吸：跟随中轻微脉冲
    ObackCapsuleEffectSlime     = 6,   // 液态史莱姆：贴边平直、外侧表面张力鼓起、轮廓带流动波的蠕动液体（照用户实机描述）
};

@interface ObackEdgeIndicator : UIView
- (instancetype)initWithEdge:(ObackEdge)edge;
- (void)stopEffectAnimations;   // 收起时停掉渐变等循环动画，避免与淡出动画冲突/残留
- (BOOL)isBreathing;            // 供 CADisplayLink 插值判断是否叠加呼吸脉冲
- (void)setFlowSpeed:(CGFloat)speed;   // 流光跟手：流速联动手指速度（1=正常，>1 更 energetic，<1 更 calm）
- (BOOL)isSlime;                      // 是否为「液态液滴」形态（决定形变方式：路径形变 vs 等比缩放）
- (void)setSlimeProgress:(CGFloat)p;  // 液滴进度：0=刚按下的一线薄液体，1=完全拉出的饱满液滴
// 垂直流动偏置：+1 = 手指向上（液体向上流 → 上大下小），-1 = 手指向下，0 = 对称。
// 只写值不重建路径；由紧接着的 setSlimeProgress: 统一应用（调用方在 tick 里同步推进两者）。
- (void)setSlimeFlowBias:(CGFloat)bias;
@end

@implementation ObackEdgeIndicator {
    ObackEdge _edge;
    CAShapeLayer *_chevron;
    CAGradientLayer *_gradientLayer; // 流光特效：渐变填充层（弱引用，由 layer 树持有）
    BOOL _breathing;                // 呼吸特效：在平滑插值里叠加正弦脉冲
    CAShapeLayer *_body;            // 液滴特效：液体本体（自绘路径，随进度形变）
    BOOL _slime;                    // 液态液滴标记（用 body 路径取代 background/cornerRadius 那套圆角矩形假设）
    CGFloat _slimeFlowBias;         // 垂直流动偏置（-1~+1）：把轮廓峰值沿上下移动，做出「被推动」的流动感
}

- (instancetype)initWithEdge:(ObackEdge)edge {
    if (self = [super initWithFrame:CGRectMake(0, 0, 56, 32)]) {
        _edge = edge;
        // 默认（经典）外观先铺底，后续按特效覆盖
        self.layer.cornerRadius = 16;
        self.userInteractionEnabled = NO;
        self.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.9];
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.2;
        self.layer.shadowRadius = 6;
        self.layer.shadowOffset = CGSizeZero;

        // 读取设置项（跨 App 全局文件），决定胶囊特效；读取失败（极少）回落经典
        NSInteger fx = ObackCapsuleEffectClassic;
        @try { fx = [ObackPreferences capsuleEffect]; } @catch (NSException *e) { fx = ObackCapsuleEffectClassic; }

        UIColor *glow = [UIColor colorWithRed:0.0 green:0.76 blue:1.0 alpha:1.0]; // 青蓝发光色（发光/霓虹共用）

        // ── 「液态液滴」独立分支 ──────────────────────────────────────────────
        // 本体是一条自绘的封闭路径，不走上面那套 cornerRadius + backgroundColor 的「圆角矩形」假设。
        // 关键特征（照实拍视频还原）：深色近黑半透明填充 + 白色箭头；贴边侧完全平直（压在屏幕边线上）、
        // 外侧鼓起成一枚细长柳叶、上下两端收成尖；静止时完全静止（流动性只由「拉出形变」表达，无表面波纹）。
        if (fx == ObackCapsuleEffectSlime) {
            _slime = YES;
            self.frame = CGRectMake(0, 0, kSlimeFrameW, kSlimeFrameH);  // 覆盖 init 里的 56×32 胶囊包围盒
            self.layer.cornerRadius = 0;                              // 抹掉刚铺底的胶囊圆角：轮廓由 _body 决定
            self.backgroundColor = [UIColor clearColor];              // 同上，底色改为 _body.fillColor
            self.layer.shadowOpacity = 0;                             // 同上，阴影改挂 _body 并随液体路径走 shadowPath

            _body = [CAShapeLayer layer];
            _body.frame = self.bounds;
            // 深色近黑 + 高不透明（视频帧采样：指示器区域亮度低至 9/255，而内容底约 120）。
            // 用 86% 而非全不透明，保留一丝「玻璃感」，浅色与深色壁纸上都能看清。
            _body.fillColor = [UIColor colorWithWhite:0.11 alpha:0.86].CGColor;
            _body.shadowColor = [UIColor blackColor].CGColor;
            _body.shadowOpacity = 0.10;   // 深色形状本身已有对比，阴影只作轻微分离，避免糊边
            _body.shadowRadius = 8;
            _body.shadowOffset = CGSizeMake(0, 1);
            [self.layer addSublayer:_body];

            _chevron = [CAShapeLayer layer];
            _chevron.lineCap = kCALineCapRound;
            _chevron.lineJoin = kCALineJoinRound;
            _chevron.strokeColor = [UIColor whiteColor].CGColor;   // 深底上的白色箭头（照视频）
            _chevron.fillColor = nil;
            [self.layer addSublayer:_chevron];

            [self setSlimeProgress:0.0];   // 先摆成贴边一线，避免 addSublayer 到出帧之间闪一下满液体
            return self;
        }

        switch (fx) {
            case ObackCapsuleEffectGlow: {           // 发光：彩色外发光
                self.layer.shadowColor = glow.CGColor;
                self.layer.shadowOpacity = 0.6;
                self.layer.shadowRadius = 14;
                break;
            }
            case ObackCapsuleEffectNeon: {           // 霓虹：亮核 + 柔晕 + 微呼吸，模拟真实灯管
                self.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
                // 灯管亮核：近白的高亮青，模拟霓虹管中心（而非一条生硬纯色描边）
                self.layer.borderWidth = 1.5;
                self.layer.borderColor = [UIColor colorWithRed:0.75 green:0.95 blue:1.0 alpha:1.0].CGColor;
                // 外层柔晕：饱和青蓝，半径更大、半透明，靠脉冲缓动产生柔和流动
                self.layer.shadowColor = glow.CGColor;
                self.layer.shadowOpacity = 0.85;
                self.layer.shadowRadius = 22;
                // 微呼吸：发光强度在 0.55~0.95 间 ease 缓动，自然不刺眼（避免恒定强光的生硬感）
                CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
                pulse.fromValue = @0.55;
                pulse.toValue   = @0.95;
                pulse.duration = 2.6;
                pulse.repeatCount = HUGE_VALF;
                pulse.autoreverses = YES;
                pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
                [self.layer addAnimation:pulse forKey:@"obNeonPulse"];
                break;
            }
            case ObackCapsuleEffectGradient: {       // 流光：细碎流光（多个窄柔峰连续流动），去大亮带、更灵动
                self.backgroundColor = [UIColor clearColor];
                CGFloat w = self.bounds.size.width;
                CGFloat h = self.bounds.size.height;
                // 渐变层 2 倍宽、含两个完全相同周期；平移刚好一个周期(w)后首尾一致 → 单向无缝流动。
                // 每个周期仅 2 个宽柔峰（全层 4 个），峰更宽更淡、彼此拉开距离 → 光缓缓流过而非碎点闪，即舒缓流光。
                CAGradientLayer *g = [CAGradientLayer layer];
                g.frame = CGRectMake(0, 0, w * 2, h);
                g.cornerRadius = 16;
                // 同色系、极低对比：基色偏亮蓝 → 中蓝 → 仅略亮的高光，整体是"同一蓝在明度上微妙起伏"，
                // 高光绝非白、与基色差距砍半 → 不再有亮块扫过暗底的生硬感，过渡如呼吸般自然。
                UIColor *cBase = [UIColor colorWithRed:0.30 green:0.58 blue:0.98 alpha:1.0]; // 基色（偏亮蓝，提亮以缩小与高光差距）
                UIColor *cMid  = [UIColor colorWithRed:0.42 green:0.68 blue:1.0  alpha:1.0]; // 过渡（中蓝）
                UIColor *cHi   = [UIColor colorWithRed:0.53 green:0.78 blue:1.0  alpha:1.0]; // 高光（仅略亮的蓝，绝非白）
                // 17 个 stop：每个周期仅 2 个宽柔峰（全层 4 个），峰间用更宽 base 留缝 → 舒缓流光（缓缓流过，非碎点闪）。
                g.colors = @[ (__bridge id)cBase.CGColor, (__bridge id)cMid.CGColor, (__bridge id)cHi.CGColor, (__bridge id)cMid.CGColor, (__bridge id)cBase.CGColor,
                              (__bridge id)cMid.CGColor,   (__bridge id)cHi.CGColor, (__bridge id)cMid.CGColor, (__bridge id)cBase.CGColor,
                              (__bridge id)cMid.CGColor,   (__bridge id)cHi.CGColor, (__bridge id)cMid.CGColor, (__bridge id)cBase.CGColor,
                              (__bridge id)cMid.CGColor,   (__bridge id)cHi.CGColor, (__bridge id)cMid.CGColor, (__bridge id)cBase.CGColor ];
                g.locations = @[ @0.0,     @0.0625,  @0.125,   @0.1875,  @0.25,
                              @0.3125,  @0.375,   @0.4375,  @0.5,
                              @0.5625,  @0.625,   @0.6875,  @0.75,
                              @0.8125,  @0.875,   @0.9375,  @1.0 ];
                g.startPoint = CGPointMake(0, 0);
                g.endPoint   = CGPointMake(1, 0);
                [self.layer insertSublayer:g atIndex:0];
                self.layer.masksToBounds = YES;   // 裁剪到圆角胶囊内（本特效无外阴影，可安全裁剪）
                _gradientLayer = g;
                // 连续向左平移一个周期，linear 无限循环 = 舒缓流光（5.5s，更慢更宽、宁静柔和）
                CABasicAnimation *flow = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
                flow.fromValue = @0;
                flow.toValue   = @(-w);
                flow.duration = 5.5;
                flow.repeatCount = HUGE_VALF;
                flow.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
                [g addAnimation:flow forKey:@"obFlow"];
                break;
            }
            case ObackCapsuleEffectFrosted: {        // 毛玻璃：半透明磨砂
                self.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.5];
                self.layer.borderWidth = 1.0;
                self.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.6].CGColor;
                self.layer.shadowColor = [UIColor blackColor].CGColor;
                self.layer.shadowOpacity = 0.15;
                self.layer.shadowRadius = 8;
                break;
            }
            case ObackCapsuleEffectBreathing: {      // 呼吸：在插值里叠加脉冲（见 _obIndicatorTick:）
                _breathing = YES;
                break;
            }
            default: break;                          // 经典 / 未知 → 基础外观
        }

        // 方向 chevron（深色，保证在浅色药丸上可见；霓虹下改用发光色）
        _chevron = [CAShapeLayer layer];
        _chevron.lineWidth = 3.0;
        _chevron.lineCap = kCALineCapRound;
        _chevron.lineJoin = kCALineJoinRound;
        _chevron.strokeColor = (fx == ObackCapsuleEffectNeon) ? glow.CGColor
                                 : [UIColor colorWithWhite:0.25 alpha:1.0].CGColor;
        _chevron.fillColor = nil;
        CGFloat cx = 28, cy = 16;
        UIBezierPath *path = [UIBezierPath bezierPath];
        if (edge == ObackEdgeLeft) {
            [path moveToPoint:CGPointMake(cx + 6, cy - 7)];
            [path addLineToPoint:CGPointMake(cx - 6, cy)];
            [path addLineToPoint:CGPointMake(cx + 6, cy + 7)];
        } else {
            [path moveToPoint:CGPointMake(cx - 6, cy - 7)];
            [path addLineToPoint:CGPointMake(cx + 6, cy)];
            [path addLineToPoint:CGPointMake(cx - 6, cy + 7)];
        }
        _chevron.path = path.CGPath;
        [self.layer addSublayer:_chevron];
    }
    return self;
}

- (BOOL)isSlime { return _slime; }

// 液滴进度：0 = 刚按下、紧贴屏幕边缘的一线薄液体；1 = 完全拉出的饱满液滴。
// 每帧由 CADisplayLink 调用（已在 Manager 侧用一部分 target 做过一次平滑），此处的重心是几何。
//
// 轮廓构造（用户拍板定案）：
//   ① 【贴边侧】是一条绝对平直的线段（x = 屏内基线），不动一丝 → 液体牢牢贴着屏幕边缘；
//   ② 【外侧】由表面张力曲线 sin(u·π)^k 生成：u 从 0 到 1 时从 0 涨到峰值再回落到 0，
//      中段（u=0.5）鼓起最多、上下两侧对称、末端导数为 0 → 圆钝收口（不是尖）。
//      ⚠️ 弧形是用户拍板要保留的形状（824da60 曾改直线被否），别再改形状本身。
//   ③ 上端、下端各以一小段直线把外侧端点连回贴边侧，形成封闭轮廓。
//   ⚠️ 刻意【不叠加任何表面波纹】：流动性完全由「拉出形变」本身表达。
//      （早期版本曾加相位自走的流动波，导致静止时也在蠕动 —— 用户明确否掉：
//        「是紧贴边缘，拉出来……我说的是拉出来时的动画」，故静止时必须完全静止。）
- (void)setSlimeProgress:(CGFloat)prog {
    if (!_slime || !_body) return;
    CGFloat p = prog;
    if (p < 0.0) p = 0.0; else if (p > 1.0) p = 1.0;
    CGFloat e = p * p * (3.0 - 2.0 * p);               // smoothstep：给箭头线宽/淡入用（起步与收尾都柔）

    // 【出来的方式（用户定案 ③ 先铺线后弯曲）】
    // 静态＝一条平贴屏幕的直线（鼓出≈0 ⇒ 看不见），拉起来才「弯」出鼓包 —— 故两条曲线分开走：
    //   沿边长度 ease-out（线先铺开） / 鼓起 ease-in（弯后长出来）。
    // ⚠️ 别再让两者同系数线性增长：那样每一帧都是同一个胖瘦的小叶子在等比放大（观感＝「胀」不是「弯」）。
    CGFloat eReach = 1.0 - pow(1.0 - p, kSlimeReachEase);                 // 0→1，先快后慢
    CGFloat eBend  = pow(p, kSlimeBendEase);                              // 0→1，先慢后快
    CGFloat gIn   = (kSlimeGrowIn0 + (kSlimeGrowIn1 - kSlimeGrowIn0) * eBend)  * kSlimeScale;   // 向屏内的鼓出
    CGFloat halfH = (kSlimeHalfH0  + (kSlimeHalfH1  - kSlimeHalfH0)  * eReach) * kSlimeScale;   // 沿屏幕边缘的半高
    BOOL isLeft = (_edge == ObackEdgeLeft);
    // 垂直流动：整体沿 y 的微移（手指向上 → 液体上浮一点，做出粘滞/惯性感）。
    // 只影响绘制、不改 view 位置 ⇒ 不影响「钉在屏幕边缘」这条铁律。
    CGFloat cy = kSlimeFrameH * 0.5 - _slimeFlowBias * kSlimeFlowShift;

    // 贴边侧在包围盒内的 x（左缘 = kSlimeRootX；右缘镜像到另一侧）
    CGFloat baseX = isLeft ? kSlimeRootX : (kSlimeFrameW - kSlimeRootX);
    // 外侧方向：左缘时向屏内是 +x；右缘时向屏内是 -x
    CGFloat outDir = isLeft ? 1.0 : -1.0;

    // 垂直流动：把轮廓峰值从固定中点 u=0.5 改成随 bias 偏移的 uP。
    // ⚠️ u 的方向：u=0 = 屏幕**上**端，u=1 = 屏幕**下**端（见 y = cy - halfH + 2·halfH·u）。
    // bias>0（手指向上）→ uP < 0.5 → 峰值上移 ⇒ **上大下小**，液体看起来被「推」着往上走；
    // bias<0 则相反（下大上小）。bias=0 时 uP=0.5，形状与对称版完全一致（向后兼容）。
    CGFloat uP = 0.5 - kSlimeFlowMax * _slimeFlowBias;
    if (uP < 0.06) uP = 0.06; else if (uP > 0.94) uP = 0.94;
    // 箭头的纵向中心跟着「最宽处」走：液体被推着上/下移动时，箭头随之浮到鼓包中央，
    // 始终待在最厚的那一段里（bias=0 时 uP=0.5 ⇒ 与原来完全一致）。
    CGFloat cyArrow = cy - halfH + 2.0 * halfH * uP;

    // 采样构造闭合轮廓。N 越大越平滑；64 点足以让液滴曲线看不出折线。
    NSInteger N = 64;
    UIBezierPath *path = [UIBezierPath bezierPath];

    // ① 外侧（从上端 u=0 走到下端 u=1）：中段直线 + 两端自然收口，峰值落在 uP（bias=0 时即中段）
    for (NSInteger i = 0; i <= N; i++) {
        CGFloat u = (CGFloat)i / (CGFloat)N;
        // 峰值重映射：把 u 分段线性映到以 uP 为峰值的参数 t；
        // 保端点（u=0→t=0、u=1→t=1）⇒ 两端依旧归零收成尖、轮廓始终闭合。
        CGFloat t = (u <= uP) ? (0.5 * u / uP)
                              : (0.5 + 0.5 * (u - uP) / (1.0 - uP));
        // 弧形侧轮廓：sin^k，k>1 → 比正弦更收、两端更快收尖（照实拍视频轮廓拟合）。
        // ⚠️ 824da60 曾把它改成「中段直线 + 两端三次曲线收口」，用户否掉：
        //    「形状还是原来的弧形，是说边出来的方式得改一下」⇒ 弧形保留，改的是【出来的过程】。
        CGFloat s = pow(sin(M_PI * t), kSlimeEndPow);
        CGFloat x = baseX + outDir * (gIn * s);
        CGFloat y = cy - halfH + 2.0 * halfH * u;
        CGPoint pt = CGPointMake(x, y);
        if (i == 0) [path moveToPoint:pt];
        else [path addLineToPoint:pt];
    }
    // ② 下端 → 贴边侧的下端点（平直侧边的收口）
    [path addLineToPoint:CGPointMake(baseX, cy + halfH)];
    // ③ 贴边侧：一条绝对平直的线，严丝合缝贴屏幕边缘
    [path addLineToPoint:CGPointMake(baseX, cy - halfH)];
    [path closePath];

    // ── 箭头 ────────────────────────────────────────────────────────────────
    // 尺寸**全部按液滴「当前」尺寸的比例**给出 → 与液体同源生长，永远落在液滴内部，
    // 起手趋零 + 透明度淡入 ⇒ 视觉是「液体先长出来，箭头随后在液体里浮现」，不再是硬蹦出来。
    // ⚠️ 早前实现是固定基准（reach 7→14 / step 4.5→8 / lineWidth 2.8→3.8 / 不透明恒为 1）：
    //    起手时液滴只有 3pt 宽的一线，箭头却已是接近满尺寸的纯白图形，且中心落在 x≈1.5
    //    → 箭头一半被屏幕边裁掉 ⇒ 观感就是「边上一闪蹦出个白箭头」（用户 2026-09-16 反馈「有点突兀」）。
    //    固定基准还导致中途箭头相对液滴过大（两者不同步）。
    // 【2026-09-16 再缩小一档】用户「箭头可以再小点」→ 三个系数同步下调约 26%，
    //   ⚠️ 仍**全部按液滴当前尺寸的比例**给出（同源生长的性质不能丢），只调系数。
    //   且本轮侧轮廓改直线后中段比弧线版更瘦（3/8 高度处 90% → 75%），箭头同步缩小才不显拥挤。
    // ⚠️ aReach 由 halfH 改为 **gIn**（0.26×36 ≈ 9.4，与旧系数在满进度时等价）：
    //    本轮起「长度」与「鼓起」不再同系数增长，若箭头纵向仍跟 halfH，中途会变成一枚
    //    「又高又瘦」的畸形箭头（例如 50% 进度时鼓出才 11pt、箭头却已 15pt 高）。
    //    两个方向都跟**鼓包**走 ⇒ 箭头全程保持同一胖瘦，与液体同步长大。
    CGFloat aReach = gIn   * 0.26;                     // 半高：完全展开 ≈ 9.4
    CGFloat aStep  = gIn   * 0.125;                    // 横向半跨：完全展开 ≈ 4.5（上一版 0.17 → 6.1）
    CGFloat aLine  = 0.30 + 1.60 * e;                  // 线宽：0.30 → 1.9（上一版 0.35 → 2.5；起手趋零）
    CGFloat aAlpha = pow(e, 1.2);                      // 淡入：比尺寸稍晚一点，杜绝「边上一闪」
    CGFloat dir    = outDir;                           // 箭头尖端朝屏幕外侧 = 返回方向（左缘朝左 / 右缘朝右）
    // 中腰「略偏屏内」放置：整枚箭头（±aStep）都落在液滴轮廓内，既不被屏幕边裁掉、也不戳出液滴外沿。
    CGFloat cx     = baseX + outDir * (gIn * 0.54);
    UIBezierPath *cp = [UIBezierPath bezierPath];
    [cp moveToPoint:CGPointMake(cx + dir * aStep, cyArrow - aReach)];
    [cp addLineToPoint:CGPointMake(cx - dir * aStep, cyArrow)];
    [cp addLineToPoint:CGPointMake(cx + dir * aStep, cyArrow + aReach)];

    // ⚠️ 必须关掉隐式动画：这里是被 CADisplayLink 逐帧调用的，
    //    若走 CA 默认的 0.25s 隐式动画，形变会滞后于手指（看起来「跟不上手」）。
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _body.path = path.CGPath;
    _body.shadowPath = path.CGPath;                    // 阴影跟着轮廓走，而不是一个矩形糊边
    _chevron.path = cp.CGPath;
    _chevron.lineWidth = aLine;
    _chevron.opacity = (float)aAlpha;                  // 与液滴一起淡入（起手为 0 ⇒ 不先于液体出现）
    [CATransaction commit];
}

// 垂直流动偏置（-1~+1）。只记录值、不重建路径 —— 调用方（_obIndicatorTick:）紧接着就会调
// setSlimeProgress: 把新 bias 应用上去，避免同一帧构造两次 64 点路径。
- (void)setSlimeFlowBias:(CGFloat)bias {
    if (!_slime) return;
    if (bias < -1.0) bias = -1.0; else if (bias > 1.0) bias = 1.0;
    _slimeFlowBias = bias;
}

- (void)stopEffectAnimations {
    // 停掉流光循环动画（冻结在当前帧），保留渐变层本身，
    // 避免收起淡出时胶囊「丢失身体」只剩箭头。层随视图 dealloc 自动释放。
    if (_gradientLayer) {
        [_gradientLayer removeAllAnimations];
        _gradientLayer = nil;
    }
    // 同步停掉霓虹呼吸脉冲，避免淡出时残留发光动画
    [self.layer removeAnimationForKey:@"obNeonPulse"];
}

- (BOOL)isBreathing { return _breathing; }

- (void)setFlowSpeed:(CGFloat)speed {
    if (_gradientLayer) _gradientLayer.speed = speed;   // 仅渐变特效有 _gradientLayer；其余特效此调用为空操作
}

@end

// 诊断广播（设置面板「立即打印诊断」按钮 → 跨进程 Darwin 通知 → 各 App 实例打印 [Oback-diag]）
@interface ObackManager ()
- (void)_emitDiagWithManual:(BOOL)manual;
@end

static void obDiagNowCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    @autoreleasepool {
        [(ObackManager *)observer _emitDiagWithManual:YES];
    }
}

#pragma mark - 私有类查找缓存（[PERF] 手势仲裁热路径每触摸多次 NSClassFromString 查表，纯属浪费）

// 类对象在进程生命周期内不可变，用 static+dispatch_once 一次性取出后复用。仍走 NSClassFromString 取（遵守私有类铁律），
// 只是 memoize，绝不硬编码 [Cls class]（那样会编译/链接失败）。
static Class _OBCls_flick(void) {                 // _UIPanOrFlickGestureRecognizer
    static Class c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"_UIPanOrFlickGestureRecognizer"); });
    return c;
}
static Class _OBCls_dragHandle(void) {            // _UIDragHandleGestureRecognizer
    static Class c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"_UIDragHandleGestureRecognizer"); });
    return c;
}
static Class _OBCls_obackNavDelegate(void) {      // ObackNavDelegate
    static Class c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"ObackNavDelegate"); });
    return c;
}

@implementation ObackManager {
    BOOL   _started;
    CGFloat _currentPercent;
    BOOL   _transitionTriggered; // 本次手势是否已真正触发 pop/dismiss（首次横向拖动才置 YES）
    UIView *_indicator;          // 边缘方向指示胶囊
    CGPoint _indicatorAnchor;    // 手势起点（胶囊初始垂直位置）
    CGFloat _indicatorStartX;    // 手势起点 x（用于计算跟随位移）
    CADisplayLink *_indicatorLink; // 胶囊平滑：每帧插值到目标位置（手势中跑，结束即停）
    CGPoint _indicatorTarget;    // 胶囊目标中心（updateIndicator 写入，tick 插值）
    CGFloat _indicatorTargetScale; // 胶囊目标缩放
    CGFloat _indicatorProgress;        // 液滴：当前已呈现的鼓出进度（0=贴边一线，1=饱满液滴）
    CGFloat _indicatorTargetProgress;  // 液滴：目标鼓出进度（updateIndicator 写入，tick 同系数插值）
    CGFloat _slimeFlowBias;            // 液滴：当前垂直流动偏置（-1~+1，tick 插值到 target）
    CGFloat _slimeFlowBiasTarget;      // 液滴：目标垂直流动偏置（由手指垂直速度映射，停手/松手时缓回 0）
    CGFloat _flowSpeed;          // 流光跟手：当前平滑流速（1=正常 5.5s 循环，>1 更快更 energetic）
    CGFloat _flowTargetSpeed;    // 流光跟手：目标流速（由手指横向速度映射，手指暂停时缓回 1.0）
    id     _navPopTarget;        // 方案A: 系统原生 nav pop 的私有 target(_UINavigationInteractiveTransition)，
                                 // 驱动 handleNavigationTransition: 用（assign，由 nav 内部持有，转场期间有效）
    BOOL   _navPopProbeFailed;   // 运行时探测: 方案A 系统交互转场未启动(自定义nav不配合)→ YES, 已切非交互 pop
    BOOL   _navPopProbed;        // 运行时探测门控: 独立于 _transitionTriggered，确保左缘 nav 首次横拖必探测一次
    UIGestureRecognizer *_simulOpponent; // 同时识别冲突: 左缘接管型nav场景下记下的对手pan(retain 自己持有, 防 pop 文章后对手随 VC/WKWebView 释放成悬空指针 → beginTransition 解引用 EXC_BAD_ACCESS)。仅 beginTransition 取消一次, endTransition/abortTransition 收尾 release+nil。
    // 全局返回：全屏 pan 相关状态
    CGPoint _globalStart;                // 全屏 pan 起点（Began 记录，Changed 判定方向）
    BOOL    _globalDriven;               // 全屏 pan 是否已确认横向意图并交给 beginTransition 驱动
    // [2026-08-22 P9] interacting 置位时刻：用于「下次触摸自愈」——若上一轮交互卡死(转场未收尾)，
    // 新手势的 shouldBegin 不再无条件 return NO，而是超时后强制收尾并放行，杜绝返回永久失效。
    NSTimeInterval _interactingSince;
    // [2026-09-16 watchdog 修复] 后台标志：进后台(UIApplicationDidEnterBackgroundNotification)置 YES，
    // 回前台(UIApplicationWillEnterForegroundNotification)置 NO。
    // 置 YES 期间**禁止一切全树遍历/链接**（_linkNavPopGesturesInWindow 入口早退 + swizzle 的
    // viewDidAppear/viewDidLayoutSubviews 也不触发链接）——因后台快照前系统会强制 layout，此时再做
    // 视图树遍历 + requireGestureRecognizerToFail: 仲裁图加边，会与快照的视图遍历争抢 UIKit 内部锁，
    // 导致主线程自旋等待、时钟烧光 10s 被 scene-update watchdog 强杀（设置 App com.apple.Preferences
    // 开启注入后实测：崩溃报告 0x8BADF00D，应用 CPU 仅 0.218s / 0% 但时钟 10s）。
    BOOL _inBackground;
    // 注：不再用单 ivar _globalPan 存引用（多 window 会被覆盖成孤儿 pan → 漏进边缘分支访问 pan.edges 崩）；
    // 改用关联对象标记 kGlobalPanKey 识别全屏 pan（见 gestureRecognizerShouldBegin: 与 attachToWindow:）
}

+ (instancetype)shared {
    static ObackManager *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = [[ObackManager alloc] init];
        // 注册「立即打印诊断」跨进程通知：设置面板按钮广播，各 App 的 ObackManager 收到后打印 [Oback-diag]
        // （含前台/后台 App 真实 bid）。observer 用单例自身，单例永不释放，(void*) 转换安全（MRC 无多 retain）。
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (void *)m, obDiagNowCallback,
                                        CFSTR("com.zlhkf.oback.diagNow"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        // [v11]「显示调试日志」通知：设置面板广播 → 本 App 注册「回到前台」监听 → 切回 App 自动弹窗显示内存日志
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (void *)m, obShowLogCallback,
                                        CFSTR("com.zlhkf.oback.showLog"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    });
    return m;
}

// [2026-08-22 P9] 拦截 interacting 置位时刻，供「下次触摸自愈」判定卡死时长（见 _obStuckSelfHealIfNeeded）
- (void)setInteracting:(BOOL)interacting {
    if (interacting && !_interacting) _interactingSince = [NSDate timeIntervalSinceReferenceDate];
    if (!interacting) _interactingSince = 0;
    _interacting = interacting;
}

// [2026-08-22 P9 根治「返回永久失效」] 新手势 shouldBegin 入口自愈：
// 若 interacting 已卡住超过 2s（远超任何正常手势时长），说明上一轮交互被中断且所有兜底都漏了
// （1.5s dispatch_after 看门狗可能因块被丢弃/时序错位而没生效），此时强制收尾并放行本次手势。
// 这是「最后一道防线」：只要用户再滑一次，就必然自愈，绝不会出现杀进程才恢复的死局。
- (BOOL)_obStuckSelfHealIfNeeded {
    if (!self.interacting) return NO;
    NSTimeInterval since = _interactingSince;
    if (since <= 0) return NO;
    NSTimeInterval held = [NSDate timeIntervalSinceReferenceDate] - since;
    if (held < 2.0) return NO;
    OBLog(@"[P9] 检测到 interacting 卡死 %.2fs → 强制自愈收尾并放行本次手势", held);
    [self _obInterruptActiveInteraction];
    return YES;
}

- (void)_emitDiagWithManual:(BOOL)manual {
    NSDictionary *d = [ObackPreferences _mergedPrefs];
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (!bid) bid = @"(nil)";
    id bl = d[@"blacklistApps"];
    NSUInteger blCount = [bl isKindOfClass:[NSArray class]] ? [bl count] : 0;
    id wlm = d[@"whitelistMode"];
    NSString *line = [NSString stringWithFormat:@"[%@] %@ bid=%@ isAllowed=%d whitelistMode=%@ blacklistCount=%lu leftEdgeExcluded=%d navPopFallback=%d capsuleEffect=%ld state=%@",
                      manual ? @"手动dump" : @"注入",
                      [NSDate date], bid, [ObackPreferences isAllowed], wlm,
                      (unsigned long)blCount, (int)[ObackPreferences isLeftEdgeExcluded],
                      (int)[ObackPreferences isNavPopFallback],
                      (long)[ObackPreferences capsuleEffect],
                                            self.interacting ? @"交互中" : (_started ? @"已注入" : @"未注入")];
    NSLog(@"[Oback-diag] %@", line);   // 给有 Mac 的人：log stream | grep Oback-diag
    // 同时写手机本地文件：无 Mac 用户可用 Filza 直接看 /var/mobile/oback_diag.log，
    // 「立即打印诊断」按钮也会读此文件在手机上展示（跨进程：各 App 各自写自己的 bid）。
    NSString *path = @"/var/mobile/oback_diag.log";
    NSString *out = [line stringByAppendingString:@"\n"];
    NSFileHandle *fh = [NSFileHandle fileHandleForUpdatingAtPath:path];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

#pragma mark - [v11] App 内显示调试日志（绕开沙盒文件隔离）

// 收到 showLog 通知：仅注册「回到前台」监听（armed 防重），等用户切回 App 时弹窗。
// 后台 App 直接 present 弹窗不可见，故延迟到前台再弹。
- (void)_armShowLogOnForeground {
    if (__obShowLogArmed) return;
    __obShowLogArmed = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_obShowLogNow)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
}

- (NSString *)_obBuildLogText {
    NSUInteger n = __obLogBuf ? __obLogBuf.count : 0;
    NSMutableString *s = [NSMutableString stringWithFormat:@"[Oback 调试日志 build=%@ 共%lu条]\n", OBACK_BUILD_TAG, (unsigned long)n];
    if (n == 0) {
        [s appendString:@"(暂无日志：请先在设置里开「调试日志」，回到本 App 做几次手势/长按选字后再点「显示调试日志」)\n"];
    } else {
        for (NSString *l in __obLogBuf) [s appendFormat:@"%@\n", l];
    }
    return [NSString stringWithString:s];
}

- (void)_obShowLogNow {
    __obShowLogArmed = NO;
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationWillEnterForegroundNotification
                                                  object:nil];
    NSString *text = [self _obBuildLogText];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _obPresentLogVC:text];
    });
}

- (UIViewController *)_obKeyRootVC {
    UIWindow *kw = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]] &&
                sc.activationState == UISceneActivationStateForegroundActive) {
                UIWindowScene *ws = (UIWindowScene *)sc;
                // UIWindowScene.windows / UIWindow.isKeyWindow 均未被废弃，避开 UIApplication.windows/keyWindow 的 -Werror
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow) { kw = w; break; }
                }
                if (!kw && ws.windows.count) kw = ws.windows.firstObject;
                break;
            }
        }
    }
    if (!kw) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { kw = w; break; }
        }
        if (!kw) kw = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
    }
    return kw.rootViewController;
}

- (void)_obPresentLogVC:(NSString *)text {
    UIViewController *rvc = [self _obKeyRootVC];
    if (!rvc) return;
    UIViewController *vc = [[UIViewController alloc] init];
    vc.title = [NSString stringWithFormat:@"Oback 日志(%@)", OBACK_BUILD_TAG];
    UITextView *tv = [[UITextView alloc] initWithFrame:vc.view.bounds];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIFont *f = [UIFont fontWithName:@"Menlo" size:10];
    if (f) tv.font = f; else tv.font = [UIFont systemFontOfSize:10];
    tv.text = text;
    tv.editable = NO;
    [vc.view addSubview:tv];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    // [v11c] 右上：分享(系统分享面板，可 AirDrop/微信/QQ/存文件/拷贝) + 复制(直接进剪贴板)，免去长按全选
    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                            target:self
                                                                            action:@selector(_obShareLog:)];
    UIBarButtonItem *copy = [[UIBarButtonItem alloc] initWithTitle:@"复制"
                                                              style:UIBarButtonItemStylePlain
                                                             target:self
                                                             action:@selector(_obCopyLog)];
    vc.navigationItem.rightBarButtonItems = @[share, copy];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                          target:self
                                                                          action:@selector(_obDismissLogVC)];
    vc.navigationItem.leftBarButtonItem = done;
    [rvc presentViewController:nav animated:YES completion:nil];
    // MRC：present 内部 retain nav；我们 alloc 的 nav/vc/tv/done/share/copy 交由父视图/容器持有，这里释放自身引用防泄漏
    [done release];
    [share release];
    [copy release];
    [tv release];
    [vc release];
    [nav release];
}

// [v11c] 系统分享面板：把整段日志作为活动项，可 AirDrop 到 Mac / 发微信QQ / 存到文件 / 拷到剪贴板
- (void)_obShareLog:(UIBarButtonItem *)sender {
    NSString *text = [self _obBuildLogText];
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[text]
                                                                      applicationActivities:nil];
    self.logActivityVC = avc;   // MRC retain，避免活动视图控制器被提前释放(iOS 已知坑)
    UIViewController *presenter = [self _obKeyRootVC].presentedViewController;
    if (!presenter) presenter = [self _obKeyRootVC];
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad && sender) {
        avc.popoverPresentationController.barButtonItem = sender;
    }
    [presenter presentViewController:avc animated:YES completion:nil];
    avc.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed,
                                        NSArray *returnedItems, NSError *activityError) {
        self.logActivityVC = nil;   // 释放我们的 retain
    };
    [avc release];
}

// [v11c] 一键复制全部日志到剪贴板，并弹「已复制」提示
- (void)_obCopyLog {
    NSString *text = [self _obBuildLogText];
    [UIPasteboard generalPasteboard].string = text;
    UIViewController *presenter = [self _obKeyRootVC].presentedViewController;
    if (!presenter) presenter = [self _obKeyRootVC];
    NSString *msg = [NSString stringWithFormat:@"已复制全部日志(%lu 条)到剪贴板", (unsigned long)(__obLogBuf ? __obLogBuf.count : 0)];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil
                                                             message:msg
                                                      preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:a animated:YES completion:nil];
    [a release];   // 弹窗由 presenter 持有，释放自身引用
}

- (void)_obDismissLogVC {
    UIViewController *rvc = [self _obKeyRootVC];
    if (!rvc) return;
    if (rvc.presentedViewController) [rvc dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - 启动与挂载

- (void)start {
    if (_started) return;
    _started = YES;
    // 诊断横幅：设置面板「诊断横幅」开关控制（默认关，key=diagBanner）。
    // 开启后直接 NSLog 到 syslog（全局、不受 roothide 容器隔离），可在 Mac 上 `log stream | grep Oback-diag`
    // 抓到本 App 真实 bid 与名单状态，用于确认①装的是哪个包②黑名单数组是否真正加载/命中（此前文件日志因容器隔离抓不到拼多多）。
    // 默认关：日用机零日志噪声；需要时临时 defaults 写入 diagBanner=1 即可开启，仍保留绕过容器隔离的诊断能力。
    if ([ObackPreferences diagBannerEnabled]) {
        [self _emitDiagWithManual:NO];   // 注入时打印诊断横幅（key=diagBanner）：真实 bid / 名单状态 / 视差等
    }
    // 黑白名单铁律：黑名单 App 完全不注入（不挂手势/不关系统手势/不链 nav），从根避免黑名单 App 因注入闪退。
    if (![ObackPreferences isAllowed]) {
        OBLog(@"start: isAllowed=NO (bid=%@)，Oback 完全不注入（黑白名单排除生效）", NSBundle.mainBundle.bundleIdentifier);
        return;
    }
    // 扩展进程(分享/动作/键盘等 appex)内无边缘返回需求，且常为 _UIHostedWindow / keyWindow=null，
    // 直接跳过挂载，避免无意义的手势注入与日志噪声（如 com.tencent.xin.sharetimeline）。
    if ([[[NSBundle mainBundle] infoDictionary] objectForKey:@"NSExtension"]) {
        OBLog(@"start skipped (extension process, bid=%@)", NSBundle.mainBundle.bundleIdentifier);
        return;
    }
    OBLog(@"start called, bid=%@, keyWindow=%@", NSBundle.mainBundle.bundleIdentifier,
          [self currentKeyWindow]);
    OBLog(@"debug log path = %@", OBLogPath());
    [self attachToWindow:[self currentKeyWindow]];
    // 兜底：部分 App 启动初期 keyWindow 尚未就绪，延迟重试一次挂载
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self attachToWindow:[self currentKeyWindow]];
    });
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(windowBecameKey:)
                                                 name:UIWindowDidBecomeKeyNotification
                                               object:nil];
    // [P8] 进后台强制收尾进行中交互：QQ 切后台时系统做场景快照，若 Oback 使其视图层卡在转场中
    // 会让快照等不到 settle → 10s 0x8BADF00D watchdog 闪退。进后台即收尾使视图静止，快照可 settle。
    // [2026-09-16 watchdog 修复] 同时置 _inBackground 标志：后台期间禁止一切全树遍历/链接
    // （见 _linkNavPopGesturesInWindow 入口早退）。快照前系统会强制 layout → 触发 swizzle 的
    // viewDidAppear/viewDidLayoutSubviews → 若不拦，设置 App 这类超大视图树会在此刻做三趟遍历 +
    // 海量 requireGestureRecognizerToFail:，与快照争抢 UIKit 锁 → 主线程自旋 → 时钟烧光被 watchdog 杀。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_obInterruptActiveInteraction)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    // 回前台：解除后台禁令，恢复正常的链接时机（下次 nav 出现/窗口变 key 时重新链接）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_obEnterForeground)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
}

- (void)windowBecameKey:(NSNotification *)n {
    if ([n.object isKindOfClass:[UIWindow class]]) {
        UIWindow *win = (UIWindow *)n.object;
        // 诊断黑名单：与 attachToWindow 同步跳过，避免无意义的链接噪声
        if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"im.xym.marknow"]) {
            OBLog(@"windowBecameKey: SKIP link（诊断黑名单 bid=im.xym.marknow）");
            return;
        }
        OBLog(@"windowBecameKey: %@ (isKeyNow=%d)", NSStringFromClass([win class]), win.isKeyWindow);
        [self attachToWindow:win];
        [self _linkNavPopGesturesInWindow:win];  // 成为 key 时重新链接（nav 可能刚压入/呈现）
    }
}

- (void)attachToWindow:(UIWindow *)win {
    if (!win) return;
    // 黑白名单铁律：黑名单 App 完全不注入（所有入口 attachToWindow 统一拦截，覆盖 start / windowBecameKey / swizzle）
    if (![ObackPreferences isAllowed]) {
        OBLog(@"attachToWindow: SKIP（isAllowed=NO, bid=%@）", NSBundle.mainBundle.bundleIdentifier);
        return;
    }
    // 诊断性黑名单：部分纯 Flutter / 单屏 app（如 im.xym.marknow）报告「打不开」。
    // 分析显示本 tweak 对其基本是无操作（无 nav 可关、无手势可链），但为彻底排除
    // window 级 pan 注入影响其启动，直接跳过挂载。装上此版本后若 marknow 能打开 → 证实是
    // oback 注入导致（后续深挖 attach 路径）；仍打不开 → 与 oback 无关（Flutter/越狱环境兼容问题）。
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if ([bid isEqualToString:@"im.xym.marknow"]) {
        OBLog(@"attachToWindow: SKIP（诊断黑名单 bid=%@）", bid);
        return;
    }
    if (objc_getAssociatedObject(win, kAttachedKey)) { [self _linkNavPopGesturesInWindow:win]; return; }  // 已挂过：仍重新链接（nav 可能刚出现）
    // 方案 A 关键修复：改用「屏幕边缘 pan」(UIScreenEdgePanGestureRecognizer) 而非普通 UIPanGestureRecognizer。
    // 普通 window 级 pan 在可滚动列表（朋友圈 feed / 聊天列表）上会被 scrollView 的 pan 抢赢识别，
    // 导致 shouldBegin=YES（胶囊出现）却永远进不了 Began（无返回）——日志实证。屏幕边缘 pan 自带
    // 「边缘优先于滚动」的系统级优先级，正是原生 interactivePop 在列表页也能用的原理，从根上根治。
    // 全局返回 App：左缘 + 右缘 edge pan 全部交还系统/App 原生（单一手势源 = 全屏 pan，杜绝双返回）。
    // 右缘 panR（含 modal dismiss）也一并不挂——这类 App 全局返回已让单手返回足够方便，Oback 右缘不再需要。
    ObackPanGestureRecognizer *panL = nil;
    if (![ObackPreferences isGlobalBackEnabled]) {
        panL = [[[ObackPanGestureRecognizer alloc] initWithTarget:self
                                                         action:@selector(handlePan:)] autorelease];
        panL.delegate = self;
        panL.maximumNumberOfTouches = 1;
        panL.cancelsTouchesInView = NO;
        panL.delaysTouchesBegan   = NO;
        panL.edges = UIRectEdgeLeft;
        [win addGestureRecognizer:panL];
    }

    ObackPanGestureRecognizer *panR = nil;
    if (![ObackPreferences isGlobalBackEnabled]) {
        panR = [[[ObackPanGestureRecognizer alloc] initWithTarget:self
                                                         action:@selector(handlePan:)] autorelease];
        panR.delegate = self;
        panR.maximumNumberOfTouches = 1;
        panR.cancelsTouchesInView = NO;
        panR.delaysTouchesBegan   = NO;
        panR.edges = UIRectEdgeRight;
        [win addGestureRecognizer:panR];
    }
    // 全局返回：全屏 pan（普通 UIPanGestureRecognizer，非边缘——UIScreenEdgePanGestureRecognizer 在
    // edges=0 时永不 begin，不能用）。仅 isGlobalBackEnabled 的 App 才挂；gestureRecognizerShouldBegin
    // 里仅允许「左热区起滑」，handleGlobalPan 进一步按「横向滑动占优」才接管 nav pop，否则交还 App。
    // 与左右缘 edge pan 完全独立（单一手势源，杜绝双返回）。全局返回 App 的左右缘均交还系统，无 Oback edge pan。
    if ([ObackPreferences isGlobalBackEnabled]) {
        UIPanGestureRecognizer *panG = [[[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                                action:@selector(handleGlobalPan:)] autorelease];
        panG.delegate = self;
        panG.maximumNumberOfTouches = 1;
        panG.cancelsTouchesInView = NO;   // 只观察、绝不吞 App 触摸（与 panL/panR 一致）
        panG.delaysTouchesBegan   = NO;
        [win addGestureRecognizer:panG];
        // 用关联对象标记识别全屏 pan（不依赖单 ivar，多 window 也能正确分流，避免孤儿 pan 漏进边缘分支访问 pan.edges 崩）
        objc_setAssociatedObject(panG, kGlobalPanKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        OBLog(@"attached 全局返回全屏 pan to window %@ (globalBackEnabled)", win);
    }
    // 这两个 window pan 仅用于「modal dismiss」检测（kind=modal）。nav pop 的边缘 pan 改挂到
    // nav.view（见 _attachNavPanToNav:），以在可滚动列表页也能压过 scrollView 的 pan。
    // 全局返回 App：panL/panR 均不挂，pans 为空数组（仅全屏 pan 在 window 上，独立分流）。
    if (panL) objc_setAssociatedObject(panL, kPanKindKey, @"modal", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (panR) objc_setAssociatedObject(panR, kPanKindKey, @"modal", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSMutableArray *pans = [NSMutableArray array];
    if (panL) [pans addObject:panL];
    if (panR) [pans addObject:panR];
    objc_setAssociatedObject(win, kAttachedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(win, kPanKey, pans, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    OBLog(@"attached pan gesture to window %@ (bounds=%.0fx%.0f)", win,
          win.bounds.size.width, win.bounds.size.height);
    [self _linkNavPopGesturesInWindow:win];
}

#pragma mark - 让其他左边缘返回手势失败于我们的手势（杜绝双返回）

// 递归收集窗口 VC 树里所有 UINavigationController
- (void)_enumerateNavControllersFrom:(UIViewController *)vc block:(void(^)(UINavigationController *nav))block {
    if (!vc || !block) return;
    if ([vc isKindOfClass:[UINavigationController class]]) block((UINavigationController *)vc);
    for (UIViewController *child in vc.childViewControllers)
        [self _enumerateNavControllersFrom:child block:block];
    if (vc.presentedViewController)
        [self _enumerateNavControllersFrom:vc.presentedViewController block:block];
}

// T2 去重：edge / scrollPan / pan 三个视图树枚举器同构（深度护栏 + subviews 递归），
// 统一为泛型 _enumerateGestureViewsIn:depth:predicate:emit:，下方三个公开方法仅提供各自的过滤谓词与类型转换。
// 深度护栏(>40 防爆栈)与递归骨架只在一处维护。
//
// [2026-09-16 watchdog 修复] 新增**节点预算** kOBEnumMaxNodes：
// 背景：设置 App(com.apple.Preferences) 开启注入后出现 scene-update watchdog 强杀(时钟 10s 但应用 CPU 仅 0.218s
// → 主线程阻塞而非计算)。根因是 _linkNavPopGesturesInWindow 对**整棵窗口视图树**连做三趟遍历
// (edge / scrollPan / pan)，且每趟对每个 scrollView 调 requireGestureRecognizerToFail: 改 UIKit 仲裁图。
// 设置 App 视图树是系统里最庞大的之一(每页数十 cell + iOS16 搜索索引层)，三趟遍历 + 海量仲裁图加边
// 与「后台快照前的强制 layout」争抢 UIKit 内部锁 → 主线程自旋等待 → 时钟烧光被 watchdog 杀。
// 预算上限保证单趟遍历的节点数有界：超出即停止递归(仅放弃该窗口尾部深子树的手势链接，
// 而我们的 pan 已挂在 window / nav.view 上，功能不依赖这些尾部节点)。普通 App 视图树远小于该上限，
// 行为零变化；仅超大视图树(设置 App / 复杂 iPad 分栏)被截断，避免遍历失控。
static const NSUInteger kOBEnumMaxNodes = 4000;

- (void)_enumerateGestureViewsIn:(UIView *)view depth:(NSUInteger)depth
			       predicate:(BOOL(^)(UIView *v, UIGestureRecognizer *g))pred
			           emit:(void(^)(UIGestureRecognizer *g))emit {
	[self _enumerateGestureViewsIn:view depth:depth predicate:pred emit:emit budget:NULL];
}

// 带共享预算的重载：budget 指向跨递归共享的剩余节点数（NULL = 不限额，兼容旧调用点）。
// 三个公开枚举器各建一个预算桶，保证「三趟遍历」各自有界且互不干扰。
- (void)_enumerateGestureViewsIn:(UIView *)view depth:(NSUInteger)depth
			       predicate:(BOOL(^)(UIView *v, UIGestureRecognizer *g))pred
			           emit:(void(^)(UIGestureRecognizer *g))emit
			          budget:(NSUInteger *)budget {
	if (!view || !emit || depth > 40) return;
	if (budget) {
		if (*budget == 0) return;
		(*budget)--;
	}
	for (UIGestureRecognizer *g in view.gestureRecognizers) {
		if (pred(view, g)) emit(g);
	}
	for (UIView *sub in view.subviews)
		[self _enumerateGestureViewsIn:sub depth:depth + 1 predicate:pred emit:emit budget:budget];
}

// 递归收集窗口视图树里所有 UIScreenEdgePanGestureRecognizer（含 App/插件自定义的左边缘返回手势）。
// 注意：我们的 window pan 现在本身就是 UIScreenEdgePanGestureRecognizer 子类，故枚举时会包含它们；
// 在链接处通过 g.delegate == self 跳过自身（避免 requireGestureRecognizerToFail 自引用），无需在此排除。
- (void)_enumerateEdgeGesturesInView:(UIView *)view depth:(NSUInteger)depth
			                               block:(void(^)(UIScreenEdgePanGestureRecognizer *g))block {
	NSUInteger budget = kOBEnumMaxNodes;
	[self _enumerateGestureViewsIn:view depth:depth
			                 predicate:^BOOL(UIView *v, UIGestureRecognizer *g){
			                     return [g isKindOfClass:[UIScreenEdgePanGestureRecognizer class]];
			                 }
			                     emit:^(UIGestureRecognizer *g){ block((UIScreenEdgePanGestureRecognizer *)g); }
			                  budget:&budget];
}

// 递归收集窗口视图树里所有 UIScrollView 的 pan 手势（横向 + 纵向皆含）。
// 根因：朋友圈等是「纵向」UITableView，其 panGestureRecognizer 优先级高于我们 window 上的
// ObackPanGestureRecognizer；而我们此前只链「横向」scrollView → 纵向表视图没被设为失败于 ourPan
// → 从边缘起滑时表视图 pan 抢赢识别、ourPan 被取消 → 胶囊出现却无返回（朋友圈"有胶囊没返回"）。
// 让「所有」scrollView 的 pan 失败于 ourPan：从边缘起滑时 ourPan 优先接管返回（无论横/纵 scroll），
// 从中间滑动时 ourPan 本就不 begin → 放行给滚动，互不干扰。完全匹配 OPPO 行为（极端边缘=返回）。
- (void)_enumerateScrollPansInView:(UIView *)view depth:(NSUInteger)depth
			                              block:(void(^)(UIPanGestureRecognizer *g))block {
	NSUInteger budget = kOBEnumMaxNodes;
	[self _enumerateGestureViewsIn:view depth:depth
			                 predicate:^BOOL(UIView *v, UIGestureRecognizer *g){
			                     return [v isKindOfClass:[UIScrollView class]] && g == ((UIScrollView *)v).panGestureRecognizer;
			                 }
			                     emit:^(UIGestureRecognizer *g){ block((UIPanGestureRecognizer *)g); }
			                  budget:&budget];
}

// 收集窗口视图树里所有 UIPanGestureRecognizer（含 plain / 屏幕边缘 / 滚动），用于让"对手手势"
// 失败于我们的右缘 pan（Oback 独占右缘返回）。排除我们自己的 pan（delegate==self）。
- (void)_enumeratePansInView:(UIView *)view depth:(NSUInteger)depth
			                        block:(void(^)(UIPanGestureRecognizer *g))block {
	NSUInteger budget = kOBEnumMaxNodes;
	[self _enumerateGestureViewsIn:view depth:depth
			                 predicate:^BOOL(UIView *v, UIGestureRecognizer *g){
			                     return [g isKindOfClass:[UIPanGestureRecognizer class]];
			                 }
			                     emit:^(UIGestureRecognizer *g){ block((UIPanGestureRecognizer *)g); }
			                  budget:&budget];
}

// 从 pan 解析出真正的 UIWindow：nav pop 的边缘 pan 挂在 nav.view 上（pan.view 是 UIView 非 window），
// 其 window 需从 pan.view.window 取；window modal pan 的 pan.view 本身是 UIWindow。
- (UIWindow *)_windowForPan:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view;
    if ([v isKindOfClass:[UIWindow class]]) return (UIWindow *)v;
    return v.window;
}

// 方案 A 终极修复：nav pop 的边缘 pan 挂到 UINavigationController.view（而非 window）。
// window 级边缘 pan 在可滚动列表（朋友圈 feed / 聊天列表）上会被 scrollView 的 pan 抢赢识别、
// 永远进不了 Began（日志实证：胶囊出现却无返回）；挂到 nav.view 后，它与系统原生
// interactivePopGestureRecognizer（同样挂在 nav.view）同优先级，在列表页也能稳定压过滚动——
// 这正是 FDFullscreenPopGesture 等成熟库的做法。pan 挂到 nav.view，调用系统同一私有
// target 的 handleNavigationTransition: 即可驱动原生交互 pop。
- (void)_attachNavPanToNav:(UINavigationController *)nav win:(UIWindow *)win {
    if (!nav || !win) return;
    if ([self _isExcludedNav:nav]) {
        OBLog(@"attachNavPan: 跳过排除的 nav=%@（朋友圈等，保留原生边缘返回）", NSStringFromClass([nav class]));
        return;
    }
    NSArray *existing = objc_getAssociatedObject(nav, kNavPansKey);
    if ([existing isKindOfClass:[NSArray class]] && existing.count >= 1) return;  // 已挂过，幂等
    UIView *navView = nav.view;            // 触发加载；为 nil 时下面 addGestureRecognizer 无操作，下次链接重试
    if (!navView) { OBLog(@"attachNavPan: nav.view 尚为 nil，跳过（下次链接重试）"); return; }
    NSMutableArray *pans = [NSMutableArray array];
    // nav.view 同时挂「左缘 + 右缘」两个边缘 pan：右缘返回与左缘走完全一致的挂载模型
    // （右缘本质是非交互 pop：rightSimplePop 松手提交，零空白/不破坏导航栏）。
    // 此前(5ac6935)误删 nav.view 右缘 pan、改由 window 级 panR 独占，但 window 级
    // UIScreenEdgePanGestureRecognizer 在部分 App（QQ 聊天等）根本不 begin → 右缘失效/被对手抢走。
    // 恢复与左缘一致的 nav.view 右缘 pan：window panR 在「有 nav 可返回」时 defer 给它（shouldBegin NO），
    // 右缘由 nav.view 右缘 pan 稳定接管——正是「之前能用的那套」。左缘窗口级 pan 同理 defer 给 nav 左缘 pan。
    UIRectEdge edges[2] = { UIRectEdgeLeft, UIRectEdgeRight };
    for (NSUInteger i = 0; i < 2; i++) {
        // 全局返回 App：左右缘 edge pan 都交还系统/App 原生，nav.view 不挂任何边缘 pan（含右缘）。
        if ([ObackPreferences isGlobalBackEnabled]) continue;
        ObackPanGestureRecognizer *pan = [[[ObackPanGestureRecognizer alloc] initWithTarget:self
                                                                                     action:@selector(handlePan:)] autorelease];
        pan.delegate = self;
        pan.maximumNumberOfTouches = 1;
        pan.cancelsTouchesInView = NO;
        pan.delaysTouchesBegan   = NO;
        pan.edges = edges[i];
        objc_setAssociatedObject(pan, kPanKindKey, @"nav", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(pan, kObackNavKey, nav, OBJC_ASSOCIATION_ASSIGN);  // 绑定所属 nav，gesture 判定/驱动时直接读，不依赖容器枚举
        [navView addGestureRecognizer:pan];
        [pans addObject:pan];
    }
    objc_setAssociatedObject(nav, kNavPansKey, pans, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    OBLog(@"attachNavPan: nav=%@ pans=%lu on nav.view (左缘+右缘)", NSStringFromClass([nav class]), (unsigned long)pans.count);
}

// 让窗口内所有「边缘返回手势」失败于我们的 window pan。
// 关键：requireGestureRecognizerToFail: 是「成对依赖」关系，App/插件即便随后把 enabled 重新置 YES，
// 其手势的 begin 仍被系统判定为必须先等我们的 pan 失败——无论对手是系统原生 interactivePop，
// 还是某越狱插件（如微信分组）添加的私有边缘返回手势，同一根手指都只认我们的单次 pop，
// 从根上消除「一次滑动弹两层」（含插件场景）。
- (void)_linkNavPopGesturesInWindow:(UIWindow *)win {
    if (!win) return;
    if (![ObackPreferences isAllowed]) {
        OBLog(@"linkNav: SKIP（isAllowed=NO, bid=%@）", NSBundle.mainBundle.bundleIdentifier);
        return;
    }
    // [2026-09-16 watchdog 修复①] 后台一律不遍历：后台快照前系统强制 layout，此时做三趟视图树遍历 +
    // 海量 requireGestureRecognizerToFail: 会与快照的视图遍历争抢 UIKit 内部锁 → 主线程自旋等待、
    // 时钟烧光 10s 被 scene-update watchdog 强杀（设置 App 实测 CPU 0.218s 但时钟 10s）。
    // 链接是「持久依赖」：后台不链接不影响已建立的关系，回前台时 _obEnterForeground 会补一次。
    if (_inBackground) return;
    // 性能：同一 window 1.5s 内不重复全树遍历（windowBecameKey / 已挂载重链可能密集触发）。
    // [2026-09-16 watchdog 修复②] 由 0.5s 提到 1.5s：链接是持久关系，不必高频重扫；
    // 超大视图树(设置 App)在快速连续 push/pop 时曾被反复触发，是本次崩溃的放大因素。
    static NSTimeInterval __lastLinkTS = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - __lastLinkTS < 1.5) return;
    __lastLinkTS = now;
    NSArray *pans = objc_getAssociatedObject(win, kPanKey);
    if (![pans isKindOfClass:[NSArray class]] || pans.count == 0) {
        OBLog(@"linkNav: 本 window 无 Oback pan，跳过链接"); return;
    }
    // 先给每个 nav 挂 nav.view 边缘 pan（方案 A 终极修复：列表页抢手势根治）
    [self _enumerateNavControllersFrom:win.rootViewController block:^(UINavigationController *nav){
        [self _attachNavPanToNav:nav win:win];
    }];
    // 收集所有我们的 pan（window modal pan + 所有挂到 nav.view 的边缘 pan）。
    // 关键：用**视图树遍历**收集（而非 childViewControllers 枚举），这样 swizzle 挂到
    // 朋友圈 nav.view 上的 pan（朋友圈 nav 不在标准 VC 链上，枚举永远漏）也能被纳入，
    // 其 scrollView 才会失败于该 pan → 朋友圈列表页边缘返回稳定压过滚动。
    NSMutableArray *allOurPans = [NSMutableArray arrayWithArray:pans];
    [self _enumerateEdgeGesturesInView:win depth:0 block:^(UIScreenEdgePanGestureRecognizer *g){
        if (g.delegate == self) [allOurPans addObject:g];   // 仅我们的边缘 pan（delegate==self）
    }];
    // 让传入手势「失败于」我们的每一个边缘 pan（左/右）。成对依赖：对手 begin 须等我们的 pan 先失败，
    // 从根上杜绝「一次滑动弹两层」。屏幕边缘 pan 自带「边缘优先于滚动」系统级优先级，列表页亦稳定接管返回。
    void (^failOnOurPans)(UIGestureRecognizer *) = ^(UIGestureRecognizer *g){
        for (ObackPanGestureRecognizer *op in allOurPans) {
            @try { [g requireGestureRecognizerToFail:op]; } @catch (NSException *e) {}
        }
    };
    CFTimeInterval t0 = CACurrentMediaTime();
    __block NSUInteger linked = 0;
    // 第一道防线：直接关掉 nav 原生 interactivePop（左边缘专属）
    [self _enumerateNavControllersFrom:win.rootViewController block:^(UINavigationController *nav){
        if ([self _isExcludedNav:nav]) {
            OBLog(@"linkNav: 跳过排除 nav（朋友圈等），保留原生 interactivePop");
            return;
        }
        if ([ObackPreferences isLeftEdgeExcluded]) {
            OBLog(@"linkNav: 左缘排除列表命中，保留系统原生 interactivePop (bid=%@)", NSBundle.mainBundle.bundleIdentifier);
            return;
        }
        nav.interactivePopGestureRecognizer.enabled = NO;
        linked++;
    }];
    // 注：窗口内「其它边缘返回手势 / 系统 interactivePop」不再用 requireGestureRecognizerToFail: 显式枚举
    // （易与对手 delegate 互锁、且 WeChat 重开 enabled 后失效）；改由 ObackManager 的
    // gestureRecognizer:shouldRequireFailureOfGestureRecognizer: 单向让步处理（OUR delegate 决策，
    // 对手不可否决，无死锁）—— 见下方新增方法。
    // 第三道防线：枚举窗口里所有 UIScrollView 的 pan（含纵向表视图 / 横向分页容器）。
    // 让它们失败于我们的 pan——从边缘起滑时 ourPan 优先接管返回（无论横/纵 scroll），
    // 从中间滑动时 ourPan 不 begin 故放行给滚动，互不干扰。
    [self _enumerateScrollPansInView:win depth:0 block:^(UIPanGestureRecognizer *g){
        failOnOurPans(g);
        linked++;
    }];
    // [2026-07-26 QQ 右缘修复] 让窗口内所有「对手 pan」（QQ 等 App 自定义的右缘手势，通常是 plain
    // UIPanGestureRecognizer，少数是屏幕边缘 pan）失败于我们的**右缘 pan**：Oback 独占右缘返回，
    // 对手在右缘让步（单向 requireGestureRecognizerToFail:，对手无法否决，无死锁）；
    // 边缘外（中间）我们的右缘 pan 不 begin → 对手 pan 正常触发（QQ 原手势保留）。
    // 仅对右缘 pan 做此单向链接——左缘保持 shouldRequireFailureOf 的让步逻辑，不影响微信修复。
    // 注：对手 pan 在中间起滑时，因我们的右缘 pan 不进入识别（起点不在右缘），require 依赖立即解除、
    // 不引入感知延迟；仅在右缘才短暂等待 Oback 判定，符合"边缘=Oback/中间=QQ"。
    // 右缘对手 pan 链接抽取到 _obLinkRightEdgeOpponentPansInWindow:（同款逻辑，现已供懒补链复用）
    [self _obLinkRightEdgeOpponentPansInWindow:win];
    [self _obLinkLeftEdgeOpponentPansInWindow:win];   // [R4 甲] 左缘同款持久链接（受 exclusivePop 门控，见方法内边界①）
    [self _obReconcileExclusivePersistentSuppress:win];  // [R7 方案A] 独占常驻压制（含开关关时的还原）；受 exclusivePop 门控
    CFTimeInterval dt = (CACurrentMediaTime() - t0) * 1000.0;
    OBLog(@"linkNav: 链接 %lu 个返回手势 (耗时 %.2f ms) @window=%@",
          (unsigned long)linked, dt, NSStringFromClass([win class]));
    if (linked == 0) {
        // 诊断：某些 app（如 marknow）linkNav 找不到任何 UINavigationController。
        // 打印 rootViewController 类名/子容器/呈现态，判断它是否用自定义容器（非标准 childViewControllers）
        // 导致枚举遗漏（→ 边缘返回无法工作、甚至"进不去页面"）。
        UIViewController *rvc = win.rootViewController;
        NSString *tabInfo = @"-";
        if ([rvc isKindOfClass:[UITabBarController class]]) {
            UIViewController *sel = [(UITabBarController *)rvc selectedViewController];
            tabInfo = sel ? NSStringFromClass([sel class]) : @"(nil)";
        }
        OBLog(@"linkNav: 0 导航！rootVC=%@ childCount=%lu presented=%@ tab=%@",
              NSStringFromClass([rvc class]),
              (unsigned long)rvc.childViewControllers.count,
              NSStringFromClass([rvc.presentedViewController class]),
              tabInfo);
    }
    [self _diagLogEdgeGesturesInWindow:win];   // 双返回诊断（开关关闭时无输出，且自带节流）
}

// [2026-07-27 QQ 右缘根治] 右缘「对手手势 requireToFail 我们的右缘 pan」链接抽取为独立方法，
// 供 _linkNavPopGesturesInWindow（链接时机触发）与 gestureRecognizerShouldBegin（右缘懒补链）两处复用，
// 专治 QQ 聊天等「进会话后才懒加载挂上」的晚到右缘手势——链接函数跑时它尚未出现、从未被压住。
- (void)_obLinkRightEdgeOpponentPansInWindow:(UIWindow *)win {
    NSMutableArray *rightPans = [NSMutableArray array];
    NSArray *pans = objc_getAssociatedObject(win, kPanKey);
    if ([pans isKindOfClass:[NSArray class]]) {
        for (ObackPanGestureRecognizer *op in pans) {
            if (op.edges & UIRectEdgeRight) [rightPans addObject:op];
        }
    }
    [self _enumerateEdgeGesturesInView:win depth:0 block:^(UIScreenEdgePanGestureRecognizer *g){
        if (g.delegate == self && (g.edges & UIRectEdgeRight)) [rightPans addObject:g];
    }];
    if (rightPans.count == 0) return;
    // 让窗口内所有「对手 pan」（QQ 等 App 自定义的右缘手势，通常是 plain UIPanGestureRecognizer，
    // 少数是屏幕边缘 pan）失败于我们的右缘 pan：Oback 独占右缘返回，对手在右缘让步（单向，无死锁）；
    // 边缘外（中间）我们的右缘 pan 不 begin → 对手 pan 正常触发（QQ 原手势保留）。
    [self _enumeratePansInView:win depth:0 block:^(UIPanGestureRecognizer *g){
        if (g.delegate == self) return;            // 跳过我们自己的 pan（避免自引用）
        for (ObackPanGestureRecognizer *rp in rightPans) {
            @try { [g requireGestureRecognizerToFail:rp]; } @catch (NSException *e) {}
        }
    }];
    if ([ObackPreferences doubleReturnDiagEnabled]) {
        NSMutableArray *opp = [NSMutableArray array];
        [self _enumeratePansInView:win depth:0 block:^(UIPanGestureRecognizer *g){
            if (g.delegate == self) return;
            [opp addObject:[NSString stringWithFormat:@"%@@%@",
                            NSStringFromClass([g class]), NSStringFromClass([g.view class])]];
        }];
        OBLog(@"diag[右缘链接(懒)] 右缘 pan=%lu 个；对手 pan 共 %lu → %@",
              (unsigned long)rightPans.count, (unsigned long)opp.count, opp);
    }
}

// 右缘懒补链：仅当近期未做过右缘链接（2s 节流）时才扫描对手 pan。
// 链接是「持久依赖」：一旦 requireToFail 建立便一直生效，故此处只为「发现晚到的新手势」，
// 不必每次滑动都全树遍历。右缘 begin 频率极低，全局 2s 节流足够且不会跨 App 互相饿死。
- (void)_obLinkRightEdgeOpponentPansIfStale:(UIWindow *)win {
    static NSTimeInterval __lastRightLinkTS = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - __lastRightLinkTS < 2.0) return;
    __lastRightLinkTS = now;
    [self _obLinkRightEdgeOpponentPansInWindow:win];
}

// =====================================================================================
// [R4 甲 2026-09-17] 左缘对手链接器 —— 让「窗口内 pop-like 且非 allowlist 的对手 pan」
// **必须等我们的左缘 pan 失败**才能识别。
// 为什么必须做（日志6 实证）：左缘触摸时 QQ 自有的 RightDragPanGestureRecognizer 已处于 Began(state=1)，
// 我们的 pan 判 YES 后整份日志 beginTransition 仍为 0 次 ⇒ pop 由 App 侧执行且 interacting=0 = 瞬闪。
// **事后压制（_suppressOpponentPansForPan）已经太晚**：对手业已 Began，再禁用它只能把它 Cancel，
// 不能把「谁赢」还给我们。右缘之所以长期 1/1，正因为右缘有本方法的镜像
// (_obLinkRightEdgeOpponentPansInWindow) —— 同一份日志里两边差别只在这一个链接器。
// 安全边界（逐条对应历史副作用，勿删）：
//  ① 与 A' 同开关（exclusivePop，默认关）⇒ 没开开关的用户左缘行为一字不改，爆炸半径受限；
//  ② 跳过「接管型 nav」（微信类，_navPopShouldDriveSystemNav:==NO）⇒ 不动微信现有的同时识别/让步体系；
//  ③ **只链非屏幕边缘对手**：屏幕边缘对手（含系统 ipg）与我们存在 shouldRequireFailureOf 的同边依赖，
//     反向再建链会成环死锁；且铁律规定 A' 绝不能碰 nav 系统 ipg；
//  ④ 过滤复用 _isAllowlistedOpponentPan（文本选择手柄/滚动/文本视图不动）+ _isPopLikeOpponentPan
//     （只链返回类对手，不链 App 的普通拖拽），与压制清单同源，不擅自扩大打击面；
//  ⑤ 单向 requireToFail（对手依赖我们，我们不依赖它）⇒ 无死锁；对手从非边缘起滑时我们的边缘 pan
//     会即刻 Failed ⇒ 依赖立即解除、不引入感知延迟（与右缘同款机制，右缘已长期验证）；
//  ⑥ 遍历走 _enumeratePansInView（自带 kOBEnumMaxNodes 预算）+ 只在 1.5s/2s 节流后的挂点调用。
// =====================================================================================
- (void)_obLinkLeftEdgeOpponentPansInWindow:(UIWindow *)win {
    if (!win) return;
    if (![ObackPreferences exclusivePopEnabled]) {
        static BOOL __obLeftLinkWarned = NO;
        if (!__obLeftLinkWarned) { __obLeftLinkWarned = YES; OBLog(@"[独占] 左缘链接跳过：开关未开(exclusivePop=0)"); }
        return;
    }
    if (_inBackground) return;   // watchdog 修复①：后台一律不遍历（同 _linkNavPopGesturesInWindow）
    NSMutableArray *leftPans = [NSMutableArray array];
    NSArray *pans = objc_getAssociatedObject(win, kPanKey);
    if ([pans isKindOfClass:[NSArray class]]) {
        for (ObackPanGestureRecognizer *op in pans) {
            if (op.edges & UIRectEdgeLeft) [leftPans addObject:op];
        }
    }
    [self _enumerateEdgeGesturesInView:win depth:0 block:^(UIScreenEdgePanGestureRecognizer *g){
        if (g.delegate == self && (g.edges & UIRectEdgeLeft)) [leftPans addObject:g];
    }];
    if (leftPans.count == 0) return;
    // 边界②：接管型 nav（微信类）不动
    // [R6 修复] nav 解析改用「窗口根枚举所有 nav，取最深层」——与 shouldBegin 通过 pan 绑定 kObackNavKey
    // 拿到 nav 同效。旧写法 topMost:win.rootViewController 在 QQ 下返回 DrawerViewController（window 根 VC），
    // 其 .navigationController 为 nil ⇒ nav=nil ⇒ _isPopLikeOpponentPan 的「nav 树」判定(②)失效、
    // RightDragPanGestureRecognizer 被过滤、requireToFail 持久依赖从未建立 ⇒ 左缘仍与 QQ 抢跑、
    // 对手先 Began 即驱动非交互 pop＝全屏瞬返（日志实证：RightDrag state=1 且从不出现「左缘链接 N」）。
    UINavigationController *nav = nil;
    NSMutableArray *allNavs = [NSMutableArray array];
    [self _enumerateNavControllersFrom:win.rootViewController block:^(UINavigationController *n){ if (n) [allNavs addObject:n]; }];
    for (NSInteger i = (NSInteger)allNavs.count - 1; i >= 0; i--) {
        nav = allNavs[i];   // 取最深层（最靠近用户的）nav 作为「nav 树」判定基准
    }
    if (nav && ![self _navPopShouldDriveSystemNav:nav]) {
        static BOOL __obLeftLinkTakeoverWarned = NO;
        if (!__obLeftLinkTakeoverWarned) {
            __obLeftLinkTakeoverWarned = YES;
            OBLog(@"[独占] 左缘链接跳过：接管型 nav=%@（保微信现有体系不动）", NSStringFromClass([nav class]));
        }
        return;
    }
    if (!nav) {
        // 静默失败警戒：nav 判不出来时 pop-like ② 无法命中 ⇒ 链接等于没做，必须留痕以便下次日志区分。
        static BOOL __obLeftLinkNoNavWarned = NO;
        if (!__obLeftLinkNoNavWarned) { __obLeftLinkNoNavWarned = YES; OBLog(@"[独占] 左缘链接：nav=nil，仅按边缘/类名词表匹配"); }
    } else {
        // [R6 诊断] 确认 nav 解析已修正（此前恒为 nil）：打印实际拿到的 nav，便于日志核对链接是否生效。
        OBLog(@"[独占] 左缘链接解析 nav=%@（窗口内 nav 共 %lu 个）", NSStringFromClass([nav class]), (unsigned long)allNavs.count);
    }
    __block NSUInteger n = 0;
    [self _enumeratePansInView:win depth:0 block:^(UIPanGestureRecognizer *g){
        if (g.delegate == self) return;                                         // 边界⑤：绝不链自己（防自引用）
        if ([g isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) return;  // 边界③：屏幕边缘对手不链（防成环 / 不碰 ipg）
        if ([self _isAllowlistedOpponentPan:g view:g.view]) return;              // 边界④
        if (![self _isPopLikeOpponentPan:g view:g.view nav:nav]) return;         // 边界④
        if (!g.enabled) return;
        for (ObackPanGestureRecognizer *lp in leftPans) {
            @try { [g requireGestureRecognizerToFail:lp]; } @catch (NSException *e) {}
        }
        n++;
    }];
    if (n > 0) {
        OBLog(@"[独占] 左缘链接 %lu 个对手 pan（须等我们的左缘 pan 失败才可识别）nav=%@",
              (unsigned long)n, nav ? NSStringFromClass([nav class]) : @"nil");
    }
}

// 左缘懒补链：镜像右缘（2s 节流）。链接是持久依赖，此处只为发现「进页面后才懒加载挂上」的晚到对手。
- (void)_obLinkLeftEdgeOpponentPansIfStale:(UIWindow *)win {
    static NSTimeInterval __lastLeftLinkTS = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - __lastLeftLinkTS < 2.0) return;
    __lastLeftLinkTS = now;
    [self _obLinkLeftEdgeOpponentPansInWindow:win];
    [self _obReconcileExclusivePersistentSuppress:win];   // [R7 方案A] 中屏也要生效：懒补链时顺手对账一次（同 2s 节流）
}


// 双返回诊断：列出本 window 视图树里所有「边缘返回手势」的精确类名 + 所属视图类。
// 原生系统手势固定为 UIScreenEdgePanGestureRecognizer；任何**其它类名**都来自 App/越狱插件
// 的私有边缘返回手势——若双返回仍在，对照日志里多出来的类名即可定位「第二层」到底是谁。
// 注意：本函数完全受「调试日志」总开关门控（走 OBLog），且同一 window 每 2s 最多打一次，避免刷屏。
- (void)_diagLogEdgeGesturesInWindow:(UIWindow *)win {
    if (![ObackPreferences doubleReturnDiagEnabled]) return;
    // 节流：同一 window 2s 内只打一次清单（每次边缘起滑都会触发补链，不节流会刷屏）
    NSNumber *last = objc_getAssociatedObject(win, kDiagLastLogKey);
    CFTimeInterval now = CACurrentMediaTime();
    if (last && (now - [last doubleValue]) < 2.0) return;
    objc_setAssociatedObject(win, kDiagLastLogKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    [self _enumerateEdgeGesturesInView:win depth:0 block:^(UIScreenEdgePanGestureRecognizer *g){
        NSString *cls = NSStringFromClass([g class]);
        UIView *v = g.view;
        NSString *owner = v ? NSStringFromClass([v class]) : @"(无宿主视图)";
        [names addObject:[NSString stringWithFormat:@"%@(宿主:%@)", cls, owner]];
    }];
    OBLog(@"diag[双返回]: window=%@ | 边缘返回手势共 %lu → %@",
          NSStringFromClass([win class]), (unsigned long)names.count, names);
}

#pragma mark - 排除名单（不干预的页面）

// 不干预的视图控制器（排除名单）。
// 机制保留作为「未来特定 App 需要跳过时的扩展点」：命中后其所在 nav 不挂我们的边缘 pan、
// 不关原生 interactivePop、shouldBegin 直接 NO，交原生处理。
// 当前名单为空——微信朋友圈（WCTimeLine）的排除已于 2026-07-26 移除：右缘改用自定义转场 +
// 起滑即时禁用系统 interactivePop + 直接调 handleNavigationTransition: 驱动原生 pop 后，
// 当初加排除的两个理由（手势抢、原生返回被关没）均已缓解，故朋友圈也由 Oback 接管边缘返回。
- (BOOL)_isExcludedViewController:(UIViewController *)vc {
    if (!vc) return NO;
    return NO;
}

- (BOOL)_isExcludedNav:(UINavigationController *)nav {
    if (!nav) return NO;
    for (UIViewController *vc in nav.viewControllers) {
        if ([self _isExcludedViewController:vc]) return YES;
    }
    return [self _isExcludedViewController:nav.topViewController];
}

#pragma mark - UIGestureRecognizerDelegate

// 只在"落在边缘 + 可返回 + 不在黑名单"时，手势才接管，否则放行给 App 自身
- (BOOL)gestureRecognizerShouldBegin:(UIScreenEdgePanGestureRecognizer *)pan {
    // [2026-08-09 文本选择手柄修复 v3] 任何 Oback pan：触摸落在活动选择手柄(蓝柄)→不 begin，手柄独占拖拽。
    // 根因见 oback_debug(30) 实证：手柄手势从不进入 shouldRequireFailureOf/shouldBeRequiredToFailBy
    // （UIKit 不把手柄作为 other 递给我们）→ 之前在仲裁层的"让路"修复(3740854/e050477/e6c4f55)全是死代码。
    // 此处在 shouldBegin 可控层直接拦截：我们直接决定 pan 是否开始，不依赖 UIKit 仲裁回调。
    // 仅按"触摸是否落在手柄"判定→选择存在但触摸在别处仍允许返回→不回归全局返回。
    {
        UIWindow *gw = [self _windowForPan:pan];
        if (gw) {
            CGPoint gloc = [pan locationInView:gw];
            CGPoint sp = [gw convertPoint:gloc toView:nil];   // 屏幕坐标，与手柄屏幕帧比对
            BOOL selActive = NO;
            CGFloat minDist = 0;
            NSInteger hs = [self _touchOnActiveTextSelectionHandle:sp selectionActive:&selActive minDist:&minDist];
            if (hs == 2) {
                // 精确命中手柄(含动画帧容差)：让路手柄独占拖拽
                OBLog(@"shouldBegin=NO (触摸命中文本选择手柄, 让路手柄拖拽)");
                return NO;
            }
            if (selActive) {
                // [2026-08-09 v8 收窄回归修复] v7 的「选择激活+回退侧列/到手柄距离≤110」宽松让路，在
                // 【选择激活且手柄常驻】时把大量全局返回触摸(全屏 pan 可在屏幕任意位置 begin)误判为"靠近手柄"
                // → Oback 让路 → QQ 原生全屏手势(NTPushPopLib)接走 → 无震动顺返、全局返回变卡(用户反馈实证)。
                // 现收窄：仅「精确命中手柄(hs==2, hitR≈70)」才让路(见下方 hs==2 分支)；选择激活但触摸不在手柄上
                // → 不让路 → Oback 全局返回正常触发(用户常从非手柄处起滑)，恢复 P0 全局返回。
                // 文本选择(按在手柄上)仍由 hs==2 精确命中接管，不受影响。
                static int sBackOk = 0;
                if (sBackOk < 15) { sBackOk++;
                    OBDIAG(@"[diag-back-ok] 选择激活但触摸x=%.0f 不在手柄上(最近距离=%.0f) → Oback 全局返回 proceed", sp.x, minDist);
                }
            }
        }
    }
    // 全局返回：全屏 pan 是普通 UIPanGestureRecognizer，无 edges，不能走下方 edge 判定（访问 pan.edges 会崩）。
    // 用关联对象标记 kGlobalPanKey 识别（替代单 ivar，多 window 不会被覆盖成孤儿 pan → 漏进边缘分支崩），
    // 命中即分流到 _globalPanShouldBegin:（其内仅做左热区 + nav pop 判定，不访问 edges）。
    if (objc_getAssociatedObject(pan, kGlobalPanKey)) {
        return [self _globalPanShouldBegin:pan];
    }
    // [2026-08-01 残影加固] 每轮手势从干净态起：先复位 cancelsTouchesInView=NO（默认安全值），
    // 杜绝上一轮 endTransition/abortTransition 万一漏跑、残留 YES 污染下一轮（曾致进入聊天界面闪小程序卡片残影）。
    // 真实滑动时 beginTransition 会按 rightSimplePop 重新定值（接管型=YES / 标准nav=NO），不影响已验证行为。
    pan.cancelsTouchesInView = NO;
    if (self.interacting) {
        // [P9] 卡死自愈：超时未收尾则强制收尾并继续判定（不再无条件 return NO 致返回永久失效）
        if (![self _obStuckSelfHealIfNeeded]) { OBLog(@"shouldBegin=NO (已在交互中)"); return NO; }
    }
    BOOL allowed = [ObackPreferences isAllowed];
    if (!allowed) { OBLog(@"shouldBegin=NO (isAllowed=NO, bid=%@)", NSBundle.mainBundle.bundleIdentifier); return NO; }

    ObackParams *p = [ObackPreferences params];
    UIWindow *win = [self _windowForPan:pan];
    CGPoint loc = [pan locationInView:win];
    CGFloat w = win.bounds.size.width;
    if (w <= 0) { OBLog(@"shouldBegin=NO (window width=0)"); return NO; }

    NSString *kind = objc_getAssociatedObject(pan, kPanKindKey);  // @"nav"(挂 nav.view) / @"modal"(挂 window)

    // 方案 A 改用屏幕边缘 pan：每个 pan 实例已固定 edges（左/右），系统据此判定是否处于边缘，
    // 并自带「边缘优先于滚动」优先级——列表页也能稳定接管返回。triggerWidth 仅作「更窄」二次约束
    //（系统边缘本身已 ≤ triggerWidth，故实际为上限收紧；用户设更小值才生效）。
    ObackEdge edge = ObackEdgeLeft;
    BOOL isEdge = NO;
    if (p.leftEnabled && (pan.edges & UIRectEdgeLeft) && loc.x <= p.triggerWidth) {
        edge = ObackEdgeLeft;  isEdge = YES;
    } else if (p.rightEnabled && (pan.edges & UIRectEdgeRight) && loc.x >= w - p.triggerWidth) {
        edge = ObackEdgeRight; isEdge = YES;
    }
    if (!isEdge) {
        OBLog(@"shouldBegin=NO (该边缘未启用/超宽: pan.edges=%ld x=%.1f w=%.1f triggerW=%.1f left=%d right=%d kind=%@)",
              (long)pan.edges, loc.x, w, p.triggerWidth, p.leftEnabled, p.rightEnabled, kind);
        return NO;
    }

    // [优化①] 横向滚动优先：触摸点下是横向可滚/分页 scrollView（微信/小红书图片查看器、Safari 图片、地图）
    // 时，边缘返回让路，交还 App 横滑——避免屏幕边缘热区的系统级「边缘优先于滚动」优先级压过横向滚动，
    // 导致图片在边缘附近滑不动或误触发返回。仅判定横向可滚(contentSize.width 明显大于可视宽)，
    // 纵向 list 不受影响（contentSize.width≈可视宽 → 不触发，仍正常返回）。比「排除列表」通用。
    // 该结果同时用作「该页左缘是否被页面自身占用」的判据 → 按页排除列表据此标红（conflict）。
    UIScrollView *hsv = [self scrollViewAtPoint:loc inView:win];
    BOOL hsvWins = (hsv && hsv.contentSize.width > hsv.bounds.size.width * 1.05);

    // [方案A] 记录本次左缘起滑所在页面的 VC 类名（含父链）+ 来源 App + 是否冲突，
    // 供设置页「按页排除」子页面按 App 分组展示、冲突标红、点选排除。
    // ⚠️ 必须在 ① 的 return【之前】：带轮播/横滑的页面恰恰是用户最想按页排除的目标，
    // 若放在 ① 之后，这类页面会在 ① 提前 return NO、永远进不到记录；且冲突标记正是取自上面的 hsvWins。
    if (edge == ObackEdgeLeft) {
        OBRecordVCChain([self topMost:win.rootViewController], hsvWins);
    }

    if (hsvWins) {
        OBLog(@"shouldBegin=NO (横向滚动让路: sv=%@ paging=%d)", NSStringFromClass([hsv class]), (int)hsv.pagingEnabled);
        return NO;
    }

    // 关键修复（朋友圈等自定义容器）：nav 类 pan 直接读其所属 nav（swizzle UINavigationController
    // 的 viewDidAppear 时已把所属 nav 绑到 pan 上），不再依赖 win.rootViewController 标准链枚举——
    // 微信朋友圈的 nav 不在 childViewControllers 标准链上，旧逻辑靠 topMost 枚举永远解析不到 → 无返回。
    UINavigationController *nav = nil;
    UIViewController *top = nil;
    if ([kind isEqualToString:@"nav"]) {
        nav = objc_getAssociatedObject(pan, kObackNavKey);
        top = nav.topViewController;
    }
    if (edge == ObackEdgeLeft && [kind isEqualToString:@"nav"]) {
        OBDIAG(@"[diag-left-nav] kind=nav nav=%@ top=%@ presenting=%d childCount=%lu",
              nav ? NSStringFromClass([nav class]) : @"nil",
              top ? NSStringFromClass([top class]) : @"nil",
              (int)(top.presentingViewController != nil),
              (unsigned long)(nav ? nav.viewControllers.count : 0));
    }
    // 左缘排除列表：命中的 App 左缘交还系统原生返回（不接管、不关 interactivePop），右缘/弹窗不受影响。
    if (edge == ObackEdgeLeft && [kind isEqualToString:@"nav"] && [ObackPreferences isLeftEdgeExcluded]) {
        OBLog(@"shouldBegin=NO (左缘排除列表命中，交还系统: bid=%@)", NSBundle.mainBundle.bundleIdentifier);
        return NO;
    }
    // 全局返回 App：左右缘 edge pan（window panL/panR、nav.view 左右缘，kind 不论）一律交还系统/App 原生
    // （单一手势源 = 全屏 pan，杜绝双返回）。右缘 modal dismiss 也交还原生——这类 App 全局返回已让单手返回足够方便，
    // Oback 右缘不再需要。
    if ([ObackPreferences isGlobalBackEnabled] && (edge == ObackEdgeLeft || edge == ObackEdgeRight)) {
        OBLog(@"shouldBegin=NO (全局返回 App 左右缘交还原生: edge=%@ bid=%@)",
              edge == ObackEdgeLeft ? @"左" : @"右", NSBundle.mainBundle.bundleIdentifier);
        return NO;
    }
    if (!nav) {
        top = [self topMost:win.rootViewController];
        nav = top.navigationController;
        if (!nav && [top isKindOfClass:[UINavigationController class]]) nav = (UINavigationController *)top;
    }
    if (!top) { OBLog(@"shouldBegin=NO (无顶层 VC)"); return NO; }

    // [优化③] 左缘按页排除：顶层 VC 及其父链（parentViewController / presentingViewController）类名
    // 命中 leftEdgeExcludedVCs（子串，大小写不敏感）时，该页左缘交还页面自身手势（如侧栏/轮播左滑），
    // Oback 不接管；右缘/弹窗不受影响。仅作用于左缘，全局返回模式另算。
    // 匹配父链：容器 VC（如 nav / tab / 自定义容器）命中即其所有子页一并交还，填表更省力。
    // 调试日志开启时同时打印 top 类名+完整父链，便于在 oback_debug.log 反查要填的真实类名。
    if (edge == ObackEdgeLeft) {
        NSMutableString *vcChain = [NSMutableString string];
        UIViewController *vc = top;
        BOOL vcHit = NO;
        while (vc) {
            NSString *cn = NSStringFromClass([vc class]);
            [vcChain appendFormat:@"%@%@", (vcChain.length ? @" -> " : @""), cn];
            if ([ObackPreferences isLeftEdgeExcludedVC:cn]) vcHit = YES;
            UIViewController *nxt = vc.parentViewController;
            if (!nxt) nxt = vc.presentingViewController;
            vc = nxt;
        }
        if (vcHit) {
            OBLog(@"shouldBegin=NO (左缘按页排除命中: vc=%@)", NSStringFromClass([top class]));
            return NO;
        }
        // [优化③诊断] 无条件打印（OBLog 内部按调试日志开关闸控）：左缘每次起滑都输出 top 类名与父链，
        // 用户开「调试日志」后在目标页左缘滑一下，Filza 打开 /var/mobile/oback_debug.log 即可复制精确类名填入设置。
        OBLog(@"[diag-vc] leftEdge top=%@ nav=%@ chain=%@",
              top ? NSStringFromClass([top class]) : @"nil",
              nav ? NSStringFromClass([nav class]) : @"nil",
              vcChain);
    }

    // 排除名单（朋友圈等）：不干预，交原生处理，避免我们的 pan 与整屏滚动手势打架、进不了 Began
    if ([self _isExcludedViewController:top]) {
        OBLog(@"shouldBegin=NO (排除视图，交原生: top=%@)", NSStringFromClass([top class]));
        return NO;
    }

    // 按 pan 种类分流（根治"window 级边缘 pan 在列表页被 scrollView 抢赢"）：
    // - nav.view 上的 pan 只接管 nav pop；
    // - window modal pan 只接管 modal dismiss（有 nav pop 可接管时让 nav pan 处理，避免双触发）。
    if ([kind isEqualToString:@"nav"]) {
        // [2026-09-17 双层 nav] 本（外层）nav 的 top 本身还是一个 UINavigationController ⇒ 内容其实在内层容器里。
        // 内层 nav.view 上也挂着我们的边缘 pan（UINavigationController 三个 swizzle 挂载点保证），
        // 由内层 pan 接管（内层不可 pop 时借用本 nav 执行 pop，见下方 _poppableNavFrom:）。
        // 故本（外层）pan 让位 —— 否则内层/外层两个 pan 会同时 shouldBegin=YES，一次滑动弹两级。
        // 保险：仅当内层确实挂上了我们的 pan 才让位；内层没挂（极端情况）则本 pan 照旧接管，不留死角。
        if ([top isKindOfClass:[UINavigationController class]]) {
            NSArray *innerPans = objc_getAssociatedObject((UINavigationController *)top, kNavPansKey);
            if ([innerPans isKindOfClass:[NSArray class]] && innerPans.count > 0) {
                OBLog(@"shouldBegin(nav)=NO (双层nav：外层让位给内层 nav=%@ 的 pan)", NSStringFromClass([top class]));
                return NO;
            }
        }
        // 顶层有 modal 时，其 dismiss 由 window modal pan 接管；nav.view 在 modal 之下不接管，避免双触发。
        if (nav.presentedViewController != nil || top.presentingViewController != nil) {
            OBLog(@"shouldBegin(nav)=NO (有 modal 在顶层，交给 window modal pan)");
            return NO;
        }
        // [2026-09-17 双层 nav 修复] 内层 nav 栈只有 1 个 VC 时，沿父链向上找真正可 pop 的外层 nav
        // （设置 App：内层 PSUIPrefsRootController 恒 count=1，可 pop 的是外层 UINavigationController）。
        // 单层 nav 的普通 App ⇒ _poppableNavFrom: 直接返回自身，行为零变化。
        UINavigationController *popNav = [self _poppableNavFrom:nav];
        if (!popNav) {
            OBLog(@"shouldBegin(nav)=NO (nav 及外层均不可 pop: childCount=%lu)",
                  (unsigned long)nav.viewControllers.count);
            return NO;
        }
        if (popNav != nav) {
            OBLog(@"shouldBegin(nav): 双层nav，改用外层可 pop 的 nav=%@（内层 %@ childCount=%lu）",
                  NSStringFromClass([popNav class]), NSStringFromClass([nav class]),
                  (unsigned long)nav.viewControllers.count);
        }
        objc_setAssociatedObject(pan, kObackPopNavKey, popNav, OBJC_ASSOCIATION_ASSIGN);
        // 即时禁用系统原生 interactivePop：微信等 App 在 viewDidAppear 后会把
        // interactivePopGestureRecognizer.enabled 重新置 YES，linkNav 的禁用被绕过 →
        // 原生边缘返回与我们的 pan 同时驱动同一 _UINavigationInteractiveTransition → 双返回。
        // 起滑瞬间(shouldBegin 确认有效 pop)再压死一次，确保本次只有我们的 pan 驱动转场。
        nav.interactivePopGestureRecognizer.enabled = NO;
        if (popNav != nav) popNav.interactivePopGestureRecognizer.enabled = NO;   // 双层 nav：外层原生返回也必须压死，防双返回
        if (edge == ObackEdgeRight) {
            self.currentParallaxToView = NO;
            self.rightSimplePop = YES;   // 右缘：非交互 pop（松手提交才 popViewControllerAnimated:，零空白/不破坏导航栏/不进自定义转场）
        } else {
            // 左缘：标准 nav 走方案A(系统原生交互转场, 跟手)；微信等自定义 nav(方案A 在微信不渲染
            // 转场 → 旧非交互兜底依赖脆弱运行时探测且首微拖即弹) 统一改走 rightSimplePop 同款
            // 非交互 pop(松手提交, 与右缘行为完全一致, 受灵敏度滑块控制, 无脆弱探测依赖)。
            if (![self _navPopShouldDriveSystemNav:popNav]) {
                self.currentParallaxToView = NO;
                self.rightSimplePop = YES;   // 复用右缘松手提交机制，左缘微信与右缘表现统一；
                                             // "不让步"改由 shouldRequireFailureOf 现场从 pan.view 解析 nav 判定（见该处，根治顺序问题）
            } else {
                self.currentParallaxToView = YES;   // 标准 nav：系统原生交互转场(跟手)
            }
            // [2026-07-29 误触修复 v2] 接管型 nav（微信等，走 rightSimplePop 非交互返回）左/右缘滑动时，
            // 底层可点击元素（聊天小程序卡片等）的激活（按钮 touchUpInside / cell 选中 / 其自带 tap 手势）
            // 不能被放行——手指滑过卡片、松手即误开。delaysTouchesBegan=YES 无效：它只延迟“触摸下发到 view”，
            // 影响不到卡片自己的手势识别器（且我们允许它与左缘 pan 同时识别）。正解在 beginTransition：
            // pan 真正 began(=真实滑动)时临时把 cancelsTouchesInView 置 YES，UIKit 向底层 view 及手势识别器
            // 发 touchesCancelled → 卡片激活被取消；松手即于 endTransition/abortTransition 复位 NO。
            // 纯边缘点击不令 pan began(无位移) → cancelsTouchesInView 维持 NO → 朋友圈/列表点击照常(保留
            // cancelsTouchesInView=NO 已验证的“点得进”行为)。方案 A 标准 nav 不受影响(rightSimplePop=NO)。
        }
    } else {
        if (top.presentingViewController != nil) {
            self.currentParallaxToView = NO;  // modal dismiss（方案B 自定义，只移 sheet）
        } else if (nav && nav.viewControllers.count > 1) {
            // 有 nav 可返回：左缘/右缘都 defer 给 nav.view 上对应的边缘 pan 接管。
            // 右缘 pan 已恢复挂到 nav.view（与左缘完全一致），由 nav.view 右缘 pan 稳定接管——
            // window 级 UIScreenEdgePanGestureRecognizer 在部分 App（QQ 聊天等）不 begin，
            // 这是 5ac6935 把右缘挪到 window 级后右缘失效/被对手抢走的根因；恢复 nav.view 右缘 pan
            // 即回到「之前能用的那套」。window pan 在此直接 NO，左缘同理（已验证稳定）。
            OBLog(@"shouldBegin(modal)=NO (有 nav pop 可接管，交给 nav.view 边缘 pan)");
            return NO;
        } else {
            OBLog(@"shouldBegin(modal)=NO (无 modal 也无 nav pop)");
            return NO;
        }
    }

    self.currentEdge = edge;
    // [2026-09-17 双层 nav 诊断] 打印本次真正要 pop 的 nav 的完整栈（底→顶）。
    // 用途：确认「弹出的下一级到底是谁」—— 设置 App 外层栈底若不是设置首页，pop 就会表现为「没反应/跳错级」。
    if ([kind isEqualToString:@"nav"]) {
        UINavigationController *dn = [self _popNavForPan:pan] ?: nav;
        NSMutableArray *st = [NSMutableArray array];
        for (UIViewController *v in dn.viewControllers) [st addObject:NSStringFromClass([v class])];
        OBLog(@"[diag-navstack] popNav=%@(挂点nav=%@) 栈%lu=%@", NSStringFromClass([dn class]),
              NSStringFromClass([nav class]), (unsigned long)st.count, st);
    }
    OBLog(@"shouldBegin=YES (kind=%@ edge=%@ top=%@ nav.childCount=%lu presenting=%d currentParallaxToView=%d)",
          kind, edge == ObackEdgeLeft ? @"左" : @"右",
          NSStringFromClass([top class]),
          (unsigned long)nav.viewControllers.count, top.presentingViewController != nil,
          self.currentParallaxToView);
    if (p.hapticEnabled) {
        UIImpactFeedbackGenerator *g = [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] autorelease];
        [g impactOccurred];
    }
    // 轻量精准补链（替代原先每次手势全树遍历 _linkNavPopGesturesInWindow:，根除起点卡顿）：
    // 仅让「触摸点正下方的 scrollView」失败于本次 pan（O(depth) 命中测试，几乎零成本），
    // 覆盖「push 后才出现的列表」这类晚到 scrollView。全窗口级的禁用原生 interactivePop /
    // 插件边缘手势链接已在 windowBecameKey / nav swizzle viewDidAppear 时各跑一次（成对依赖持久），
    // 无需每次手势重做。
    UIScrollView *sv = [self scrollViewAtPoint:loc inView:win];
    if (sv && sv.panGestureRecognizer) {
        @try { [sv.panGestureRecognizer requireGestureRecognizerToFail:pan]; } @catch (NSException *e) {}
    }
    // [2026-07-27 QQ 右缘根治] 右缘懒补链：复刻 scrollView 即时补链同款思路，专治「晚到右缘手势」。
    // QQ 聊天的右缘手势常是进会话后才懒加载挂上，链接函数(_linkNavPopGesturesInWindow)跑时它尚未出现、
    // 从未被 requireToFail → 我们的右缘 begin 后 QQ 手势也 begin 抢赢。此处右缘 begin 时就地补一次
    // 对手 pan 链接（2s 节流，仅抓晚到的新手势），确保右缘 Oback 独占、中间仍归 App 原生。
    if (edge == ObackEdgeRight) {
        [self _obLinkRightEdgeOpponentPansIfStale:win];
    } else {
        // [R4 甲] 左缘：进会话后才懒加载挂上的对手（RightDragPan 等）在此补链，使其在本轮触摸前就欠我们一次失败。
        [self _obLinkLeftEdgeOpponentPansIfStale:win];
    }
    // 关键修复：胶囊在 shouldBegin=YES 时即显示，而非等 Began。左边缘会被系统原生
    // interactivePopGestureRecognizer（UIScreenEdgePanGestureRecognizer）抢走，导致我们的手势
    // 永远进不了 Began，胶囊若只在 Began 显示则左边缘永不出现（日志实证：左边缘 shouldBegin=YES
    // 却无 indicator shown）。改在 shouldBegin 显示，左右边缘一致；showIndicator 内已设 0.4s
    // 安全兜底，防止被抢走时胶囊残留。
    [self showIndicatorWithEdge:edge atPoint:loc inWindow:win];
    _indicatorAnchor = loc;
    _indicatorStartX = loc.x;
    // [2026-09-17 A' 挂点前移 —— 本轮关键修复] 压制必须发生在「判定 YES 的这一刻」，不能等 beginTransition。
    // 日志实证（文本(4).txt）：本 pan 判 YES 后**既没有 begin 也没有 abort** ⇒ 一直停在 Possible 被静默重置，
    // 永远进不了 beginTransition ⇒ 挂在 beginTransition 的压制全程不触发（A' 一次都没跑）。
    // 另：该 pan 进不了 Began 的旧因（本文件 1704 行注释已记）正是「被同边的原生/App 边缘手势抢走」——
    // 而 A' 的命中条件①（UIScreenEdgePanGestureRecognizer）/②（nav.view 树上）恰好覆盖这些抢跑者，
    // 故前移压制点不仅让 A' 生效，还有望顺带治好「有胶囊没返回」（此前只剩 beginTransition 一次调用时无解）。
    // [R3 诊断] 压制之前先抓一次仲裁现场 —— 此处 state 才是「谁已经赢了」的原始证据。
    [self _obDiagArenaSnapshotForPan:pan window:win nav:nav edge:edge point:loc];
    [self _suppressOpponentPansForPan:pan];
    return YES;
}

#pragma mark - 手势处理

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:           [self beginTransition:pan]; break;
        case UIGestureRecognizerStateChanged:         [self updateTransition:pan]; break;
        case UIGestureRecognizerStateEnded:           [self endTransition:pan]; break;  // ← 松手：做 commit 判定 finish/cancel（此前误接到 abort 导致返回必被取消）
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:          // ← 纵向为主等导致手势失败/被系统取消，紧急清理胶囊+重置状态
            [self abortTransition:pan];
            break;
        default: break;
    }
}

#pragma mark - 全局返回（全屏 pan）

// 全屏 pan 的 shouldBegin：仅「左热区起滑 + 有 nav 可 pop」才允许识别。是否真正接管 nav pop
// 由 handleGlobalPan 的横向速度判定决定（避免误吞 App 内横向滚动）。不访问 pan.edges（普通 pan 无此属性）。

- (BOOL)_globalPanShouldBegin:(UIPanGestureRecognizer *)pan {
    // [2026-08-09] kYieldActiveKey 机制已移除（多次引发回归），不再需要每轮复位
    if (self.interacting) {
        // [P9] 卡死自愈：全局返回同样受益——上一轮转场卡死后，下一次滑动即自愈放行，不再永久失效
        if (![self _obStuckSelfHealIfNeeded]) { OBLog(@"globalShouldBegin=NO (已在交互中)"); return NO; }
    }
    if (![ObackPreferences isAllowed]) return NO;
    if (![ObackPreferences isGlobalBackEnabled]) return NO;
    UIWindow *win = [self _windowForPan:pan];
    CGPoint loc = [pan locationInView:win];
    CGFloat w = win.bounds.size.width;
    if (w <= 0) return NO;
    // 热区按触发侧：左手侧(默认)=左侧约 1/3 起滑；右手侧=右侧约 1/4 起滑（薄热区，类似边缘手势插件）。
    // 对侧起滑一律交还系统/App 原生（全局返回 App 的 Oback 右缘已禁用）。
    BOOL rightSide = [ObackPreferences isGlobalBackRightSide];
    // 窄热区（全局返回默认左 1/3 / 右 1/4 薄热区），避免误吞 App 内横向手势。
    if (rightSide) {
        if (loc.x < w * 3.0 / 4.0) { OBLog(@"globalShouldBegin=NO (非右热区 x=%.1f w=%.1f)", loc.x, w); return NO; }
    } else {
        if (loc.x > w / 3.0) { OBLog(@"globalShouldBegin=NO (非左热区 x=%.1f w=%.1f)", loc.x, w); return NO; }
    }
    UINavigationController *nav = objc_getAssociatedObject(pan, kObackNavKey);
    UIViewController *top = nil;
    if (nav) top = nav.topViewController;
    if (!top) {
        top = [self topMost:win.rootViewController];
        nav = top.navigationController;
        if (!nav && [top isKindOfClass:[UINavigationController class]]) nav = (UINavigationController *)top;
    }
    if (!top) return NO;
    if ([self _isExcludedViewController:top]) return NO;
    // [2026-09-17 双层 nav 修复] 同上：内层不可 pop 时改用外层可 pop 的 nav，并写入 pan 供后续 pop 执行点读取。
    UINavigationController *gPopNav = [self _poppableNavFrom:nav];
    if (gPopNav) { objc_setAssociatedObject(pan, kObackPopNavKey, gPopNav, OBJC_ASSOCIATION_ASSIGN); nav = gPopNav; }
    if (nav && nav.viewControllers.count > 1) {
        OBLog(@"globalShouldBegin=YES (loc.x=%.1f 有nav pop=%lu)", loc.x,
              (unsigned long)nav.viewControllers.count);
        return YES;
    }
    if (top.presentingViewController != nil) {
        // [优化②] 全局返回也接管弹窗 dismiss：勾了全局返回的 App，弹窗页全屏横滑也能返回
        // （复用 handleGlobalPan→beginTransition→triggerTransitionInWindow 的 modal dismiss 链路）。
        OBLog(@"globalShouldBegin=YES (loc.x=%.1f modal dismiss)", loc.x);
        return YES;
    }
    return NO;  // 无 nav pop 且无 modal：不接管，交还
}

// 全屏 pan 处理：Began 仅记录起点、不驱动；Changed 首次有效位移判定方向——
// 向右且横向占优 → 确认接管 nav pop（交给已验证的 beginTransition/updateTransition/endTransition）；
// 向左/纵向 → 取消交还 App（防误吞滚动）。单一手势源，与左右缘 edge pan 完全隔离，杜绝双返回。
- (void)handleGlobalPan:(UIPanGestureRecognizer *)pan {
    // [2026-08-09 回归修复] 移除 kYieldActiveKey 短路机制——该机制在 shouldRecognizeSimultaneouslyWith 中
    // 按类名置位(手柄类常驻文本视图→误杀全局返回)，后改为按 state 置位(时序问题：panG Began 早于手柄 Began)，
    // 均引发回归。文本选择/手柄拖拽让路改由 shouldBeRequiredToFailBy 动态仲裁(返回热区内 Oback 优先、
    // 热区外让路)，handleGlobalPan 不再做额外短路，照常驱动返回转场。
    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            _globalStart = [pan locationInView:[self _windowForPan:pan]];
            _globalDriven = NO;
            self.interacting = YES;   // 占住，防其他 pan 同时在 shouldBegin 被放行
            // [P8] 自愈看门狗：若本次手势 1.5s 后仍未收到终态并被清空(interacting 仍 YES)，
            // 说明手势被切后台/锁屏/弹窗等中断而未派发 Ended/Cancelled → interacting 卡死，
            // 会致 QQ 视图层卡在转场中、切后台快照 watchdog(0x8BADF00D) 闪退。兜底强制收尾。
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (self.interacting) { [self _obInterruptActiveInteraction]; }
            });
            OBLog(@"handleGlobalPan Began (panView=%@)", NSStringFromClass([[pan view] class]));
            break;                     // 不立即驱动 nav pop、不显示胶囊（方向未定）
        }
        case UIGestureRecognizerStateChanged: {
            if (_globalDriven) { [self updateTransition:pan]; break; }
            UIWindow *win = [self _windowForPan:pan];
            CGPoint cur = [pan locationInView:win];
            CGFloat dx = cur.x - _globalStart.x;
            CGFloat dy = cur.y - _globalStart.y;
            CGPoint v = [pan velocityInView:win];
            BOOL rightSide = [ObackPreferences isGlobalBackRightSide];
            // 左手侧(默认)：从左侧热区起滑、向右滑(dx>0)=返回；右手侧：从右侧薄热区起滑、向左滑(dx<0)=返回。
            // currentEdge 随之设左/右缘，转场 dir 自动镜像（见 updateTransition/endTransition 的 dir 取值）。
            CGFloat backThresh = rightSide ? -30.0 : 30.0;   // [2026-08-08] 触发距离加长：防单手快滑聊天记录时误触返回
            BOOL movingBack  = rightSide ? (dx < backThresh) : (dx > backThresh);
            if (movingBack) {
                // velocity 横向占优判定（1.69x）：横向意图确认才接管，纵滑交还 App 滚动。
                CGFloat vx = v.x;
                if ((rightSide ? vx < 0 : vx > 0) && (vx * vx) > (v.y * v.y) * 1.69) {
                    _globalDriven = YES;
                } else if (fabs(dy) > fabs(dx) * 1.5 && fabs(dy) > 12.0) {
                    [self _cancelGlobalPan:pan];
                }
                if (_globalDriven) {
                    OBLog(@"handleGlobalPan -> _globalDriven=YES（接管转场）");
                    // 全局返回：横向意图确认、接管转场这一刻给轻量触感反馈（与边缘手势 shouldBegin 一致）
                    ObackParams *p = [ObackPreferences params];
                    if (p.hapticEnabled) {
                        UIImpactFeedbackGenerator *g = [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] autorelease];
                        [g impactOccurred];
                    }
                    UINavigationController *nav = [self _popNavForPan:pan];
                    if (!nav) {
                        UIViewController *top = [self topMost:win.rootViewController];
                        nav = top.navigationController;
                        if (!nav && [top isKindOfClass:[UINavigationController class]]) nav = (UINavigationController *)top;
                    }
                    if (nav) nav.interactivePopGestureRecognizer.enabled = NO;  // 接管前禁用系统 interactivePop 防双触发
                    BOOL stdNav = [self _navPopShouldDriveSystemNav:nav];  // 标准nav=YES(方案A) / 微信等=NO(rightSimplePop)
                    if (rightSide) {
                        // 右缘：方案B 统一非交互 pop（动画交还系统），不进自定义转场
                        self.currentParallaxToView = NO;
                        self.rightSimplePop = YES;
                    } else {
                        self.currentParallaxToView = stdNav;
                        self.rightSimplePop = !stdNav;
                    }
                    self.currentEdge = rightSide ? ObackEdgeRight : ObackEdgeLeft;
                    [self beginTransition:pan];   // 驱动 nav pop + 显示胶囊（复用已验证转场链路）
                }
            } else {
                // 未向返回方向移动，或明显纵向为主：即时交还 App。
                [self _cancelGlobalPan:pan];
            }
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            if (_globalDriven) {
                [self endTransition:pan];
            } else {
                self.interacting = NO;
                [self dismissIndicatorSafety];
            }
            _globalDriven = NO;
            // [2026-08-06 崩溃修复] 手势结束清空 panG 的 nav 绑定(RETAIN 短期持有→此刻释放)：杜绝悬空指针/跨轮泄漏。
            // 仅对 window 全屏 pan(带 kGlobalPanKey)生效；边缘 pan 不带该标记、其 ASSIGN 关联本就安全，不受影响。
            if (objc_getAssociatedObject(pan, kGlobalPanKey)) {
                objc_setAssociatedObject(pan, kObackNavKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(pan, kObackPopNavKey, nil, OBJC_ASSOCIATION_ASSIGN);
            }
            break;
        }
        default: break;
    }
}

- (void)_cancelGlobalPan:(UIPanGestureRecognizer *)pan {
    // 非横向意图（向左/纵向）：取消本次识别交还 App，避免与 App 滚动/手势双触发；下次触摸可重新识别。
    self.interacting = NO;
    _globalDriven = NO;
    [self dismissIndicatorSafety];
    pan.enabled = NO;
    pan.enabled = YES;
}

// [P8] 修复 QQ 切后台 scene-update watchdog 闪退（崩溃报告 EXC_CRASH/SIGKILL 0x8BADF00D）：
// 全屏 pan 接管 QQ 的 NTPushPopLib 转场后，手势被切后台/锁屏/弹窗中断而未收到终态回调时，
// interacting 会卡在 YES、挂起转场动画不收尾 → QQ 视图层永远「在转场中」→
// 后台场景快照(UIApplication _performSnapshotsWithAction)等不到 settle → 10s 看门狗强杀。
// 进后台/失活或前台自愈看门狗触发时调用：主动收尾一切进行中交互，使视图层立即静止 → 快照可 settle。
- (void)_obInterruptActiveInteraction {
    // [2026-09-16 watchdog 修复] 置后台标志：本方法由 UIApplicationDidEnterBackgroundNotification 驱动，
    // 置位后 _linkNavPopGesturesInWindow 全树遍历入口一律早退（防与后台快照争 UIKit 锁）。
    _inBackground = YES;
    if (self.interacting) {
        OBLog(@"[P8] 强制收尾进行中交互 interacting=YES（防快照 watchdog 闪退）");
    }
    self.interacting = NO;
    _globalDriven = NO;
    // [方案B] 自定义转场(ObackAnimator / ObackInteractiveTransition)已整体移除，不再有持有转场 context 的
    // 自定义动画器需要强制收尾。进后台/失活时仅对方案A 系统原生交互转场兜底 finishInteractiveTransition
    // （参考 _scheduleNavPopWatchdog 防御性复位），避免系统交互转场卡在 interactive 态导致界面冻结。
    if (_navPopTarget && [_navPopTarget respondsToSelector:@selector(finishInteractiveTransition)]) {
        @try { [_navPopTarget finishInteractiveTransition]; } @catch (NSException *e) { OBLog(@"[P8] finish(_navPopTarget) fail: %@", e); }
    }
    _navPopTarget = nil;
    _currentPercent = 0;
    _transitionTriggered = NO;
    [self _restoreOpponentPans];                // [A'] 进后台：立即恢复对手手势（不带 0.12s 延迟，防残留禁用）
    [self dismissIndicatorSafety];              // 收起胶囊（interacting 已置 NO，会执行）
}

// [2026-09-16 watchdog 修复] 回前台：解除后台禁令。
// 同时补一次链接（后台期间新出现的 nav/scrollView 可能尚未被链接），时机安全——回前台时不做快照。
- (void)_obEnterForeground {
    if (!_inBackground) return;
    _inBackground = NO;
    OBLog(@"[watchdog-fix] 回前台，解除后台禁令");
    UIWindow *win = [self currentKeyWindow];
    if (win) [self _linkNavPopGesturesInWindow:win];
}

- (void)beginTransition:(UIPanGestureRecognizer *)pan {
    // 新手势开始
    // 诊断：确认本次手势是否真正进入 beginTransition，并打印触发 pan 的身份（window pan / nav pan）。
    // 若一次滑动同时出现两条 beginTransition 且 panView 分别为 UIWindow 与 nav.view，则双返回根因是
    // window pan 与 nav pan 同时开火（二者 delegate 均为 self，shouldRequireFailureOf 会互相跳过而不协调）。
    {
        UIWindow *dbgWin = [self _windowForPan:pan];
        OBLog(@"beginTransition: entered (currentParallaxToView=%d top=%@ panView=%@ kind=%@)",
              self.currentParallaxToView,
              NSStringFromClass([[self topMost:dbgWin.rootViewController] class]),
              NSStringFromClass([[pan view] class]),
              objc_getAssociatedObject(pan, kPanKindKey) ?: @"window");
    }

    UIWindow *win = [self _windowForPan:pan];
    UIViewController *top = [self topMost:win.rootViewController];
    if (!top) return;

    // 手势已进入 Began：取消 shouldBegin 时设的安全兜底定时器（正常生命周期会收起胶囊）
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(dismissIndicatorSafety) object:nil];

    self.interacting = YES;
    // [A' 接管即独占] 确认接管（手势 Began）后立即压制 App 自带的返回手势（QQ 全屏 NTPushPopLib 等），
    // 本次手势期间由 Oback 独占返回；松手/取消后自动恢复。默认关（面板「接管即独占」），关时本行为空操作。
    [self _suppressOpponentPansForPan:pan];
    // [2026-07-29 误触修复 v2] 接管型 nav 真实滑动（rightSimplePop）期间吞掉底层触摸：UIKit 向底层 view
    // 及其手势识别器发 touchesCancelled，手指滑过的小程序卡片等不会被误触激活（松手不再 touchUpInside/选中）。
    // 方案 A（rightSimplePop=NO）保持 NO——系统原生交互转场自行处理 touch 取消，无需我们干预。
    // 直接按 rightSimplePop 定值（而非仅置 YES），确保每轮 begin 都确定性重设，不依赖上一轮 end/abort 的复位。
    pan.cancelsTouchesInView = NO;   // 兜底重置（纵向滑动已靠 handleGlobalPan Began 重置；此处再保险）
    if (self.rightSimplePop) {
        // 确认横向接管后吞掉后续底层 touch：防拖动中暴露的上一页元素被误触激活；
        // 仅在接管（_globalDriven）后的本轮生效，下一轮 Began 会再重置为 NO。
        pan.cancelsTouchesInView = YES;
    }
    // 同时识别场景下取消对手(微信朋友圈内部 pan),确保 Oback 左缘 rightSimplePop 独占返回、杜绝双返回
    if (_simulOpponent) {
        [_simulOpponent setState:UIGestureRecognizerStateCancelled];
        [_simulOpponent release]; _simulOpponent = nil;
    }
    _transitionTriggered = NO;

    // 方案 A：nav pop 改为驱动系统原生交互 pop（根除自定义转场 reparent toView 导致的空白/损坏）。
    // 在手势 Began(位移=0)即启动系统原生交互转场，由后续 updateTransition 的横向位移 scrub。
    // modal dismiss（currentParallaxToView=NO）走方案B 自定义转场，不在此启动。
    // 右缘固定走 rightSimplePop 非交互返回（松手提交才 popViewControllerAnimated:），不在此启动交互转场。
    // 自定义 nav 视差（实验）功能已移除——左缘 nav pop 一律走方案A 系统原生（最稳、零冻结）。
    if (self.currentParallaxToView && self.currentEdge != ObackEdgeRight) {
        [self driveSystemNavPopBeginWithPan:pan window:win];   // 方案A 系统原生交互 pop
    }

    CGPoint loc = [pan locationInView:win];
    _indicatorAnchor = loc;
    _indicatorStartX = loc.x;

    // 胶囊多数情况已在 shouldBegin=YES 时显示；此处仅作兜底（极少数 Began 早于胶囊显示的边界场景）
    if (!_indicator) [self showIndicatorWithEdge:self.currentEdge atPoint:loc inWindow:win];
}

// 首次横向拖动时（p>0）才真正触发 pop/dismiss。
// 关键修复：此前在 beginTransition(手势 Began) 就立即 popViewControllerAnimated:，
// 一旦用户只是点按/纵向滑动即取消，交互转场易被卡在"进行中"态导致界面冻结。
- (void)triggerTransitionInWindow:(UIWindow *)win withPan:(UIPanGestureRecognizer *)pan {
    // 优先用 shouldBegin 阶段已解析并写入 pan 的 kObackNavKey（QQ/TIM 全屏 pan 等 window pan 也在此写入，
    // 绕过 topMost 枚举——QQ 抽屉/聊天自定义容器下 topMost 只拿到 DrawerViewController 导致 nav=nil 不 pop）。
    UINavigationController *boundNav = objc_getAssociatedObject(pan, kObackNavKey);
    UINavigationController *nav = [self _popNavForPan:pan];   // 双层 nav 时取真正可 pop 的外层
    UIViewController *top = nil;
    if (boundNav) top = boundNav.topViewController;           // top 始终是「可见页面」(内层 nav 的 top)
    if (!top && nav) top = nav.topViewController;
    if (!top) {
        top = [self topMost:win.rootViewController];
        nav = top.navigationController;
        if (!nav && [top isKindOfClass:[UINavigationController class]]) nav = (UINavigationController *)top;
    }
    if (!top) return;

    if (nav && nav.viewControllers.count > 1) {
        id nd = nav.delegate;
        OBLog(@"beginTransition: pop nav (childCount=%lu) delegateBefore=%@",
              (unsigned long)nav.viewControllers.count,
              nd ? NSStringFromClass([nd class]) : @"(nil)");
        // 兜底：强制确保 ObackNavDelegate 转发器就位。
        // 若 setDelegate: 因时机（早期设置未触发 hook）/ 退避门控 / 子类覆写等原因没装，
        // 这里再 setDelegate: 一次触发 hook 重新包装；已是 ObackNavDelegate 则幂等透传。
        [nav setDelegate:nd];
        OBLog(@"pop nav delegateAfter=%@ isOback=%d",
              nav.delegate ? NSStringFromClass([nav.delegate class]) : @"(nil)",
              (int)[[nav.delegate class] isSubclassOfClass:_OBCls_obackNavDelegate()]);
        if (self.currentEdge == ObackEdgeRight) {
            // [方案B] 右缘统一走 rightSimplePop 非交互 pop（updateTransition 早期 return 已在松手时 pop）；
            // 此处为历史自定义镜像转场分支（已退役，ObackAnimator 已移除），仅保留 pop 触发以防极端路径回退。
            self.currentParallaxToView = YES;   // 兜底：标记视差（正常右缘不会到达此处）
            OBLog(@"trigger: nav pop 右缘（方案B 走 rightSimplePop，历史自定义转场已退役）");
            [nav popViewControllerAnimated:YES];
        } else if (self.interacting) {
            // 方案 A：交互 pop 已在 beginTransition 通过 handleNavigationTransition: 启动，
            // 此处不再调用 popViewControllerAnimated:（否则会触发第二次转场/黑屏）。
            OBLog(@"trigger: nav pop 已启动(系统原生交互)，忽略重复 popViewControllerAnimated");
        } else {
            // 非交互兜底：真正触发 pop（自定义 nav 视差实验已退役，方案B 下由系统/App 原生收尾）。
            self.currentParallaxToView = YES;
            OBLog(@"trigger: nav pop 自定义视差/兜底，popViewControllerAnimated");
            [nav popViewControllerAnimated:YES];
        }
    } else if (top.presentingViewController) {
        // 方案B（安全恢复弹窗 dismiss 视差）：只移动被 dismiss 的 sheet(fromView)，
        // 绝不碰底层 presenting(toView)（黑屏根因），也不加深遮罩（避免已可见背景闪暗）。
        OBLog(@"beginTransition: dismiss modal (方案B: 手势驱动视差, 只移 sheet 不碰 presenting)");
        self.currentParallaxToView = NO;
        id existing = top.transitioningDelegate;
        ObackTransitioningDelegate *td = nil;
        if ([existing isKindOfClass:[ObackTransitioningDelegate class]]) {
            td = (ObackTransitioningDelegate *)existing;
        } else {
            td = [[[ObackTransitioningDelegate alloc] init] autorelease];
            td.original = existing;
            top.transitioningDelegate = td;
        }
        objc_setAssociatedObject(top, kObackTDKey, td, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        self.currentTD = td;
        [top dismissViewControllerAnimated:YES completion:nil];
    }
}

// 单向让步（根治微信双返回 + QQ 等右缘冲突）：当我们的边缘 pan(g) 与另一个边缘返回手势(other, 同边)竞争时，
// 让 OUR pan 要求 other 先失败——OUR delegate 决策，对手无法否决，且不会与对手的 requireToFail 互锁死锁。
// 结果：对手识别→我们取消（单层原生返回）；对手不识别→我们接管（单层 Oback 返回）。绝不会双触发。
// 注意：scrollView 的 pan 协调仍由 shouldBegin 内的 requireGestureRecognizerToFail: 显式处理（other 非边缘，此处不拦）。
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
 shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)other {
    _obArbRec(&_obArbReqFail, other);   // [R3] 探针：被咨询了就打计数（在全部 early return 之前）
    if (g == other || other == nil) return NO;
    // [2026-08-09→修复 文本选择手柄/光标] 关键修复：Oback 全屏 pan 必须等「文本选择手柄/光标」失败
    // 再 begin。之前只在 shouldBeRequiredToFailBy 让路，但日志实证(oback_debug 28)：手柄手势
    // 从未进入我们的仲裁(全程无 DragHandle 进入 shouldBeRequiredToFailBy)，导致 pan 照常 begin
    // 并以 cancelsTouchesInView 抢走 touch → 手柄拖不动("多数时候不行，偶尔能")。
    // 改从 Oback 一侧主动声明依赖(Apple "Preferring one gesture over another" 官方姿势)，强制 UIKit
    // 建立"pan 失败于手柄"边，手柄才能独占拖拽。手柄空闲(无选字)时处于 Failed 态→pan 立即 proceed→返回正常。
    BOOL gIsGlobal = (g.delegate == self && [[g view] isKindOfClass:[UIWindow class]] &&
                      ![g isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]);
    if (gIsGlobal) {
        Class dragHandleCls = _OBCls_dragHandle();
        BOOL isHandle = (dragHandleCls && [other isKindOfClass:dragHandleCls]);
        if (!isHandle) {
            NSString *ocls = NSStringFromClass([other class]);
            if ([ocls containsString:@"DragHandle"] || [ocls containsString:@"Handle"]) isHandle = YES;
        }
        Class flickCls = _OBCls_flick();
        BOOL isCaret = (flickCls && [other isKindOfClass:flickCls] &&
                        other.view && ([other.view isKindOfClass:[UITextView class]] ||
                                       [other.view isKindOfClass:[UITextField class]]));
        // [DIAG4] 更宽的选类过滤日志：只要对手类名含 Handle/Drag/Flick/Select/Caret 或挂在文本视图，
        // 就打一行（即便 isHandle/isCaret 没命中也打），用于确认 shouldRequireFailureOf 是否被 UIKit
        // 用手柄调用过。若这行从不出现 → 手柄根本没进我们的仲裁(不同 window/独占)→ 需 hook 思路。
        {
            NSString *socls = NSStringFromClass([other class]);
            BOOL selish = ([socls containsString:@"Handle"] || [socls containsString:@"Drag"] ||
                           [socls containsString:@"Flick"] || [socls containsString:@"Select"] ||
                           [socls containsString:@"Caret"] ||
                           (other.view && ([other.view isKindOfClass:[UITextView class]] ||
                                           [other.view isKindOfClass:[UITextField class]])));
            if (selish) {
                OBDIAG(@"[diag-reqfail-sel] shouldRequireFailureOf globalPan other=%@ view=%@ isHandle=%d isCaret=%d",
                      socls, other.view ? NSStringFromClass([other.view class]) : @"nil", isHandle, isCaret);
            }
        }
        if (isHandle || isCaret) {
            OBDIAG(@"[diag-reqfail] shouldRequireFailureOf: 全屏 panG 要求 %@@%@ 先判定(让路文本选择手柄/光标)",
                  NSStringFromClass([other class]), other.view ? NSStringFromClass([other.view class]) : @"nil");
            return YES;
        }
        // 其余手势不在此声明依赖，落回下方边缘 pan 原有决策
    }
    if (![g isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) return NO;  // 仅我们的边缘 pan 参与决策
    if (other.delegate == self) {
        // 同为我们的 pan：仅让 nav pan 单向对 window pan 让步（无死锁），杜绝同边双开火 → 双返回。
        // window pan 始终不向 nav pan 让步，故不会互锁；其余自身组合（window↔window / nav↔nav 同边）仍跳过。
        BOOL gIsWindow = [[g view] isKindOfClass:[UIWindow class]];
        BOOL oIsWindow = [[other view] isKindOfClass:[UIWindow class]];
        if (!gIsWindow && oIsWindow) return YES;   // nav pan 让步于 window pan
        return NO;
    }
    if (![other isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) return NO;
    UIScreenEdgePanGestureRecognizer *mg = (UIScreenEdgePanGestureRecognizer *)g;
    UIScreenEdgePanGestureRecognizer *og = (UIScreenEdgePanGestureRecognizer *)other;
    if ((mg.edges & og.edges) == 0) return NO;   // 不同边（左/右）互不干涉
    // [2026-07-26 QQ 右缘修复] 右缘：Oback 必须独占返回（用户要"右缘返回"），不再向对手同边屏幕边缘
    // 手势让步。让步改由下方 _linkNavPopGesturesInWindow 对"对手手势"显式 requireGestureRecognizerToFail:
    // 我们的右缘 pan（单向：对手无法否决，无死锁）。左缘仍保留让步（保微信等左缘双返回修复）。
    if (mg.edges & UIRectEdgeRight) return NO;   // 右缘：永不向对手让步（右缘返回独占）
    // 左缘：默认向同边对手左边缘手势让步，避免 Oback + 系统/App 左边缘手势双返回。
    // 例外：本左缘 pan 挂在「接管型 nav」的 nav.view 上（mg.view.nextResponder 即该 nav），
    // 其自带/原生左边缘返回在朋友圈等页识别了却不真正返回（自定义容器层级不标准），若让步会让
    // Oback 左缘被取消而对手也不返回→双输。此时不让步，Oback 左缘 rightSimplePop 独占接管。
    // 关键修正（见 oback_debug(59) 顺序铁证）：不再依赖 shouldBegin 设置的 ivar——gestureRecognizerShouldBegin
    // 与 shouldRequireFailureOf 调用顺序不保证，ivar 读到上一次手势残留值→误让步→朋友圈左缘失效。
    // 改为直接从 pan.view 解析 nav（nav.view.nextResponder 即 UINavigationController），零关联对象时机/顺序问题。
    UINavigationController *mnav = nil;
    UIResponder *mnr = mg.view.nextResponder;
    if ([mnr isKindOfClass:[UINavigationController class]]) mnav = (UINavigationController *)mnr;
    BOOL mgIsTakeover = (mnav && ![self _navPopShouldDriveSystemNav:mnav]);
    OBLog(@"shouldRequireFailure: 左缘冲突 opponent=<%@:0x%p> ourNav=%@ takeover=%d",
          NSStringFromClass([og.view class]), og.view,
          mnav ? NSStringFromClass([mnav class]) : @"nil", mgIsTakeover);
    if (mgIsTakeover) {
        return NO;   // 接管型 nav：不让步，Oback 左缘独占接管（与右缘一致）
    }
    return YES;                                   // 同边（左）边缘手势：我们的 pan 让步于对手（单层返回，杜绝双触发）
}

// 同时识别（攻克朋友圈左缘被内部 pan 挤掉）：微信朋友圈(WCTimeLineViewController)内部挂了一个
// 非屏幕边缘的普通 UIPanGestureRecognizer(微信自有横滑/返回实现)。shouldRequireFailureOf 第 941 行
// 因对手非边缘手势直接 return NO(不建立失败依赖)；而本类未实现 shouldRecognizeSimultaneouslyWith
// → 系统默认不允许同时识别 → 微信内部 pan 先 Began → 我们的左缘 pan 被判 Failed → 不进 beginTransition
// → 胶囊显示(shouldBegin=YES)却无法返回。右缘朋友圈无此冲突(右侧无内部 pan)故正常。
// 修复：仅对「左缘 + 接管型 nav(微信类)」返回 YES 允许同时识别，并在本 pan Began 时取消对手(_simulOpponent)
// 以独占返回；标准 nav 与其他边保持默认(不影响现有让步/右缘独占逻辑)。
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    _obArbRec(&_obArbSimul, other);   // [R3] 探针
    if (g == other || other == nil) return NO;
    if (other.delegate == self) return NO;   // 自身另一个 pan(左/右/modal): 不与之同时识别, 更不记录为对手(否则 beginTransition 会误取消自身 → 右缘被取消 abort)
    if ([other isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) return NO; // 同边屏幕边缘手势(微信自带左边缘返回)交 shouldBeRequiredToFailBy 压制, 不在此同时识别(否则双 Began → 双返回)
    if (![g isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) return NO;
    UIScreenEdgePanGestureRecognizer *mg = (UIScreenEdgePanGestureRecognizer *)g;
    if (!(mg.edges & UIRectEdgeLeft)) return NO;           // 仅左缘需要(右缘/标准 nav 无此冲突)
    UIResponder *mnr = mg.view.nextResponder;
    if (![mnr isKindOfClass:[UINavigationController class]]) return NO;
    UINavigationController *mnav = (UINavigationController *)mnr;
    if ([self _navPopShouldDriveSystemNav:mnav]) return NO; // 标准 nav 不动(让步逻辑已够)
    [_simulOpponent release]; _simulOpponent = [other retain]; // retain 持有对手: 即使文章页 pop 后 WKWebView 释放, 手势对象仍存活(view 被置 nil), beginTransition 取消时不会解引用悬空指针(ef16030 仅 endTransition 清零不够——系统会在收尾后再次回调本方法重设指针)
    OBLog(@"simultaneously: 左缘接管型nav(%@)允许与<%@:0x%p>同时识别",
          NSStringFromClass([mnav class]), NSStringFromClass([other class]), other);
    return YES;
}

// 压制同边屏幕边缘手势(微信自带左边缘返回)失败于我们的左缘 pan：根治聊天界面左缘双返回。
// 微信聊天页自带左边缘返回能正常返回；此前 shouldRecognizeSimultaneouslyWith 把同边屏幕边缘手势
// 也当作『内部 pan』允许同时识别 → 我们的左缘 pan 与微信自带左边缘手势都 Began → 各 pop 一次 → 双返回
// (聊天界面-分组列表-主界面一次弹两层，用户微信分组插件使栈多一层更易暴露)。此处让微信自带左边缘手势
// 必须等我们的左缘 pan 失败才认：用户从边缘滑→我们的 pan 接管→微信自带失败→仅 Oback 单返回；
// 用户不滑边缘→我们的 pan 失败→微信自带正常返回(单返回)。朋友圈场景微信自带本就不返回，失败于我们
// (我们接管)无副作用。仅作用于左缘 + 接管型 nav(微信类)，其他边/标准 nav 保持默认，不影响右缘独占与
// 系统/插件单返回。
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    _obArbRec(&_obArbReqFailBy, other);   // [R3] 探针
    if (g == other || other == nil) return NO;
    if (other.delegate == self) return NO;   // 自身另一个 pan：不互相要求失败(防死锁/互消)
    if (![g isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) return NO;
    UIScreenEdgePanGestureRecognizer *mg = (UIScreenEdgePanGestureRecognizer *)g;
    if (!(mg.edges & UIRectEdgeLeft)) return NO;            // 仅左缘接管型需要
    if (![other isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) return NO; // 仅压制同边屏幕边缘手势(微信自带左边缘返回)
    UIScreenEdgePanGestureRecognizer *og = (UIScreenEdgePanGestureRecognizer *)other;
    if ((mg.edges & og.edges) == 0) return NO;             // 不同边不干涉
    UIResponder *mnr = mg.view.nextResponder;
    if (![mnr isKindOfClass:[UINavigationController class]]) return NO;
    UINavigationController *mnav = (UINavigationController *)mnr;
    if ([self _navPopShouldDriveSystemNav:mnav]) return NO; // 标准 nav 不动(让步逻辑已够)
    OBLog(@"shouldBeRequiredToFailBy: 左缘接管型nav(%@)压制同边屏幕边缘手势<%@:0x%p>(单返回)",
          NSStringFromClass([mnav class]), NSStringFromClass([other class]), other);
    return YES;   // 对手必须等我们的左缘 pan 失败才认 → 我们优先, 单返回
}

- (void)updateTransition:(UIPanGestureRecognizer *)pan {
    if (!self.interacting) return;
    UIWindow *win = [self _windowForPan:pan];
    CGFloat w = win.bounds.size.width;
    if (w <= 0) return;

    // 右缘非交互 pop：仅更新胶囊 + 记录位移进度，绝不 scrub / 绝不触发交互转场
    // （避免方案A 左原点语义导致的右缘负向反 scrub 与几何错配空白）。
    // 关键修复：此前未在此更新 _currentPercent，松手时进度恒为 0、仅靠速度投影，
    // 慢速内滑永远不 commit → 右缘只出胶囊不返回。现按位移同步进度，正常内滑即可提交。
    if (self.rightSimplePop) {
        CGPoint t = [pan translationInView:win];
        CGFloat dir = (self.currentEdge == ObackEdgeLeft) ? 1.0 : -1.0;
        CGFloat p = dir * t.x / w;
        p = MAX(0.0, MIN(1.0, p));
        _currentPercent = p;
        [self updateIndicatorWithPan:pan window:win];
        return;
    }

    CGPoint t = [pan translationInView:win];
    CGFloat dir = (self.currentEdge == ObackEdgeLeft) ? 1.0 : -1.0;
    CGFloat p = dir * t.x / w;
    p = MAX(0.0, MIN(1.0, p));

    // 首次横向拖动（p>0）才真正触发
    if (!_transitionTriggered && p > 0.001) {
        if (self.currentParallaxToView && self.currentEdge != ObackEdgeRight && _navPopProbeFailed) {
            // 微信等自定义nav(非交互路径)：首次横拖才 popViewControllerAnimated:（同右缘节奏）。
            // 不在 Began 即 pop，避免撕裂视图层级导致手势收不到终态、胶囊残留。
            UINavigationController *navP = nil;
            NSString *kindP = objc_getAssociatedObject(pan, kPanKindKey);
            if ([kindP isEqualToString:@"nav"]) navP = [self _popNavForPan:pan];
            if (!navP) {
                UIViewController *topP = [self topMost:win.rootViewController];
                navP = [self _poppableNavFrom:topP.navigationController];
                if (!navP && [topP isKindOfClass:[UINavigationController class]]) navP = [self _poppableNavFrom:(UINavigationController *)topP];
                if (!navP) navP = topP.navigationController;
            }
            if (navP) { @try { [navP popViewControllerAnimated:YES]; } @catch (NSException *e) {} }
            _transitionTriggered = YES;
        } else {
            // modal/右缘路径在此触发；nav 方案A路径已在 begin 启动，这里不再触发
            [self triggerTransitionInWindow:win withPan:pan];
            _transitionTriggered = YES;
        }
    }

    // [运行时探测切换] 左缘 nav pop：首次横向拖动实测系统交互转场是否真进入 interactive 态。
    // 关键修复：原探测错误地嵌在 `if(!_transitionTriggered)` 内——而左缘 nav 路径在 begin 已置
    // _transitionTriggered=YES（driveSystemNavPopBeginWithPan 第1190行），导致探测永不执行（旧实现下
    // _navPopProbeFailed 恒为 NO）、微信等自定义 nav 永远走方案A 而失效。现改用 _navPopProbed 单独门控，
    // 确保首次横向拖动必跑一次。标准 nav → interactive=YES 继续方案A 跟手；微信等自定义 nav →
    // 永不 interactive，当场切非交互 popViewControllerAnimated:（永不失效，代价不跟手）。
    // 探测仅用于方案A 识别微信等自定义 nav（系统原生交互转场能否启动）。nav 视差实验走自定义转场，
    // 其 transitionCoordinator 可能 interactive=NO → 误判 _navPopProbeFailed → 非交互重复 pop + 冲突，故跳过。
    if (self.currentParallaxToView && self.currentEdge != ObackEdgeRight && !_navPopProbed) {
        _navPopProbed = YES;
        if (!_navPopProbeFailed) {
            UINavigationController *navP = nil;
            NSString *kindP = objc_getAssociatedObject(pan, kPanKindKey);
            if ([kindP isEqualToString:@"nav"]) navP = [self _popNavForPan:pan];
            if (!navP) {
                UIViewController *topP = [self topMost:win.rootViewController];
                navP = [self _poppableNavFrom:topP.navigationController];
                if (!navP && [topP isKindOfClass:[UINavigationController class]]) navP = [self _poppableNavFrom:(UINavigationController *)topP];
                if (!navP) navP = topP.navigationController;
            }
            if (navP) {
                id tc = [navP.topViewController transitionCoordinator];
                BOOL interactive = (tc && [tc respondsToSelector:@selector(isInteractive)] && [tc isInteractive]);
                if (!interactive) {
                    OBLog(@"navPop 探测: 系统交互转场未启动(自定义nav?), 切非交互 pop (nav=%@)",
                          NSStringFromClass([navP class]));
                    _navPopProbeFailed = YES;
                    _navPopTarget = nil;   // 后续 _callSystemNavPop: 直接 return，避免重复驱动系统转场
                    @try { [navP popViewControllerAnimated:YES]; } @catch (NSException *e) {}
                }
            }
        }
    }

    _currentPercent = p;
    if (self.currentParallaxToView && (self.currentEdge == ObackEdgeRight)) {
        // 右缘：方案B 统一走 rightSimplePop 非交互 pop（updateTransition 早期 return 已处理），此处不再 scrub
    } else if (self.currentParallaxToView) {
        // 方案 A：nav pop 用系统原生交互转场，直接把当前 pan 喂给 handleNavigationTransition: 做 scrub。
        // 探测失败(_navPopProbeFailed)已切非交互 pop，此处不再喂系统转场(避免冲突)，仅保留胶囊反馈。
        if (!_navPopProbeFailed) [self _callSystemNavPop:pan];
    } else {
        // modal dismiss（方案B：交还系统/App 原生 dismiss，非交互，不 scrub）
    }
    [self updateIndicatorWithPan:pan window:win];
}

- (void)endTransition:(UIPanGestureRecognizer *)pan {
    [self _restoreOpponentPansDeferred];   // [A'] 排恢复（0.12s 后且未再次接管才真正恢复；覆盖下方所有 return 分支）
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_restoreOpponentPansIfIdle) object:nil];   // [A'] 撤掉安全阀
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(dismissIndicatorSafety) object:nil];
    pan.cancelsTouchesInView = NO;   // [2026-07-29 误触修复 v2] 复位：下一轮手势起始 cancelsTouchesInView 回到默认 NO（纯点击不误吞）
    // [2026-07-28 崩溃修复] 收尾 release+nil _simulOpponent。该指针已改为 retain 自持(994 行赋值处)，
    // 故 pop 文章后对手手势对象不会被释放(仅 view 置 nil)，beginTransition 取消时安全；但每轮仍须在
    // 生命周期结束处 release(交还所有权)以防泄漏。注:ef16030 原仅在 endTransition/abortTransition 清零
    // 不够——系统会在 endTransition 之后再次回调 shouldRecognizeSimultaneouslyWith 把指针重设回即将释放的
    // WKWebView 手势；retain 语义使"重设后的指针"也始终有效，从根上杜绝"第一次正常、第二次崩溃"的悬空崩溃。
    [_simulOpponent release]; _simulOpponent = nil;
    if (!self.interacting) return;
    UIWindow *win = [self _windowForPan:pan];
    CGFloat w = win.bounds.size.width;
    // ===== 右缘非交互 pop（零空白修复）=====
    // 右缘不喂系统左原点 handleNavigationTransition:（会算错底页坐标→空白），也不进自定义视差转场；
    // 松手提交才 popViewControllerAnimated: 非交互返回——方向天然正确、导航栏不破坏、零空白。
    if (self.rightSimplePop) {
        CGPoint v = [pan velocityInView:win];
        CGFloat dir = (self.currentEdge == ObackEdgeLeft) ? 1.0 : -1.0;
        CGFloat vel = dir * v.x;
        CGFloat projected = _currentPercent;
        if (w > 0) projected += (vel * 0.12) / w;
        projected = MAX(0.0, MIN(1.0, projected));
        CGFloat effective = MAX(_currentPercent, projected);
        ObackParams *p = [ObackPreferences params];
        BOOL commit = (effective > p.commitRatio) || (vel > p.commitVelocity);
        NSString *kind = objc_getAssociatedObject(pan, kPanKindKey);
        UINavigationController *nav = nil;
        if ([kind isEqualToString:@"nav"]) {
            nav = [self _popNavForPan:pan];
        }
        if (!nav) {
            UIViewController *top = [self topMost:win.rootViewController];
            nav = top.navigationController;
            if (!nav && [top isKindOfClass:[UINavigationController class]]) nav = (UINavigationController *)top;
        }
        if (commit && nav && nav.viewControllers.count > 1) {
            NSUInteger cntBefore = nav.viewControllers.count;
            @try { [nav popViewControllerAnimated:YES]; }
            @catch (NSException *e) { OBLog(@"endTransition 右缘 pop 异常: %@", e); }
            // [2026-09-17 双层 nav 诊断] pop 前后栈深对照：after == before-1 ⇒ pop 真的生效；
            // 相等 ⇒ pop 被容器(iOS 设置 App 的 PSSplitViewController)拦截/回滚，即用户看到的「没反应」。
            OBLog(@"[diag-pop] nav=%@ 前=%lu 后=%lu top=%@", NSStringFromClass([nav class]),
                  (unsigned long)cntBefore, (unsigned long)nav.viewControllers.count,
                  nav.topViewController ? NSStringFromClass([nav.topViewController class]) : @"nil");
        }
        // 关键修复：右缘分支此前漏调 dismissIndicatorCommitted，胶囊永远残留屏幕。
        // 提交→放大淡出；取消→弹回边缘，与左右边缘行为一致。
        if (_indicator) [self dismissIndicatorCommitted:commit params:p window:win];
        self.interacting = NO;
        _navPopTarget = nil;
        _currentPercent = 0;
        _transitionTriggered = NO;
        self.rightSimplePop = NO;
        OBLog(@"endTransition: 右缘非交互 pop (commit=%d nav=%@)", commit, nav ? NSStringFromClass([nav class]) : @"nil");
        return;
    }
    CGPoint v = [pan velocityInView:win];
    CGFloat dir = (self.currentEdge == ObackEdgeLeft) ? 1.0 : -1.0;
    CGFloat vel = dir * v.x;   // 前向(朝返回方向)为正


    // 动量投影：按当前速度再投影约 0.12s 的惯性滑行距离，避免"快滑却因瞬时位移小被取消"。
    // 真机日志显示用户多为快速内滑(percent 仅 0.23~0.37 就松手)，纯位移阈值会误判取消。
    CGFloat projected = _currentPercent;
    if (w > 0) projected += (vel * 0.12) / w;
    projected = MAX(0.0, MIN(1.0, projected));
    CGFloat effective = MAX(_currentPercent, projected);

    ObackParams *p = [ObackPreferences params];
    // 提交判定：① 实际/投影位移过阈值(含惯性)；② 纯高速甩动(即便几乎没拖动)
    CGFloat commitRatio = p.commitRatio;
    CGFloat commitVelocity = p.commitVelocity;
    BOOL commit = (effective > commitRatio) || (vel > commitVelocity);
    OBLog(@"endTransition (percent=%.2f vel=%.0f projected=%.2f commit=%d triggered=%d)",
          _currentPercent, vel, projected, commit, _transitionTriggered);
    if (_indicator) [self dismissIndicatorCommitted:commit params:p window:win];

    // ===== 方案 A：nav pop 用系统原生交互转场 =====
    // 直接把当前 pan(已 Ended)喂给 handleNavigationTransition:，系统据此完成/取消原生 pop。
    // 无自定义动画器、无 completeTransition 调用、无 watchdog —— 全部由 UIKit 原生收尾。
    // [稳定性决策] nav pop 的提交/灵敏度完全由系统 _UINavigationInteractiveTransition 决定，
    // 上面算的 commit / commitRatio / commitVelocity 对 nav pop 不生效（仅打日志）。设置面板里的
    // 灵敏度滑块只对 modal dismiss(方案B 自定义转场)生效——这是为换取"零冻结/原生手感"的取舍，
    // 不回退到自定义 nav 转场（那曾是导致黑屏/冻结的根因）。
    if (self.currentParallaxToView) {
        if (_navPopProbeFailed) {
            // 探测失败已切非交互 pop：此处仅复位状态，不再喂系统转场（避免与已进行的非交互 pop 冲突）
            OBLog(@"endTransition: nav pop 探测失败→非交互返回复位 (commit=%d)", commit);
            self.interacting = NO;
            _navPopTarget = nil;
            _currentPercent = 0;
            _transitionTriggered = NO;
            return;
        }
        [self _callSystemNavPop:pan];
        self.interacting = NO;
        _navPopTarget = nil;
        _currentPercent = 0;
        _transitionTriggered = NO;
        OBLog(@"endTransition: nav pop 系统原生收尾 (commit=%d)", commit);
        return;
    }

    // ===== 以下为 modal dismiss 路径（方案B：交还系统/App 原生 dismiss，非交互，不可中途取消）=====
    // 注：这里不释放 currentTD —— 弹窗若 cancel 仍 present，其 transitioningDelegate(assign)
    // 仍指向该 td；释放会留下野指针。td 的生命周期由被 dismiss 的 VC 关联对象保证（见 beginTransition）。
    if (!_transitionTriggered && commit) {
        // 快滑但几乎无净位移（手势 Began→Ended 之间无有效横向移动，p 从未 >0.001），
        // 交互转场未启动；但速度已达提交阈值(commit=1) → 用户意图明确"一滑即回"。
        // 直接走系统动画 dismiss（非交互，最干净），避免"胶囊飞出却没反应"的困惑。
        self.interacting = NO;
        OBLog(@"endTransition: modal 快滑零位移，原生 dismiss (vel=%.0f edge=%@)", vel,
              self.currentEdge == ObackEdgeLeft ? @"左" : @"右");
        [self triggerTransitionInWindow:win withPan:pan];
        _currentPercent = 0;
        _transitionTriggered = NO;
        return;   // 此路径用系统原生动画，无 ObackAnimator，无需兜底收尾
    }
    // 原生 dismiss 已由系统动画自行收尾（首次横拖即触发，不可中途取消），无需 forceFinish/watchdog；仅复位状态。
    self.interacting = NO;
    _currentPercent = 0;
    _transitionTriggered = NO;
}


// nav pop 安全看门狗（方案A 专用）：个别 App（如 Filza）会禁用/改造系统原生 interactivePopGestureRecognizer，
// 导致我们经 handleNavigationTransition: 驱动的系统交互转场在松手后卡在「进行中」态
// （UIKit 关闭 userInteraction → 界面冻结，后台再回来才被系统清掉）。
// 机制：手势启动即排一个 0.8s 定时器，捕获此刻的系统交互动画器(_navPopTarget= _UINavigationInteractiveTransition，
// 它是 UIPercentDrivenInteractiveTransition 子类，响应 finish/cancelInteractiveTransition)；
// 正常 pop 约 0.35s 完成，到时 coordinator 已为 nil/非 interactive → 空操作；若仍卡在 interactive 态 →
// 对捕获的 target 强制 finishInteractiveTransition 收尾，并防御性复位 manager 状态，杜绝冻结。
// 注意：finish/cancel 是交互动画器(UIViewControllerInteractiveTransitioning)的方法，不是 transitionCoordinator 的，
// 故必须对捕获的 _navPopTarget 调用，而非对 coordinator 调用（否则 -Werror 未声明方法）。
// 幂等保护：这 0.8s 内若 topViewController 已变（发生新的 push/pop）说明转场已正常推进，跳过。
- (void)_scheduleNavPopWatchdog:(UINavigationController *)nav {
    if (!nav) return;
    UIViewController *topAtSchedule = nav.topViewController;
    if (!topAtSchedule) return;
    id target = _navPopTarget;                 // 系统交互动画器（percent-driven），endTransition 会把它置 nil，故此处先捕获
    if (!target) return;
    [target retain];                           // MRC：block 持有期间强持，避免被 UIKit 释放成野指针
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (nav.topViewController != topAtSchedule) { [target release]; return; }   // 已正常推进，跳过
        if (self.interacting) { [target release]; return; }   // 已有新手势进行中，不干扰（避免误伤二次滑动）
        id tc = [topAtSchedule transitionCoordinator];
        BOOL stuck = (tc && [tc respondsToSelector:@selector(isInteractive)] && [tc isInteractive]);
        if (stuck) {
            OBLog(@"navPop watchdog: 系统交互转场仍卡住，强制结束 (top=%@)",
                  NSStringFromClass([topAtSchedule class]));
            @try {
                if ([target respondsToSelector:@selector(finishInteractiveTransition)])
                    [target finishInteractiveTransition];   // 完成到目标态（父页），贴合用户已见到的返回结果
                else if ([target respondsToSelector:@selector(cancelInteractiveTransition)])
                    [target cancelInteractiveTransition];
            } @catch (NSException *e) { OBLog(@"navPop watchdog finish fail: %@", e); }
        }
        // 防御性复位：即使正常路径已复位，也兜底，防止极端情况下 interacting 残留导致冻结
        if (self.interacting && nav.topViewController == topAtSchedule) {
            self.interacting = NO;
            _navPopTarget = nil;
            _currentPercent = 0;
            _transitionTriggered = NO;
        }
        [target release];
    });
}

// 手势意外失败(Failed/超时等)时的紧急清理：取消转场+消除胶囊，防止残留
- (void)abortTransition:(UIPanGestureRecognizer *)pan {
    [self _restoreOpponentPansDeferred];   // [A'] 同上：手势失败/被取消也要恢复对手手势
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_restoreOpponentPansIfIdle) object:nil];   // [A'] 撤掉安全阀
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(dismissIndicatorSafety) object:nil];
    pan.cancelsTouchesInView = NO;   // [2026-07-29 误触修复 v2] 复位：下一轮手势起始 cancelsTouchesInView 回到默认 NO（纯点击不误吞）
    // [2026-07-28 崩溃修复] 同 endTransition：手势失败/被取消时 release+nil _simulOpponent
    // (retain 自持语义下交还所有权，杜绝泄漏；同时保证下一轮不会解引用悬空指针)。
    [_simulOpponent release]; _simulOpponent = nil;
    OBLog(@"abortTransition (state=%ld)", (long)pan.state);
    UIWindow *win = [self _windowForPan:pan];
    ObackParams *p = [ObackPreferences params];
    if (_indicator) [self dismissIndicatorCommitted:NO params:p window:win];
    if (self.currentParallaxToView) {
        if (self.currentEdge == ObackEdgeRight) {
            // 右缘：方案B 统一走 rightSimplePop 非交互 pop（abort 即复位，原生转场自行处理）
        } else {
            // 方案 A：nav pop 用系统原生交互转场，把当前 pan(Failed/Cancelled)喂给 handleNavigationTransition:
            // 让系统取消原生 pop；无自定义动画器，无需 watchdog/interactive cancel。
            // 探测失败(_navPopProbeFailed)已切非交互 pop，不再喂系统转场(避免冲突)，直接走下方复位。
            if (_transitionTriggered && !_navPopProbeFailed) [self _callSystemNavPop:pan];
        }
        // 兜底：若系统 target 取不到导致原生 pop 从未启动（driveSystemNavPopBegin 降级为非交互 pop），
        // 此处 _navPopTarget 为 nil，_callSystemNavPop 为空操作，无需额外处理。
    } else {
        // modal dismiss（方案B 原生 dismiss 非交互、不可中途取消）：abort 不回滚已触发的 dismiss，仅复位状态。
    }
    self.interacting = NO;
    _navPopTarget = nil;
    _currentPercent = 0;
    _transitionTriggered = NO;
    self.rightSimplePop = NO;     // 复位：避免残留导致下次手势误判右缘非交互
    // [2026-08-06 崩溃修复] 同 endTransition：panG 的 nav 绑定在手势结束时清空(RETAIN→释放)，杜绝悬空/泄漏。
    if (objc_getAssociatedObject(pan, kGlobalPanKey)) {
        objc_setAssociatedObject(pan, kObackNavKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(pan, kObackPopNavKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    // 边缘 pan(kind=nav) 的本次解析结果也要清：下一轮手势重新判定（页面已变，外层栈可能已 pop）。
    if ([objc_getAssociatedObject(pan, kPanKindKey) isEqualToString:@"nav"]) {
        objc_setAssociatedObject(pan, kObackPopNavKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
}

#pragma mark - [A'] 接管即独占：本次手势期间压制 App 自带返回手势

// [A' 方案] 通用化的「Oback 接管即独占」。
// 背景：QQ 自带全屏返回手势（NTPushPopLib —— 一个挂在**独立 overlay window** 上的 plain
//   UIPanGestureRecognizer），与 Oback 的边缘 pan 抢同一次滑动 → 抢跑 / 双返回。历史实证（见 _pub_p8 备份）：
//   · A 方案（requireGestureRecognizerToFail: 跨 window 建依赖）对 QQ **无效**——跨 window 依赖不可靠，对手先抢跑；
//   · B 方案（Oback 接管时直接把对手 pan 置 enabled=NO）**有效**，但当时写死了大量 QQ 私有类名。
//   ⇒ 本方案把 B 通用化：命中与放行都用**通用 UIKit 语义**，不写死任何 App 私有类名，做成面板开关（默认关）。
//
// 命中（会被临时禁用）任一条件：
//   ① UIScreenEdgePanGestureRecognizer（系统 / App / 插件的边缘返回手势，跨 window 也抓得到）
//   ② 挂在 nav.view 树上（原生 pop 与多数自研全屏返回都挂在导航容器视图上）
//   ③ 手势类名含返回语义词（PushPop / SlideBack / SwipeBack / PopGesture / BackGesture / PanPop）
//      —— 覆盖「挂在独立 window 上、不在 nav 树里」的自研全屏返回（QQ 属此类）
// 一律放行（绝不禁用）：
//   · Oback 自己的 pan（delegate == self）
//   · 滚动手势（UIScrollView.panGestureRecognizer + 私有 UIScrollViewPanGestureRecognizer）
//   · 文本视图内的 pan（UITextView / UITextField：拖光标、选词）
//   · 选择 / 手柄 / 放大镜类（类名含 Handle/Select/Caret/Drag/Loupe/Magnifier/Range/Text）
//   · 左滑操作容器（类名含 Swipe：列表项左滑引用 / 删除 / 侧滑菜单）
//   · **nav 的 interactivePopGestureRecognizer**：Oback 既有逻辑把它**永久**禁用（1273/1619/1832 行），
//     若被 A' 记录在案并在恢复时重新置 YES，就会破坏该不变量、重新引入双返回 ⇒ 直接放行不碰。
// ⚠️ 存储必须用 NSHashTable weakObjectsHashTable：pan 一旦 dealloc 条目自动消失，延后恢复循环
//    绝不会向野指针发消息（历史用 NSMutableSet 装 NSValue 曾致 EXC_BAD_ACCESS 崩溃）。
- (NSHashTable *)_suppressedPanTable {
    NSHashTable *t = objc_getAssociatedObject(self, kObackSuppressedPansKey);
    if (!t) {
        t = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(self, kObackSuppressedPansKey, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return t;
}

// [R7 方案A] 独占常驻禁用集合（弱引用，MRC 下由关联对象持有）。
// 与 _suppressedPanTable 的区别：那个随本次接管 end/abort 恢复；本集合在开关开启期间**不恢复**。
- (NSHashTable *)_exclusiveDisabledPanTable {
    NSHashTable *t = objc_getAssociatedObject(self, kObackExclusiveDisabledPansKey);
    if (!t) {
        t = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(self, kObackExclusiveDisabledPansKey, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return t;
}


// 是否某个 UINavigationController 的系统原生 interactivePopGestureRecognizer。
// 判据：该手势挂在 nav.view 上，而 UIViewController 的 view 的 nextResponder 就是 VC 本身 ⇒ 可直接向
// nextResponder 取 interactivePopGestureRecognizer 比对，无需遍历，也不依赖任何私有类名。
- (BOOL)_isNavInteractivePop:(UIGestureRecognizer *)g {
    if (!g) return NO;
    UIView *v = g.view;
    if (!v) return NO;
    @try {
        UIResponder *r = v.nextResponder;
        if ([r isKindOfClass:[UINavigationController class]])
            return (g == ((UINavigationController *)r).interactivePopGestureRecognizer);
    } @catch (NSException *e) {}
    return NO;
}

- (BOOL)_isAllowlistedOpponentPan:(UIPanGestureRecognizer *)g view:(UIView *)v {
    if (!g) return YES;
    if (g.delegate == self) return YES;                     // 自己的 pan：绝不自压
    if ([self _isNavInteractivePop:g]) return YES;          // 系统 ipg：Oback 已永久禁用，A' 不碰（见上方说明）
    Class scrollPanCls = NSClassFromString(@"UIScrollViewPanGestureRecognizer");
    if (scrollPanCls && [g isKindOfClass:scrollPanCls]) return YES;
    if (v) {
        if ([v isKindOfClass:[UIScrollView class]] && g == ((UIScrollView *)v).panGestureRecognizer) return YES;
        if ([v isKindOfClass:[UITextView class]] || [v isKindOfClass:[UITextField class]]) return YES;
    }
    NSString *gcls = NSStringFromClass([g class]);
    NSString *vcls = v ? NSStringFromClass([v class]) : nil;
    // [R4 乙 2026-09-17] 裸 @"Drag" 是**子串**匹配 ⇒ 把 QQ 的返回手势 RightDragPanGestureRecognizer 一起放行了
    // （日志6 实证：它因此整轮不被压制，且在我们判 YES 之前就已 Began ⇒ 左缘永不接管 + 非交互 pop = 瞬闪）。
    // 收窄为它原本想覆盖的两个文本选择手柄类名 —— 手柄侧靠 "Handle"/"DragAnimation"/"DragHandle" 覆盖。
    // ⚠️ 本函数对手势类名**和宿主类名**共用这张表：宿主侧靠 @"Select" 兜住 SwiftUI 的
    //    PlatformViewHost<…SelectionManagerBox…>（2026-09-17 P0 修复），故宿主侧词表刻意保持不变。
    NSArray *allow = @[@"Handle", @"Select", @"Caret", @"DragAnimation", @"DragHandle", @"Loupe", @"Magnifier", @"Range", @"Swipe", @"Text"];
    for (NSString *w in allow) {
        if (gcls && [gcls rangeOfString:w options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        if (vcls && [vcls rangeOfString:w options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

- (BOOL)_isPopLikeOpponentPan:(UIPanGestureRecognizer *)g view:(UIView *)v nav:(UINavigationController *)nav {
    if (!g) return NO;
    if ([g isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) return YES;                    // ① 边缘返回手势
    if (nav && nav.view && v && (v == nav.view || [v isDescendantOfView:nav.view])) return YES;    // ② nav 树上
    NSString *gcls = NSStringFromClass([g class]);                                                 // ③ 类名含返回语义
    NSArray *popWords = @[@"PushPop", @"SlideBack", @"SwipeBack", @"PopGesture", @"BackGesture", @"PanPop"];
    for (NSString *w in popWords) {
        if (gcls && [gcls rangeOfString:w options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

// =====================================================================================
// [R3 诊断 2026-09-17] 仲裁现场快照 —— 在 shouldBegin=YES 那一刻抓，一次实测回答三问：
//   ① 谁已经赢了：全场 state != Possible 的手势（含类名@宿主 view@window；ours 标出我们自己的）
//   ② 对手是谁：nav 系统 ipg 的 类名/enabled/state/targets/delegate + 触摸点祖先链上的全部边缘手势
//   ③ 有没有被咨询：三个仲裁回调的累计计数 + 最近对手（区分「对手类型不符」与「UIKit 真没问」）
// ⚠️ 只打日志、不改任何状态；遍历一律带节点预算（历史 watchdog 根因就是「无预算的全树遍历被快照争锁」）。
// ⚠️ **不受面板「接管即独占」开关门控** —— 否则「谁抢了左缘手势」这个结论又会被「开关没开」这个变量污染
//    （上一轮 文本(4) 就是这么被绕进去的：A' 零日志，无法区分开关没开 / 逻辑不触发）。
// ⚠️ 每条都带 build tag：历史三次「诊断全空」其实都是没装对版本（2026-08-04/08-09/09-16），必须一次排除。
// =====================================================================================
- (void)_obDiagArenaSnapshotForPan:(UIPanGestureRecognizer *)pan window:(UIWindow *)win
                               nav:(UINavigationController *)nav edge:(ObackEdge)edge point:(CGPoint)loc {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    // ① nav 系统 ipg 详表（nil nav 也要能打，故全程判空）
    UIGestureRecognizer *ipg = nav ? nav.interactivePopGestureRecognizer : nil;
    NSString *ipgDesc = @"nil";
    if (ipg) {
        NSArray *targets = nil;
        @try { targets = [ipg valueForKey:@"_targets"]; } @catch (NSException *e) { targets = nil; }
        ipgDesc = [NSString stringWithFormat:@"%@ enabled=%d state=%ld targets=%lu delegate=%@",
                   NSStringFromClass([ipg class]), (int)ipg.enabled, (long)ipg.state,
                   (unsigned long)(targets ? targets.count : 0),
                   ipg.delegate ? NSStringFromClass([ipg.delegate class]) : @"nil"];
    }
    OBDIAG(@"[diag-arena@%@] edge=%@ bid=%@ pan=%@ win=%@ ipg=%@",
           OBACK_BUILD_TAG, (edge == ObackEdgeLeft ? @"左" : @"右"), bid,
           NSStringFromClass([pan class]), win ? NSStringFromClass([win class]) : @"nil", ipgDesc);
    // ② 全场「已不在 Possible」的手势 = 已经赢的 / 正在赢的
    NSArray *wins = nil;
    @try { wins = [self _allVisibleWindows]; } @catch (NSException *e) { wins = nil; }
    if (wins.count == 0) wins = win ? [NSArray arrayWithObject:win] : [NSArray array];
    NSMutableArray *active = [NSMutableArray array];
    for (UIWindow *w in wins) {
        if (!w) continue;
        NSUInteger budget = kOBEnumMaxNodes;
        [self _enumerateGestureViewsIn:w depth:0
                             predicate:^BOOL(UIView *v, UIGestureRecognizer *g){
                                 return (g.state != UIGestureRecognizerStatePossible);
                             }
                                  emit:^(UIGestureRecognizer *g){
            [active addObject:[NSString stringWithFormat:@"%@@%@@win:%@(state=%ld%@)",
                               NSStringFromClass([g class]),
                               g.view ? NSStringFromClass([g.view class]) : @"nil",
                               NSStringFromClass([w class]), (long)g.state,
                               (g.delegate == self ? @",ours" : @"")]];
        } budget:&budget];
    }
    OBDIAG(@"[diag-arena] 已识别手势(%lu): %@", (unsigned long)active.count, active);
    // ③ 仲裁计数
    OBDIAG(@"[diag-arena] 仲裁计数 reqFail=%lu reqFailBy=%lu simul=%lu 最近对手=%@",
           (unsigned long)_obArbReqFail, (unsigned long)_obArbReqFailBy, (unsigned long)_obArbSimul,
           _obArbLastOpp ? _obArbLastOpp : @"-");
    // ④ 触摸点祖先链上的边缘手势（一眼看出同边对手是谁 / 是不是我们自己的）
    UIView *hv = (win && !CGRectIsEmpty(win.bounds)) ? [win hitTest:loc withEvent:nil] : nil;
    NSMutableArray *chain = [NSMutableArray array];
    for (UIView *v = hv; v; v = v.superview) {
        for (UIGestureRecognizer *g in v.gestureRecognizers) {
            if (![g isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) continue;
            UIScreenEdgePanGestureRecognizer *eg = (UIScreenEdgePanGestureRecognizer *)g;
            [chain addObject:[NSString stringWithFormat:@"%@@%@(edges=%lu state=%ld en=%d%@)",
                              NSStringFromClass([g class]), NSStringFromClass([v class]),
                              (unsigned long)eg.edges, (long)g.state, (int)g.enabled,
                              (g.delegate == self ? @",ours" : @"")]];
        }
    }
    OBDIAG(@"[diag-arena] 触摸点(%.0f,%.0f)链上边缘手势(%lu): %@",
           loc.x, loc.y, (unsigned long)chain.count, chain);
}

- (void)_suppressOpponentPansForPan:(UIPanGestureRecognizer *)pan {
    if (!pan) return;
    if (![ObackPreferences exclusivePopEnabled]) {
        // 只在每次启动打一条：日志里有没有这一行，一锤定音区分
        // 「开关没读到（roothide 跨进程）」与「读到了但没走到挂点」——上次只能靠猜。
        static BOOL __obExclWarned = NO;
        if (!__obExclWarned) { __obExclWarned = YES; OBLog(@"[独占] 开关未开(exclusivePop=0)，本次启动不做任何压制"); }
        return;   // 面板开关默认关：不开则完全不改 App 手势状态
    }
    UIWindow *win = [self _windowForPan:pan];
    // [R10 2026-09-18] 本条路径原先还要解析 nav，供旧判据的「挂在 nav.view 树上」那一条使用。
    // 判据收窄后 nav 已不被任何一行读取，这里一并删掉那两三次树遍历：既省掉 shouldBegin 热路径上的开销，
    // 也避免「赋值未读取」在 -Werror 下直接编译失败。
    // ⚠️ 只删**本条路径**的解析。左缘链接器（_obLinkLeftEdgeOpponentPansInWindow）仍需要 nav，未动。
    NSHashTable *suppressed = [self _suppressedPanTable];
    __block NSUInteger n = 0;
    NSArray *windows = nil;
    @try { windows = [self _allVisibleWindows]; } @catch (NSException *e) { windows = nil; }
    if (windows.count == 0) windows = win ? [NSArray arrayWithObject:win] : [NSArray array];
    for (UIWindow *w in windows) {
        if (!w) continue;
        [self _enumeratePansInView:w depth:0 block:^(UIPanGestureRecognizer *g){
            if (g == pan) return;                                    // 触发本次接管的那一个：不动
            UIView *v = g.view;
            if (!g.enabled) return;                                  // 已禁用：不重复记录
            if ([self _isAllowlistedOpponentPan:g view:v]) return;
            // [R10 2026-09-18] (a) 判据收窄：由旧的「边缘类 / nav 树 / 类名」三合一，改为**仅类名精确命中返回语义**，
            // 与常驻压制所用的那套判据完全对齐（同一个方法）。
            // 依据 = R8 日志实测（非推断）：每次边缘起滑此处会禁用 7~8 个，且**全部是无辜方** ——
            //   NTAISummaryFloatEar（智能体浮耳）/ NTAIOQuickReplyGestureRecognizer / NTAIONoticeCollectionView ×2 /
            //   UICollectionView / 裸 UIView ×2；而真凶 RightDragPanGestureRecognizer **不在其中**：
            //   它早已被常驻压制置为不可用，被上面那行「已禁用则直接跳过」短路。
            // ⇒ 本压制对「治瞬返」的净贡献为 0，纯属误伤（与历史 T4 删掉整套 B 方案同一成因）。
            // 另：「边缘类」那一条在本场景贡献同样为 0 —— 触摸链上唯一的非 Oback 边缘手势是 nav 系统 ipg，早已被禁用。
            // ⚠️ 不得改动被共享的旧判据方法本身：左缘链接器（约 1495 行）正是靠它的「nav 树」分支命中 RightDrag
            //    才修好 R6 的全屏瞬返；整体删掉那条分支会让瞬返立刻回归。
            if (![self _isSwipeRightPopOpponentPan:g]) return;
            g.enabled = NO;
            [suppressed addObject:g];
            n++;
            OBLog(@"[独占] 禁用对手返回手势 %@ (view=%@ window=%@)",
                  NSStringFromClass([g class]), NSStringFromClass([v class]), NSStringFromClass([w class]));
        }];
    }
    // [R10] 判据收窄后此处应恒为 0~1 个（收窄前实测每次 7~8 个）。改为**始终**打一行：
    // 这就是「误伤已消除」的证据行；否则 n==0 时静默，无法区分「收窄生效」与「这条路径根本没走到」。
    OBLog(@"[独占] 本次接管压制对手手势 %lu 个（R10 收窄判据）", (unsigned long)n);
    // [A' 安全阀] 挂点前移到 shouldBegin 后新增：日志实证「判 YES 却从未 Began」是常态 ⇒
    // endTransition/abortTransition 都不会来，若不兜底，被禁用的对手手势会**永久失效**。
    // 故排一个 0.6s 定时器：到时若仍未接管（interacting==NO）就恢复。正常接管时该定时器空转（表已空）。
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_restoreOpponentPansIfIdle) object:nil];
    [self performSelector:@selector(_restoreOpponentPansIfIdle) withObject:nil afterDelay:0.9];   // [R3] 0.6→0.9：给正常滑动留足时间，减少误判为「未接管」
}

// 安全阀体：仅当 Oback 没有真正接管时才恢复（interacting==NO）
// [R3 2026-09-17 丙 —— 必须修] 安全阀改为**延后**恢复（走 _restoreOpponentPansDeferred）。
// 原实现直接调 _restoreOpponentPans（立即恢复）绕过了 0.12s 延后保护：左缘「判 YES 却从不 Began」时
// end/abort 永不触发 ⇒ 恢复只走本安全阀 ⇒ 每次都在触摸中途把对手手势放出去 ⇒ 对手基于已收到的位移
// 瞬间判定 pop = 瞬闪。这正是 2026-08-06（95f0c49 `_restoreQQNativePopDeferred`）与 2026-09-17 两次
// 记在 _restoreOpponentPansDeferred 头上的历史坑，不要再绕过去。
- (void)_restoreOpponentPansIfIdle {
    if (self.interacting) return;
    // [R3] 手指仍在屏幕上 → 绝不恢复（否则对手 pan 拿着同一串 touch 立刻判定 pop = 瞬闪）。
    // 只把安全阀往后重排一轮；离屏判定带 1.5s 失联兜底，故不会永久禁死对手手势。
    if (_obTouchInFlight()) {
        [self performSelector:@selector(_restoreOpponentPansIfIdle) withObject:nil afterDelay:0.9];
        return;
    }
    [self _restoreOpponentPansDeferred];   // 离屏了才恢复，且仍走 0.12s 延后 + interacting 守卫（丙）
}

- (void)_restoreOpponentPans {
    NSHashTable *suppressed = objc_getAssociatedObject(self, kObackSuppressedPansKey);
    if (!suppressed || suppressed.count == 0) return;
    NSHashTable *excl = objc_getAssociatedObject(self, kObackExclusiveDisabledPansKey);
    NSUInteger n = 0, kept = 0;
    for (UIGestureRecognizer *g in suppressed) {
        if (!g) continue;
        // [R7 方案A] 常驻压制集合内的手势**不恢复**：否则一次边缘滑动结束就把中屏返回手势放回去，
        // 中屏瞬闪立刻复现（方案A 等于白做）。它只在开关关闭时由 _obReconcile… 统一还原。
        if (excl && [excl containsObject:g]) { kept++; continue; }
        g.enabled = YES;   // 弱引用表已自动剔除 dealloc 的 pan，此处 g 必存活（view 已脱离也照常恢复，避免残留禁用）
        n++;
    }
    [suppressed removeAllObjects];
    OBLog(@"[独占] 已恢复 %lu 个对手手势（%lu 个仍常驻压制）", (unsigned long)n, (unsigned long)kept);
}

// ⚠️ 历史坑：不能立即恢复 —— 对手 pan 同步收到过同一串 touch，一恢复就会基于已收到的位移瞬间判定返回 → 瞬闪。
// 故延后 0.12s，且执行时确认 Oback 没有再次接管（interacting==NO）才恢复。
- (void)_restoreOpponentPansDeferred {
    NSHashTable *suppressed = objc_getAssociatedObject(self, kObackSuppressedPansKey);
    if (!suppressed || suppressed.count == 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.interacting) return;   // Oback 又接管了（新一次滑动）：保持压制，由该次手势的 end/abort 再排恢复
        [self _restoreOpponentPans];
    });
}

#pragma mark - [R7 方案A] 独占常驻压制（治「中屏任意处轻滑即非交互瞬返」）

// [R7 方案A 2026-09-18] 方案A 的**打击面 = 右滑返回类对手手势**。刻意不用 _isPopLikeOpponentPan ②(nav 树)：
// ② 会把快速回复（NTAIOQuickReply）、滑动删除（_UISwipeActionPan）、页面内浮层一并纳入 —— 那正是历史 B 方案
// 「抑制过广 → 误伤 overlay（元宝浮耳滑不出 / 引用左滑失效）」的老路，T4 正因此删掉整套（-813 行）。
- (BOOL)_isSwipeRightPopOpponentPan:(UIPanGestureRecognizer *)g {
    if (!g) return NO;
    if (g.delegate == self) return NO;                                         // 自己的 pan：绝不碰
    if ([g isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) return NO; // 屏幕边缘手势：不碰（防成环 / 不碰系统 ipg）
    if ([self _isNavInteractivePop:g]) return NO;                              // nav 系统 ipg：Oback 已永久禁用，不碰
    NSString *gcls = NSStringFromClass([g class]);
    if (!gcls) return NO;
    // QQ 私有右滑返回 RightDragPanGestureRecognizer 是本次日志实证的凶手；其余为同类返回语义兜底。
    NSArray *popWords = @[@"RightDrag", @"PushPop", @"SlideBack", @"SwipeBack", @"PopGesture", @"BackGesture", @"PanPop"];
    for (NSString *w in popWords) {
        if ([gcls rangeOfString:w options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

// [R7 方案A 2026-09-18] 「独占常驻压制」：exclusivePop 开启期间，持久禁用窗口内「右滑返回」类对手手势，
// 使**中屏任意处**轻滑不再触发 App 自有的非交互 pop（= 用户报的「全屏瞬闪」），返回只走 Oback 跟手的左缘。
//
// 为什么中屏必须来这一刀（日志8 实证）：中屏触摸（x∈[116,299]）不触发 Oback 左缘 pan（门限 x<triggerWidth），
// R6 给 RightDrag 加的 requireToFail 在中屏会**立即解除** ⇒ 它自由触发 QQ 非交互 pop
// （nav-anim query op=2 interacting=0，且该触摸无任何 shouldBegin=YES）⇒ 全屏瞬闪。
//
// 与 _suppressOpponentPansForPan:（接管期压制）的分工：后者只在边缘接管时做、end/abort 后 0.12s 恢复（治「左缘抢跑」）；
// 本压制与触摸无关、常驻，只在**开关关闭**时统一还原（治「中屏 QQ 自己 pop」）。
//
// 安全边界（逐条对应历史副作用，勿删）：
//   ① 与 A' 同开关 exclusivePop（默认关）⇒ 不开开关者左缘/中屏行为一字不改；
//   ② 打击面 = _isSwipeRightPopOpponentPan（**仅类名精确命中返回语义**）⇒ 快速回复/滑动删除/滚动/文本选择一律不碰；
//   ③ 屏幕边缘手势 / 系统 ipg 不碰（防成环；不做历史 B 那套「必须同时禁 ipg」）；
//   ④ 弱引用集合 ⇒ pan 释放自动出表，无野指针（历史 EXC_BAD_ACCESS 坑）；开关关闭时统一还原（可撤销）；
//   ⑤ 后台早退 + 走带 kOBEnumMaxNodes 预算的 _enumeratePansInView。
- (void)_obReconcileExclusivePersistentSuppress:(UIWindow *)win {
    NSHashTable *excl = [self _exclusiveDisabledPanTable];
    // 开关关闭：把上次常驻禁用的全部还原（T4 删除历史 B 的理由之一正是「不可撤销」，本方案刻意保留可撤销性）
    // ⚠️ [R8] 本分支必须留在 `if (!win) return;` **之前**：还原不依赖窗口；若因 win=nil 提前返回，
    //    关开关后会残留永久禁用的对手手势（不可撤销 ⇒ 正是 T4 删历史 B 的理由）。潜在缺陷，一并修掉。
    if (![ObackPreferences exclusivePopEnabled]) {
        if (excl.count > 0) {
            NSUInteger n = excl.count;
            for (UIGestureRecognizer *g in excl) { if (g) g.enabled = YES; }
            [excl removeAllObjects];
            OBLog(@"[独占] 常驻压制：开关已关，还原 %lu 个对手手势", (unsigned long)n);
        }
        return;
    }
    if (!win) return;
    if (_inBackground) return;   // watchdog：后台不遍历（同 _linkNavPopGesturesInWindow）
    NSArray *wins = nil;
    @try { wins = [self _allVisibleWindows]; } @catch (NSException *e) { wins = nil; }
    if (wins.count == 0) wins = [NSArray arrayWithObject:win];
    __block NSUInteger added = 0;
    // [R8 可观测性] 扫描数/命中数是判定「对账到底跑没跑、跑的时候命中几个」的唯一证据。
    // 日志9 的残留瞬返卡在三种可能（对账没跑 / 跑了但实例当时还没建 / 实例被 QQ 重新 enabled），
    // 而旧实现只在 added>0 时留痕 ⇒ 三种情况日志长得一模一样、无法区分。以下计数把它们彻底分开。
    __block NSUInteger scanned = 0;
    __block NSUInteger hits = 0;
    for (UIWindow *w in wins) {
        if (!w) continue;
        [self _enumeratePansInView:w depth:0 block:^(UIPanGestureRecognizer *g){
            scanned++;
            if (![self _isSwipeRightPopOpponentPan:g]) return;
            hits++;
            BOOL known = [excl containsObject:g];
            if (g.enabled) g.enabled = NO;
            if (!known) {
                [excl addObject:g];
                added++;
                OBLog(@"[独占] 常驻禁用右滑返回手势 %@ (view=%@ window=%@)",
                      NSStringFromClass([g class]), NSStringFromClass([g.view class]), NSStringFromClass([w class]));
            }
        }];
    }
    if (added > 0) OBLog(@"[独占] 本轮常驻压制新增 %lu 个（累计 %lu）", (unsigned long)added, (unsigned long)excl.count);
    // [R8] 每次对账都留痕（≤1s 节流，防边缘起滑高频触发刷屏）。三态读法：
    //   有本行且「命中 0 / 常驻集 >0」 ⇒ 新页面重造了实例（旧实例随页面释放，弱表已自动出表）；
    //   有本行且「命中 N / 本轮新增 0」 ⇒ 实例已在集内但被 QQ 重新 enabled（本行前刚被压回 NO）；
    //   完全没有本行                ⇒ 对账根本没跑（调用点缺失）—— 这正是 R8 要区分的那三态。
    static NSTimeInterval __lastExclReconcileTS = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - __lastExclReconcileTS >= 1.0) {
        __lastExclReconcileTS = now;
        OBLog(@"[独占] 对账：扫描 pan %lu / 命中右滑返回类 %lu / 本轮新增 %lu / 常驻集 %lu",
              (unsigned long)scanned, (unsigned long)hits, (unsigned long)added, (unsigned long)excl.count);
    }
}

// [R8 覆盖] push 时对账：新页面的对手手势（QQ 逐页新建 RightDragPan）是在 push 时/后才挂上的。
// 日志9 实证：push 03:51:50 -> pop 03:51:51 仅隔 1s，期间常驻对账一次都没跑（旧实现对账只在启动链接
// 与边缘懒补链[2s 节流]时触发）=> 群聊页那个 RightDrag 实例从未被收编 => 非交互瞬返仍出现 1 次。
// 故：push 转场开始即对账一次（抓已存在的实例），再延后 0.35s 补一次（抓转场中/后才懒建的实例）。
- (void)_obReconcileExclusivePersistentSuppressForNav:(UINavigationController *)nav {
    UIWindow *win = nil;
    @try { win = nav.view.window; } @catch (NSException *e) { win = nil; }
    if (!win) {
        @try { NSArray *w = [self _allVisibleWindows]; win = w.count ? w.firstObject : nil; } @catch (NSException *e) { win = nil; }
    }
    [self _obReconcileExclusivePersistentSuppress:win];
    if (![ObackPreferences exclusivePopEnabled]) return;   // 关开关：上面那次调用已负责还原，无需延后补扫
    // 延后补扫（幂等；节流日志会体现本次补扫是否真抓到新实例）
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_obReconcileExclusiveSuppressDeferred) object:nil];
    [self performSelector:@selector(_obReconcileExclusiveSuppressDeferred) withObject:nil afterDelay:0.35];
}

// [R8] push 后的延后补扫：刻意不持有 nav（避免强引用已 pop 的控制器），只按当前可见 window 重扫一次。
- (void)_obReconcileExclusiveSuppressDeferred {
    UIWindow *win = nil;
    @try { NSArray *w = [self _allVisibleWindows]; win = w.count ? w.firstObject : nil; } @catch (NSException *e) { win = nil; }
    if (!win) { @try { win = [self currentKeyWindow]; } @catch (NSException *e) { win = nil; } }
    [self _obReconcileExclusivePersistentSuppress:win];
}

// [R8 自愈] 把「已经赢了我们的」漏网 pop 凶手即时并入常驻集并禁用 —— 即便对账漏掉某个新实例，
// 也只可能漏一次：pop 发生的那一刻就把它收编，此后同一实例永久失效。
// 返回 YES = 本次真新增压制（调用方据此决定是否额外留痕）。
- (BOOL)_obAdoptExclusiveSuppressForPan:(UIPanGestureRecognizer *)g reason:(NSString *)reason {
    if (!g) return NO;
    if (![ObackPreferences exclusivePopEnabled]) return NO;   // 与常驻压制同开关：关开关者行为一字不改
    if (![self _isSwipeRightPopOpponentPan:g]) return NO;      // 只收编打击面内（返回语义）的对手，不扩大打击面
    NSHashTable *excl = [self _exclusiveDisabledPanTable];
    if ([excl containsObject:g]) {
        if (g.enabled) g.enabled = NO;    // 已知实例被 QQ 重新 enabled：重新压回去（不重复计数）
        return NO;
    }
    g.enabled = NO;
    [excl addObject:g];
    OBLog(@"[独占] 自愈：漏网 pop 凶手 %@ 已即时压制并收编（常驻集 %lu，%@）",
          NSStringFromClass([g class]), (unsigned long)excl.count, reason ? reason : @"-");
    return YES;
}

// [R7 诊断 2026-09-18] 每次「非 Oback 驱动的 nav pop」发生时，抓出当时**已不在 Possible** 的手势
// = 真正发起 pop 的凶手。用途：验证方案A 打击面是否命中真凶（RightDragPan）；若仍冒出别的类名 = 漏网第二凶手。
// ⚠️ 由 Tweak.xm 在 op=2(Pop) 且 interacting=0 时调用；带 build tag（防「没装对版本」被误读为「诊断为空」）。
// [R7 诊断 / R8 升级] 每次「非 Oback 驱动的 nav pop」发生时，抓出当时**已不在 Possible** 的手势
// = 真正发起 pop 的凶手；R8 起**当场自愈**：把命中打击面的漏网凶手收编进常驻集并禁用。
// 用途：验证方案A 打击面是否命中真凶（RightDragPan）；若仍冒出别的类名 = 漏网第二凶手（下一次即被自愈收编）。
// ⚠️ 由 Tweak.xm 在 op=2(Pop) 且 interacting=0 时调用；带 build tag（防「没装对版本」被误读为「诊断为空」）。
// ⚠️ 遍历开销大，故门控分开：自愈只受 exclusivePop（要治漏网，不能依赖调试日志）；凶手清单打印只受 debugLog；
//    两者都关时直接 return（零开销）。
- (void)_obDiagLogPopFirerForNav:(UINavigationController *)nav {
    if (!nav) return;
    BOOL wantLog  = [ObackPreferences debugLogEnabledLive];
    BOOL wantHeal = [ObackPreferences exclusivePopEnabled];
    if (!wantLog && !wantHeal) return;
    UIWindow *win = nil;
    @try { win = nav.view.window; } @catch (NSException *e) { win = nil; }
    if (!win) return;
    NSMutableArray *hits = [NSMutableArray array];
    NSMutableArray *adopt = [NSMutableArray array];   // 先收集，枚举结束后再改状态（不在遍历中动手势图）
    NSUInteger budget = kOBEnumMaxNodes;
    [self _enumerateGestureViewsIn:win depth:0
                         predicate:^BOOL(UIView *v, UIGestureRecognizer *g){
                             UIGestureRecognizerState s = g.state;
                             return (s == UIGestureRecognizerStateBegan
                                     || s == UIGestureRecognizerStateChanged
                                     || s == UIGestureRecognizerStateEnded);
                         }
                              emit:^(UIGestureRecognizer *g){
        if (wantLog) {
            [hits addObject:[NSString stringWithFormat:@"%@@%@(state=%ld%@)",
                             NSStringFromClass([g class]),
                             g.view ? NSStringFromClass([g.view class]) : @"nil",
                             (long)g.state,
                             (g.delegate == self ? @",ours" : @"")]];
        }
        if (wantHeal && g.enabled && [g isKindOfClass:[UIPanGestureRecognizer class]]) {
            if ([self _isSwipeRightPopOpponentPan:(UIPanGestureRecognizer *)g])
                [adopt addObject:(UIPanGestureRecognizer *)g];
        }
    } budget:&budget];
    for (UIPanGestureRecognizer *p in adopt) {
        [self _obAdoptExclusiveSuppressForPan:p reason:@"pop 现场自愈"];
    }
    if (wantLog) {
        OBDIAG(@"[pop-firer@%@] Oback 未驱动的 pop 发起者候选(%lu): %@",
               OBACK_BUILD_TAG, (unsigned long)hits.count, hits);
    }
}


#pragma mark - 方案 A：驱动系统原生 nav pop

// 取系统 interactivePopGestureRecognizer 的私有 target（_UINavigationInteractiveTransition 实例）。
// 该 target 的 action handleNavigationTransition: 即系统原生交互 pop 的入口。
- (id)navPopSystemTargetForNav:(UINavigationController *)nav {
    @try {
        id ipg = nav.interactivePopGestureRecognizer;
        NSArray *targets = [ipg valueForKey:@"_targets"];
        id targetObj = targets.firstObject;
        id t = [targetObj valueForKey:@"target"];
        // [诊断 2026-08-04] 取不到系统 target 时细分打印 nav/ipg 状态，定位为何无法跟手：
        //  - ipg=nil                                → nav 压根没交互 pop（自研容器）
        //  - ipg 存在但 enabled=0                    → 仅被禁（可尝试重新 enabled 后喂系统转场）
        //  - ipg 存在 enabled=1 但 targets=0         → target 被剥（自研返回手势换掉系统转场，必须走自定义转场）
        // 仅对"非微信类"的未知非标准 nav 打印，避免微信等已知项刷屏。
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        BOOL knownCustom = (bid && [bid caseInsensitiveCompare:@"com.tencent.xin"] == NSOrderedSame)
                        || (nav && [NSStringFromClass([nav class]) hasPrefix:@"MMUI"]);
        if (!t && !knownCustom) {
            OBDIAG(@"[diag-navTarget] nil | bid=%@ nav=%@ ipg=%@ enabled=%d targets.count=%lu delegate=%@",
                  bid, NSStringFromClass([nav class]), ipg,
                  (ipg ? (int)((UIGestureRecognizer *)ipg).enabled : -1),
                  (unsigned long)(targets ? targets.count : 0),
                  (ipg ? [(UIGestureRecognizer *)ipg delegate] : nil));
        }
        return t;
    } @catch (NSException *e) {
        OBLog(@"navPopSystemTarget fail: %@ (nav=%@)", e, NSStringFromClass([nav class]));
        return nil;
    }
}

// 在手势 Began(位移=0)启动系统原生交互 pop：把 window pan 作为 sender 喂给 handleNavigationTransition:。
// 等价于 FDFullscreenPopGesture 把自定义 pan 的 target 设为系统 target、action 设为
// handleNavigationTransition: —— 系统原生交互转场运行，toView 由 UIKit 原生呈现与清理，
// 彻底消除"自定义转场 reparent toView 进 containerView"导致的底部空白 / 导航栏损坏 / scrollView 错位。
- (void)driveSystemNavPopBeginWithPan:(UIPanGestureRecognizer *)pan window:(UIWindow *)win {
    // nav 类 pan 直接读所属 nav（swizzle 已绑定），绕过 topMost 枚举——朋友圈等自定义容器不在标准链上
    UINavigationController *nav = nil;
    if ([objc_getAssociatedObject(pan, kPanKindKey) isEqualToString:@"nav"]) {
        nav = [self _popNavForPan:pan];
    }
    if (!nav) {
        UIViewController *top = [self topMost:win.rootViewController];
        nav = top.navigationController;
        if (!nav && [top isKindOfClass:[UINavigationController class]]) nav = (UINavigationController *)top;
    }
    if (!nav) { OBLog(@"navPop: 无 nav，放弃"); return; }
    // 兜底确保 ObackNavDelegate 就位（delegate:nil 时自动包装；已是 ObackNavDelegate 则幂等）
    [nav setDelegate:nav.delegate];

    // [判定是否驱动方案A] 已知不配合系统交互转场的自定义nav(微信等)或取不到系统target，
    // 绝不调用 handleNavigationTransition:（否则会自污染 isInteractive 信号，且微信有 machinery 却不渲染
    // 导致转场不可见）。直接走非交互 popViewControllerAnimated:，方向正确、永不失效（代价不跟手）。
    if (![self _navPopShouldDriveSystemNav:nav]) {
        OBLog(@"navPop: 判定为非标准nav(自定义/已知不配合), 首次横拖时非交互 pop (nav=%@, bid=%@)",
              NSStringFromClass([nav class]), [[NSBundle mainBundle] bundleIdentifier]);
        _navPopTarget = nil;
        _navPopProbeFailed = YES;     // 标记非交互路径：update 首次横拖才 pop(同右缘节奏)，
                                      // 避免 Began 即 pop 撕裂视图层级使手势收不到终态→胶囊残留。
                                      // 此处不 pop / 不置 interacting=NO / 不置 _transitionTriggered，
                                      // 让手势走完整生命周期，由 endTransition 可靠收胶囊(见 rightSimplePop 同机制)。
        return;
    }

    _navPopTarget = [self navPopSystemTargetForNav:nav];
    if (!_navPopTarget) {
        // 极端兜底：取不到系统 target，降级为非交互 popViewControllerAnimated
        OBLog(@"navPop: 取不到系统 target，降级为非交互 popViewControllerAnimated");
        _navPopProbeFailed = YES;
        [nav popViewControllerAnimated:YES];
        self.interacting = NO;
        _transitionTriggered = YES;
        return;
    }
    // 系统原生 interactivePopGestureRecognizer 保持 disabled（避免它自己触发 double），
    // 直接把我们的 pan 作为 sender 喂给它的私有 action。
    _navPopProbeFailed = NO;   // 每次左缘 begin 重置探测标记
    _navPopProbed = NO;        // 探测门控同步重置（独立于 _transitionTriggered，避免上次手势残留）
    [self _callSystemNavPop:pan];
    _transitionTriggered = YES;
    [self _scheduleNavPopWatchdog:nav];   // 安全看门狗：防个别 App(如 Filza) 系统交互转场卡死冻结
    OBLog(@"navPop: 系统原生交互 pop 已启动 (target=%@)", NSStringFromClass([_navPopTarget class]));
}

// 判定左缘 nav pop 是否走方案A(驱动系统 handleNavigationTransition: 跟手)。
// 返回 NO 的情形：
//  1) 当前 App 命中"已知不配合系统交互转场的自定义nav"——典型为微信(com.tencent.xin)：
//     其 nav 拥有完整的系统 interactivePop machinery(target 存在)但故意不渲染交互转场，
//     纯结构探测(isInteractive)会被其自污染，必须用 bundle id / 类名精确命中；
//  2) 取不到系统 interactivePop 私有 target(无 machinery 的 App)。
// 其余标准 nav 返回 YES。
- (BOOL)_navPopShouldDriveSystemNav:(UINavigationController *)nav {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (bid && [bid caseInsensitiveCompare:@"com.tencent.xin"] == NSOrderedSame) return NO; // 微信：有machinery但不渲染
    // 类名兜底（防 bundle id 读取异常 / 微信变体）
    NSString *navCls = NSStringFromClass([nav class]);
    if (navCls && [navCls hasPrefix:@"MMUI"]) return NO; // 微信系自定义 nav
    // 用户自选「无动画修复程序」：系统交互转场不渲染/无动画的自定义 nav（如酷安），
    // 强制走 rightSimplePop 非交互标准滑出返回（有动画、不跟手），避免方案A 空转瞬切无动画。
    // 设置页「选无动画修复程序」按 App 勾选写入 navPopFallbackApps；仅命中 App 受影响，其他 App 零变化。
    if ([ObackPreferences isNavPopFallback]) return NO;
    // 标准 nav：必须有可用的系统交互转场 target
    id t = [self navPopSystemTargetForNav:nav];
    return (t != nil);
}

// 把 window pan 作为 sender 喂给系统私有 action handleNavigationTransition:。
// Began→开始原生交互转场；Changed→scrub 进度；Ended/Cancelled→系统完成/取消。
- (void)_callSystemNavPop:(UIPanGestureRecognizer *)pan {
    if (!_navPopTarget) return;
    SEL sel = NSSelectorFromString(@"handleNavigationTransition:");
    if (![_navPopTarget respondsToSelector:sel]) return;
    [_navPopTarget performSelector:sel withObject:pan];
}

#pragma mark - 边缘方向胶囊

// 胶囊初始停靠位置：贴住触发边缘、垂直对齐手势起点
- (CGPoint)indicatorHomeCenterForEdge:(ObackEdge)edge basePoint:(CGPoint)loc window:(UIWindow *)win {
    CGFloat halfW = 28.0;      // 胶囊包围盒半宽
    CGFloat inset = 8.0;       // 露出屏幕边缘外的部分（贴边感）
    if ([ObackPreferences capsuleEffect] == ObackCapsuleEffectSlime) {
        // 液体包围盒更宽，且液体【贴边侧必须完全压屏幕边】（不像胶囊那样留 inset 微凸）：
        // halfW - inset 就是中心的 x，令其等于 halfW（即 inset=0）→ 液体平直的那一侧正好落在屏幕边线上，
        // 多出的差量 0 让「底部贴屏幕边缘」在几何上成立（inset>0 会让液体整体向屏内缩、露出缝隙）。
        halfW = kSlimeFrameW * 0.5;
        inset = 0.0;
    }
    CGFloat x = (edge == ObackEdgeLeft) ? (halfW - inset)
                                        : (win.bounds.size.width - halfW + inset);
    return CGPointMake(x, loc.y);   // y 跟随起手点 → 纵向跟手
}

- (void)showIndicatorWithEdge:(ObackEdge)edge atPoint:(CGPoint)loc inWindow:(UIWindow *)win {
    // 强制清理残留胶囊（上次手势 Failed/异常退出时可能未消除，或上一次 dismiss 动画还在跑）
    if (_indicator) {
        [_indicator.layer removeAllAnimations];   // 杀掉进行中的淡出/弹回动画
        [_indicator removeFromSuperview];
        _indicator = nil;
        [self _stopIndicatorLink];   // 停掉上一轮的平滑插值（showIndicator 之后会重建）
    }
    ObackEdgeIndicator *ind = [[[ObackEdgeIndicator alloc] initWithEdge:edge] autorelease];
    ind.center = [self indicatorHomeCenterForEdge:edge basePoint:loc window:win];
    ind.alpha = 0.0;
    // 液体：起手就是贴着屏幕边的一线薄液体，靠 setSlimeProgress: 随手指「长」出来 → 不再做 0.85 预压
    BOOL slime = [ind isSlime];
    ind.transform = slime ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.85, 0.85);
    [win addSubview:ind];
    [win bringSubviewToFront:ind];
    _indicator = ind;
    _flowSpeed = 1.0; _flowTargetSpeed = 1.0;   // 流光跟手：每轮手势从正常流速(1.0)起
    // 启动胶囊平滑插值（CADisplayLink 每帧驱动；手势结束在 dismissIndicator* 停掉，仅手势中跑，功耗可忽略）
    if (!_indicatorLink) {
        _indicatorLink = [[CADisplayLink displayLinkWithTarget:self
                                                      selector:@selector(_obIndicatorTick:)] retain];
        [_indicatorLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
    _indicatorTarget = ind.center;
    _indicatorTargetScale = slime ? 1.0 : 0.85;  // 液滴不做等比缩放（形变由 setSlimeProgress: 负责）
    _indicatorProgress = 0.0;                    // 液滴：从贴边一线起步
    _indicatorTargetProgress = 0.0;
    _slimeFlowBias = 0.0;                        // 液滴：垂直流动从「对称」起手
    _slimeFlowBiasTarget = 0.0;
    OBLog(@"indicator shown (edge=%@ y=%.0f)", edge == ObackEdgeLeft ? @"左" : @"右", loc.y);
    [UIView animateWithDuration:0.15 delay:0 options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ ind.alpha = 0.9; } completion:nil];
    // 安全兜底：若手势始终未进入 Began（左边缘被系统原生返回手势抢走），0.4s 后自动收起胶囊，避免残留
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(dismissIndicatorSafety) object:nil];
    [self performSelector:@selector(dismissIndicatorSafety) withObject:nil afterDelay:0.4];
}

// 安全兜底收起：仅当手势从未真正开始（interacting=NO）时才收起，正常生命周期由 endTransition/abortTransition 处理
- (void)dismissIndicatorSafety {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(dismissIndicatorSafety) object:nil];
    if (self.interacting) return;          // 已正常开始，交给生命周期处理
    if (!_indicator) return;
    UIWindow *win = (UIWindow *)_indicator.window;   // 用胶囊实际所在的 window，避免多窗口坐标错乱
    if (!win) { [_indicator removeFromSuperview]; _indicator = nil; return; }
    [self dismissIndicatorCommitted:NO params:[ObackPreferences params] window:win];
}

- (void)updateIndicatorWithPan:(UIPanGestureRecognizer *)pan window:(UIWindow *)win {
    if (!_indicator) return;
    CGFloat fingerX = [pan locationInView:win].x;
    CGFloat dx = fingerX - _indicatorStartX;
    CGFloat dir = (self.currentEdge == ObackEdgeLeft) ? 1.0 : -1.0;
    CGFloat maxTravel = [(ObackEdgeIndicator *)_indicator isSlime] ? kSlimeMaxTravel : kIndicatorMaxTravel;
    // 跟随手指；液滴的 maxTravel = 0 → travel 恒为 0 ⇒ 形状**钉在屏幕边缘不动**，
    // 跟手感完全由下方 setSlimeProgress: 的「从边缘长出来」表达（见 kSlimeMaxTravel 注释）。
    CGFloat travel = MIN(fabs(dx), maxTravel) * dir;
    CGPoint home = [self indicatorHomeCenterForEdge:self.currentEdge basePoint:_indicatorAnchor window:win];
    // 仅更新目标位置/缩放，真正位移由 CADisplayLink(_obIndicatorTick:) 每帧插值 → 平滑不抖
    _indicatorTarget = CGPointMake(home.x + travel, home.y);
    if ([(ObackEdgeIndicator *)_indicator isSlime]) {
        _indicatorTargetScale = 1.0;   // 液体不做等比缩放
        // 液体用「路径形变」表达进度：0=贴边一线 → 1=完全拉出的饱满液滴。
        // 0.45 归一：拉到约一半行程就基本饱满，之后维持。
        // ⚠️ 只写 target，实际形变在 _obIndicatorTick: 里与位置同一系数插值，
        //    否则「位置滞后、形状先到」会在快滑时脱节。
        _indicatorTargetProgress = MIN(1.0, _currentPercent / 0.45);
        // 手指垂直速度 → 垂直流动偏置（向上为 +1）。用户要求：手指向上 → 深色液体也向上跑 → 上大下小。
        // 速度是瞬时量、会抖，故先做一次低通（0.6/0.4），再由 tick 做第二级插值 → 两级平滑足够顺。
        // 手指停住/松手时速度归零 ⇒ bias 自动缓回 0 ⇒ 液体回到对称（不做自走波纹）。
        CGFloat vy = [pan velocityInView:win].y;                  // UIKit：y 向下为正
        CGFloat biasRaw = MAX(-1.0, MIN(1.0, -vy / kSlimeFlowRefV));  // 手指向上 ⇒ vy<0 ⇒ biasRaw>0
        _slimeFlowBiasTarget = _slimeFlowBiasTarget * 0.6 + biasRaw * 0.4;
    } else {
        _indicatorTargetScale = 0.85 + 0.15 * MIN(1.0, _currentPercent / 0.3);
    }
    _indicator.alpha = 0.9;
    // [2026-08-01 流光跟手] 手指横向速度 → 流光目标速度：快滑更 energetic、慢拖更 calm
    CGFloat vx = [pan velocityInView:win].x;
    _flowTargetSpeed = MAX(0.8, MIN(3.0, 0.8 + fabs(vx) / 1500.0 * 2.2));
    // 不再每帧 [win bringSubviewToFront:]（O(n) 主窗口子视图重排）；仅在 showIndicator 时置顶一次
}

// 液滴缩放时的「支点」修正：把 center 换算成「贴边侧始终停在屏幕边线上」的位置。
// 直接 CGAffineTransformMakeScale 是围绕 center 缩放 → 贴边侧也会跟着缩，露出缝隙；
// 令 center.x = halfW*s（左缘）/ W - halfW*s（右缘），则缩放后贴边侧依旧压在边线上。
- (CGPoint)_slimeEdgeAnchoredCenterForScale:(CGFloat)s y:(CGFloat)y window:(UIWindow *)win edge:(ObackEdge)edge {
    CGFloat halfW = kSlimeFrameW * 0.5;
    CGFloat cx = (edge == ObackEdgeLeft) ? (halfW * s)
                                         : (win.bounds.size.width - halfW * s);
    return CGPointMake(cx, y);
}

- (void)dismissIndicatorCommitted:(BOOL)committed params:(ObackParams *)p window:(UIWindow *)win {
    UIView *ind = _indicator;
    _indicator = nil;
    _flowSpeed = 1.0; _flowTargetSpeed = 1.0;   // 流光跟手：复位，下一轮手势干净起步
    [self _stopIndicatorLink];   // 手势结束：停平滑插值，胶囊交给 UIView 动画淡出/弹回
    [(ObackEdgeIndicator *)ind stopEffectAnimations];   // 停渐变等循环动画，避免与下方淡出动画冲突
    if (!ind) return;
    BOOL slime = [(ObackEdgeIndicator *)ind isSlime];
    if (committed) {
        // 提交返回：放大淡出（液体本身已很大，放大幅度收敛，避免糊成一片白）
        CGFloat endScale = slime ? 1.12 : 1.35;
        // 液滴：放大也要以屏幕边缘为支点，贴边侧始终留在边线上（居中放大会往屏内缩出一条缝）
        CGPoint target = slime ? [self _slimeEdgeAnchoredCenterForScale:endScale
                                                                      y:ind.center.y
                                                                 window:win
                                                                   edge:self.currentEdge]
                               : ind.center;
        [UIView animateWithDuration:MAX(0.18, p.duration * 0.6) delay:0
                             options:UIViewAnimationOptionCurveEaseIn
                          animations:^{
            ind.alpha = 0.0;
            ind.center = target;
            ind.transform = CGAffineTransformMakeScale(endScale, endScale);
        } completion:^(BOOL f) { [ind removeFromSuperview]; }];
    } else {
        // 取消：弹回边缘并缩小消失
        CGFloat backScale = slime ? 0.72 : 0.6;
        CGPoint home = [self indicatorHomeCenterForEdge:self.currentEdge
                                              basePoint:_indicatorAnchor window:win];
        // 液滴：缩小同样以屏幕边缘为支点（否则「弹回边缘」的过程反而是从边缘缩开）
        CGPoint target = slime ? [self _slimeEdgeAnchoredCenterForScale:backScale
                                                                      y:home.y
                                                                 window:win
                                                                   edge:self.currentEdge]
                               : home;
        [UIView animateWithDuration:MAX(0.22, p.duration * 0.7) delay:0
                             options:UIViewAnimationOptionCurveEaseOut
                          animations:^{
            ind.center = target;
            ind.alpha = 0.0;
            ind.transform = CGAffineTransformMakeScale(backScale, backScale);
        } completion:^(BOOL f) { [ind removeFromSuperview]; }];
    }
}

#pragma mark - 胶囊平滑（CADisplayLink 每帧插值）

- (void)_obIndicatorTick:(CADisplayLink *)link {
    if (!_indicator) { [self _stopIndicatorLink]; return; }
    // 每帧向目标位置/缩放靠近 35%，快速滑动时平滑跟随、消除抖动
    static const CGFloat k = 0.35;
    CGPoint c = _indicator.center;
    c.x += (_indicatorTarget.x - c.x) * k;
    c.y += (_indicatorTarget.y - c.y) * k;
    _indicator.center = c;
    CGFloat targetScale = _indicatorTargetScale;
    CGFloat targetAlpha = 0.9;
    if ([(ObackEdgeIndicator *)_indicator isBreathing]) {
        double t = CACurrentMediaTime();
        double s = sin(t * 4.0);                  // ≈1.57s 周期
        targetScale *= (1.0 + 0.05 * s);         // 缩放 ±5% 脉冲
        targetAlpha = 0.9 + 0.08 * s;            // 透明度 ±0.08 脉冲
    }
    // [2026-08-01 流光跟手] 向目标流速平滑靠近；无新速度输入（手指暂停）时缓回 calm(1.0)。仅渐变特效生效。
    _flowTargetSpeed += (1.0 - _flowTargetSpeed) * 0.05;
    _flowSpeed += (_flowTargetSpeed - _flowSpeed) * 0.15;
    [(ObackEdgeIndicator *)_indicator setFlowSpeed:_flowSpeed];
    CGFloat sc = _indicator.transform.a;          // 当前 x 缩放（transform 仅等比缩放）
    sc += (targetScale - sc) * k;
    _indicator.transform = CGAffineTransformMakeScale(sc, sc);
    _indicator.alpha = targetAlpha;
    // 液滴：与位置同一系数插值到目标鼓出进度 + 目标垂直流动偏置。
    // 「静止时完全静止」仍是铁律：**只要 bias 已归零且没在动，就不重建路径**（省掉每帧 64 点构造）。
    // 也刻意不解锁任何自走的相位波（早期版本那样做会被用户否掉）。
    if ([(ObackEdgeIndicator *)_indicator isSlime]) {
        CGFloat dp = _indicatorTargetProgress - _indicatorProgress;
        CGFloat db = _slimeFlowBiasTarget - _slimeFlowBias;
        // 需要重建的三种情形：进度在变 / bias 在变 / bias 尚未归零（还得继续往 0 收）
        BOOL moving = (fabs(dp) > 0.002) || (fabs(db) > 0.002) || (fabs(_slimeFlowBias) > 0.002);
        if (moving) {
            _indicatorProgress += dp * k;
            // 流动偏置用略小的系数：比位置/进度稍「黏」一点，液体推起来更有重量感
            _slimeFlowBias += db * (k * 0.7);
            [(ObackEdgeIndicator *)_indicator setSlimeFlowBias:_slimeFlowBias];
            [(ObackEdgeIndicator *)_indicator setSlimeProgress:_indicatorProgress];
        }
    }
}

- (void)_stopIndicatorLink {
    if (_indicatorLink) {
        [_indicatorLink invalidate];
        [_indicatorLink release];
        _indicatorLink = nil;
    }
}

#pragma mark - 辅助

// [P3] 集中所有「枚举可见 window」逻辑：iOS13+ 走 connectedScenes，否则/为空时回退弃用旧 API。
// 原 5 处重复枚举合并于此，改一处全局生效（含 iOS<13 与 connectedScenes 为空两层兜底）。
- (NSArray<UIWindow *> *)_allVisibleWindows {
    NSMutableArray<UIWindow *> *arr = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                [arr addObjectsFromArray:((UIWindowScene *)scene).windows];
            }
        }
    }
    if (arr.count == 0) {
        // 兜底：connectedScenes 为空(旧系统/异常)或 iOS<13，退回弃用旧 API
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [arr addObjectsFromArray:[[UIApplication sharedApplication] windows]];
        #pragma clang diagnostic pop
    }
    return arr;
}

// iOS 13+ 多场景后 keyWindow 已废弃，需遍历 connectedScenes 取前台活跃窗口
- (UIWindow *)currentKeyWindow {
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) { window = w; break; }
            }
            if (window) break;
            // 启动早期 scene 未激活时，退而取该场景任意 window
            if (!window && ws.windows.firstObject) window = ws.windows.firstObject;
        }
    }
    return window;
}

// 找到当前最上层的可见 VC（处理 present / nav / tab）
- (UIViewController *)topMost:(UIViewController *)vc {
    return [self topMost:vc depth:0];
}

- (UIViewController *)topMost:(UIViewController *)vc depth:(NSUInteger)depth {
    if (!vc) return nil;
    if (depth > 20) return vc;   // 深度护栏：防御被其他 tweak 改坏的异常 VC 层级（含循环引用）导致无限递归爆栈
    if (vc.presentedViewController) return [self topMost:vc.presentedViewController depth:depth + 1];
    if ([vc isKindOfClass:[UINavigationController class]]) return [self topMost:[(UINavigationController *)vc topViewController] depth:depth + 1];
    if ([vc isKindOfClass:[UITabBarController class]])    return [self topMost:[(UITabBarController *)vc selectedViewController] depth:depth + 1];
    // [2026-09-17] UISplitViewController 此前完全没有处理 ⇒ 设置 App(PSSplitViewController) 的
    // window 级兜底 pan 永远解析不到 nav（日志实证：top=PSSplitViewController nav=nil）。
    // 折叠态(iPhone)取最后一个子 VC（= detail 侧的外层 UINavigationController），展开态同理取 detail。
    if ([vc isKindOfClass:[UISplitViewController class]]) {
        NSArray *sub = [(UISplitViewController *)vc viewControllers];
        UIViewController *last = [sub lastObject];
        if (last && last != vc) return [self topMost:last depth:depth + 1];
    }
    return vc;
}

// [2026-09-17 双层 nav 修复] 从 nav 起沿「外层导航链」向上找第一个真正可 pop 的 nav。
// 命中条件：viewControllers.count > 1。找不到则返回 nil（调用方按「不可返回」处理）。
// 普通 App 是单层 nav ⇒ 第一次迭代即返回自身，行为零变化；仅 nav 套 nav（设置 App / UISplitViewController
// 折叠态）才会向上跳一级。深度护栏 8 防被其他 tweak 改坏的异常层级导致死循环。
- (UINavigationController *)_poppableNavFrom:(UINavigationController *)nav {
    UINavigationController *n = nav;
    for (NSUInteger i = 0; i < 8; i++) {
        if (!n || ![n isKindOfClass:[UINavigationController class]]) return nil;
        if (n.viewControllers.count > 1) return n;
        UINavigationController *up = n.navigationController;
        if (!up && [n.parentViewController isKindOfClass:[UINavigationController class]])
            up = (UINavigationController *)n.parentViewController;
        if (!up || up == n) return nil;
        n = up;
    }
    return nil;
}

// 本次手势真正要 pop 的 nav：优先读 shouldBegin 阶段解析出的 kObackPopNavKey，
// 没有（单层 nav 的普通 App / 全局返回路径）则回退到 pan 绑定的 kObackNavKey —— 与旧行为完全一致。
- (UINavigationController *)_popNavForPan:(UIPanGestureRecognizer *)pan {
    if (!pan) return nil;
    UINavigationController *popNav = objc_getAssociatedObject(pan, kObackPopNavKey);
    if (popNav && [popNav isKindOfClass:[UINavigationController class]]) return popNav;
    return objc_getAssociatedObject(pan, kObackNavKey);
}

// 命中测试找最近的 UIScrollView（用于冲突规避）
- (UIScrollView *)scrollViewAtPoint:(CGPoint)point inView:(UIView *)view {
    if (!view) return nil;
    UIView *hit = [view hitTest:point withEvent:nil];
    while (hit) {
        if ([hit isKindOfClass:[UIScrollView class]]) return (UIScrollView *)hit;
        hit = hit.superview;
    }
    return nil;
}


// [2026-08-09 文本选择手柄修复 v3] 判定「屏幕坐标 sp 是否落在活动文本选择手柄(蓝柄)上/附近」。
// 仅在 shouldBegin 可控层使用：触摸落在手柄→Oback pan 不 begin→手柄独占拖拽。
// 为什么不用仲裁层(shouldRequireFailureOf/shouldBeRequiredToFailBy)：oback_debug(30) 实证手柄手势
// 从不进入这两个方法(UIKit 不把手柄作为 other 递给我们)→ 在仲裁层让路是死代码。shouldBegin 是我们
// 直接决定 pan 是否开始的层，不依赖 UIKit 回调，故必须在此拦截。
// sp 为屏幕坐标([pan locationInView:win] 经 convertPoint:toView:nil 得到)，与各 window 手柄的屏幕帧比对。
// 仅命中选择手柄类视图(系统私有类 _UIDragHandleGestureRecognizer 或其载体 _UIDragHandleView)，
// 不靠模糊"Handle"匹配大视图→不会误杀全局返回。命中半径 44pt 容差手指。
- (NSInteger)_touchOnActiveTextSelectionHandle:(CGPoint)sp selectionActive:(BOOL *)outActive minDist:(CGFloat *)outMinDist {
    if (outActive) *outActive = NO;
    Class dragHandleCls = _OBCls_dragHandle();
    // 收集所有候选 window（含 QQ overlay window 上的选择视图）
    NSMutableArray *wins = [NSMutableArray array];
    @try { [wins addObjectsFromArray:[self _allVisibleWindows]]; } @catch (NSException *e) { wins = nil; }
    if (!wins || wins.count == 0) return NO;
    // [diag-hit] 定位 QQ 自定义选择手柄真实类：在触摸点做跨 window hit-test（限前 50 次，避免刷屏）
    static int sHitCount = 0;
    if (sHitCount < 50) {
        sHitCount++;
        UIView *hv = nil;
        for (UIWindow *w in wins) {
            CGPoint wp = CGPointZero;
            @try { wp = [w convertPoint:sp fromView:nil]; } @catch (NSException *e) { continue; }
            UIView *h = nil;
            @try { h = [w hitTest:wp withEvent:nil]; } @catch (NSException *e) { h = nil; }
            if (h) { hv = h; break; }
        }
        if (hv) {
            NSMutableString *chain = [NSMutableString string];
            UIView *t = hv; int d = 0;
            while (t && d < 5) { [chain appendFormat:@"%@/", NSStringFromClass([t class])]; t = t.superview; d++; }
            NSMutableString *grs = [NSMutableString string];
            for (UIGestureRecognizer *g in (hv.gestureRecognizers ?: @[])) [grs appendFormat:@"%@,", NSStringFromClass([g class])];
            OBDIAG(@"[diag-hit] @(%.0f,%.0f) top=%@ chain=%@ grs=%@", sp.x, sp.y, NSStringFromClass([hv class]), chain, grs);
        }
    }
    // [2026-09-17 收紧 75→32] 几何依据：QQ 手柄球实测 rect=(57,229,18,18) ⇒ 球半径 9pt；指腹≈40pt ⇒ 半径≈20pt；
    // 留 3pt 余量 ⇒ 合理抓取半径 32pt。75 是 v12e 为「修漏判」放宽的，但漏判真因（零帧容器坐标算歪）
    // 已在同版本由 effectiveRect（取子视图/CALayer 真实帧）修掉，半径没必要再留 2 倍冗余。
    // 日志实证（文本(4).txt build qq-excl+0850112）：左缘触摸 x=23/26 距残留手柄 61/31pt 即被拦死 —— 都是半径过大的误杀。
    // ⚠️ 真正的「压在手柄上」由 hitTest 分支负责（无半径限制），故收紧 dist 兜底几乎不影响抓取。
    CGFloat hitR = 32.0;
    CGFloat screenW = 0;
    if (wins.count) { @try { screenW = ((UIWindow *)wins.firstObject).bounds.size.width; } @catch (NSException *e) {} }
    if (screenW <= 0) screenW = 390.0;  // 兜底宽度
    BOOL leftZone = (sp.x < 60.0);   // 左缘热区：失败多发的竞争区
    __block BOOL hit = NO;
    __block CGFloat hitAlpha = -1.0;      // [2026-09-17] 命中手柄的 alpha（诊断：0 = 残留未显示，误拦根因）
    __block BOOL hitWinNil = NO;          // 命中手柄 window==nil（已脱离视图树）
    __block NSString *hitCls = nil;
    __block NSString *hitReason = nil;   // hitTest(可靠) / dist(坐标兜底)
    __block CGFloat minDist = CGFLOAT_MAX;
    __block NSString *minCls = nil;
    __block BOOL anyHandlePresent = NO;
    __block CGRect hsRect = CGRectZero;   // 最近手柄屏幕 rect（诊断用）
    __block int sHandleViews = 0;         // [v12f] 命中手柄类视图计数(诊断：漏判时看是否根本没扫到)
    __block int sHandleWinNil = 0;        // [v12f] 手柄视图 window==nil 计数(overlay window 瞬时脱离→坐标算歪根因)
    __block NSMutableSet *panCands = (leftZone ? [NSMutableSet set] : nil);  // 左缘：收集非 Oback 的 pan 候选(找 QQ 左缘自定义手势)
    // (A) [2026-08-09 v12] 公开 API 选择几何：UITextView 有活动选择时，用 caretRectForPosition 算出起止手柄
    // 真实屏幕坐标→判断触摸是否落在手柄上。不依赖私有手柄类名/所在 window——QQ 手柄怎么实现都能精确命中。
    __block BOOL geomFound = NO;
    void (^checkTV)(UITextView *) = ^(UITextView *tv){
        if (!tv) return;
        @try {
            UITextRange *selRange = tv.selectedTextRange;
            if (!selRange || selRange.isEmpty) return;
            CGRect rS = CGRectZero, rE = CGRectZero;
            @try { rS = [tv convertRect:[tv caretRectForPosition:selRange.start] toView:nil]; } @catch (NSException *e) {}
            @try { rE = [tv convertRect:[tv caretRectForPosition:selRange.end] toView:nil]; } @catch (NSException *e) {}
            CGFloat (^rd)(CGRect) = ^CGFloat(CGRect r){
                if (CGRectIsEmpty(r)) return (CGFloat)CGFLOAT_MAX;
                CGFloat nx = MAX(r.origin.x, MIN(sp.x, r.origin.x + r.size.width));
                CGFloat ny = MAX(r.origin.y, MIN(sp.y, r.origin.y + r.size.height));
                return (CGFloat)hypot(sp.x - nx, sp.y - ny);
            };
            CGFloat dS = rd(rS), dE = rd(rE);
            CGFloat d = MIN(dS, dE);
            geomFound = YES;
            if (d < minDist) { minDist = d; minCls = @"UITextView.selection"; hsRect = (dS <= dE) ? rS : rE; }
            anyHandlePresent = YES;
            if (d <= hitR) { hit = YES; hitCls = @"UITextView.selection"; }
        } @catch (NSException *e) {}
    };
    // [P2] 原 scanTV(UITextView 选择几何) 已合并进下方 scan 的单次遍历：整树遍历 2 次→1 次，检测逻辑零变化
    // 手柄类名判定：2=论断式(QQ DragAnimation.* + UIKit 系统手柄/光标/放大镜)，1=泛匹配(需小视图排除大块选择高亮)
    NSInteger (^handleKind)(NSString *) = ^NSInteger(NSString *cls){
        if (!cls) return 0;
        if ([cls hasPrefix:@"DragAnimation"]) return 2;
        if ([cls containsString:@"DragHandle"] || [cls containsString:@"SelectionHandle"] ||
            [cls containsString:@"Caret"] || [cls containsString:@"Loupe"] ||
            [cls containsString:@"Magnifier"] || [cls containsString:@"SelectRange"] ||
            [cls containsString:@"TextRange"]) return 2;
        if ([cls containsString:@"Handle"] || [cls containsString:@"Select"] ||
            [cls containsString:@"Range"] || [cls containsString:@"Drag"] ||
            [cls containsString:@"Flick"]) return 1;
        return 0;
    };
    // [v12e] 手柄有效屏幕 rect：容器 frame 可能为零(动画/overlay window)，递归取其可见子视图(手柄球)的非空小帧包围盒
    // 定位真实手柄位置——v.center 对零帧容器失真(实测差 101~160pt→漏判)。只取 <140pt 的小帧，排除选择高亮等大块。
    CGRect (^effectiveRect)(UIView *) = ^CGRect(UIView *hv){
        CGRect r = CGRectZero;
        @try { r = [hv convertRect:hv.bounds toView:nil]; } @catch (NSException *e) { r = CGRectZero; }
        if (!CGRectIsEmpty(r)) return r;
        __block CGRect acc = CGRectZero;
        __block void (^walk)(UIView *, int) = nil;
        walk = ^(UIView *v, int depth){
            if (!v || depth > 3) return;   // [v12f] 深度 2→3：手柄球可能嵌在 3 层子视图内(实测漏判根因之一)
            for (UIView *s in v.subviews) {
                CGRect sr = CGRectZero;
                @try { sr = [s convertRect:s.bounds toView:nil]; } @catch (NSException *e) { sr = CGRectZero; }
                if (!CGRectIsEmpty(sr) && sr.size.width < 140.0 && sr.size.height < 140.0) {
                    acc = CGRectIsEmpty(acc) ? sr : CGRectUnion(acc, sr);
                }
                if (depth < 3) walk(s, depth + 1);
            }
        };
        walk(hv, 0);
        // [v13] 子视图取不到 → 走 CALayer：文本(17).txt 里 DragAnimation 容器 5 个但 minDist 恒为
        // CGFLOAT_MAX(日志打印成 0)，说明它既无有效 frame 也无带帧子视图 —— 手柄球是**直接画在
        // layer.sublayers 上**的，UIView 层级里根本看不到。改走 layer 才拿得到真实几何。
        if (CGRectIsEmpty(acc)) {
            __block void (^lwalk)(CALayer *, int) = nil;
            lwalk = ^(CALayer *L, int depth){
                if (!L || depth > 3) return;
                for (CALayer *sl in L.sublayers) {
                    CGRect lr = CGRectZero;
                    @try { lr = [sl convertRect:sl.bounds toLayer:nil]; } @catch (NSException *e) { lr = CGRectZero; }
                    if (!CGRectIsEmpty(lr) && lr.size.width < 140.0 && lr.size.height < 140.0) {
                        acc = CGRectIsEmpty(acc) ? lr : CGRectUnion(acc, lr);
                    }
                    if (depth < 3) lwalk(sl, depth + 1);
                }
            };
            @try { lwalk(hv.layer, 0); } @catch (NSException *e) {}
        }
        return acc;
    };
    __block void (^scan)(UIView *, UIWindow *, UIView *);
    scan = ^(UIView *v, UIWindow *ownerWin, UIView *winHitView) {
        if (!v || v.hidden) return;  // [v10] 去掉 alpha<0.01/frame空跳过：QQ 手柄出现是 alpha/scale 动画，帧未稳时这些为真→漏检(根因)
        if ([v isKindOfClass:[UITextView class]]) checkTV((UITextView *)v);  // [P2] 合并 scanTV：UITextView 选择几何并入单次遍历
        NSString *cls = NSStringFromClass([v class]);
        NSInteger kind = handleKind(cls);
        if (kind == 0 && dragHandleCls && [v isKindOfClass:dragHandleCls]) kind = 2;
        if (kind > 0) {
            anyHandlePresent = YES;
            sHandleViews++;                              // [v12f] 诊断计数
            if (v.window == nil) sHandleWinNil++;        // [v12f] overlay window 瞬时脱离→坐标算歪根因计数
            // [v12d 根治] QQ 选择手柄在独立 overlay window 内；之前用 v.frame/v.center 算屏幕坐标，
            // 因 scale 动画帧未稳 + v.window 在扫描时刻为 nil → 坐标算成(0,0)/CGFLOAT_MAX → 永不命中。
            // 现改为：在手柄所属 window(ownerWin) 上对触摸点 sp 做 hitTest，若命中视图是 v 或其后代/
            // 或命中链含手柄类 → 手指确在手柄上 → 让路。完全绕开坐标计算，用 UIKit 自带 hitTest 几何，
            // 动画帧稳不稳都准（hitTest 按当前渲染帧判定，与视觉一致）。
            if (ownerWin && !hit && winHitView) {  // [P2] 复用每 window 预计算的 hitTest 结果，不再为每个手柄视图重复 hitTest 整树
                UIView *t = winHitView;
                while (t) {
                    NSInteger tk = (t == v) ? kind : handleKind(NSStringFromClass([t class]));
                    if (tk > 0) {
                        // [2026-09-17 P0 根治] 泛匹配(kind==1)在此分支此前**漏了 small 约束** ——
                        // 与 dist 分支不一致。实测微信：SwiftUI 全屏容器
                        //   _TtGC7SwiftUI16PlatformViewHostGVS_P10$18ff673c817ListRepresentable
                        //   GVS_28CollectionViewListDataSourceOs5Never_GOS_19SelectionManagerBoxS3____
                        // 仅因类名含 "Selection…" 被判 kind==1，而它位于**任何触摸点**的祖先链上
                        // ⇒ 左缘返回 100% 被拦死（日志：24 次起滑全部 shouldBegin=NO）。
                        // 现与 dist 分支对齐：kind==1 必须是小视图(<140pt，真正的手柄球)才让路；
                        // kind==2(DragHandle/SelectionHandle/Caret/Loupe/Magnifier/DragAnimation…)保持无约束。
                        // 零帧容器(动画中)判为不小 → 保守不放行拦截，宁可不拦也不误杀全局返回。
                        BOOL smallOK = YES;
                        if (tk == 1) {
                            CGSize bs = CGSizeZero;
                            @try { bs = t.bounds.size; } @catch (NSException *e) {}
                            smallOK = (bs.width > 0.0 && bs.width < 140.0 && bs.height > 0.0 && bs.height < 140.0);
                        }
                        if (smallOK) {
                            hit = YES;
                            hitCls = (t == v) ? cls : NSStringFromClass([t class]);
                            hitReason = @"hitTest";
                            break;
                        }
                    }
                    t = t.superview;
                }
            }
            // 距离/坐标诊断（尽力；动画帧稳时作为 hitTest 的补充命中，不稳时仅诊断，不依赖）
            // [v12e] 用 effectiveRect：零帧容器取可见子视图(手柄球)真实帧，纠正 v.center 失真
            CGRect sf = effectiveRect(v);
            CGPoint c = CGPointZero; BOOL haveRect = NO;
            if (!CGRectIsEmpty(sf)) {
                c = CGPointMake(CGRectGetMidX(sf), CGRectGetMidY(sf)); haveRect = YES;
            } else {
                // [v12f] 兜底：v.window 可能为 nil(overlay window 瞬时)→ 用扫描时的 ownerWin 做坐标基准，
                // 否则 convertPoint:toView:v.window 拿到 nil window → 坐标算成(0,0)/CGFLOAT_MAX → 漏判。
                @try {
                    UIView *base = v.superview ?: (v.window ?: ownerWin);
                    UIView *refWin = v.window ?: ownerWin;
                    if (base && refWin) {
                        CGPoint inWin = [base convertPoint:v.center toView:refWin];
                        CGRect wf = refWin.frame;
                        c = CGPointMake(wf.origin.x + inWin.x, wf.origin.y + inWin.y);
                        haveRect = YES;   // 有中心即可判距（矩形尺寸未知，按点距算）
                    }
                } @catch (NSException *e) {}
            }
            if (c.x != 0 || c.y != 0) {
                CGFloat d;
                if (haveRect && !CGRectIsEmpty(sf)) {
                    // [v9] 到手柄矩形最近点距离(dRect)：按在手柄边缘外侧也能命中，比到中心距离更准
                    CGFloat nx = MAX(sf.origin.x, MIN(sp.x, sf.origin.x + sf.size.width));
                    CGFloat ny = MAX(sf.origin.y, MIN(sp.y, sf.origin.y + sf.size.height));
                    d = (CGFloat)hypot(sp.x - nx, sp.y - ny);
                } else {
                    d = (CGFloat)hypot(sp.x - c.x, sp.y - c.y);
                }
                // [v13 诊断修正] hsRect 此前只在 checkTV(UITextView 几何)里赋值，scan 路径从不写它，
                // 导致 [diag-near] 的 rect 恒为 (0,0,0,0)，被误读成"手柄零帧"。这里补上。
                if (d < minDist) { minDist = d; minCls = cls; hsRect = sf; }
                if (!hit) {
                    BOOL small = (kind == 2) ? YES : (haveRect && !CGRectIsEmpty(sf) ? (sf.size.width < 140.0 && sf.size.height < 140.0) : NO);
                    BOOL near = (d <= hitR);
                    BOOL veryNear = (d <= 32.0f);   // [2026-09-17] 45→32：与 hitR 同步。31pt 那次误拦正是此常量所致
                    // [2026-09-17 可见性约束] 只有**当前真的显示着**的手柄才参与 dist 兜底判定。
                    // 根因：QQ 聊天页里长期残留 6 个 DragAnimation.DragAnimationBaseView（日志实测），
                    // 选择早已收起/淡出后它们仍在视图树里 ⇒ 任何左缘触摸只要落到附近就被永久拦死
                    // （「选过一次字之后左缘就废了」）。hitTest 分支不需要此约束（它按当前渲染帧判定，天然准确）。
                    BOOL visible = (v.window != nil && !v.hidden && v.alpha > 0.05);
                    if (kind == 2) {
                        // [v12f] 确证手柄(kind==2)：取消半区 side 约束。居中柄(≈W/2)与"手柄在触摸对侧"时
                        // 原 side 判定会误杀真实命中(只靠 veryNear 兜底)，是 v12e 多数抓取漏判的根因。
                        // kind==2 类(DragHandle/SelectionHandle/Caret/Loupe/DragAnimation…)均为选择/光标相关，
                        // 命中即让路不会误伤全局返回。
                        if (visible && (near || veryNear)) {
                            hit = YES; hitCls = cls; hitReason = @"dist";
                            hitAlpha = v.alpha; hitWinNil = (v.window == nil);
                        }
                    } else {
                        // [v9] 半区约束 side：左柄管左半、右柄管右半；居中柄(≈W/2) side 恒真；极近(d<=45)兜底不限侧
                        BOOL side = (c.x < screenW * 0.5f) ? (sp.x < screenW * 0.5f) : (sp.x >= screenW * 0.5f);
                        if (visible && small && ((near && side) || veryNear)) {
                            hit = YES; hitCls = cls; hitReason = @"dist";
                            hitAlpha = v.alpha; hitWinNil = (v.window == nil);
                        }
                    }
                }
            }
        }
        if (panCands) {
            for (UIGestureRecognizer *gr in (v.gestureRecognizers ?: @[])) {
                if ([gr isKindOfClass:[UIPanGestureRecognizer class]] && gr.delegate != self)
                    [panCands addObject:[NSString stringWithFormat:@"%@@%@", NSStringFromClass([gr class]), NSStringFromClass([gr.view class])]];
            }
        }
        for (UIView *sub in v.subviews) scan(sub, ownerWin, winHitView);
    };
    for (UIWindow *w in wins) {   // [P2] 每 window 仅做一次 hitTest，结果随 scan 下传，避免对每个手柄视图重复 hitTest 整树
        if (!w) continue;
        CGPoint wp = CGPointZero;
        @try { wp = [w convertPoint:sp fromView:nil]; } @catch (NSException *e) {}
        UIView *hw = nil;
        @try { hw = [w hitTest:wp withEvent:nil]; } @catch (NSException *e) { hw = nil; }
        scan(w, w, hw);
    }
    static int sGeomCount = 0;
    if (geomFound && sGeomCount < 50) { sGeomCount++;
        OBDIAG(@"[diag-selgeom] 选择活动 触摸x=%.0f 最近距离=%.0f 手柄rect=(%.0f,%.0f,%.0f,%.0f) hit=%d",
              sp.x, (minDist==CGFLOAT_MAX?0:minDist), hsRect.origin.x, hsRect.origin.y, hsRect.size.width, hsRect.size.height, (int)hit);
    }
    static int sNearCount = 0;
    if (outActive) *outActive = anyHandlePresent;
    if (outMinDist) *outMinDist = (minDist == CGFLOAT_MAX ? 0 : minDist);
    if (hit) {
        OBDIAG(@"[diag-handle] 命中活动选择手柄(%@) via %@ 距离=%.0f 触摸x=%.0f alpha=%.2f winNil=%d → shouldBegin 让路",
              hitCls ? hitCls : @"?", hitReason ? hitReason : @"?", (minDist==CGFLOAT_MAX?0:minDist), sp.x, hitAlpha, (int)hitWinNil);
        return 2;
    }
    if (anyHandlePresent && minDist > hitR && minDist < 260.0 && sNearCount < 25) {
        sNearCount++;
        OBDIAG(@"[diag-near] 选择激活但触摸未命中手柄: 触摸x=%.0f 最近=%@ 距离=%.0f rect=(%.0f,%.0f,%.0f,%.0f) 手柄视图数=%d winNil=%d geom=%d 候选pan=%@",
              sp.x, minCls ? minCls : @"?", (minDist==CGFLOAT_MAX?0:minDist),
              hsRect.origin.x, hsRect.origin.y, hsRect.size.width, hsRect.size.height,
              sHandleViews, sHandleWinNil, (int)geomFound,
              (panCands ? [panCands allObjects] : @[]));
    }
    return anyHandlePresent ? 1 : 0;
}

@end

#pragma mark - 仅识别横向的 pan 实现
@implementation ObackPanGestureRecognizer

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    __obLastTouchTS = [NSDate timeIntervalSinceReferenceDate];   // [R3] 手指在屏幕上（安全阀据此不恢复对手手势）
    [super touchesBegan:touches withEvent:event];
    UITouch *touch = [touches anyObject];
    if (touch) self.startPoint = [touch locationInView:self.view];
    // 诊断（节流 1s）：确认 window pan 是否收到朋友圈/照片查看器/部分 app 的触摸。
    // 若某页面【无任何 [diag] 输出】却也【无 shouldBegin】，说明触摸未送达本 window pan
    // （内容在独立 window 或触摸被其它手势吞掉）→ 边缘返回自然"没效果"。
    static CFTimeInterval sLastDiag = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - sLastDiag > 1.0) {
        sLastDiag = now;
        UITouch *t = [touches anyObject];
        CGPoint l = t ? [t locationInView:self.view] : CGPointZero;
        // self.view 即本 pan 挂载的 window（window 级手势），故直接用其类名表示所在 window
        OBLog(@"[diag] pan touchesBegan @(%.0f,%.0f) win=%@",
              l.x, l.y, NSStringFromClass([self.view class]));
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    __obLastTouchTS = [NSDate timeIntervalSinceReferenceDate];   // [R3] 仍在拖动
    if (self.state == UIGestureRecognizerStatePossible) {
        UITouch *touch = [touches anyObject];
        if (touch) {
            CGPoint now = [touch locationInView:self.view];
            CGFloat dx = now.x - self.startPoint.x;
            CGFloat dy = now.y - self.startPoint.y;
            // 放松「仅横向」判定（稳定性修复）：极端边缘起滑应优先判为返回，贴合 OPPO 行为。
            // 旧逻辑：前 8pt 内只要纵向>横向即判失败 → 拇指斜滑被误杀 → 「有时要划好几次才触发」。
            // 新逻辑：仅当位移明显偏纵向(dy > 2*dx)且已超过较大阈值(14pt)才失败、放行底层滚动；
            // 轻微对角/横向均视为返回意图，边缘返回成功率大幅提升。
            if (fabs(dx) >= 14.0 || fabs(dy) >= 14.0) {
                if (fabs(dy) > 2.0 * fabs(dx)) {
                    self.state = UIGestureRecognizerStateFailed;
                    return;
                }
            }
        }
    }
    [super touchesMoved:touches withEvent:event];
}

// [R3] 手指离开屏幕：清除在途标记，安全阀下一轮即可恢复对手手势。
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    __obLastTouchTS = 0;
    [super touchesEnded:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    __obLastTouchTS = 0;
    [super touchesCancelled:touches withEvent:event];
}

@end
