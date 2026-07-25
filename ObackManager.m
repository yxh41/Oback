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

void OBLog(NSString *fmt, ...) {
    if (![ObackPreferences debugLogEnabled]) return;   // 调试日志关闭 → 完全不写盘/不 NSLog（最省）
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
static void *kDiagLastLogKey = &kDiagLastLogKey;  // 双返回诊断：同一 window 日志节流（每 2s 最多打一次手势清单）
static CGFloat const kIndicatorMaxTravel = 110.0;   // 胶囊最多跟随手指移动的距离 (pt)

#pragma mark - 边缘方向指示胶囊（OPPO 风格：跟随手指、带方向箭头）

@interface ObackEdgeIndicator : UIView
- (instancetype)initWithEdge:(ObackEdge)edge;
@end

@implementation ObackEdgeIndicator {
    ObackEdge _edge;
    CAShapeLayer *_chevron;
}
- (instancetype)initWithEdge:(ObackEdge)edge {
    if (self = [super initWithFrame:CGRectMake(0, 0, 56, 32)]) {
        _edge = edge;
        // 默认：白色半透明胶囊 + 柔和阴影
        self.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.9];
        self.layer.cornerRadius = 16;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.2;
        self.layer.shadowRadius = 6;
        self.layer.shadowOffset = CGSizeZero;
        self.userInteractionEnabled = NO;

        // 方向 chevron（深色，保证在白底/暗底都可见）
        _chevron = [CAShapeLayer layer];
        _chevron.lineWidth = 3.0;
        _chevron.lineCap = kCALineCapRound;
        _chevron.lineJoin = kCALineJoinRound;
        _chevron.strokeColor = [UIColor colorWithWhite:0.25 alpha:1.0].CGColor;
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
@end

@implementation ObackManager {
    BOOL   _started;
    CGFloat _currentPercent;
    BOOL   _transitionTriggered; // 本次手势是否已真正触发 pop/dismiss（首次横向拖动才置 YES）
    UIView *_indicator;          // 边缘方向指示胶囊
    CGPoint _indicatorAnchor;    // 手势起点（胶囊初始垂直位置）
    CGFloat _indicatorStartX;    // 手势起点 x（用于计算跟随位移）
    ObackAnimator *_watchAnimator; // MRC 强引用：兜底收尾定时器期间持有动画器，避免 UIKit 释放成野指针
    id     _navPopTarget;        // 方案A: 系统原生 nav pop 的私有 target(_UINavigationInteractiveTransition)，
                                 // 驱动 handleNavigationTransition: 用（assign，由 nav 内部持有，转场期间有效）
}

+ (instancetype)shared {
    static ObackManager *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [[ObackManager alloc] init]; });
    return m;
}

#pragma mark - 启动与挂载

