#import "ObackManager.h"
#import "ObackPreferences.h"
#import <objc/runtime.h>

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
    [self attachToWindow:UIApplication.sharedApplication.keyWindow];
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
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(handlePan:)];
    pan.delegate = self;
    pan.maximumNumberOfTouches = 1;
    [win addGestureRecognizer:pan];
    objc_setAssociatedObject(win, kAttachedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - UIGestureRecognizerDelegate

// 只在"落在边缘 + 可返回 + 不在黑名单"时，手势才接管，否则放行给 App 自身
- (BOOL)gestureRecognizerShouldBegin:(UIPanGestureRecognizer *)pan {
    if (self.interacting) return NO;
    if (![ObackPreferences isAllowed]) return NO;

    ObackParams *p = [ObackPreferences params];
    UIWindow *win = (UIWindow *)pan.view;
    CGPoint loc = [pan locationInView:win];
    CGFloat w = win.bounds.size.width;
    if (w <= 0) return NO;

    ObackEdge edge = ObackEdgeLeft;
    BOOL isEdge = NO;
    if (p.leftEnabled && loc.x <= p.triggerWidth)            { edge = ObackEdgeLeft;  isEdge = YES; }
    else if (p.rightEnabled && loc.x >= w - p.triggerWidth)  { edge = ObackEdgeRight; isEdge = YES; }
    if (!isEdge) return NO;

    UIViewController *top = [self topMost:win.rootViewController];
    if (!top) return NO;

    UINavigationController *nav = top.navigationController;
    if (!nav && [top isKindOfClass:[UINavigationController class]]) nav = (UINavigationController *)top;

    BOOL poppable = (nav && nav.viewControllers.count > 1) || (top.presentingViewController != nil);
    if (!poppable) return NO;

    // 左边缘且列表已横向滚动时，让位给滚动，避免和横滑列表打架
    if (edge == ObackEdgeLeft) {
        UIScrollView *sv = [self scrollViewAtPoint:loc inView:win];
        if (sv && sv.contentOffset.x > 1.0) return NO;
    }

    self.currentEdge = edge;
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
        [nav popViewControllerAnimated:YES];
    } else if (top.presentingViewController) {
        [top dismissViewControllerAnimated:YES completion:nil];
    } else {
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
