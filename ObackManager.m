#import "ObackManager.h"
#import "ObackPreferences.h"
#import <objc/runtime.h>

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

void OBLog(NSString *fmt, ...) {
    BOOL enabled = [ObackPreferences debugLogEnabled];
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
    // 开关从「关→开」翻转：追加一行分隔，明确标识「以下为开关生效后日志」，
    // 消除「这份日志到底是开关开还是关时写的」困惑（配合抓前删旧日志，分析更准）。
    if (!_obLogWasOn) {
        _obLogWasOn = YES;
        NSString *sep = [NSString stringWithFormat:@"[%@] Oback: === 调试日志已开启（以下为开关生效后日志）===\n", [NSDate date]];
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
    // 同时进 syslog（可用 syslog 工具实时看）
    NSLog(@"%@", line);
    [msg release];
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
static void *kYieldActiveKey = &kYieldActiveKey;  // [2026-08-09 回归修复] 仅当蓝色选择手柄手势(_UIDragHandleGestureRecognizer)真实处于拖拽态(Began/Changed)时由 handleGlobalPan 置 YES，令其短路(不驱动返回、交还 QQ 原生)。注：判定基于手势真实 state 而非类名——手柄类名常驻于文本视图，按类名置位会误杀全局返回。
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
    ObackAnimator *_watchAnimator; // MRC 强引用：兜底收尾定时器期间持有动画器，避免 UIKit 释放成野指针
    id     _navPopTarget;        // 方案A: 系统原生 nav pop 的私有 target(_UINavigationInteractiveTransition)，
                                 // 驱动 handleNavigationTransition: 用（assign，由 nav 内部持有，转场期间有效）
    BOOL   _navPopProbeFailed;   // 运行时探测: 方案A 系统交互转场未启动(自定义nav不配合)→ YES, 已切非交互 pop
    BOOL   _navPopProbed;        // 运行时探测门控: 独立于 _transitionTriggered，确保左缘 nav 首次横拖必探测一次
    UIGestureRecognizer *_simulOpponent; // 同时识别冲突: 左缘接管型nav场景下记下的对手pan(retain 自己持有, 防 pop 文章后对手随 VC/WKWebView 释放成悬空指针 → beginTransition 解引用 EXC_BAD_ACCESS)。仅 beginTransition 取消一次, endTransition/abortTransition 收尾 release+nil。
    // 全局返回：全屏 pan 相关状态
    CGPoint _globalStart;                // 全屏 pan 起点（Began 记录，Changed 判定方向）
    BOOL    _globalDriven;               // 全屏 pan 是否已确认横向意图并交给 beginTransition 驱动
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
    });
    return m;
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
        // [2026-08-05 QQ/TIM] 挂上 panG 即建立全屏对手压制（最早时机，window/panG 均已确定）。
        // 链接时机(_linkNavPopGesturesInWindow)因「全局返回 App 无 Oback pan」被 early return 跳过，
        // 故此处补建，确保 QQ 聊天全屏返回手势被压制、Oback 独占；晚到手势由 shouldBegin 懒补链兜底。
        if ([self _navPopShouldUseObackAnimator:nil]) {
            [self _obLinkFullScreenOpponentPansInWindow:win];
        }
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

// 递归收集窗口视图树里所有 UIScreenEdgePanGestureRecognizer（含 App/插件自定义的左边缘返回手势）。
// 注意：我们的 window pan 现在本身就是 UIScreenEdgePanGestureRecognizer 子类，故枚举时会包含它们；
// 在链接处通过 g.delegate == self 跳过自身（避免 requireGestureRecognizerToFail 自引用），无需在此排除。
// 深度护栏避免超大视图树爆栈。
- (void)_enumerateEdgeGesturesInView:(UIView *)view depth:(NSUInteger)depth
                               block:(void(^)(UIScreenEdgePanGestureRecognizer *g))block {
    if (!view || !block || depth > 40) return;
    for (UIGestureRecognizer *g in view.gestureRecognizers) {
        if ([g isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) block((UIScreenEdgePanGestureRecognizer *)g);
    }
    for (UIView *sub in view.subviews)
        [self _enumerateEdgeGesturesInView:sub depth:depth + 1 block:block];
}

// 递归收集窗口视图树里所有 UIScrollView 的 pan 手势（横向 + 纵向皆含）。
// 根因：朋友圈等是「纵向」UITableView，其 panGestureRecognizer 优先级高于我们 window 上的
// ObackPanGestureRecognizer；而我们此前只链「横向」scrollView → 纵向表视图没被设为失败于 ourPan
// → 从边缘起滑时表视图 pan 抢赢识别、ourPan 被取消 → 胶囊出现却无返回（朋友圈"有胶囊没返回"）。
// 让「所有」scrollView 的 pan 失败于 ourPan：从边缘起滑时 ourPan 优先接管返回（无论横/纵 scroll），
// 从中间滑动时 ourPan 本就不 begin → 放行给滚动，互不干扰。完全匹配 OPPO 行为（极端边缘=返回）。
- (void)_enumerateScrollPansInView:(UIView *)view depth:(NSUInteger)depth
                              block:(void(^)(UIPanGestureRecognizer *g))block {
    if (!view || !block || depth > 40) return;
    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *sv = (UIScrollView *)view;
        if (sv.panGestureRecognizer) block(sv.panGestureRecognizer);
    }
    for (UIView *sub in view.subviews)
        [self _enumerateScrollPansInView:sub depth:depth + 1 block:block];
}

// 收集窗口视图树里所有 UIPanGestureRecognizer（含 plain / 屏幕边缘 / 滚动），用于让"对手手势"
// 失败于我们的右缘 pan（Oback 独占右缘返回）。排除我们自己的 pan（delegate==self）。
- (void)_enumeratePansInView:(UIView *)view depth:(NSUInteger)depth
                        block:(void(^)(UIPanGestureRecognizer *g))block {
    if (!view || !block || depth > 40) return;
    for (UIGestureRecognizer *g in view.gestureRecognizers) {
        if ([g isKindOfClass:[UIPanGestureRecognizer class]]) block((UIPanGestureRecognizer *)g);
    }
    for (UIView *sub in view.subviews)
        [self _enumeratePansInView:sub depth:depth + 1 block:block];
}

