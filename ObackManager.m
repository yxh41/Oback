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
@property (nonatomic, retain) UIActivityViewController *logActivityVC;  // [v11c] retain 防活动视图控制器提前释放(MRC 陷阱)
@end

// [构建标记] 人工标签写在这里，**commit 短哈希由 CI 自动追加**（.github/workflows/build.yml 的
// "Patch package version with git hash" 步骤会把本行改写成 @"<标签>+<短哈希>"），故不必手改哈希。
// 日志开启时打印，用于一锤定音确认装的是哪个代码版本（解决"装的是不是最新"的争议）。
#define OBACK_BUILD_TAG @"T4-noqq-t2"

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

#pragma mark - [P6] 诊断日志宏（编译期收敛）

// 所有 [diag-*] 诊断日志统一走本宏。当前在 Makefile 定义 OBACK_DIAG=1（真机调试需要），故照常输出；
// 若需极简 release 包，去掉 Makefile 的 -DOBACK_DIAG 即可把全部诊断日志整体编译剔除（含参数计算），进一步减负。
#ifdef OBACK_DIAG
#define OBDIAG(fmt, ...) OBLog(fmt, ##__VA_ARGS__)
#else
#define OBDIAG(fmt, ...) do {} while (0)
#endif

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
// [2026-08-09] kYieldActiveKey 机制已彻底移除（多次引发回归），声明一并删除——无任何引用。
static void *kDiagLastLogKey = &kDiagLastLogKey;  // 双返回诊断：同一 window 日志节流（每 2s 最多打一次手势清单）
static void *kGlobalPanKey = &kGlobalPanKey;        // 全屏 pan 引用（绑到 window，gestureRecognizerShouldBegin 识别用）
static CGFloat const kIndicatorMaxTravel = 110.0;   // 胶囊最多跟随手指移动的距离 (pt)

#pragma mark - 边缘方向指示胶囊（OPPO 风格：跟随手指、带方向箭头）

typedef NS_ENUM(NSInteger, ObackCapsuleEffect) {
    ObackCapsuleEffectClassic   = 0,   // 经典：白药丸 + 柔和阴影 + 深色箭头
    ObackCapsuleEffectGlow      = 1,   // 发光：彩色外发光
    ObackCapsuleEffectNeon      = 2,   // 霓虹：霓虹描边 + 强发光
    ObackCapsuleEffectGradient  = 3,   // 流光：动态渐变填充
    ObackCapsuleEffectFrosted   = 4,   // 毛玻璃：半透明磨砂
    ObackCapsuleEffectBreathing = 5,   // 呼吸：跟随中轻微脉冲
};

@interface ObackEdgeIndicator : UIView
- (instancetype)initWithEdge:(ObackEdge)edge;
- (void)stopEffectAnimations;   // 收起时停掉渐变等循环动画，避免与淡出动画冲突/残留
- (BOOL)isBreathing;            // 供 CADisplayLink 插值判断是否叠加呼吸脉冲
- (void)setFlowSpeed:(CGFloat)speed;   // 流光跟手：流速联动手指速度（1=正常，>1 更 energetic，<1 更 calm）
@end

@implementation ObackEdgeIndicator {
    ObackEdge _edge;
    CAShapeLayer *_chevron;
    CAGradientLayer *_gradientLayer; // 流光特效：渐变填充层（弱引用，由 layer 树持有）
    BOOL _breathing;                // 呼吸特效：在平滑插值里叠加正弦脉冲
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
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_obInterruptActiveInteraction)
                                                 name:UIApplicationDidEnterBackgroundNotification
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
- (void)_enumerateGestureViewsIn:(UIView *)view depth:(NSUInteger)depth
			       predicate:(BOOL(^)(UIView *v, UIGestureRecognizer *g))pred
			           emit:(void(^)(UIGestureRecognizer *g))emit {
	if (!view || !emit || depth > 40) return;
	for (UIGestureRecognizer *g in view.gestureRecognizers) {
		if (pred(view, g)) emit(g);
	}
	for (UIView *sub in view.subviews)
		[self _enumerateGestureViewsIn:sub depth:depth + 1 predicate:pred emit:emit];
}

