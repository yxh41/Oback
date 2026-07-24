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
    if ([n.object isKindOfClass:[UIWindow class]]) [self attachToWindow:n.object];
}

- (void)attachToWindow:(UIWindow *)win {
    if (!win) return;
    if (objc_getAssociatedObject(win, kAttachedKey)) return;  // 每个 window 只挂一次
    ObackPanGestureRecognizer *pan = [[ObackPanGestureRecognizer alloc] initWithTarget:self
                                                                                 action:@selector(handlePan:)];
    pan.delegate = self;
    pan.maximumNumberOfTouches = 1;
    [win addGestureRecognizer:pan];
    objc_setAssociatedObject(win, kAttachedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    OBLog(@"attached pan gesture to window %@ (bounds=%.0fx%.0f)", win,
          win.bounds.size.width, win.bounds.size.height);
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
        OBLog(@"beginTransition: pop nav (childCount=%lu)", (unsigned long)nav.viewControllers.count);
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
    // 仅当本次手势确实触发了转场才 finish/cancel；纯点按未触发则什么都不碰，安全复位。
    if (_transitionTriggered) {
        if (commit) [self.interactive finish];   // 走标准 finishInteractiveTransition
        else        [self.interactive cancel];   // 走标准 cancelInteractiveTransition
    }
    self.interacting = NO;
    self.interactive = nil;
    _currentPercent = 0;
    _transitionTriggered = NO;
}

// 手势意外失败(Failed/超时等)时的紧急清理：取消转场+消除胶囊，防止残留
- (void)abortTransition:(UIPanGestureRecognizer *)pan {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(dismissIndicatorSafety) object:nil];
    OBLog(@"abortTransition (state=%ld)", (long)pan.state);
    UIWindow *win = (UIWindow *)pan.view;
    ObackParams *p = [ObackPreferences params];
    if (_indicator) [self dismissIndicatorCommitted:NO params:p window:win];
    // 仅当本次手势确实触发了转场才 cancel（走标准 cancelInteractiveTransition）；
    // 未触发则什么都不碰，安全复位，避免误调用导致导航卡在交互态。
    if (_transitionTriggered && self.interactive) [self.interactive cancel];
    self.interacting = NO;
    self.interactive = nil;
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