- (UIView *)_yuanbaoSummaryViewIn:(UIView *)view cls:(Class)ybCls {
    // [2026-08-06 辅助] 递归查找元宝AI总结浮层(NTAISummaryFloatEar)的可见 view；找不到返回 nil。
    if (!view || !ybCls) return nil;
    if ([view isKindOfClass:ybCls]) return view;
    for (UIView *sub in view.subviews) {
        UIView *r = [self _yuanbaoSummaryViewIn:sub cls:ybCls];
        if (r) return r;
    }
    return nil;
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
        // [2026-08-05 QQ/TIM] 全局返回 App 无 Oback 边缘 pan（kPanKey 为空），但 QQ 聊天全屏返回需压制。
        // 故 QQ/TIM 不跳过，直接建立全屏对手压制后返回（覆盖进聊天后懒加载的晚到全屏手势）；其他 App 维持原跳过。
        if ([self _navPopShouldUseObackAnimator:nil]) {
            [self _obLinkFullScreenOpponentPansInWindow:win];
            OBLog(@"linkNav: 本 window 无 Oback pan，但 QQ/TIM 已建全屏压制"); return;
        }
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
    // [2026-08-05 QQ/TIM 左缘根治] 左缘对手 pan 链接（仅 QQ/TIM：NTPushPopLib 左缘自定义手势非系统
    // interactivePop、禁不掉），压住其左缘手势使 Oback 独占、与右缘表现一致；其他 App 不调用、路径零改动。
    if ([self _navPopShouldUseObackAnimator:nil]) {
        [self _obLinkLeftEdgeOpponentPansInWindow:win];
        [self _obLinkFullScreenOpponentPansInWindow:win];   // [2026-08-05] 全屏返回对手压制（聊天任意位置全屏返回）
    }
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

// [2026-08-05 QQ/TIM 左缘根治] 左缘「对手手势 requireToFail 我们的左缘 pan」链接，
// 镜像右缘 _obLinkRightEdgeOpponentPansInWindow:，专治 QQ/TIM 自研转场库 NTPushPopLib
// 的左缘自定义手势——它不与系统 interactivePopGestureRecognizer 共用，禁用后者也压不住它，
// 故左缘起滑时我们的 pan 与 QQ 左缘手势同时开火、抢走转场 → 表现为「瞬闪/不跟手」
// （右缘因已有对等压制故已跟手，左缘此前缺此环）。让窗口内所有非 Oback 的 pan 失败于
// 我们的左缘 pan：Oback 独占左缘返回；边缘外（中间）左缘 pan 不 begin → 对手 pan 正常触发（QQ 原手势保留）。
- (void)_obLinkLeftEdgeOpponentPansInWindow:(UIWindow *)win {
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
    // 让窗口内所有「对手 pan」（QQ 等 App 自定义的左缘手势，通常是 plain UIPanGestureRecognizer，
    // 少数是屏幕边缘 pan）失败于我们的左缘 pan：Oback 独占左缘返回，对手在左缘让步（单向，无死锁）；
    // 边缘外（中间）我们的左缘 pan 不 begin → 对手 pan 正常触发（QQ 原手势保留）。
    [self _enumeratePansInView:win depth:0 block:^(UIPanGestureRecognizer *g){
        if (g.delegate == self) return;            // 跳过我们自己的 pan（避免自引用）
        for (ObackPanGestureRecognizer *lp in leftPans) {
            @try { [g requireGestureRecognizerToFail:lp]; } @catch (NSException *e) {}
        }
    }];
    if ([ObackPreferences doubleReturnDiagEnabled]) {
        NSMutableArray *opp = [NSMutableArray array];
        [self _enumeratePansInView:win depth:0 block:^(UIPanGestureRecognizer *g){
            if (g.delegate == self) return;
            [opp addObject:[NSString stringWithFormat:@"%@@%@",
                            NSStringFromClass([g class]), NSStringFromClass([g.view class])]];
        }];
    OBLog(@"diag[左缘链接(懒)] 左缘 pan=%lu 个；对手 pan 共 %lu → %@",
          (unsigned long)leftPans.count, (unsigned long)opp.count, opp);
    }
}

// [2026-08-05 QQ/TIM 全屏返回根治] 全屏「对手 pan」链接：QQ 聊天界面任意位置触发的全屏返回手势
// （NTPushPopLib，plain UIPanGestureRecognizer，非系统 interactivePop）与 Oback 全屏 pan(panG) 抢转场→瞬返。
// 让窗口内所有非 Oback、非 UIScrollView 滚动的 pan 失败于我们的 panG：Oback 独占全屏返回，QQ 全屏手势让步
// （单向 requireToFail，无死锁）；纵向滑动时 panG 在 handleGlobalPan 判定非横向后自取消→QQ 可正常触发（但不返回）。
// 仅 QQ/TIM：_linkNavPopGesturesInWindow（链接时机）与 _globalPanShouldBegin（懒补链）两处调用，其他 App 路径零改动。
// [2026-08-06] 判断是否为 QQ 单条消息「左滑引用 / 快速回复」手势。这些手势贴在聊天列表 cell 上，
// 若被全屏返回压制（禁用或 requireToFail 抢赢）会导致引用失效；应让 panG 让步于它们，由 App 原生处理引用。
- (BOOL)_isQQQuotePan:(UIPanGestureRecognizer *)g {
    NSString *cls = NSStringFromClass([g class]);
    NSArray *quoteKw = @[@"SwipeAction", @"QuickReply"];
    for (NSString *kw in quoteKw) {
        if ([cls rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

// [2026-08-08 修复 文本选择/光标] 识别 QQ 聊天里文本选择(_UIMultiSelectOneFingerPanGesture)、
// 光标/loupe(_UIPanOrFlickGestureRecognizer) 及文本视图(UITextView/UITextField)上的 pan：
// 这些手势被 Oback 一锅端压制会导致「选字后无法移动光标/复制」。返回 YES 时 Oback 应放行（不压制、让其独占）。
- (BOOL)_isQQTextOrSelectionPan:(UIPanGestureRecognizer *)g {
    Class multiSelCls = NSClassFromString(@"_UIMultiSelectOneFingerPanGesture");
    Class flickCls = NSClassFromString(@"_UIPanOrFlickGestureRecognizer");
    if ((multiSelCls && [g isKindOfClass:multiSelCls]) ||
        (flickCls && [g isKindOfClass:flickCls])) return YES;
    if (g.view && ([g.view isKindOfClass:[UITextView class]] || [g.view isKindOfClass:[UITextField class]])) return YES;
    return NO;
}

// [2026-08-09] QQ 聊天「多选范围拖拽」手势(_UIMultiSelectOneFingerPanGesture)：覆盖整个聊天区(含返回热区)，
// Oback 必须赢它(不能让路/不能死锁)，故单独识别、不放进 _isQQYieldPan。
- (BOOL)_isQQMultiselectPan:(UIPanGestureRecognizer *)g {
    Class multiSelCls = NSClassFromString(@"_UIMultiSelectOneFingerPanGesture");
    return (multiSelCls && [g isKindOfClass:multiSelCls]);
}
// [2026-08-08/09 修复 文本选择/光标/元宝总结左滑] 这些局部手势被 Oback 全屏 pan 抢识别会破坏对应交互；
// 返回 YES 时让 panG 在 shouldBeRequiredToFailBy 中单向让路（不压制、不接管）。
// [2026-08-09] 不含 multiselect：多选范围拖拽覆盖全屏(含返回热区)，Oback 必须赢它，不让路。
- (BOOL)_isQQYieldPan:(UIPanGestureRecognizer *)g {
    if ([self _isQQMultiselectPan:g]) return NO;                 // 多选范围拖拽：Oback 赢，不让路
    Class flickCls = NSClassFromString(@"_UIPanOrFlickGestureRecognizer");
    if (flickCls && [g isKindOfClass:flickCls]) return YES;      // 光标/loupe
    if (g.view && ([g.view isKindOfClass:[UITextView class]] || [g.view isKindOfClass:[UITextField class]])) return YES;
    Class dragHandleCls = NSClassFromString(@"_UIDragHandleGestureRecognizer");
    if (dragHandleCls && [g isKindOfClass:dragHandleCls]) return YES;   // 蓝色选择手柄拖拽
    Class ybCls = NSClassFromString(@"NTAISummaryFloatEar");
    if (ybCls && g.view && [g.view isKindOfClass:ybCls]) return YES;          // 元宝浮耳拖拽
    Class swipeCls = NSClassFromString(@"NTDiffableListKit.NTSwipeSpringAnimationContainerView");
    if (swipeCls && g.view && [g.view isKindOfClass:swipeCls]) return YES;    // 消息左滑(引用/回复/元宝总结)
    return NO;
}

- (void)_obLinkFullScreenOpponentPansInWindow:(UIWindow *)win {
    UIPanGestureRecognizer *globalPan = nil;
    for (UIGestureRecognizer *g in win.gestureRecognizers) {
        if (g.delegate == self && objc_getAssociatedObject(g, kGlobalPanKey)) {
            if ([g isKindOfClass:[UIPanGestureRecognizer class]]) { globalPan = (UIPanGestureRecognizer *)g; break; }
        }
    }
    if (!globalPan) return;
    // UIScrollViewPanGestureRecognizer 是 UIKit 私有类，公共 SDK 头未声明 → 用 NSClassFromString 运行时取，避免编译失败
    Class scrollPanCls = NSClassFromString(@"UIScrollViewPanGestureRecognizer");
    // [2026-08-06 修复 QQ 原生全屏返回抢先 pop 致瞬返] QQ 的 NTPushPopLib 全屏返回手势可能挂在
    // 与 Oback panG 不同的 UIWindow（overlay window）上，原仅枚举 globalPan 所在 window 的 subview 树
    // 会漏掉它 → 从未被 requireToFail 压制 → Oback Began 后 QQ 原生不 fail、抢先吞 touch 并 pop
    // （interacting=0 → ObackNavDelegate 返回 nil → 走 NTPushPopLib 瞬返）。改为枚举所有可见 window 的
    // pan 一并压制（跨 window 的 requireToFail 依赖对 UIKit 有效）。
    NSArray *windows = nil;
    @try {
        if (@available(iOS 13.0, *)) {
            NSMutableArray *arr = [NSMutableArray array];
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    [arr addObjectsFromArray:((UIWindowScene *)scene).windows];
                }
            }
            windows = arr;
        }
        if (!windows || windows.count == 0) {
            // 兜底：connectedScenes 为空时的旧 API（弃用，仅作安全网，用 pragma 压掉 -Werror 告警）
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            windows = [[UIApplication sharedApplication] windows];
            #pragma clang diagnostic pop
        }
    } @catch (NSException *e) { windows = nil; }
    if (!windows || windows.count == 0) windows = @[win];
    for (UIWindow *w in windows) {
        if (!w) continue;
        [self _enumeratePansInView:w depth:0 block:^(UIPanGestureRecognizer *g){
            if (g.delegate == self) return;            // 跳过 Oback 自己的 pan（避免自引用）
            // [2026-08-09 修复 文本选择蓝色手柄拖不动] 光标loupe/文本视图/元宝浮耳/消息左滑/选择手柄等
            // 局部交互手势不被强制失败于 Oback 全局 pan(否则 Oback 一旦 begin 即抢走 touch, 手柄/光标拖不动)。
            // 交由 shouldBeRequiredToFailBy 动态仲裁(Oback 失败于它们；返回热区内仍保返回)。
            // 注：multiselect 不在 _isQQYieldPan 内，仍落到下方强制失败分支(保证返回从任意位置有效)。
            if ([self _isQQYieldPan:g]) { return; }
            // [2026-08-06 修复①] 单条消息左滑引用/快速回复手势（SwipeAction/QuickReply）：
            // 不应被压制，而要让 panG 让步于它——左滑引用时它独占，右滑返回时它不 begin → panG 照常驱动返回。
            if ([self _isQQQuotePan:g]) {
                @try { [globalPan requireGestureRecognizerToFail:g]; } @catch (NSException *e) {}
                return;
            }
            // [2026-08-07 修复 元宝AI总结浮耳滑不出] 浮耳(NTAISummaryFloatEar)是独立拖拽手势：
            // 不能让它失败于 Oback（否则 Oback 接管时浮耳被强制 fail → 拖不动总结），改为让 Oback 全屏 pan
            // 失败于浮耳——用户滑浮耳时浮耳独占拖拽、Oback 让出（与引用手势同模式，单向无死锁）。
            // 配合 _suppressQQNativePopForNav: 已排除禁用浮耳，浮耳可正常工作。
            Class ybCls = NSClassFromString(@"NTAISummaryFloatEar");
            if (ybCls && g.view && [g.view isKindOfClass:ybCls]) {
                @try { [globalPan requireGestureRecognizerToFail:g]; } @catch (NSException *e) {}
                return;
            }
            // [2026-08-08 修复 文本选择/光标] 光标/loupe(_UIPanOrFlickGestureRecognizer) 及文本视图上的 pan：
            // Oback 让步（失败于它们），不在压制里禁用，否则聊天里选字/移动光标被吞。
            // 注：消息列表的 _UIMultiSelectOneFingerPanGesture 不在此设静态 requireToFail——它铺满整个
            // 聊天区(含左缘返回热区)，静态让路会在「从左缘起滑返回」时误让路给选择手势导致返回偶尔失效；
            // 改由 gestureRecognizer:shouldBeRequiredToFailBy 动态仲裁(返回热区内不让路，保全局返回)。
            Class flickCls = NSClassFromString(@"_UIPanOrFlickGestureRecognizer");
            BOOL isLoupe = (flickCls && [g isKindOfClass:flickCls]);
            BOOL isText = (g.view && ([g.view isKindOfClass:[UITextView class]] || [g.view isKindOfClass:[UITextField class]]));
            if (isLoupe || isText) {
                @try { [globalPan requireGestureRecognizerToFail:g]; } @catch (NSException *e) {}
                return;
            }
            // [2026-08-08 修复 元宝总结左滑] 消息左滑手势(NTDiffableListKit.NTSwipeSpringAnimationContainerView)
            // 用于触发引用/回复/元宝总结等；左滑永非全局返回（全局返回是右滑），Oback 一律让步（失败于它），
            // 让其独占拖拽，解决「元宝总结滑不出」（见用户反馈）。
            Class swipeCls = NSClassFromString(@"NTDiffableListKit.NTSwipeSpringAnimationContainerView");
            if (swipeCls && g.view && [g.view isKindOfClass:swipeCls]) {
                @try { [globalPan requireGestureRecognizerToFail:g]; } @catch (NSException *e) {}
                return;
            }
            // [2026-08-06 修复③ 纵滚死 + 快滑瞬闪] 不再用 requireToFail 让 scroll 与全屏 pan 二选一：
            // 二选一会让纵滑时 scroll 被压制（panG 抢首发 touch，判纵向取消后 scroll 也救不回 → 聊天不能上下滑）；
            // 且横滑聊天需「多帧确认横向占优」才接管，快滑在确认前松手 → QQ 原生 NTPushPopLib 抢 pop → 瞬闪。
            // 改为：scroll 与全屏 pan 同时识别（gestureRecognizer:shouldRecognizeSimultaneouslyWithGestureRecognizer:
            // 对「全屏 pan + scrollPan」返回 YES），由 handleGlobalPan 的方向判定决定接管/交还——
            //  · 纵滑：panG 与 scroll 同时 begin，panG 判纵向取消、scroll 继续滚（不返回，不卡死）；
            //  · 横滑聊天：panG 判横向占优即接管返回，set cancelsTouchesInView=YES 吞 scroll 后续。
            // 图片查看器横滑由 _globalPanShouldBegin 的 _scrollViewIsHorizontallyScrollableAtPoint 提前 return NO 拦截，
            // 全屏 pan 根本不 begin，故不会与图片查看器 scroll 同时识别（无瞬触返回）。
            BOOL isScroll = (scrollPanCls && [g isKindOfClass:scrollPanCls]);
            if (isScroll) {
                // [2026-08-06 修复③ 纵滚死+快滑瞬闪·仅 QQ/TIM] QQ/TIM 全屏：scroll 与 panG 同时识别（见
                // gestureRecognizer:shouldRecognizeSimultaneouslyWithGestureRecognizer: 对「全屏 pan + scrollPan」返回 YES），
                // 由 handleGlobalPan 方向判定接管/交还，取代 requireToFail 二选一（二选一会让纵滑时 scroll 被压制 →
                // 聊天不能上下滑）。其他 App 保持原 scroll 让步 panG（[g requireToFail:globalPan]，已验证无回归）。
                if ([self _navPopShouldUseObackAnimator:nil]) return;   // QQ/TIM：交给 simultaneous 协调
                [g requireGestureRecognizerToFail:globalPan];           // 其他 App：scroll 让步 panG
                return;
            }
            @try { [g requireGestureRecognizerToFail:globalPan]; } @catch (NSException *e) {}  // 其余 QQ 全屏返回手势失败于 panG
        }];
    }
    if ([ObackPreferences doubleReturnDiagEnabled]) {
        NSMutableArray *all = [NSMutableArray array];
        NSMutableArray *opp = [NSMutableArray array];
        for (UIWindow *w in windows) {
            if (!w) continue;
            [self _enumeratePansInView:w depth:0 block:^(UIPanGestureRecognizer *g){
                BOOL isSelf = (g.delegate == self);
                BOOL isScroll = (scrollPanCls && [g isKindOfClass:scrollPanCls]);
                [all addObject:[NSString stringWithFormat:@"%@@%@%@%@",
                                NSStringFromClass([g class]), NSStringFromClass([g.view class]),
                                isSelf ? @"[Oback]" : @"", isScroll ? @"★scroll" : @""]];
                if (isSelf) return;                 // 跳过 Oback 自己的 pan
                [opp addObject:[NSString stringWithFormat:@"%@@%@%@",
                                NSStringFromClass([g class]), NSStringFromClass([g.view class]),
                                isScroll ? @"★scroll" : @""]];
            }];
        }
        OBLog(@"diag[全屏链接] panG=%@ 命中；全窗口 pan 共 %lu → %@",
              NSStringFromClass([globalPan.view class]), (unsigned long)all.count, all);
        OBLog(@"diag[全屏链接] 其中「非 Oback 非 scroll」对手 pan 共 %lu → %@",
              (unsigned long)opp.count, opp);
    }
}

// —— [2026-08-06 根治 QQ/TIM 原生 NTPushPopLib 抢先 pop 致瞬返] ——
// requireToFail 跨 window 对 QQ 原生全屏返回手势不可靠（原生 pan 挂独立 overlay window 且抢跑，
// Oback panG Began 后 QQ 原生仍抢先 popViewControllerAnimated:，Oback 因竞争 self-cancel 致 interacting=0 走原生瞬返）。
// 故改为：Oback panG Began 接管时直接禁用 QQ 原生全屏返回 pan，使其收不到本轮触摸，Oback 独占驱动 pop；
// 手势结束/取消时 _restoreQQNativePop 恢复。仅对 QQ/TIM 生效（其他 App 不调此方法），零回归。
static const void *kSuppressedQQPansKey = &kSuppressedQQPansKey;

- (void)_suppressQQNativePopForNav:(UINavigationController *)nav {
    if (![self _navPopShouldUseObackAnimator:nav]) return;
    if (!nav || nav.viewControllers.count <= 1) return;
    NSHashTable *suppressed = objc_getAssociatedObject(self, kSuppressedQQPansKey);
    if (!suppressed) {
        // [2026-08-07 修复 悬垂指针崩溃] 原 NSMutableSet 装 NSValue(nonretainedObjectValue:)，
        // pan 释放后 nonretainedObjectValue 不归零，0.12s 后 dispatch_after 回调里 g.enabled
        // 向野指针发消息 → EXC_BAD_ACCESS(QQ/TIM 专属)。改用弱引用表：pan 一 dealloc 条目自动
        // 抹除，恢复循环再也见不到死对象。MRC 下由 NSHashTable 托管弱引用，不引入新泄漏。
        suppressed = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(self, kSuppressedQQPansKey, suppressed, OBJC_ASSOCIATION_RETAIN);
    }
    Class scrollPanCls = NSClassFromString(@"UIScrollViewPanGestureRecognizer");
    // 枚举所有可见 window 的 pan（含 overlay window 上的 QQ 原生 pan）
    NSArray *windows = nil;
    @try {
        if (@available(iOS 13.0, *)) {
            NSMutableArray *arr = [NSMutableArray array];
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]])
                    [arr addObjectsFromArray:((UIWindowScene *)scene).windows];
            }
            windows = arr;
        }
        if (!windows || windows.count == 0) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            windows = [[UIApplication sharedApplication] windows];
            #pragma clang diagnostic pop
        }
    } @catch (NSException *e) { windows = nil; }
    if (!windows || windows.count == 0) windows = @[];
    for (UIWindow *w in windows) {
        if (!w) continue;
        [self _enumeratePansInView:w depth:0 block:^(UIPanGestureRecognizer *g){
            if (g.delegate == self) return;                       // 跳过 Oback 自己的 pan
            if (scrollPanCls && [g isKindOfClass:scrollPanCls]) return;  // 跳过 scrollView 的 pan
            if ([self _isQQQuotePan:g]) return;                   // 左滑引用/快速回复手势：禁用会破坏引用，放行
            Class ybCls = NSClassFromString(@"NTAISummaryFloatEar");
            if (ybCls && g.view && [g.view isKindOfClass:ybCls]) return;  // 元宝AI总结浮耳：禁用会破坏拖拽关闭，放行
            // [2026-08-08 修复 文本选择/光标] 文本选择/光标/loupe 及文本视图 pan：放行，不压制（否则选字后无法移动光标）
            if ([self _isQQTextOrSelectionPan:g]) return;
            // [2026-08-08 修复 元宝总结左滑] 消息左滑手势容器：放行，不压制（让左滑触发引用/回复/元宝总结）
            Class swipeCls = NSClassFromString(@"NTDiffableListKit.NTSwipeSpringAnimationContainerView");
            if (swipeCls && g.view && [g.view isKindOfClass:swipeCls]) return;
            NSString *cls = NSStringFromClass([g class]);
            // 命中条件①：类名含 PushPop（QQ 原生 NTPushPopLib 系列手势，跨 window 也抓得到）
            BOOL isQQPop = [cls rangeOfString:@"PushPop" options:NSCaseInsensitiveSearch].location != NSNotFound;
            // 命中条件②：贴在 nav.view 树上、非 scroll 非 Oback 的全屏 pan（QQ 原生 pop 通常挂 nav.view）
            BOOL onNav = (g.view && [g.view isDescendantOfView:nav.view]);
            if (!isQQPop && !onNav) return;
            if (!g.enabled) return;
            g.enabled = NO;
            [suppressed addObject:g];
            OBLog(@"[QQ 原生 pop 压制] 禁用 %@ (view=%@)", cls, NSStringFromClass([g.view class]));
        }];
    }
    // [2026-08-06 根治 QQ 原生 pop 漏禁] 同时禁用系统 interactivePopGestureRecognizer
    // （_UIParallaxTransitionPanGestureRecognizer@UILayoutContainerView）。它挂在 nav.view 自身（非 descendant），
    // 上方 onNav 判定 isDescendantOfView 对其返回 NO → 漏禁；QQ/TIM 用它做原生边缘返回（瞬返动画），
    // Oback 接管时应一并禁用，由 Oback 独占驱动 pop，杜绝瞬返。
    UIGestureRecognizer *sysPop = nav.interactivePopGestureRecognizer;
    if (sysPop && [sysPop isKindOfClass:[UIPanGestureRecognizer class]] && sysPop.enabled) {
        sysPop.enabled = NO;
        [suppressed addObject:sysPop];
        OBLog(@"[QQ 原生 pop 压制] 禁用 %@ (view=%@)", NSStringFromClass([sysPop class]), NSStringFromClass([sysPop.view class]));
    }
    // 诊断：列出所有「非 Oback 非 scroll」pan 候选（类名+view），便于万一未命中时精准定位 QQ 原生 pan 真实身份
    if ([ObackPreferences doubleReturnDiagEnabled]) {
        NSMutableArray *cand = [NSMutableArray array];
        for (UIWindow *w in windows) {
            if (!w) continue;
            [self _enumeratePansInView:w depth:0 block:^(UIPanGestureRecognizer *g){
                if (g.delegate == self) return;
                if (scrollPanCls && [g isKindOfClass:scrollPanCls]) return;
                [cand addObject:[NSString stringWithFormat:@"%@@%@", NSStringFromClass([g class]), NSStringFromClass([g.view class])]];
            }];
        }
        OBLog(@"diag[QQ pop 候选] 非 Oback 非 scroll pan → %@", cand);
    }
}