- (void)start {
    if (_started) return;
    _started = YES;
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
    ObackPanGestureRecognizer *panL = [[ObackPanGestureRecognizer alloc] initWithTarget:self
                                                                                 action:@selector(handlePan:)];
    panL.delegate = self;
    panL.maximumNumberOfTouches = 1;
    // 仍设 NO：pan 只观察、绝不吞掉 App 触摸（修复朋友圈点不进详情 / Flutter 类 app 像打不开）。
    panL.cancelsTouchesInView = NO;
    panL.delaysTouchesBegan   = NO;
    panL.edges = UIRectEdgeLeft;

    ObackPanGestureRecognizer *panR = [[ObackPanGestureRecognizer alloc] initWithTarget:self
                                                                                 action:@selector(handlePan:)];
    panR.delegate = self;
    panR.maximumNumberOfTouches = 1;
    panR.cancelsTouchesInView = NO;
    panR.delaysTouchesBegan   = NO;
    panR.edges = UIRectEdgeRight;

    [win addGestureRecognizer:panL];
    [win addGestureRecognizer:panR];
    // 这两个 window pan 仅用于「modal dismiss」检测（kind=modal）。nav pop 的边缘 pan 改挂到
    // nav.view（见 _attachNavPanToNav:），以在可滚动列表页也能压过 scrollView 的 pan。
    objc_setAssociatedObject(panL, kPanKindKey, @"modal", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(panR, kPanKindKey, @"modal", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSArray *pans = @[panL, panR];
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
    if ([existing isKindOfClass:[NSArray class]] && existing.count == 2) return;  // 已挂过，幂等
    UIView *navView = nav.view;            // 触发加载；为 nil 时下面 addGestureRecognizer 无操作，下次链接重试
    if (!navView) { OBLog(@"attachNavPan: nav.view 尚为 nil，跳过（下次链接重试）"); return; }
    NSMutableArray *pans = [NSMutableArray array];
    UIRectEdge edges[2] = { UIRectEdgeLeft, UIRectEdgeRight };
    for (NSUInteger i = 0; i < 2; i++) {
        ObackPanGestureRecognizer *pan = [[ObackPanGestureRecognizer alloc] initWithTarget:self
                                                                                     action:@selector(handlePan:)];
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
    OBLog(@"attachNavPan: nav=%@ pans=%lu on nav.view", NSStringFromClass([nav class]), (unsigned long)pans.count);
}

// 让窗口内所有「边缘返回手势」失败于我们的 window pan。
// 关键：requireGestureRecognizerToFail: 是「成对依赖」关系，App/插件即便随后把 enabled 重新置 YES，
// 其手势的 begin 仍被系统判定为必须先等我们的 pan 失败——无论对手是系统原生 interactivePop，
// 还是某越狱插件（如微信分组）添加的私有边缘返回手势，同一根手指都只认我们的单次 pop，
// 从根上消除「一次滑动弹两层」（含插件场景）。
- (void)_linkNavPopGesturesInWindow:(UIWindow *)win {
    if (!win) return;
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
        nav.interactivePopGestureRecognizer.enabled = NO;
        failOnOurPans(nav.interactivePopGestureRecognizer);
        linked++;
    }];
    // 第二道防线：枚举窗口里所有 UIScreenEdgePanGestureRecognizer（含插件自定义的边缘返回手势），
    // 让它们全部失败于我们的 pan——plugin 私有的边缘手势也能压住，杜绝「一次滑动弹两层」。
    [self _enumerateEdgeGesturesInView:win depth:0 block:^(UIScreenEdgePanGestureRecognizer *g){
        if (g.delegate == self) return;   // 跳过我们自己的边缘 pan（避免 requireGestureRecognizerToFail 自引用）
        failOnOurPans(g);
        linked++;
    }];
    // 第三道防线：枚举窗口里所有 UIScrollView 的 pan（含纵向表视图 / 横向分页容器）。
    // 让它们失败于我们的 pan——从边缘起滑时 ourPan 优先接管返回（无论横/纵 scroll），
    // 从中间滑动时 ourPan 不 begin 故放行给滚动，互不干扰。
    [self _enumerateScrollPansInView:win depth:0 block:^(UIPanGestureRecognizer *g){
        failOnOurPans(g);
        linked++;
    }];
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

// 不干预的视图控制器：其所在 nav 不挂我们的边缘 pan、不关原生 interactivePop，交原生处理。
// 当前仅微信朋友圈（WCTimeLineViewController 及其相关）：整屏滚动信息流与我们的边缘 pan
// 存在手势竞争——我们的 pan 在 shouldBegin=YES 后仍进不了 Began（被朋友圈 scrollView/原生
// 手势抢走），且 swizzle 关掉原生 interactivePop 后会把朋友圈原本可用的原生边缘返回也弄没。
// 用户明确要求「不干预朋友圈」，故整页跳过，保留微信原生边缘返回。
- (BOOL)_isExcludedViewController:(UIViewController *)vc {
    if (!vc) return NO;
    NSString *name = NSStringFromClass([vc class]);
    if ([name isEqualToString:@"WCTimeLineViewController"] ||
        [name rangeOfString:@"WCTimeLine"].location != NSNotFound) {
        return YES;
    }
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
        self.currentParallaxToView = YES;   // nav pop（系统原生交互转场，不 reparent toView）
    } else {
        if (top.presentingViewController != nil) {
            self.currentParallaxToView = NO;  // modal dismiss（方案B 自定义，只移 sheet）
        } else if (nav && nav.viewControllers.count > 1) {
            OBLog(@"shouldBegin(modal)=NO (有 nav pop 可接管，交给 nav pan)");
            return NO;
        } else {
            OBLog(@"shouldBegin(modal)=NO (无 modal 也无 nav pop)");
            return NO;
        }
    }

    self.currentEdge = edge;
    OBLog(@"shouldBegin=YES (kind=%@ edge=%@ top=%@ nav.childCount=%lu presenting=%d parallaxToView=%d)",
          kind, edge == ObackEdgeLeft ? @"左" : @"右",
          NSStringFromClass([top class]),
          (unsigned long)nav.viewControllers.count, top.presentingViewController != nil,
          self.currentParallaxToView);
    if (p.hapticEnabled) {
        UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
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

- (void)beginTransition:(UIPanGestureRecognizer *)pan {
    // 新手势开始：清空上一次松手速度/进度，避免遗留值串入本次动画
    self.releaseVelocity = 0;
    self.releasePercent  = 0;
    // 诊断：确认本次手势是否真正进入 beginTransition（朋友圈此前"胶囊出现但无返回"疑似未到此）。
    {
        UIWindow *dbgWin = [self _windowForPan:pan];
        OBLog(@"beginTransition: entered (parallaxToView=%d top=%@)",
              self.currentParallaxToView,
              NSStringFromClass([[self topMost:dbgWin.rootViewController] class]));
    }

    UIWindow *win = [self _windowForPan:pan];
    UIViewController *top = [self topMost:win.rootViewController];
    if (!top) return;

    // 手势已进入 Began：取消 shouldBegin 时设的安全兜底定时器（正常生命周期会收起胶囊）
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(dismissIndicatorSafety) object:nil];

    ObackParams *p = [ObackPreferences params];
    self.interactive = [[ObackInteractiveTransition alloc] initWithEdge:self.currentEdge params:p];
    self.interacting = YES;
    _transitionTriggered = NO;

    // 方案 A：nav pop 改为驱动系统原生交互 pop（根除自定义转场 reparent toView 导致的空白/损坏）。
    // 在手势 Began(位移=0)即启动系统原生交互转场，由后续 updateTransition 的横向位移 scrub。
    // modal dismiss（currentParallaxToView=NO）走方案B 自定义转场，不在此启动。
    if (self.currentParallaxToView) {
        [self driveSystemNavPopBeginWithPan:pan window:win];
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
    // nav 类 pan 直接读所属 nav（swizzle 已绑定），绕过 topMost 枚举——朋友圈等自定义容器不在标准链上
    UINavigationController *nav = nil;
    UIViewController *top = nil;
    if ([objc_getAssociatedObject(pan, kPanKindKey) isEqualToString:@"nav"]) {
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
        self.currentParallaxToView = YES;   // nav pop 视差（移动上一页）
        if (self.interacting) {
            // 方案 A：交互 pop 已在 beginTransition 通过 handleNavigationTransition: 启动，
            // 此处不再调用 popViewControllerAnimated:（否则会触发第二次转场/黑屏）。
            OBLog(@"trigger: nav pop 已启动(系统原生交互)，忽略重复 popViewControllerAnimated");
        } else {
            // 非交互兜底（快滑零位移：endTransition 先把 interacting 置 NO 再走此路径）
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
            td = [[ObackTransitioningDelegate alloc] init];
            td.original = existing;
            top.transitioningDelegate = td;
        }
        objc_setAssociatedObject(top, kObackTDKey, td, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        self.currentTD = td;
        [top dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)updateTransition:(UIPanGestureRecognizer *)pan {
    if (!self.interacting) return;
    UIWindow *win = [self _windowForPan:pan];
    CGFloat w = win.bounds.size.width;
    if (w <= 0) return;

    CGPoint t = [pan translationInView:win];
    CGFloat dir = (self.currentEdge == ObackEdgeLeft) ? 1.0 : -1.0;
    CGFloat p = dir * t.x / w;
    p = MAX(0.0, MIN(1.0, p));

    // 首次横向拖动（p>0）才真正触发（modal 路径在此触发 dismiss；nav 路径已在 begin 启动，这里不再触发）
    if (!_transitionTriggered && p > 0.001) {
        [self triggerTransitionInWindow:win withPan:pan];
        _transitionTriggered = YES;
    }

    _currentPercent = p;
    if (self.currentParallaxToView) {
        // 方案 A：nav pop 用系统原生交互转场，直接把当前 pan 喂给 handleNavigationTransition: 做 scrub
        [self _callSystemNavPop:pan];
    } else {
        if (self.interactive) [self.interactive updateWithPercent:p];
    }
    [self updateIndicatorWithPan:pan window:win];
}

- (void)endTransition:(UIPanGestureRecognizer *)pan {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(dismissIndicatorSafety) object:nil];
    if (!self.interacting) return;
    UIWindow *win = [self _windowForPan:pan];
    CGFloat w = win.bounds.size.width;
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
    BOOL commit = (effective > p.commitRatio) || (vel > p.commitVelocity);
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

// 手势意外失败(Failed/超时等)时的紧急清理：取消转场+消除胶囊，防止残留
- (void)abortTransition:(UIPanGestureRecognizer *)pan {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(dismissIndicatorSafety) object:nil];
    // 手势意外失败（无明确释放速度）：清速度为 0，让取消动画走温和回弹（不继承动量）
    self.releaseVelocity = 0;
    self.releasePercent  = 0;
    OBLog(@"abortTransition (state=%ld)", (long)pan.state);
    UIWindow *win = [self _windowForPan:pan];
    ObackParams *p = [ObackPreferences params];
    if (_indicator) [self dismissIndicatorCommitted:NO params:p window:win];
    if (self.currentParallaxToView) {
        // 方案 A：nav pop 用系统原生交互转场，把当前 pan(Failed/Cancelled)喂给 handleNavigationTransition:
        // 让系统取消原生 pop；无自定义动画器，无需 watchdog/interactive cancel。
        if (_transitionTriggered) [self _callSystemNavPop:pan];
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
}

#pragma mark - 方案 A：驱动系统原生 nav pop

// 取系统 interactivePopGestureRecognizer 的私有 target（_UINavigationInteractiveTransition 实例）。
// 该 target 的 action handleNavigationTransition: 即系统原生交互 pop 的入口。
- (id)navPopSystemTargetForNav:(UINavigationController *)nav {
    @try {
        id ipg = nav.interactivePopGestureRecognizer;
        NSArray *targets = [ipg valueForKey:@"_targets"];
        id targetObj = targets.firstObject;
        return [targetObj valueForKey:@"target"];
    } @catch (NSException *e) {
        OBLog(@"navPopSystemTarget fail: %@", e);
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
    _navPopTarget = [self navPopSystemTargetForNav:nav];
    if (!_navPopTarget) {
        // 极端兜底：取不到系统 target，降级为非交互 popViewControllerAnimated（interacting 置 NO
        // 让 delegate 返回 nil → 系统默认转场），至少能返回，不卡死。
        OBLog(@"navPop: 取不到系统 target，降级为非交互 popViewControllerAnimated");
        [nav popViewControllerAnimated:YES];
        self.interacting = NO;
        _transitionTriggered = YES;
        return;
    }
    // 系统原生 interactivePopGestureRecognizer 保持 disabled（避免它自己触发 double），
    // 直接把我们的 pan 作为 sender 喂给它的私有 action。
    [self _callSystemNavPop:pan];
    _transitionTriggered = YES;
    OBLog(@"navPop: 系统原生交互 pop 已启动 (target=%@)", NSStringFromClass([_navPopTarget class]));
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
    }
    ObackEdgeIndicator *ind = [[ObackEdgeIndicator alloc] initWithEdge:edge];
    ind.center = [self indicatorHomeCenterForEdge:edge basePoint:loc window:win];
    ind.alpha = 0.0;
    ind.transform = CGAffineTransformMakeScale(0.85, 0.85);
    [win addSubview:ind];
    [win bringSubviewToFront:ind];
    _indicator = ind;
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
    CGFloat s = 0.85 + 0.15 * MIN(1.0, _currentPercent / 0.3);   // 拉动越大，胶囊越饱满
    _indicator.center = CGPointMake(home.x + travel, home.y);
    _indicator.transform = CGAffineTransformMakeScale(s, s);
    _indicator.alpha = 0.9;
    [win bringSubviewToFront:_indicator];
}

- (void)dismissIndicatorCommitted:(BOOL)committed params:(ObackParams *)p window:(UIWindow *)win {
    UIView *ind = _indicator;
    _indicator = nil;
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