// 递归收集窗口视图树里所有 UIScreenEdgePanGestureRecognizer（含 App/插件自定义的左边缘返回手势）。
// 注意：我们的 window pan 现在本身就是 UIScreenEdgePanGestureRecognizer 子类，故枚举时会包含它们；
// 在链接处通过 g.delegate == self 跳过自身（避免 requireGestureRecognizerToFail 自引用），无需在此排除。
- (void)_enumerateEdgeGesturesInView:(UIView *)view depth:(NSUInteger)depth
			                               block:(void(^)(UIScreenEdgePanGestureRecognizer *g))block {
	[self _enumerateGestureViewsIn:view depth:depth
			                 predicate:^BOOL(UIView *v, UIGestureRecognizer *g){
			                     return [g isKindOfClass:[UIScreenEdgePanGestureRecognizer class]];
			                 }
			                     emit:^(UIGestureRecognizer *g){ block((UIScreenEdgePanGestureRecognizer *)g); }];
}

// 递归收集窗口视图树里所有 UIScrollView 的 pan 手势（横向 + 纵向皆含）。
// 根因：朋友圈等是「纵向」UITableView，其 panGestureRecognizer 优先级高于我们 window 上的
// ObackPanGestureRecognizer；而我们此前只链「横向」scrollView → 纵向表视图没被设为失败于 ourPan
// → 从边缘起滑时表视图 pan 抢赢识别、ourPan 被取消 → 胶囊出现却无返回（朋友圈"有胶囊没返回"）。
// 让「所有」scrollView 的 pan 失败于 ourPan：从边缘起滑时 ourPan 优先接管返回（无论横/纵 scroll），
// 从中间滑动时 ourPan 本就不 begin → 放行给滚动，互不干扰。完全匹配 OPPO 行为（极端边缘=返回）。
- (void)_enumerateScrollPansInView:(UIView *)view depth:(NSUInteger)depth
			                              block:(void(^)(UIPanGestureRecognizer *g))block {
	[self _enumerateGestureViewsIn:view depth:depth
			                 predicate:^BOOL(UIView *v, UIGestureRecognizer *g){
			                     return [v isKindOfClass:[UIScrollView class]] && g == ((UIScrollView *)v).panGestureRecognizer;
			                 }
			                     emit:^(UIGestureRecognizer *g){ block((UIPanGestureRecognizer *)g); }];
}

