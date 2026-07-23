#import "ObackTransition.h"

// 私有扩展：补一个「已完成」标记，避免 completeTransition 被重复调用（UIKit 会告警/异常）
@interface ObackInteractiveTransition ()
@property (nonatomic, assign) BOOL completed;
@end

// 核心：根据百分比把"当前页"和"上一页"摆到位，模拟 OPPO 视差
// parallaxToView=YES  → nav pop：上一页(presenting/toView)探出+放大（视差），当前页平移。
// parallaxToView=NO   → 弹窗 dismiss 方案B：只动被 dismiss 的 fromView(sheet 滑出+轻微缩小)，
//                       绝不碰底层 presenting(toView)（黑屏根因），也不加深遮罩（避免已可见背景闪暗）。
static void OBApplyParallax(CGFloat percent,
                            UIView *fromView,
                            UIView *toView,
                            UIView *dimView,
                            ObackEdge edge,
                            ObackParams *p,
                            BOOL parallaxToView) {
    CGFloat w = fromView.window ? fromView.window.bounds.size.width
                                : [UIScreen mainScreen].bounds.size.width;
    if (w <= 0) w = [UIScreen mainScreen].bounds.size.width;

    percent = MAX(0.0, MIN(1.0, percent));
    CGFloat dir = (edge == ObackEdgeLeft) ? 1.0 : -1.0;

    // 当前页/被 dismiss 的 sheet：始终按方向平移；方案B 下额外给一点点缩小增强"飞出"感
    CGFloat fromScale = 1.0;
    if (!parallaxToView) fromScale = 1.0 - 0.08 * percent;
    fromView.transform = CGAffineTransformConcat(
        CGAffineTransformMakeTranslation(dir * percent * w, 0),
        CGAffineTransformMakeScale(fromScale, fromScale));

    if (parallaxToView) {
        // 上一页：从对侧探出 + 轻微放大（视差）
        CGFloat toX = -dir * p.parallaxOffset * w * (1.0 - percent);
        CGFloat scale = p.previousScaleMin + (1.0 - p.previousScaleMin) * percent;
        toView.transform = CGAffineTransformConcat(
            CGAffineTransformMakeTranslation(toX, 0),
            CGAffineTransformMakeScale(scale, scale));
        // 上一页初始被压暗，随拖动变亮
        if (dimView) dimView.alpha = (1.0 - percent) * p.dimAlpha;
    } else {
        // 方案B：底层 presenting 绝不碰（黑屏根因）；不加深遮罩，避免已可见背景闪暗
        toView.transform = CGAffineTransformIdentity;
        if (dimView) dimView.alpha = 0.0;
    }
}

@implementation ObackParams
+ (instancetype)defaults {
    ObackParams *p = [[ObackParams alloc] init];
    p.triggerWidth     = 40.0;   // 边缘触发宽度：24 太窄（用户常从 25~32pt 起滑，判为"不在边缘"），放宽到 40
    p.leftEnabled      = YES;
    p.rightEnabled     = YES;
    p.hapticEnabled    = YES;
    p.parallaxOffset   = 0.30;
    p.previousScaleMin = 0.92;
    p.dimAlpha         = 0.35;
    p.shadowEnabled    = YES;
    p.shadowOpacity    = 0.25;
    p.duration         = 0.32;
    // 提交阈值：偏灵敏（贴近 OPPO/系统边缘返回手感）。
    // 旧值 commitRatio=0.40 太严 —— 真机日志(oback_debug(4).log)显示用户自然内滑大多只到
    // 0.34~0.38 就被判取消(6/7 次取消)，导致"主功能体验不好"。降到 0.30 让部分拖动即可提交；
    // commitVelocity 同步下调到 400，让一般甩动(flick)也能可靠提交。
    p.commitRatio      = 0.30;
    p.commitVelocity   = 400.0;
    return p;
}
@end

@interface ObackInteractiveTransition ()
@property (nonatomic, retain) id<UIViewControllerContextTransitioning> ctx;
@property (nonatomic, retain) UIView *fromView;
@property (nonatomic, retain) UIView *toView;
@property (nonatomic, retain) UIView *dimView;
@end

@implementation ObackAnimator

- (instancetype)initWithEdge:(ObackEdge)edge params:(ObackParams *)params {
    if (self = [super init]) {
        _edge = edge;
        _params = params ?: [ObackParams defaults];
        _parallaxToView = YES;   // 默认 nav pop 视差（安全且已验证）；弹窗 dismiss 由调用方置 NO
    }
    return self;
}

- (NSTimeInterval)transitionDuration:(id<UIViewControllerContextTransitioning>)transitionContext {
    return self.params.duration;
}