- (void)_restoreQQNativePop {
    NSHashTable *suppressed = objc_getAssociatedObject(self, kSuppressedQQPansKey);
    if (!suppressed || suppressed.count == 0) return;
    NSUInteger n = suppressed.count;
    for (UIPanGestureRecognizer *g in suppressed) {
        // 弱引用表已自动剔除 dealloc 的 pan；此处 g 必为存活对象，安全启用
        if (g) g.enabled = YES;
    }
    [suppressed removeAllObjects];
    OBLog(@"[QQ 原生 pop 压制] 已恢复 %lu 个手势", (unsigned long)n);
}

- (void)_restoreQQNativePopDeferred {
    // [2026-08-06 修复 瞬闪] Oback 取消/结束时延后恢复 QQ 原生 pan：QQ/TIM 下 cancelsTouchesInView=NO
    // 使原生同步接收 touch，若立即恢复原生会基于已收到的 touch 历史瞬间判定 pop → 顺闪。
    // 延后一帧并确认 Oback 未再次接管(interacting)后才恢复，避免原生抢回本次手势会话。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.interacting) return;   // Oback 又接管（新一次滑动），不恢复，保持原生禁用让 Oback 独占
        [self _restoreQQNativePop];
    });
}

// 全屏懒补链：仅当近期未做过全屏链接（2s 节流）时才扫描对手 pan（治 QQ 聊天「进会话后懒加载」的晚到全屏手势）。
- (void)_obLinkFullScreenOpponentPansIfStale:(UIWindow *)win {
    static NSTimeInterval __lastFullLinkTS = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - __lastFullLinkTS < 2.0) return;
    __lastFullLinkTS = now;
    [self _obLinkFullScreenOpponentPansInWindow:win];
}

