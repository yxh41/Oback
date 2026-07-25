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
@interface ObackPanGestureRecognizer : UIPanGestureRecognizer
@property (nonatomic, assign) CGPoint startPoint;
@end

static void *kAttachedKey = &kAttachedKey;
static void *kObackTDKey = &kObackTDKey;   // 让被 dismiss 的 VC 自己 retain 其 transition 转发器，避免野指针
void *kPanKey = &kPanKey;                  // 暴露给 Tweak.xm：window 上挂载的 Oback 全屏 pan 手势（用于让原生 interactivePop 失败于它）
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
        OBLog(@"windowBecameKey: %@ (isKeyNow=%d)", NSStringFromClass([win class]), win.isKeyWindow);
        [self attachToWindow:win];
        [self _linkNavPopGesturesInWindow:win];  // 成为 key 时重新链接（nav 可能刚压入/呈现）
    }
}

- (void)attachToWindow:(UIWindow *)win {
    if (!win) return;
    if (objc_getAssociatedObject(win, kAttachedKey)) { [self _linkNavPopGesturesInWindow:win]; return; }  // 已挂过：仍重新链接（nav 可能刚出现）
    ObackPanGestureRecognizer *pan = [[ObackPanGestureRecognizer alloc] initWithTarget:self
                                                                                 action:@selector(handlePan:)];
    pan.delegate = self;
    pan.maximumNumberOfTouches = 1;
    [win addGestureRecognizer:pan];
    objc_setAssociatedObject(win, kAttachedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(win, kPanKey, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
// 注意：我们的 window pan 是 UIPanGestureRecognizer 子类（非 UIScreenEdgePanGestureRecognizer），
// 故 isKindOfClass 过滤已天然排除它，无需额外判等。深度护栏避免超大视图树爆栈。
- (void)_enumerateEdgeGesturesInView:(UIView *)view depth:(NSUInteger)depth
                               block:(void(^)(UIScreenEdgePanGestureRecognizer *g))block {
    if (!view || !block || depth > 40) return;
    for (UIGestureRecognizer *g in view.gestureRecognizers) {
        if ([g isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) block((UIScreenEdgePanGestureRecognizer *)g);
    }
    for (UIView *sub in view.subviews)
        [self _enumerateEdgeGesturesInView:sub depth:depth + 1 block:block];
}

// 让窗口内所有「边缘返回手势」失败于我们的 window pan。
// 关键：requireGestureRecognizerToFail: 是「成对依赖」关系，App/插件即便随后把 enabled 重新置 YES，
// 其手势的 begin 仍被系统判定为必须先等我们的 pan 失败——无论对手是系统原生 interactivePop，
// 还是某越狱插件（如微信分组）添加的私有边缘返回手势，同一根手指都只认我们的单次 pop，
// 从根上消除「一次滑动弹两层」（含插件场景）。
- (void)_linkNavPopGesturesInWindow:(UIWindow *)win {
    if (!win) return;
    ObackPanGestureRecognizer *pan = objc_getAssociatedObject(win, kPanKey);
    if (!pan) { OBLog(@"linkNav: 本 window 无 Oback pan，跳过链接"); return; }
    CFTimeInterval t0 = CACurrentMediaTime();
    __block NSUInteger linked = 0;
    // 第一道防线：直接关掉 nav 原生 interactivePop（左边缘专属）
    [self _enumerateNavControllersFrom:win.rootViewController block:^(UINavigationController *nav){
        nav.interactivePopGestureRecognizer.enabled = NO;
        @try { [nav.interactivePopGestureRecognizer requireGestureRecognizerToFail:pan]; }
        @catch (NSException *e) { OBLog(@"linkNav: nav requireGestureRecognizerToFail 异常: %@", e); }
        linked++;
    }];
    // 第二道防线：枚举窗口里所有 UIScreenEdgePanGestureRecognizer（含插件自定义的边缘返回手势），
    // 让它们全部失败于我们的 pan——plugin 私有的边缘手势也能压住，杜绝「一次滑动弹两层」。
    [self _enumerateEdgeGesturesInView:win depth:0 block:^(UIScreenEdgePanGestureRecognizer *g){
        @try { [g requireGestureRecognizerToFail:pan]; }
        @catch (NSException *e) { OBLog(@"linkNav: edge requireGestureRecognizerToFail 异常: %@", e); }
        linked++;
    }];
    CFTimeInterval dt = (CACurrentMediaTime() - t0) * 1000.0;
    OBLog(@"linkNav: 链接 %lu 个返回手势 (耗时 %.2f ms) @window=%@",
          (unsigned long)linked, dt, NSStringFromClass([win class]));
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

#pragma mark - UIGestureRecognizerDelegate

// 只在"落在边缘 + 可返回 + 不在黑名单"时，手势才接管，否则放行给 App 自身
- (BOOL)gestureRecognizerShouldBegin:(UIPanGestureRecognizer *)pan {
    if (self.interacting) { OBLog(@"shouldBegin=NO (已在交互中)"); return NO; }
    BOOL allowed = [ObackPreferences isAllowed];
    if (!allowed) { OBLog(@"shouldBegin=NO (isAllowed=NO, bid=%@)", NSBundle.mainBundle.bundleIdentifier); return NO; }

    ObackParams *p = [ObackPreferences params];
    UIWindow *win = (UIWindow *)pan.view;
    CGPoint loc = [pan locationInView:win];
    CGFloat w = win.bounds.size.width;
    if (w <= 0) { OBLog(@"shouldBegin=NO (window width=0)"); return NO; }

    ObackEdge edge = ObackEdgeLeft;
    BOOL isEdge = NO;
    if (p.leftEnabled && loc.x <= p.triggerWidth)            { edge = ObackEdgeLeft;  isEdge = YES; }
    else if (p.rightEnabled && loc.x >= w - p.triggerWidth)  { edge = ObackEdgeRight; isEdge = YES; }
    if (!isEdge) {
        OBLog(@"shouldBegin=NO (不在边缘: x=%.1f w=%.1f triggerW=%.1f left=%d right=%d)",
              loc.x, w, p.triggerWidth, p.leftEnabled, p.rightEnabled);
        return NO;
    }

    UIViewController *top = [self topMost:win.rootViewController];
    if (!top) { OBLog(@"shouldBegin=NO (无顶层 VC)"); return NO; }

    UINavigationController *nav = top.navigationController;
    if (!nav && [top isKindOfClass:[UINavigationController class]]) nav = (UINavigationController *)top;

    BOOL poppable = (nav && nav.viewControllers.count > 1) || (top.presentingViewController != nil);
    if (!poppable) {
        OBLog(@"shouldBegin=NO (不可返回: nav.childCount=%lu presenting=%d)",
              (unsigned long)nav.viewControllers.count, top.presentingViewController != nil);
        return NO;
    }

    // 边缘内滑与下方横向滚动列表冲突时，让位给滚动（左右边缘通用）
    UIScrollView *sv = [self scrollViewAtPoint:loc inView:win];
    if (sv) {
        CGFloat maxX = sv.contentSize.width - sv.bounds.size.width;
        BOOL canScrollHoriz = (maxX > 1.0);
        if (canScrollHoriz) {
            // 左边缘内滑且列表还能向左滚 -> 放行给滚动
            if (edge == ObackEdgeLeft && sv.contentOffset.x > 1.0) {
                OBLog(@"shouldBegin=NO (让位横向滚动, 左边缘)");
                return NO;
            }
            // 右边缘内滑且列表还能向右滚 -> 放行给滚动
            if (edge == ObackEdgeRight && sv.contentOffset.x < maxX - 1.0) {
                OBLog(@"shouldBegin=NO (让位横向滚动, 右边缘)");
                return NO;
            }
        }
    }

    self.currentEdge = edge;
    OBLog(@"shouldBegin=YES (edge=%@ nav.childCount=%lu presenting=%d)",
          edge == ObackEdgeLeft ? @"左" : @"右",
          (unsigned long)nav.viewControllers.count, top.presentingViewController != nil);
    if (p.hapticEnabled) {
        UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [g impactOccurred];
    }
    // 实时补链：本 window 可能在我们初次(windowBecameKey)枚举之后才压入分组/子容器，
    // 其边缘返回手势从未被链接 → 加固对它形同虚设。故每次确认接管时，对当前窗口重新
    // 枚举并让所有边缘返回手势失败于我们的 pan（幂等无害：requireGestureRecognizerToFail
    // 为成对依赖，设一次即持久；且依赖在每个 touch 事件重评估 → 当次滑动也会被持续压制，
    // 因我们的 pan 在手指移动期间保持交互态不会失败，故对方边缘手势整段被阻塞，只弹一层）。
    [self _linkNavPopGesturesInWindow:win];
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

    UIWindow *win = (UIWindow *)pan.view;
    UIViewController *top = [self topMost:win.rootViewController];
    if (!top) return;

    // 手势已进入 Began：取消 shouldBegin 时设的安全兜底定时器（正常生命周期会收起胶囊）
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(dismissIndicatorSafety) object:nil];

    ObackParams *p = [ObackPreferences params];
    self.interactive = [[ObackInteractiveTransition alloc] initWithEdge:self.currentEdge params:p];
    self.interacting = YES;
    _transitionTriggered = NO;

    CGPoint loc = [pan locationInView:win];
    _indicatorAnchor = loc;
    _indicatorStartX = loc.x;

    // 胶囊多数情况已在 shouldBegin=YES 时显示；此处仅作兜底（极少数 Began 早于胶囊显示的边界场景）
    if (!_indicator) [self showIndicatorWithEdge:self.currentEdge atPoint:loc inWindow:win];
}

// 首次横向拖动时（p>0）才真正触发 pop/dismiss。
// 关键修复：此前在 beginTransition(手势 Began) 就立即 popViewControllerAnimated:，
// 一旦用户只是点按/纵向滑动即取消，交互转场易被卡在"进行中"态导致界面冻结。
- (void)triggerTransitionInWindow:(UIWindow *)win {
    UIViewController *top = [self topMost:win.rootViewController];
    if (!top) return;

    UINavigationController *nav = top.navigationController;
    if (!nav && [top isKindOfClass:[UINavigationController class]]) nav = (UINavigationController *)top;

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
        [nav popViewControllerAnimated:YES];
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
    if (!self.interacting || !self.interactive) return;
    UIWindow *win = (UIWindow *)pan.view;
    CGFloat w = win.bounds.size.width;
    if (w <= 0) return;

    CGPoint t = [pan translationInView:win];
    CGFloat dir = (self.currentEdge == ObackEdgeLeft) ? 1.0 : -1.0;
    CGFloat p = dir * t.x / w;
    p = MAX(0.0, MIN(1.0, p));

    // 首次横向拖动（p>0）才真正触发 pop/dismiss；纯纵向/点按不会启动转场
    if (!_transitionTriggered && p > 0.001) {
        [self triggerTransitionInWindow:win];
        _transitionTriggered = YES;
    }

    _currentPercent = p;
    [self.interactive updateWithPercent:p];
    [self updateIndicatorWithPan:pan window:win];
}

- (void)endTransition:(UIPanGestureRecognizer *)pan {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(dismissIndicatorSafety) object:nil];
    if (!self.interacting || !self.interactive) return;
    UIWindow *win = (UIWindow *)pan.view;
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
        [self triggerTransitionInWindow:win];
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
    UIWindow *win = (UIWindow *)pan.view;
    ObackParams *p = [ObackPreferences params];
    if (_indicator) [self dismissIndicatorCommitted:NO params:p window:win];
    // 仅当本次手势确实触发了转场才 cancel（直接驱动中断式动画器反向回弹）；
    // 未触发则什么都不碰，安全复位，避免误调用导致导航卡在交互态。
    if (_transitionTriggered && self.interactive) [self.interactive cancel];
    // 兜底收尾：cancel 内部 pa=nil 时早退不会调 completeTransition，此处定时器保证转场仍被收尾（见 _scheduleCompletionWatchdog）
    [self _scheduleCompletionWatchdog];
    self.interacting = NO;
    self.interactive = nil;
    self.currentAnimator = nil;   // assign 弱引用，显式清更安全
    _currentPercent = 0;
    _transitionTriggered = NO;
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
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.state == UIGestureRecognizerStatePossible) {
        UITouch *touch = [touches anyObject];
        if (touch) {
            CGPoint now = [touch locationInView:self.view];
            CGFloat dx = now.x - self.startPoint.x;
            CGFloat dy = now.y - self.startPoint.y;
            // 累计位移超阈值后判定方向，纵向则直接失败，放行给底层滚动
            if (fabs(dx) >= 8.0 || fabs(dy) >= 8.0) {
                if (fabs(dy) > fabs(dx)) {
                    self.state = UIGestureRecognizerStateFailed;
                    return;
                }
            }
        }
    }
    [super touchesMoved:touches withEvent:event];
}

@end