// 收集窗口视图树里所有 UIPanGestureRecognizer（含 plain / 屏幕边缘 / 滚动），用于让"对手手势"
// 失败于我们的右缘 pan（Oback 独占右缘返回）。排除我们自己的 pan（delegate==self）。
- (void)_enumeratePansInView:(UIView *)view depth:(NSUInteger)depth
			                        block:(void(^)(UIPanGestureRecognizer *g))block {
	[self _enumerateGestureViewsIn:view depth:depth
			                 predicate:^BOOL(UIView *v, UIGestureRecognizer *g){
			                     return [g isKindOfClass:[UIPanGestureRecognizer class]];
			                 }
			                     emit:^(UIGestureRecognizer *g){ block((UIPanGestureRecognizer *)g); }];
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
    // 性能：同一 window 500ms 内不重复全树遍历（windowBecameKey / 已挂载重链可能密集触发）
    static NSTimeInterval __lastLinkTS = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - __lastLinkTS < 0.5) return;
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

    // 排除名单（朋友圈等）：不干预，交原生处理，避免我们的 pan 与整屏滚动手势打架、进不了 Began
    if ([self _isExcludedViewController:top]) {
        OBLog(@"shouldBegin=NO (排除视图，交原生: top=%@)", NSStringFromClass([top class]));
        return NO;
    }

    // 按 pan 种类分流（根治"window 级边缘 pan 在列表页被 scrollView 抢赢"）：
    // - nav.view 上的 pan 只接管 nav pop；
    // - window modal pan 只接管 modal dismiss（有 nav pop 可接管时让 nav pan 处理，避免双触发）。
    if ([kind isEqualToString:@"nav"]) {
        // 顶层有 modal 时，其 dismiss 由 window modal pan 接管；nav.view 在 modal 之下不接管，避免双触发。
        if (nav.presentedViewController != nil || top.presentingViewController != nil) {
            OBLog(@"shouldBegin(nav)=NO (有 modal 在顶层，交给 window modal pan)");
            return NO;
        }
        if (!(nav && nav.viewControllers.count > 1)) {
            OBLog(@"shouldBegin(nav)=NO (nav 不可 pop: childCount=%lu)",
                  (unsigned long)nav.viewControllers.count);
            return NO;
        }
        // 即时禁用系统原生 interactivePop：微信等 App 在 viewDidAppear 后会把
        // interactivePopGestureRecognizer.enabled 重新置 YES，linkNav 的禁用被绕过 →
        // 原生边缘返回与我们的 pan 同时驱动同一 _UINavigationInteractiveTransition → 双返回。
        // 起滑瞬间(shouldBegin 确认有效 pop)再压死一次，确保本次只有我们的 pan 驱动转场。
        nav.interactivePopGestureRecognizer.enabled = NO;
        if (edge == ObackEdgeRight) {
            self.currentParallaxToView = NO;
            self.rightSimplePop = YES;   // 右缘：非交互 pop（松手提交才 popViewControllerAnimated:，零空白/不破坏导航栏/不进自定义转场）
        } else {
            // 左缘：标准 nav 走方案A(系统原生交互转场, 跟手)；微信等自定义 nav(方案A 在微信不渲染
            // 转场 → 旧非交互兜底依赖脆弱运行时探测且首微拖即弹) 统一改走 rightSimplePop 同款
            // 非交互 pop(松手提交, 与右缘行为完全一致, 受灵敏度滑块控制, 无脆弱探测依赖)。
            if (![self _navPopShouldDriveSystemNav:nav]) {
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
    }
    // 关键修复：胶囊在 shouldBegin=YES 时即显示，而非等 Began。左边缘会被系统原生
    // interactivePopGestureRecognizer（UIScreenEdgePanGestureRecognizer）抢走，导致我们的手势
    // 永远进不了 Began，胶囊若只在 Began 显示则左边缘永不出现（日志实证：左边缘 shouldBegin=YES
    // 却无 indicator shown）。改在 shouldBegin 显示，左右边缘一致；showIndicator 内已设 0.4s
    // 安全兜底，防止被抢走时胶囊残留。
    [self showIndicatorWithEdge:edge atPoint:loc inWindow:win];
    _indicatorAnchor = loc;
    _indicatorStartX = loc.x;
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
    if (nav && nav.viewControllers.count > 1) {
        OBLog(@"globalShouldBegin=YES (loc.x=%.1f 有nav pop=%lu)", loc.x,
              (unsigned long)nav.viewControllers.count);
        return YES;
    }
    return NO;  // 无 nav pop：不接管，交还（modal dismiss 由 Oback 右缘提供）
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
                    UINavigationController *nav = objc_getAssociatedObject(pan, kObackNavKey);
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
    [self dismissIndicatorSafety];              // 收起胶囊（interacting 已置 NO，会执行）
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
    UINavigationController *nav = objc_getAssociatedObject(pan, kObackNavKey);
    UIViewController *top = nil;
    if (nav) {
        top = nav.topViewController;
    } else if ([objc_getAssociatedObject(pan, kPanKindKey) isEqualToString:@"nav"]) {
        // 兼容旧路径：nav 类 pan 直接读所属 nav
        nav = objc_getAssociatedObject(pan, kObackNavKey);
        top = nav.topViewController;
    }
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
            if ([kindP isEqualToString:@"nav"]) navP = objc_getAssociatedObject(pan, kObackNavKey);
            if (!navP) {
                UIViewController *topP = [self topMost:win.rootViewController];
                navP = topP.navigationController;
                if (!navP && [topP isKindOfClass:[UINavigationController class]]) navP = (UINavigationController *)topP;
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
            if ([kindP isEqualToString:@"nav"]) navP = objc_getAssociatedObject(pan, kObackNavKey);
            if (!navP) {
                UIViewController *topP = [self topMost:win.rootViewController];
                navP = topP.navigationController;
                if (!navP && [topP isKindOfClass:[UINavigationController class]]) navP = (UINavigationController *)topP;
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
            nav = objc_getAssociatedObject(pan, kObackNavKey);
        }
        if (!nav) {
            UIViewController *top = [self topMost:win.rootViewController];
            nav = top.navigationController;
            if (!nav && [top isKindOfClass:[UINavigationController class]]) nav = (UINavigationController *)top;
        }
        if (commit && nav && nav.viewControllers.count > 1) {
            @try { [nav popViewControllerAnimated:YES]; }
            @catch (NSException *e) { OBLog(@"endTransition 右缘 pop 异常: %@", e); }
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
        nav = objc_getAssociatedObject(pan, kObackNavKey);
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
    CGFloat halfW = 28.0;
    CGFloat x = (edge == ObackEdgeLeft) ? (halfW - 8.0)
                                        : (win.bounds.size.width - halfW + 8.0);
    return CGPointMake(x, loc.y);
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
    ind.transform = CGAffineTransformMakeScale(0.85, 0.85);
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
    _indicatorTargetScale = 0.85;
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
    CGFloat travel = MIN(fabs(dx), kIndicatorMaxTravel) * dir;   // 跟随手指，最多移动 kIndicatorMaxTravel
    CGPoint home = [self indicatorHomeCenterForEdge:self.currentEdge basePoint:_indicatorAnchor window:win];
    // 仅更新目标位置/缩放，真正位移由 CADisplayLink(_obIndicatorTick:) 每帧插值 → 平滑不抖
    _indicatorTarget = CGPointMake(home.x + travel, home.y);
    _indicatorTargetScale = 0.85 + 0.15 * MIN(1.0, _currentPercent / 0.3);
    _indicator.alpha = 0.9;
    // [2026-08-01 流光跟手] 手指横向速度 → 流光目标速度：快滑更 energetic、慢拖更 calm
    CGFloat vx = [pan velocityInView:win].x;
    _flowTargetSpeed = MAX(0.8, MIN(3.0, 0.8 + fabs(vx) / 1500.0 * 2.2));
    // 不再每帧 [win bringSubviewToFront:]（O(n) 主窗口子视图重排）；仅在 showIndicator 时置顶一次
}

- (void)dismissIndicatorCommitted:(BOOL)committed params:(ObackParams *)p window:(UIWindow *)win {
    UIView *ind = _indicator;
    _indicator = nil;
    _flowSpeed = 1.0; _flowTargetSpeed = 1.0;   // 流光跟手：复位，下一轮手势干净起步
    [self _stopIndicatorLink];   // 手势结束：停平滑插值，胶囊交给 UIView 动画淡出/弹回
    [(ObackEdgeIndicator *)ind stopEffectAnimations];   // 停渐变等循环动画，避免与下方淡出动画冲突
    if (!ind) return;
    if (committed) {
        // 提交返回：放大淡出
        [UIView animateWithDuration:MAX(0.18, p.duration * 0.6) delay:0
                             options:UIViewAnimationOptionCurveEaseIn
                          animations:^{
            ind.alpha = 0.0;
            ind.transform = CGAffineTransformMakeScale(1.35, 1.35);
        } completion:^(BOOL f) { [ind removeFromSuperview]; }];
    } else {
        // 取消：弹回边缘并缩小消失
        CGPoint home = [self indicatorHomeCenterForEdge:self.currentEdge
                                              basePoint:_indicatorAnchor window:win];
        [UIView animateWithDuration:MAX(0.22, p.duration * 0.7) delay:0
                             options:UIViewAnimationOptionCurveEaseOut
                          animations:^{
            ind.center = home;
            ind.alpha = 0.0;
            ind.transform = CGAffineTransformMakeScale(0.6, 0.6);
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
    return vc;
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
    CGFloat hitR = 75.0;   // [2026-08-09 v12e] 容差 60→75：配合子视图真实帧定位，给手指余量；半区 side 约束仍护全局返回
    CGFloat screenW = 0;
    if (wins.count) { @try { screenW = ((UIWindow *)wins.firstObject).bounds.size.width; } @catch (NSException *e) {} }
    if (screenW <= 0) screenW = 390.0;  // 兜底宽度
    BOOL leftZone = (sp.x < 60.0);   // 左缘热区：失败多发的竞争区
    __block BOOL hit = NO;
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
                    if (t == v || handleKind(NSStringFromClass([t class])) > 0) {
                        hit = YES; hitCls = cls; hitReason = @"hitTest"; break;
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
                    BOOL veryNear = (d <= 45.0f);
                    if (kind == 2) {
                        // [v12f] 确证手柄(kind==2)：取消半区 side 约束。居中柄(≈W/2)与"手柄在触摸对侧"时
                        // 原 side 判定会误杀真实命中(只靠 veryNear 兜底)，是 v12e 多数抓取漏判的根因。
                        // kind==2 类(DragHandle/SelectionHandle/Caret/Loupe/DragAnimation…)均为选择/光标相关，
                        // 命中即让路不会误伤全局返回。
                        if (near || veryNear) { hit = YES; hitCls = cls; hitReason = @"dist"; }
                    } else {
                        // [v9] 半区约束 side：左柄管左半、右柄管右半；居中柄(≈W/2) side 恒真；极近(d<=45)兜底不限侧
                        BOOL side = (c.x < screenW * 0.5f) ? (sp.x < screenW * 0.5f) : (sp.x >= screenW * 0.5f);
                        if (small && ((near && side) || veryNear)) { hit = YES; hitCls = cls; hitReason = @"dist"; }
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
        OBDIAG(@"[diag-handle] 命中活动选择手柄(%@) via %@ 距离=%.0f 触摸x=%.0f → shouldBegin 让路", hitCls ? hitCls : @"?", hitReason ? hitReason : @"?", (minDist==CGFLOAT_MAX?0:minDist), sp.x);
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

@end