// 左缘懒补链：仅当近期未做过左缘链接（2s 节流）时才扫描对手 pan。
// 链接是「持久依赖」：一旦 requireToFail 建立便一直生效，故此处只为「发现晚到的新手势」，
// 不必每次滑动都全树遍历。左缘 begin 频率极低，全局 2s 节流足够且不会跨 App 互相饿死。
- (void)_obLinkLeftEdgeOpponentPansIfStale:(UIWindow *)win {
    static NSTimeInterval __lastLeftLinkTS = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - __lastLeftLinkTS < 2.0) return;
    __lastLeftLinkTS = now;
    [self _obLinkLeftEdgeOpponentPansInWindow:win];
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
    if (self.interacting) { OBLog(@"shouldBegin=NO (已在交互中)"); return NO; }
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
        OBLog(@"[diag-left-nav] kind=nav nav=%@ top=%@ presenting=%d childCount=%lu",
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
        BOOL useOBAnimator = [self _navPopShouldUseObackAnimator:nav];
        self.navPopUseObackAnimator = useOBAnimator;
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
        // [QQ/TIM 自研转场 nav] 覆盖为 ObackAnimator 自定义交互 pop（跟手）：左右缘都走自定义，
        // 不碰 rightSimplePop 也不走方案A（方案A 喂不进 NTPushPopLib 等自研转场 → 瞬返）。
        if (useOBAnimator) {
            self.currentParallaxToView = NO;
            self.rightSimplePop = NO;
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
    // 对手 pan 链接（2s 节流，仅抓晚到的新手势），确保右缘 Oback 独占、中间仍归 QQ。
    // [2026-08-05 QQ/TIM 左缘根治] 左缘同等处理：仅 QQ/TIM（navPopUseObackAnimator=YES）在左缘 begin 时
    // 补链，压住 NTPushPopLib 左缘自定义手势，使左缘 Oback 独占、与右缘表现一致；其他 App 左缘不补链、
    // 路径零改动。
    if (edge == ObackEdgeRight) {
        [self _obLinkRightEdgeOpponentPansIfStale:win];
    } else if (edge == ObackEdgeLeft && self.navPopUseObackAnimator) {
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
// [2026-08-06 修复 QQ/TIM 全局返回瞬返] 递归解析窗口内「顶层可见 UINavigationController」，
// 用于全局返回开启、nav.view 边缘 pan 未挂载（不携带 kObackNavKey）时，给全屏 pan 兜底解析 nav 栈深。
// 兼容 QQ/TIM 自定义容器：topMost 拿不到 nav.navigationController 时，直接搜 VC 树里的 UINavigationController。
- (UINavigationController *)_topNavControllerInWindow:(UIWindow *)win {
    return [self _topNavFromVC:win.rootViewController depth:0];
}
- (UINavigationController *)_topNavFromVC:(UIViewController *)vc depth:(NSUInteger)depth {
    if (!vc || depth > 24) return nil;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)vc;
        UIViewController *top = nav.visibleViewController ?: nav.topViewController;
        if (top && top != vc) {
            UINavigationController *deeper = [self _topNavFromVC:top depth:depth + 1];
            if (deeper) return deeper;   // 优先返回更深（被 push / present）的 nav
        }
        return nav.viewControllers.count > 0 ? nav : nil;
    }
    if ([vc isKindOfClass:[UITabBarController class]])
        return [self _topNavFromVC:((UITabBarController *)vc).selectedViewController depth:depth + 1];
    if (vc.presentedViewController)
        return [self _topNavFromVC:vc.presentedViewController depth:depth + 1];
    for (UIViewController *child in vc.childViewControllers) {
        UINavigationController *n = [self _topNavFromVC:child depth:depth + 1];
        if (n) return n;
    }
    return nil;
}

- (BOOL)_globalPanShouldBegin:(UIPanGestureRecognizer *)pan {
    // [2026-08-09] 新一轮识别开始，先清掉上一轮的「选择手势同时识别」标志，避免残留导致返回被误短路
    objc_setAssociatedObject(self, kYieldActiveKey, @(NO), OBJC_ASSOCIATION_RETAIN);
    if (self.interacting) { OBLog(@"globalShouldBegin=NO (已在交互中)"); return NO; }
    [self _restoreQQNativePop];   // 清扫上一轮可能残留的禁用（保险；正常路径已在 End/Cancel 恢复，空集合时无日志）
    if (![ObackPreferences isAllowed]) return NO;
    if (![ObackPreferences isGlobalBackEnabled]) return NO;
    UIWindow *win = [self _windowForPan:pan];
    CGPoint loc = [pan locationInView:win];
    CGFloat w = win.bounds.size.width;
    if (w <= 0) return NO;
    // 热区按触发侧：左手侧(默认)=左侧约 1/3 起滑；右手侧=右侧约 1/4 起滑（薄热区，类似边缘手势插件）。
    // 对侧起滑一律交还系统/App 原生（全局返回 App 的 Oback 右缘已禁用）。
    BOOL rightSide = [ObackPreferences isGlobalBackRightSide];
    if ([self _navPopShouldUseObackAnimator:nil]) {
        // [2026-08-05 QQ/TIM] QQ 聊天界面「任意位置」都能触发全屏返回手势，故 Oback 全屏 pan 在
        // QQ/TIM 内取消热区限制，任意位置起滑都允许识别；是否真正接管由 handleGlobalPan 横向判定决定。
        // 否则中间/右侧滑不在左热区→Oback 不 begin→QQ 原生全屏手势抢接管→瞬返。
        OBLog(@"globalShouldBegin: QQ/TIM 全屏 pan 不限热区（任意位置允许）");
        [self _obLinkFullScreenOpponentPansInWindow:win];   // QQ/TIM 全屏对手压制：枚举所有 window 的对手 pan（含 overlay window 上的 QQ 全屏返回手势）建立 requireToFail
        // [2026-08-08 修复 文本选择蓝色手柄拖不动] Oback 全屏 pan 在 QQ/TIM 内任意触摸都 begin，即使
        // shouldBeRequiredToFailBy 让路，与文本选择蓝色手柄拖拽手势抢识别仍导致手柄拖不动。治本：检测到
        // 当前有「活动文本选择」(蓝手柄/放大镜视图存在 或 文本视图有非空选中范围)时直接不让 Oback 全屏
        // pan begin——彻底不进入识别/仲裁，把选择拖拽手势让出来。选择态是瞬态(点别处即消失)，不会长期禁用
        // 全局返回；非选择态下元宝浮耳拖拽不受影响。
        if ([self _activeTextSelectionInWindow:win]) {
            OBLog(@"globalShouldBegin=NO (文本选择/光标激活中, 交还选择拖拽)");
            return NO;
        }
        // [2026-08-06 修复 元宝AI总结浮层滑不出] 触摸落在元宝总结浮耳(NTAISummaryFloatEar)上时交还，
        // 让浮耳自身拖拽手势处理关闭；否则 Oback 接管并禁用其 pan 会导致总结滑不出（见 oback_debug(20).log）。
        Class ybCls = NSClassFromString(@"NTAISummaryFloatEar");
        if (ybCls) {
            // [2026-08-08 修复 元宝检测坐标错位(二次)] 上版用 hitTest + yb.bounds 由 window 本地坐标换算，
            // 对 QQ overlay window 仍算错(oback_debug(22): 浮耳found=YES→未命中)。改用「浮耳自身屏幕帧」
            // [yb convertRect:yb.bounds toView:nil] 比对屏幕触摸点 sp：convertRect:toView:nil 经完整视图层级
            // 转绝对屏幕坐标，跨任意 window/transform 都准，且不受透明覆盖层拦截 hitTest 影响。
            CGPoint sp = [win convertPoint:loc toView:nil];   // nil=屏幕坐标系，跨 window 桥接基准
            NSArray *ywins = nil;
            @try {
                if (@available(iOS 13.0, *)) {
                    NSMutableArray *arr = [NSMutableArray array];
                    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                        if ([scene isKindOfClass:[UIWindowScene class]])
                            [arr addObjectsFromArray:((UIWindowScene *)scene).windows];
                    }
                    ywins = arr;
                }
                if (!ywins || ywins.count == 0) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
                    ywins = [[UIApplication sharedApplication] windows];
                    #pragma clang diagnostic pop
                }
            } @catch (NSException *e) { ywins = nil; }
            if (!ywins || ywins.count == 0) ywins = @[win];
            BOOL hitEar = NO;
            NSMutableString *diag = nil;
            if ([ObackPreferences doubleReturnDiagEnabled]) diag = [NSMutableString string];
            // [2026-08-08 修复 元宝检测坐标错位(三次)] 收拢态浮耳 frame 宽度=0 且贴右缘(x=screenW)，
            // 上版用 [yb convertRect:bounds toView:nil] 做 CGRectContainsPoint 对零宽 rect 恒失败
            // (oback_debug(23): ear frame=(390,210,0,36)，真实触摸 x≤389 永远落在外侧)。
            // 改：以浮耳中心为锚点扩展「可握持热区」(右缘收拢态锚定 x=screenW 向左扩展)，
            // 另加「右缘 100pt 内直接让路」兜底层——浮耳在右缘、全局返回在左缘互不冲突，
            // 右缘交给 QQ 原生手势(浮耳拖拽/消息左滑)处理绝不影响返回。
            CGFloat W = [UIScreen mainScreen].bounds.size.width;
            CGFloat rightBandX = W - 100.0;
            BOOL earExists = NO;
            for (UIWindow *yw in ywins) {
                if (!yw) continue;
                UIView *yb = [self _yuanbaoSummaryViewIn:yw cls:ybCls];
                if (!yb) continue;
                earExists = YES;
                CGRect earScreen = CGRectZero;
                @try { earScreen = [yb convertRect:yb.bounds toView:nil]; } @catch (NSException *e) { earScreen = CGRectZero; }
                CGFloat cx = CGRectGetMidX(earScreen);
                CGFloat cy = CGRectGetMidY(earScreen);
                if (earScreen.size.width < 8.0) cx = W;            // 收拢态：锚定右缘
                CGFloat halfW = 64.0, halfH = 120.0;              // 可握持热区(覆盖拇指够到的范围)
                CGRect hit = CGRectMake(cx - halfW, cy - halfH, halfW*2, halfH*2);
                if (CGRectContainsPoint(hit, sp)) { hitEar = YES; }
                if (diag) [diag appendFormat:@" ear@%@ frame=(%.0f,%.0f,%.0f,%.0f) center=(%.0f,%.0f) sp=(%.1f,%.1f) rightBandX=%.0f;",
                                   NSStringFromClass([yw class]), earScreen.origin.x, earScreen.origin.y,
                                   earScreen.size.width, earScreen.size.height, cx, cy, sp.x, sp.y, rightBandX];
                if (hitEar) break;
            }
            // 兜底层：窗口存在浮耳且触摸落右缘 100pt 内，一律让路(覆盖浮耳被拖到非锚定纵向位置的情形)
            if (!hitEar && earExists && !rightSide && sp.x > rightBandX) hitEar = YES;
            if (hitEar) {
                OBLog(@"globalShouldBegin=NO (触摸落在元宝AI总结浮层, 交还浮耳拖拽关闭)");
                return NO;
            }
            // [2026-08-08 诊断] 未命中时记录浮耳屏幕帧与触摸点，确认坐标换算是否已纠正
            if ([ObackPreferences doubleReturnDiagEnabled]) {
                OBLog(@"[元宝诊断] loc=(%.1f,%.1f) sp屏幕=(%.1f,%.1f) 未命中(earExists=%@);%@",
                      loc.x, loc.y, sp.x, sp.y, earExists ? @"YES" : @"NO", diag ? diag : @"");
            }
        }
    } else {
        // 仅 QQ/TIM 外保留窄热区（全局返回默认左 1/3 / 右 1/4 薄热区），避免误吞 App 内横向手势。
        if (rightSide) {
            if (loc.x < w * 3.0 / 4.0) { OBLog(@"globalShouldBegin=NO (非右热区 x=%.1f w=%.1f)", loc.x, w); return NO; }
        } else {
            if (loc.x > w / 3.0) { OBLog(@"globalShouldBegin=NO (非左热区 x=%.1f w=%.1f)", loc.x, w); return NO; }
        }
    }
    __block UINavigationController *nav = objc_getAssociatedObject(pan, kObackNavKey);
    UIViewController *top = nil;
    if (nav) top = nav.topViewController;
    if (!top) {
        top = [self topMost:win.rootViewController];
        nav = top.navigationController;
        if (!nav && [top isKindOfClass:[UINavigationController class]]) nav = (UINavigationController *)top;
    }
    // [2026-08-06 QQ/TIM 全屏返回根治] QQ 聊天 VC 常嵌自定义容器，top.navigationController 为 nil
    // （topMost 解析不到 nav）→ shouldBegin 一直 NO → panG 不 begin → QQ 原生全屏手势瞬返。
    // 边缘手势因 swizzle 时已用 kObackNavKey 关联 QQNavigationController 而跟手；此处兜底借用同 window 上
    // Oback 边缘 pan 已关联的 nav，使全屏 pan 也能解析到当前 nav 栈深（列表=1 不接管、聊天=2 接管）。
    if (!nav && [self _navPopShouldUseObackAnimator:nil]) {
        [self _enumeratePansInView:win depth:0 block:^(UIPanGestureRecognizer *g){
            if (g == pan) return;
            if (g.delegate != self) return;
            UINavigationController *n = objc_getAssociatedObject(g, kObackNavKey);
            if (n && n.viewControllers.count > 0) { nav = n; }
        }];
        // [2026-08-06 修复] 全局返回开启时 _attachNavPanToNav 跳过 nav.view 边缘 pan（ObackManager.m:526），
        // 上方「借边缘 pan 的 kObackNavKey」落空 → nav 永远 nil → panG 不 begin → QQ 原生瞬返。
        // 兜底：递归窗口 VC 树解析顶层 UINavigationController（QQ/TIM 自定义容器 topMost 拿不到 nav）。
        if (!nav) nav = [self _topNavControllerInWindow:win];
        if (nav) {
            // [2026-08-06 崩溃修复] 原 OBJC_ASSOCIATION_ASSIGN：panG 挂 window 长期存活，nav 被 QQ 释放后
            // 指针悬空，下次手势取出访问 → KERN_INVALID_ADDRESS:0x10 SIGSEGV(见 QQ 崩溃日志)。
            // 改 RETAIN_NONATOMIC 短期持有(手势活跃期)，手势结束(handleGlobalPan State 分支/abortTransition)清空 → 无悬空/无泄漏。
            // 注：边缘 pan 的 kObackNavKey 仍保持 ASSIGN(安全：pan 挂 nav.view，pan 存活⊨nav 存活)。
            objc_setAssociatedObject(pan, kObackNavKey, nav, OBJC_ASSOCIATION_RETAIN_NONATOMIC);  // 写回，供 handleGlobalPan 取 nav 驱动 pop
            OBLog(@"global QQ/TIM: 解析 nav=%@ count=%lu",
                  NSStringFromClass([nav class]), (unsigned long)nav.viewControllers.count);
        }
    }
    if (!top) return NO;
    if ([self _isExcludedViewController:top]) return NO;
    // [2026-08-06 修复 图片查看器横滑误触返回] 仅 QQ/TIM：触摸点下横向可滚 scrollView 交还横滑（图片查看器 paging），
    // 避免全屏 pan 误吞返回。其他 App 不引入此交还（恢复原先全局返回体验），不影响纵向滚动。
    if ([self _navPopShouldUseObackAnimator:nil] &&
        [self _scrollViewIsHorizontallyScrollableAtPoint:loc inWindow:win]) {
        OBLog(@"globalShouldBegin=NO (QQ/TIM 横向可滚 scrollView, 交还图片查看器/横向分页横滑)");
        return NO;
    }
    // [2026-08-06 修正] QQ 抽屉浮层打开时交还关闭手势，但必须双签名（全屏半透明遮罩 + 贴左半屏面板）
    // 且触摸点在左 0.7 屏内，否则不拦截——避免聊天界面常驻的全屏半透明视图被误判为抽屉遮罩而让返回失效。
    // [2026-08-06 收窄] 仅 QQ/TIM 判定抽屉（其他 App 无 QQ 抽屉，此判定仅会误杀），做到"只针对 QQ"。
    if ([self _navPopShouldUseObackAnimator:nil] && [self _qqDrawerOpenInWindow:win] && loc.x < w * 0.7) {
        OBLog(@"globalShouldBegin=NO (QQ 侧边栏抽屉打开且触摸在左侧, 交还关闭手势)");
        return NO;
    }
    if (nav && nav.viewControllers.count > 1) {
        // 有 nav pop 可接管：允许识别。
        // [2026-08-07 根治无震动瞬返] 提前到 shouldBegin 即禁用 QQ 原生 pan（含 overlay window 上的 NTPushPopLib），
        // 消除「shouldBegin 已返回 YES、但 handleGlobalPan Began 才禁用」之间的间隙——该间隙里跨 window 原生 pan
        // 抢先 pop 即表现为「无震动瞬返」（见 :879 requireToFail 跨 window 不可靠）。handleGlobalPan Began 的
        // 压制保留为冗余安全网。
        if ([self _navPopShouldUseObackAnimator:nil]) [self _suppressQQNativePopForNav:nav];
        OBLog(@"globalShouldBegin=YES (loc.x=%.1f 有nav pop=%lu, QQ/TIM=%d)", loc.x,
              (unsigned long)nav.viewControllers.count, [self _navPopShouldUseObackAnimator:nil]);
        return YES;
    }
    return NO;  // 无 nav pop：不接管，交还（modal dismiss 由 Oback 右缘提供）
}