- (void)animateTransition:(id<UIViewControllerContextTransitioning>)ctx {
    UIView *container = ctx.containerView;
    UIViewController *from = [ctx viewControllerForKey:UITransitionContextFromViewControllerKey];
    UIViewController *to   = [ctx viewControllerForKey:UITransitionContextToViewControllerKey];
    UIView *fromView = from.view;
    UIView *toView   = to.view;

    if (toView.superview != container) [container insertSubview:toView atIndex:0];

    UIView *dim = [[UIView alloc] initWithFrame:container.bounds];
    dim.backgroundColor = [UIColor blackColor];
    dim.alpha = 0;
    dim.userInteractionEnabled = NO;   // 关键：遮罩绝不拦截触摸，即便残留也只是黑、不会"无法操作"
    [container insertSubview:dim aboveSubview:toView];
    [container bringSubviewToFront:fromView];

    [self applyShadowTo:fromView];
    OBApplyParallax(0, fromView, toView, dim, self.edge, self.params, self.parallaxToView);

    [UIView animateWithDuration:[self transitionDuration:ctx]
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        OBApplyParallax(1, fromView, toView, dim, self.edge, self.params, self.parallaxToView);
    } completion:^(BOOL finished) {
        [dim removeFromSuperview];
        [ctx completeTransition:![ctx transitionWasCancelled]];
        OBLog(@"animator done (cancelled=%d finished=%d)", [ctx transitionWasCancelled], finished);
    }];
}

- (void)applyShadowTo:(UIView *)v {
    v.layer.shadowColor = [UIColor blackColor].CGColor;
    v.layer.shadowOpacity = self.params.shadowEnabled ? self.params.shadowOpacity : 0.0;
    v.layer.shadowRadius = 12.0;
    v.layer.shadowOffset = CGSizeMake((self.edge == ObackEdgeLeft ? -6.0 : 6.0), 0.0);
    v.layer.masksToBounds = NO;
}

@end

@implementation ObackInteractiveTransition

- (instancetype)initWithEdge:(ObackEdge)edge params:(ObackParams *)params {
    if (self = [super init]) {
        _edge = edge;
        _params = params ?: [ObackParams defaults];
        _parallaxToView = YES;   // 默认 nav pop 视差；弹窗 dismiss 由调用方置 NO
    }
    return self;
}

- (void)startInteractiveTransition:(id<UIViewControllerContextTransitioning>)ctx {
    _ctx = ctx;
    _completed = NO;
    UIView *container = ctx.containerView;
    _fromView = [ctx viewControllerForKey:UITransitionContextFromViewControllerKey].view;
    _toView   = [ctx viewControllerForKey:UITransitionContextToViewControllerKey].view;
    OBLog(@"interactive transition begin (fromView=%@ toViewInWindow=%d)",
          _fromView, (_toView && _toView.window) ? 1 : 0);

    if (_toView.superview != container) [container insertSubview:_toView atIndex:0];

    _dimView = [[UIView alloc] initWithFrame:container.bounds];
    _dimView.backgroundColor = [UIColor blackColor];
    _dimView.alpha = 0;
    _dimView.userInteractionEnabled = NO;   // 关键：遮罩绝不拦截触摸
    [container insertSubview:_dimView aboveSubview:_toView];
    [container bringSubviewToFront:_fromView];

    [self applyShadowTo:_fromView];
    [self updateWithPercent:0];
}

- (void)updateWithPercent:(CGFloat)percent {
    OBApplyParallax(percent, _fromView, _toView, _dimView, self.edge, self.params, self.parallaxToView);
}

- (void)applyShadowTo:(UIView *)v {
    v.layer.shadowColor = [UIColor blackColor].CGColor;
    v.layer.shadowOpacity = self.params.shadowEnabled ? self.params.shadowOpacity : 0.0;
    v.layer.shadowRadius = 12.0;
    v.layer.shadowOffset = CGSizeMake((self.edge == ObackEdgeLeft ? -6.0 : 6.0), 0.0);
    v.layer.masksToBounds = NO;
}

- (void)finish {
    [UIView animateWithDuration:self.params.duration
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        OBApplyParallax(1, _fromView, _toView, _dimView, self.edge, self.params, self.parallaxToView);
    } completion:^(BOOL finished) {
        if (_completed) return; _completed = YES;
        [_dimView removeFromSuperview];
        [_ctx completeTransition:YES];
        OBLog(@"interactive transition finished (finished=%d)", finished);
    }];
}

- (void)cancel {
    [UIView animateWithDuration:self.params.duration
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        OBApplyParallax(0, _fromView, _toView, _dimView, self.edge, self.params, self.parallaxToView);
    } completion:^(BOOL finished) {
        if (_completed) return; _completed = YES;
        [_dimView removeFromSuperview];
        [_ctx completeTransition:NO];
        OBLog(@"interactive transition cancelled (finished=%d)", finished);
    }];
}

@end
