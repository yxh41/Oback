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

static void OBLog(NSString *fmt, ...) {
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

@implementation ObackManager {
    BOOL   _started;
    CGFloat _currentPercent;
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
    return YES;
}

#pragma mark - 手势处理

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:       [self beginTransition:pan]; break;
        case UIGestureRecognizerStateChanged:     [self updateTransition:pan]; break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:   [self endTransition:pan];   break;
        default: break;
    }
}

- (void)beginTransition:(UIPanGestureRecognizer *)pan {
    UIWindow *win = (UIWindow *)pan.view;
    UIViewController *top = [self topMost:win.rootViewController];
    if (!top) return;

    UINavigationController *nav = top.navigationController;
    if (!nav && [top isKindOfClass:[UINavigationController class]]) nav = (UINavigationController *)top;

    ObackParams *p = [ObackPreferences params];
    self.interactive = [[ObackInteractiveTransition alloc] initWithEdge:self.currentEdge params:p];
    self.interacting = YES;

    if (nav && nav.viewControllers.count > 1) {
        OBLog(@"beginTransition: pop nav (childCount=%lu)", (unsigned long)nav.viewControllers.count);
        [nav popViewControllerAnimated:YES];
    } else if (top.presentingViewController) {
        OBLog(@"beginTransition: dismiss modal");
        [top dismissViewControllerAnimated:YES completion:nil];
    } else {
        OBLog(@"beginTransition: 无操作(不可返回)");
        self.interacting = NO;
        self.interactive = nil;
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
    _currentPercent = p;
    [self.interactive updateWithPercent:p];
}

- (void)endTransition:(UIPanGestureRecognizer *)pan {
    if (!self.interacting || !self.interactive) return;
    UIWindow *win = (UIWindow *)pan.view;
    CGPoint v = [pan velocityInView:win];
    CGFloat dir = (self.currentEdge == ObackEdgeLeft) ? 1.0 : -1.0;
    CGFloat vel = dir * v.x;

    ObackParams *p = [ObackPreferences params];
    BOOL commit = (_currentPercent > p.commitRatio) || (vel > p.commitVelocity);
    if (commit) [self.interactive finish];
    else        [self.interactive cancel];

    self.interacting = NO;
    self.interactive = nil;
    _currentPercent = 0;
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
    if (!vc) return nil;
    if (vc.presentedViewController) return [self topMost:vc.presentedViewController];
    if ([vc isKindOfClass:[UINavigationController class]]) return [self topMost:[(UINavigationController *)vc topViewController]];
    if ([vc isKindOfClass:[UITabBarController class]])    return [self topMost:[(UITabBarController *)vc selectedViewController]];
    return vc;
}

// 命中测试找最近的 UIScrollView（用于冲突规避）
- (UIScrollView *)scrollViewAtPoint:(CGPoint)point inView:(UIView *)view {
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