// 全屏 pan 处理：Began 仅记录起点、不驱动；Changed 首次有效位移判定方向——
// 向右且横向占优 → 确认接管 nav pop（交给已验证的 beginTransition/updateTransition/endTransition）；
// 向左/纵向 → 取消交还 App（防误吞滚动）。单一手势源，与左右缘 edge pan 完全隔离，杜绝双返回。
- (void)handleGlobalPan:(UIPanGestureRecognizer *)pan {
    // [2026-08-09 回归修复] 是否让路于「蓝色选择手柄拖拽」：基于手柄手势真实 state(Began/Changed) 判定，
    // 而非仅凭类名——手柄手势类常驻于文本视图(未拖拽时 state=Possible/Failed)，若按类名让路会误杀全局返回
    // (聊天消息即文本视图，任意滑返回都会被误判成"在拖手柄")。仅当手柄真在拖拽时才令 Oback 让路：
    // 不驱动返回转场，并恢复 globalShouldBegin 已压制的 QQ 原生 pop，把拖拽交还 QQ 原生处理选择/光标。
    if ([self _navPopShouldUseObackAnimator:nil] && [self _activeHandleDragInWindow:[self _windowForPan:pan]]) {
        objc_setAssociatedObject(self, kYieldActiveKey, @(YES), OBJC_ASSOCIATION_RETAIN);
    }
    if ([objc_getAssociatedObject(self, kYieldActiveKey) boolValue]) {
        UIGestureRecognizerState st = pan.state;
        if (st == UIGestureRecognizerStateEnded || st == UIGestureRecognizerStateCancelled ||
            st == UIGestureRecognizerStateFailed) {
            objc_setAssociatedObject(self, kYieldActiveKey, @(NO), OBJC_ASSOCIATION_RETAIN);
            // 让路结束：清扫本轮交互状态(镜像正常 End 收尾)，避免 interacting 残留挡住后续手势
            self.interacting = NO;
            _globalDriven = NO;
            [self dismissIndicatorSafety];
            if (objc_getAssociatedObject(pan, kGlobalPanKey)) {
                objc_setAssociatedObject(pan, kObackNavKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        // 让路：交还 QQ 原生处理选择/光标，恢复(若已)被压制的 QQ 原生 pop，避免其一直禁用
        if ([self _navPopShouldUseObackAnimator:nil]) [self _restoreQQNativePopDeferred];
        return;
    }
    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            _globalStart = [pan locationInView:[self _windowForPan:pan]];
            _globalDriven = NO;
            // [2026-08-06 收窄] 仅 QQ/TIM 在 Began 强制 cancelsTouchesInView=NO：全屏 pan 任意位置 begin 会吞 touch，
            // 致聊天列表无法上下滑；其他 App 不强制（沿用上轮复位值，已验证无回归），恢复原先全局返回手感。
            if ([self _navPopShouldUseObackAnimator:nil]) {
                pan.cancelsTouchesInView = NO;
            }
            self.interacting = YES;   // 占住，防其他 pan 同时在 shouldBegin 被放行
            // [2026-08-06 根治 QQ 原生 NTPushPopLib 抢先 pop] Began 即禁用 QQ 原生全屏返回 pan，
            // 使其收不到本轮触摸，Oback 独占驱动（不再依赖不可靠的跨 window requireToFail）；
            // 手势结束/取消时 _restoreQQNativePop 恢复。仅 QQ/TIM 且有可 pop 的 nav 时生效。
            if ([self _navPopShouldUseObackAnimator:nil]) {
                UINavigationController *nav = objc_getAssociatedObject(pan, kObackNavKey);
                if (nav && nav.viewControllers.count > 1) [self _suppressQQNativePopForNav:nav];
            }
            OBLog(@"handleGlobalPan Began (panView=%@, QQ/TIM=%d)", NSStringFromClass([[pan view] class]),
                  [self _navPopShouldUseObackAnimator:nil]);
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
            BOOL qqMode = [self _navPopShouldUseObackAnimator:nil];   // QQ/TIM 全屏：放宽纵向抖动容忍，防误杀返回手势致瞬返
            // 左手侧(默认)：从左侧热区起滑、向右滑(dx>0)=返回；右手侧：从右侧薄热区起滑、向左滑(dx<0)=返回。
            // currentEdge 随之设左/右缘，转场 dir 自动镜像（见 updateTransition/endTransition 的 dir 取值）。
            CGFloat backThresh = rightSide ? -30.0 : 30.0;   // [2026-08-08] 触发距离加长：防单手快滑聊天记录时误触返回
            BOOL movingBack  = rightSide ? (dx < backThresh) : (dx > backThresh);
            BOOL movingAway  = rightSide ? (dx > 6.0)      : (dx < -6.0);
            if (movingBack) {
                if (qqMode) {
                    // [2026-08-08] 仅当横向位移明显占优(水平>垂直)才接管：纯纵滑(看聊天记录)不会误触返回；
                    // 真实右滑返回本就横向占优，不影响跟手，也不回退瞬返修复(快滑在 dx>阈值且横向占优时即接管)。
                    if (fabs(dx) > fabs(dy)) {
                    // [2026-08-06 修复快滑瞬闪·仅 QQ/TIM] 一旦向返回方向移动(dx 超阈值)即接管，不等 velocity 横向占优——
                    // QQ 原生 NTPushPopLib 会抢 pop，快滑在确认占优前就松手/结束 → Oback 未接管 → QQ 原生抢 pop → 瞬闪。
                    // 纵滑因 dx 小不进此分支，由下方明显纵向 cancel 交还（scroll 经 simultaneous 继续滚，不卡死）。
                    _globalDriven = YES;
                    }
                } else {
                    // 其他 App：保持原 velocity 横向占优判定（1.69x），零回归
                    CGFloat vx = v.x;
                    if ((rightSide ? vx < 0 : vx > 0) && (vx * vx) > (v.y * v.y) * 1.69) {
                        _globalDriven = YES;
                    } else if (fabs(dy) > fabs(dx) * 1.5 && fabs(dy) > 12.0) {
                        [self _cancelGlobalPan:pan];
                    }
                }
                if (_globalDriven) {
                    OBLog(@"handleGlobalPan -> _globalDriven=YES（接管转场）；useOBAnimator=%d", [self _navPopShouldUseObackAnimator:nil]);
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
                    BOOL useOBAnimator = [self _navPopShouldUseObackAnimator:nav];
                    self.navPopUseObackAnimator = useOBAnimator;
                    self.currentParallaxToView = (stdNav && !useOBAnimator);
                    self.rightSimplePop = (!stdNav && !useOBAnimator);
                    self.currentEdge = rightSide ? ObackEdgeRight : ObackEdgeLeft;
                    [self beginTransition:pan];   // 驱动 nav pop + 显示胶囊（复用已验证转场链路）
                }
            } else if (movingAway || !qqMode || (fabs(dy) > fabs(dx) * 1.5 && fabs(dy) > 12.0)) {
                // 未向返回方向移动，或明显纵向为主(>12px 且 >1.5x 横向)：交还。QQ/TIM 全屏纵滚时 scroll 由
                // simultaneous 同时识别继续滚动（不返回，不卡死）；其他 App 即时交还。
                [self _cancelGlobalPan:pan];
            }
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            [self _restoreQQNativePopDeferred];   // 延后恢复 QQ 原生 pan（防本轮取消后原生抢回致瞬闪）
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
    [self _restoreQQNativePopDeferred];   // 延后恢复 QQ 原生 pan（防本轮取消后原生抢回致瞬闪）
    self.interacting = NO;
    _globalDriven = NO;
    [self dismissIndicatorSafety];
    pan.enabled = NO;
    pan.enabled = YES;
}

- (void)beginTransition:(UIPanGestureRecognizer *)pan {
    // 新手势开始：清空上一次松手速度/进度，避免遗留值串入本次动画
    self.releaseVelocity = 0;
    self.releasePercent  = 0;
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

    ObackParams *p = [ObackPreferences params];
    self.interactive = [[[ObackInteractiveTransition alloc] initWithEdge:self.currentEdge params:p] autorelease];
    self.interacting = YES;
    // [2026-07-29 误触修复 v2] 接管型 nav 真实滑动（rightSimplePop）期间吞掉底层触摸：UIKit 向底层 view
    // 及其手势识别器发 touchesCancelled，手指滑过的小程序卡片等不会被误触激活（松手不再 touchUpInside/选中）。
    // 方案 A（rightSimplePop=NO）保持 NO——系统原生交互转场自行处理 touch 取消，无需我们干预。
    // 直接按 rightSimplePop 定值（而非仅置 YES），确保每轮 begin 都确定性重设，不依赖上一轮 end/abort 的复位。
    // QQ/TIM 自定义转场同样需吞掉底层触摸（拖动中暴露的上一页元素不被误触），故一并纳入。
    pan.cancelsTouchesInView = NO;   // 兜底重置（纵向滑动已靠 handleGlobalPan Began 重置；此处再保险）
    if (self.rightSimplePop || self.navPopUseObackAnimator) {
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
              (int)[[nav.delegate class] isSubclassOfClass:NSClassFromString(@"ObackNavDelegate")]);
        if (self.navPopUseObackAnimator) {
            // QQ/TIM：自定义交互 nav pop（ObackAnimator 阴影渐隐，上一页 Identity），跟手，规避自研转场不跟手
            self.currentParallaxToView = NO;
            self.rightSimplePop = NO;
            OBLog(@"trigger: QQ/TIM nav pop 自定义 ObackAnimator，popViewControllerAnimated");
            [nav popViewControllerAnimated:YES];
        } else if (self.currentEdge == ObackEdgeRight) {
            // 右缘固定走自定义镜像转场：真正触发 pop，由 nav delegate(ObackNavDelegate) 返回
            // ObackAnimator（自定义转场）+ interactionController 返回 self.interactive 接管，
            // 后续 updateTransition 用 self.interactive updateWithPercent 做 scrub（不再喂
            // handleNavigationTransition:）。方向由 OBApplyParallax 的 edge 分支处理，正确无误。
            self.currentParallaxToView = YES;   // 右缘自定义镜像转场走 updateTransition 自定义 scrub 分支(1340)
            OBLog(@"trigger: nav pop 右缘自定义镜像转场，popViewControllerAnimated");
            [nav popViewControllerAnimated:YES];
        } else if (self.interacting) {
            // 方案 A：交互 pop 已在 beginTransition 通过 handleNavigationTransition: 启动，
            // 此处不再调用 popViewControllerAnimated:（否则会触发第二次转场/黑屏）。
            OBLog(@"trigger: nav pop 已启动(系统原生交互)，忽略重复 popViewControllerAnimated");
        } else {
            // 自定义 nav 视差(实验) 或 非交互兜底：真正触发 pop，由 nav delegate(ObackNavDelegate)
            // 返回 ObackAnimator（自定义转场）+ interactionController 返回 self.interactive 接管 scrub。
            self.currentParallaxToView = YES;   // 兜底分支走 updateTransition 自定义 scrub 分支(1345)
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
    // [2026-08-06 修复纵滚死] 全局返回全屏 pan（挂 UIWindow 的普通 UIPanGestureRecognizer，delegate=self）
    // 与 UIScrollView 的 pan 同时识别：取代 requireToFail 二选一（二选一会让纵滑时 scroll 被压制 →
    // 聊天不能上下滑）。方向接管/交还由 handleGlobalPan 判定。仅对 scrollPan 返回 YES；QQ 原生 pan /
    // 引用手势（非 scroll）不受影响（它们走 requireToFail）。
    Class scrollPanClsSim = NSClassFromString(@"UIScrollViewPanGestureRecognizer");
    BOOL gIsGlobal = (g.delegate == self && [g.view isKindOfClass:[UIWindow class]] && ![g isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]);
    BOOL oIsGlobal = (other.delegate == self && [other.view isKindOfClass:[UIWindow class]] && ![other isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]);
    if (gIsGlobal || oIsGlobal) {
        // 仅 QQ/TIM 全屏返回启用 simultaneous（其他 App 保持原 scroll 让步逻辑，零回归）
        if ([self _navPopShouldUseObackAnimator:nil]) {
            UIGestureRecognizer *global = gIsGlobal ? g : other;
            UIGestureRecognizer *theOther = (global == g) ? other : g;
            if (theOther.delegate != self && scrollPanClsSim && [theOther isKindOfClass:scrollPanClsSim]) return YES;
            // [2026-08-09 回归修复] 允许文本选择/光标/元宝/消息左滑与全屏 pan 同时识别(互不取消)。
            // 注意：不再在此处按"对手类名是手柄"无条件置 kYieldActiveKey —— 手柄手势类常驻于文本视图
            // (未拖拽时 state=Possible/Failed)，按类名让路会误杀全局返回(聊天消息即文本视图)。
            // 是否让路改由 handleGlobalPan 基于手柄手势真实 state(Began/Changed) 动态判定。
            if (theOther.delegate != self) {
                Class dragHandleCls = NSClassFromString(@"_UIDragHandleGestureRecognizer");
                BOOL isHandle = (dragHandleCls && [theOther isKindOfClass:dragHandleCls]);
                if (!isHandle) {
                    NSString *ocls = NSStringFromClass([theOther class]);
                    if ([ocls containsString:@"DragHandle"]) isHandle = YES;
                }
                if (isHandle) {
                    OBLog(@"simultaneously: 全屏 panG 与 %@ 同时识别(手柄；是否让路由 handleGlobalPan 按 state 判定)",
                          NSStringFromClass([theOther class]));
                    return YES;
                }
                if ([self _isQQYieldPan:(UIPanGestureRecognizer *)theOther]) return YES;
            }
        }
    }
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
    // [2026-08-08 修复 文本选择/光标/元宝总结左滑] 全屏 panG 在 QQ/TIM 内任意触摸都 begin，
    // shouldBegin 阶段才设 requireToFail 对已开始的本轮识别太晚兜不住、文本选择/元宝拖拽被吞。
    // 改用系统级仲裁：对手是文本选择/光标loupe/元宝浮耳拖拽/消息左滑时，panG 必须失败于它们 →
    // 这些手势独占拖拽，Oback 让路（单向无死锁：对手 delegate 非 self，不会反向要求 panG 失败）。
    if ([self _navPopShouldUseObackAnimator:nil]) {
        BOOL gIsGlobal = (g.delegate == self && [g.view isKindOfClass:[UIWindow class]] &&
                          ![g isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]);
        if (gIsGlobal) {
            // [2026-08-09] 多选范围拖拽(multiselect)覆盖整个聊天区含返回热区，Oback 必须赢它，
            // 不让路(否则与下方强制失败分支互锁→返回从任意位置失效)。让路仅限局部交互手势。
            if ([self _isQQMultiselectPan:(UIPanGestureRecognizer *)other]) {
                OBLog(@"shouldBeRequiredToFailBy: 全屏 panG 不让路于 multiselect(保返回从任意位置), 对手=%@", NSStringFromClass([other class]));
                return NO;
            }
            if ([self _isQQYieldPan:(UIPanGestureRecognizer *)other]) {
                // [2026-08-08 优化 文本选择/全局返回共存] 触摸落在全局返回热区(对应侧边缘 trig pt 内)时优先返回、不让路；
                // 其余位置(真正在文字上选字/移光标)才让路给文本选择/光标/元宝/消息左滑。
                BOOL rightSide = [ObackPreferences isGlobalBackRightSide];
                CGPoint p = [g locationInView:nil];
                CGFloat W = [UIScreen mainScreen].bounds.size.width;
                CGFloat trig = 40.0;   // 全局返回边缘热区(与 triggerWidth 默认一致)
                BOOL inBackZone = rightSide ? (p.x > W - trig) : (p.x < trig);
                if (inBackZone) {
                    OBLog(@"shouldBeRequiredToFailBy: 全屏 panG 在返回热区内不让路(保全局返回), 对手=%@", NSStringFromClass([other class]));
                    return NO;
                }
                OBLog(@"shouldBeRequiredToFailBy: 全屏 panG 让路于 %@ (文本选择/光标/元宝/消息左滑)",
                      NSStringFromClass([other class]));
                return YES;
            }
        }
    }
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
    // _transitionTriggered=YES（driveSystemNavPopBeginWithPan 第1190行），导致探测永不执行、
    // _navPopProbeFailed 恒为 NO、微信等自定义 nav 永远走方案A 而失效。现改用 _navPopProbed 单独门控，
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
        // 实验：自定义 nav 视差 scrub（同 modal 方案B 机制，驱动 animator 的 fractionComplete）
        if (self.interactive) [self.interactive updateWithPercent:p];
    } else if (self.currentParallaxToView) {
        // 方案 A：nav pop 用系统原生交互转场，直接把当前 pan 喂给 handleNavigationTransition: 做 scrub。
        // 探测失败(_navPopProbeFailed)已切非交互 pop，此处不再喂系统转场(避免冲突)，仅保留胶囊反馈。
        if (!_navPopProbeFailed) [self _callSystemNavPop:pan];
    } else {
        if (self.interactive) [self.interactive updateWithPercent:p];
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
        self.interactive = nil;
        self.currentAnimator = nil;
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

    // 记录松手时的前向速度/进度：
    // - 写回 manager 自身（供诊断 / 下次 beginTransition 清零逻辑参考）
    // - 同步写入当前动画器（forceFinishIfNeeded 用 OBApplyParallax 做归位动画时可能参考）
    self.releaseVelocity = vel;
    self.releasePercent  = _currentPercent;
    self.currentAnimator.releaseVelocity = vel;
    self.currentAnimator.releasePercent  = _currentPercent;

    // 动量投影：按当前速度再投影约 0.12s 的惯性滑行距离，避免"快滑却因瞬时位移小被取消"。
    // 真机日志显示用户多为快速内滑(percent 仅 0.23~0.37 就松手)，纯位移阈值会误判取消。
    CGFloat projected = _currentPercent;
    if (w > 0) projected += (vel * 0.12) / w;
    projected = MAX(0.0, MIN(1.0, projected));
    CGFloat effective = MAX(_currentPercent, projected);

    ObackParams *p = [ObackPreferences params];
    // 提交判定：① 实际/投影位移过阈值(含惯性)；② 纯高速甩动(即便几乎没拖动)
    // [2026-08-06 修复 QQ/TIM 轻滑即返] QQ/TIM 全屏任意位置接管，commitVelocity=400 太低 → 轻快划即返回。
    // 仅对 navPopUseObackAnimator(QQ/TIM 自定义转场)路径收紧门槛，不动 modal dismiss / 普通 App nav pop 手感。
    CGFloat commitRatio = p.commitRatio;
    CGFloat commitVelocity = p.commitVelocity;
    if (self.navPopUseObackAnimator) {
        commitRatio = MAX(commitRatio, 0.35);
        commitVelocity = MAX(commitVelocity, 650.0);
    }
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
        if (self.currentEdge == ObackEdgeRight) {
            // 实验：自定义 nav 视差收尾（同 modal 方案B 机制，含右缘固定自定义镜像转场；复用已验证的 forceFinishIfNeeded）
            if (_transitionTriggered) {
                if (commit) [self.interactive finish];
                else {
                    self.currentAnimator.releaseVelocity = 0;  // 取消：温和回弹，不带入前向速度
                    [self.interactive cancel];
                }
            } else if (commit) {
                // 快滑零位移：自定义转场未启动，走系统非交互 pop（最干净）
                self.interacting = NO;
                self.interactive = nil;
                self.currentAnimator = nil;
                _navPopTarget = nil;
                _currentPercent = 0;
                _transitionTriggered = NO;
                [self triggerTransitionInWindow:win withPan:pan];
                return;
            }
            [self _scheduleCompletionWatchdog];
            self.interacting = NO;
            self.interactive = nil;
            self.currentAnimator = nil;
            _navPopTarget = nil;
            _currentPercent = 0;
            _transitionTriggered = NO;
            OBLog(@"endTransition: nav pop 自定义视差收尾 (commit=%d)", commit);
            return;
        }
        if (_navPopProbeFailed) {
            // 探测失败已切非交互 pop：此处仅复位状态，不再喂系统转场（避免与已进行的非交互 pop 冲突）
            OBLog(@"endTransition: nav pop 探测失败→非交互返回复位 (commit=%d)", commit);
            self.interacting = NO;
            _navPopTarget = nil;
            self.interactive = nil;
            self.currentAnimator = nil;
            _currentPercent = 0;
            _transitionTriggered = NO;
            return;
        }
        [self _callSystemNavPop:pan];
        self.interacting = NO;
        _navPopTarget = nil;
        self.interactive = nil;
        self.currentAnimator = nil;
        _currentPercent = 0;
        _transitionTriggered = NO;
        OBLog(@"endTransition: nav pop 系统原生收尾 (commit=%d)", commit);
        return;
    }

    // ===== 以下为 modal dismiss 路径（方案B），保持不变 =====
    // 注意：这里不释放 currentTD —— 弹窗若 cancel 仍 present，其 transitioningDelegate(assign)
    // 仍指向该 td；释放会留下野指针。td 的生命周期由被 dismiss 的 VC 关联对象保证（见 beginTransition）。
    // 仅当本次手势确实触发了交互转场才 finish/cancel；纯点按未触发则什么都不碰，安全复位。
    if (_transitionTriggered) {
        if (commit) [self.interactive finish];   // 提交：forceFinishIfNeeded 做 UIView 动画归位 + completeTransition
        else {
            self.currentAnimator.releaseVelocity = 0;  // 取消：温和回弹，不带入前向速度
            [self.interactive cancel];           // 反向续跑动画器回弹（直接驱动中断式动画器）
        }
    } else if (commit) {
        // 快滑但几乎无净位移（手势 Began→Ended 之间无有效横向移动，p 从未 >0.001），
        // 交互转场未启动；但速度已达提交阈值(commit=1) → 用户意图明确"一滑即回"。
        // 直接走系统动画 pop/dismiss（非交互，最干净），避免"胶囊飞出却没反应"的困惑。
        // 实测 oback_debug(10).log 第296行即此场景：percent=0.00 vel=723 projected=0.22 commit=1 triggered=0。
        // 关键修复：先置 interacting=NO，让 delegate 返回 nil 交互控制器 → 真正非交互转场，
        // 由系统动画自动完成（最干净），避免"交互控制器已返回却永不 finish"导致停滞冻结。
        self.currentAnimator = nil;
        self.interacting = NO;
        OBLog(@"endTransition: 快滑零位移，非交互直接返回 (vel=%.0f edge=%@)", vel,
              self.currentEdge == ObackEdgeLeft ? @"左" : @"右");
        [self triggerTransitionInWindow:win withPan:pan];
        self.interactive = nil;
        _currentPercent = 0;
        _transitionTriggered = NO;
        return;   // 此路径用系统原生动画，无 ObackAnimator，无需兜底收尾
    }
    // 兜底收尾：finish/cancel 已直接调 forceFinishIfNeeded（不再走 continueAnimation），
    // watchdog 仅作为最后一道保险（若 UIView 动画 completion 因极端情况未触发）。
    [self _scheduleCompletionWatchdog];
    self.interacting = NO;
    self.interactive = nil;
    self.currentAnimator = nil;   // assign 弱引用，显式清更安全
    _currentPercent = 0;
    _transitionTriggered = NO;
    self.navPopUseObackAnimator = NO;   // 复位：避免残留导致下次手势误判自定义转场
}

// 兜底收尾定时器：当前 ObackAnimator 在 0.5s 内若仍未自行完成（completed=NO），
// 强制调 completeTransition，确保转场一定收尾，绝不遗留"卡交互态"冻结。
// manager 单例常驻 → 定时器回调持有 _watchAnimator（已 retain）安全，无野指针风险。
- (void)_scheduleCompletionWatchdog {
    ObackAnimator *a = self.currentAnimator;
    if (!a) return;
    [_watchAnimator release];
    _watchAnimator = [a retain];   // MRC：定时器期间强持，避免 UIKit 释放动画器成野指针
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [_watchAnimator forceFinishIfNeeded];
        [_watchAnimator release];
        _watchAnimator = nil;
    });
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
            self.interactive = nil;
            self.currentAnimator = nil;
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
    // 手势意外失败（无明确释放速度）：清速度为 0，让取消动画走温和回弹（不继承动量）
    self.releaseVelocity = 0;
    self.releasePercent  = 0;
    OBLog(@"abortTransition (state=%ld)", (long)pan.state);
    UIWindow *win = [self _windowForPan:pan];
    ObackParams *p = [ObackPreferences params];
    if (_indicator) [self dismissIndicatorCommitted:NO params:p window:win];
    if (self.currentParallaxToView) {
        if (self.currentEdge == ObackEdgeRight) {
            // 实验：自定义 nav 视差取消（同 modal 方案B：含右缘固定自定义镜像转场；驱动 animator 反向回弹 + watchdog 兜底收尾）
            if (_transitionTriggered && self.interactive) [self.interactive cancel];
            [self _scheduleCompletionWatchdog];
        } else {
            // 方案 A：nav pop 用系统原生交互转场，把当前 pan(Failed/Cancelled)喂给 handleNavigationTransition:
            // 让系统取消原生 pop；无自定义动画器，无需 watchdog/interactive cancel。
            // 探测失败(_navPopProbeFailed)已切非交互 pop，不再喂系统转场(避免冲突)，直接走下方复位。
            if (_transitionTriggered && !_navPopProbeFailed) [self _callSystemNavPop:pan];
        }
        // 兜底：若系统 target 取不到导致原生 pop 从未启动（driveSystemNavPopBegin 降级为非交互 pop），
        // 此处 _navPopTarget 为 nil，_callSystemNavPop 为空操作，无需额外处理。
    } else {
        // 仅当本次手势确实触发了转场才 cancel（直接驱动中断式动画器反向回弹）；
        // 未触发则什么都不碰，安全复位，避免误调用导致导航卡在交互态。
        if (_transitionTriggered && self.interactive) [self.interactive cancel];
        // 兜底收尾：cancel 内部 pa=nil 时早退不会调 completeTransition，此处定时器保证转场仍被收尾（见 _scheduleCompletionWatchdog）
        [self _scheduleCompletionWatchdog];
    }
    self.interacting = NO;
    self.interactive = nil;
    self.currentAnimator = nil;   // assign 弱引用，显式清更安全
    _navPopTarget = nil;
    _currentPercent = 0;
    _transitionTriggered = NO;
    self.rightSimplePop = NO;     // 复位：避免残留导致下次手势误判右缘非交互
    self.navPopUseObackAnimator = NO;   // 复位：避免残留导致下次手势误判自定义转场
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
            OBLog(@"[diag-navTarget] nil | bid=%@ nav=%@ ipg=%@ enabled=%d targets.count=%lu delegate=%@",
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

// 判定 nav pop 是否走 ObackAnimator 自定义交互转场（跟手）。
// 与 _navPopShouldDriveSystemNav: 互补：后者决定「方案A 系统原生」还是「非交互 rightSimplePop」；
// 本方法决定「额外走 Oback 自研转场」（仅对自研转场不跟手、但仍能正常 pop 的 App）。
// 当前命中：QQ(com.tencent.mqq) / TIM(com.tencent.tim) —— 它们用 NTPushPopLib 等自研转场库整体接管
// 交互返回，方案A 喂不进、运行时会瞬返；但 popViewControllerAnimated: 正常 → 改由 ObackAnimator
// （阴影渐隐，上一页 Identity 天然可见）接管跟手。仅按 bundle id 圈死，其他 App 零变化。
- (BOOL)_navPopShouldUseObackAnimator:(UINavigationController *)nav {
    (void)nav;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!bid) return NO;
    if ([bid caseInsensitiveCompare:@"com.tencent.mqq"] == NSOrderedSame) return YES; // QQ
    if ([bid caseInsensitiveCompare:@"com.tencent.tim"] == NSOrderedSame) return YES; // TIM（QQ 同门，自研转场同样不跟手）
    return NO;
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

// 触摸点下的 scrollView 是否横向可滚（图片查看器/横向分页容器）。用于全屏 pan 避让，避免横滑误触返回。
- (BOOL)_scrollViewIsHorizontallyScrollableAtPoint:(CGPoint)point inWindow:(UIWindow *)win {
    UIScrollView *sv = [self scrollViewAtPoint:point inView:win];
    if (!sv) return NO;
    if (!sv.scrollEnabled) return NO;
    // 内容宽明显大于可视宽 → 横向可滚（图片查看器 paging：contentSize.width = count * width）
    return (sv.contentSize.width > sv.bounds.size.width * 1.2);
}

// [2026-08-08 修复 文本选择蓝色手柄] 检测当前是否存在「活动文本选择」：
// 文本选择激活时系统会显示蓝色选择手柄 + 放大镜(loupe)视图，且底层 UITextView/UITextField 的
// selectedTextRange 非空。命中任一项即认为处于选择态，Oback 全屏 pan 应让路(不 begin)。
// 私有类名用 containsString 模糊匹配(避免不同 iOS 版本类名微调)，文本视图用 selectedTextRange 精确判定。
- (BOOL)_activeTextSelectionInView:(UIView *)v {
    if (!v) return NO;
    NSString *cls = NSStringFromClass([v class]);
    // [2026-08-09 强化] 放宽类名匹配，覆盖 QQ 自研选择 UI 可能的私有类名
    if ([cls containsString:@"TextSelection"] || [cls containsString:@"SelectionView"] ||
        [cls containsString:@"Loupe"] || [cls containsString:@"Magnifier"] ||
        [cls containsString:@"DragHandle"] || [cls containsString:@"Caret"] ||
        [cls containsString:@"SelectionHandle"] || [cls containsString:@"Magnif"] ||
        [cls containsString:@"Handle"]) {
        return YES;
    }
    // [2026-08-09 强化] 蓝色选择手柄拖拽手势 _UIDragHandleGestureRecognizer 直接挂在其手柄 view 上；
    // 识别该手势类(比视图类名更稳)，且 view 可见即代表当前有文本选择激活 → 让 Oback 让路。
    Class dragHandleCls = NSClassFromString(@"_UIDragHandleGestureRecognizer");
    for (UIGestureRecognizer *gr in v.gestureRecognizers) {
        BOOL isHandle = (dragHandleCls && [gr isKindOfClass:dragHandleCls]);
        if (!isHandle) {
            NSString *gcls = NSStringFromClass([gr class]);
            if ([gcls containsString:@"DragHandle"]) isHandle = YES;
        }
        if (isHandle) {
            UIView *hv = gr.view;
            if (hv && !hv.hidden && hv.alpha > 0.01 && !CGRectIsEmpty(hv.frame)) return YES;
        }
    }
    if ([v isKindOfClass:[UITextView class]] || [v isKindOfClass:[UITextField class]]) {
        @try {
            // [2026-08-08 编译修复] v 静态类型为 UIView*，直接发 selectedTextRange 在 -Werror 下报错；
            // 用 respondsToSelector + performSelector(返回 id) 绕开未知方法警告，行为与原逻辑一致。
            if ([v respondsToSelector:@selector(selectedTextRange)]) {
                id range = [v performSelector:@selector(selectedTextRange)];
                if (range) {
                    UITextRange *tr = (UITextRange *)range;
                    if (![tr isEmpty]) return YES;
                }
            }
        } @catch (NSException *e) {}
    }
    for (UIView *sub in v.subviews) {
        if ([self _activeTextSelectionInView:sub]) return YES;
    }
    return NO;
}

- (BOOL)_activeTextSelectionInWindow:(UIWindow *)win {
    if (!win) return NO;
    if ([self _activeTextSelectionInView:win]) return YES;
    // QQ 等可能把选择/放大镜视图放到 overlay window，补充枚举其余 window
    NSArray *wins = nil;
    @try {
        if (@available(iOS 13.0, *)) {
            NSMutableArray *arr = [NSMutableArray array];
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]])
                    [arr addObjectsFromArray:((UIWindowScene *)scene).windows];
            }
            wins = arr;
        } else {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            wins = [[UIApplication sharedApplication] windows];
            #pragma clang diagnostic pop
        }
    } @catch (NSException *e) { wins = nil; }
    for (UIWindow *w in wins) {
        if (w && w != win && [self _activeTextSelectionInView:w]) return YES;
    }
    return NO;
}

// [2026-08-09 回归修复] 判定「蓝色选择手柄」是否正在被拖拽：仅当手柄手势(_UIDragHandleGestureRecognizer)
// 真实处于 Began/Changed 才视为拖拽中。手柄手势类常驻于文本视图(未拖拽时为 Possible/Failed)，
// 不能仅凭类名/视图存在判断——否则聊天里任意滑返回都会被误判为"在拖手柄"而让路、全局返回失效。
// 与 _activeTextSelectionInWindow: 区分：后者判"是否有选择"(含静止选中态)，本方法判"是否正在拖拽手柄"。
- (BOOL)_activeHandleDragInWindow:(UIWindow *)win {
    if (!win) return NO;
    Class dragHandleCls = NSClassFromString(@"_UIDragHandleGestureRecognizer");
    if (!dragHandleCls) return NO;
    __block BOOL found = NO;
    __block void (^checkView)(UIView *);
    checkView = ^(UIView *v) {
        if (found || !v) return;
        for (UIGestureRecognizer *gr in v.gestureRecognizers) {
            if ([gr isKindOfClass:dragHandleCls]) {
                UIGestureRecognizerState s = gr.state;
                if (s == UIGestureRecognizerStateBegan || s == UIGestureRecognizerStateChanged) { found = YES; return; }
            }
        }
        for (UIView *sub in v.subviews) checkView(sub);
    };
    checkView(win);
    if (found) return YES;
    // 补充 overlay window（QQ 选择/放大镜视图可能放在别的 window）
    NSArray *wins = nil;
    @try {
        if (@available(iOS 13.0, *)) {
            NSMutableArray *arr = [NSMutableArray array];
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) [arr addObjectsFromArray:((UIWindowScene *)scene).windows];
            }
            wins = arr;
        } else {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            wins = [[UIApplication sharedApplication] windows];
            #pragma clang diagnostic pop
        }
    } @catch (NSException *e) { wins = nil; }
    for (UIWindow *w in wins) {
        if (w && w != win) { checkView(w); if (found) return YES; }
    }
    return NO;
}

// 检测 QQ 左侧抽屉/侧边栏是否处于打开。打开时全屏 pan 不接管返回，让抽屉自身关闭手势生效
// （否则用户横滑关抽屉被我们的返回抢走，只能点按钮关）。
// [2026-08-06 修正] 必须用「全屏半透明遮罩」+「贴左半屏面板」双签名，否则 QQ 聊天界面常驻的
// 全屏半透明视图（背景/输入区遮罩）会被单遮罩条件误判为抽屉→返回被禁→QQ 原生瞬返。
- (BOOL)_qqDrawerOpenInWindow:(UIWindow *)win {
    if (!win) return NO;
    CGFloat w = win.bounds.size.width, h = win.bounds.size.height;
    if (w <= 0 || h <= 0) return NO;
    BOOL mask = NO, panel = NO;
    [self _scanDrawer:win width:w height:h mask:&mask panel:&panel];
    if (mask || panel) OBLog(@"[drawer-scan] mask=%d panel=%d (w=%.1f) — 若聊天界面误命中请把此行发我定位", mask, panel, w);
    return (mask && panel);
}
- (void)_scanDrawer:(UIView *)v width:(CGFloat)w height:(CGFloat)h mask:(BOOL *)mask panel:(BOOL *)panel {
    for (UIView *sub in v.subviews) {
        CGRect f = sub.frame;
        // 全屏半透明遮罩（抽屉关闭层）：点击空白处关闭抽屉。下限 alpha>=0.05 排除 QQ 聊天界面常驻的
        // 近全透明背景层——它曾被单 mask 条件误判为抽屉遮罩，是 81a3e07→ebef7cd 聊天界面返回失效主因。
        if (sub.userInteractionEnabled && sub.alpha >= 0.05 && sub.alpha < 0.98 &&
            f.size.width >= w * 0.95 && f.size.height >= h * 0.95) *mask = YES;
        // 贴左半屏面板：QQ 抽屉菜单约 0.6~0.8 屏宽。收紧到 [0.4w, 0.86w]——排除近全屏主界面(>=0.98w)
        // 与左侧窄控件(<0.4w)，避免聊天界面/导航栏子视图被误判为抽屉面板（ebef7cd 的 panel 判定过宽仍误命中）。
        if (sub.userInteractionEnabled && f.origin.x <= 2 &&
            f.size.width >= w * 0.4 && f.size.width < w * 0.86) *panel = YES;
        [self _scanDrawer:sub width:w height:h mask:mask panel:panel];
    }
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
