#import "ObackTransition.h"

// 核心：根据百分比把"当前页"和"上一页"摆到位，模拟 OPPO 视差
static void OBApplyParallax(CGFloat percent,
                            UIView *fromView,
                            UIView *toView,
                            UIView *dimView,
                            ObackEdge edge,
                            ObackParams *p) {
    CGFloat w = fromView.window ? fromView.window.bounds.size.width
                                : [UIScreen mainScreen].bounds.size.width;
    if (w <= 0) w = [UIScreen mainScreen].bounds.size.width;

    percent = MAX(0.0, MIN(1.0, percent));
    CGFloat dir = (edge == ObackEdgeLeft) ? 1.0 : -1.0;

    // 当前页：整体平移
    CGFloat fromX = dir * percent * w;
    fromView.transform = CGAffineTransformMakeTranslation(fromX, 0);

    // 上一页：从对侧探出 + 轻微放大（视差）
    CGFloat toX = -dir * p.parallaxOffset * w * (1.0 - percent);
    CGFloat scale = p.previousScaleMin + (1.0 - p.previousScaleMin) * percent;
    toView.transform = CGAffineTransformConcat(
        CGAffineTransformMakeTranslation(toX, 0),
        CGAffineTransformMakeScale(scale, scale));

    // 上一页初始被压暗，随拖动变亮
    if (dimView) dimView.alpha = (1.0 - percent) * p.dimAlpha;
}

@implementation ObackParams
+ (instancetype)defaults {
    ObackParams *p = [[ObackParams alloc] init];
    p.triggerWidth     = 24.0;
    p.leftEnabled      = YES;
    p.rightEnabled     = YES;
    p.hapticEnabled    = YES;
    p.parallaxOffset   = 0.30;
    p.previousScaleMin = 0.92;
    p.dimAlpha         = 0.35;
    p.shadowEnabled    = YES;
    p.shadowOpacity    = 0.25;
    p.duration         = 0.32;
    p.commitRatio      = 0.40;
    p.commitVelocity   = 500.0;
    return p;
}
@end

@interface ObackInteractiveTransition ()
@property (nonatomic, strong) id<UIViewControllerContextTransitioning> ctx;
@property (nonatomic, strong) UIView *fromView;
@property (nonatomic, strong) UIView *toView;
@property (nonatomic, strong) UIView *dimView;
@end

@implementation ObackAnimator

- (instancetype)initWithEdge:(ObackEdge)edge params:(ObackParams *)params {
    if (self = [super init]) {
        _edge = edge;
        _params = params ?: [ObackParams defaults];
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
    [container insertSubview:dim aboveSubview:toView];
    [container bringSubviewToFront:fromView];

    [self applyShadowTo:fromView];
    OBApplyParallax(0, fromView, toView, dim, self.edge, self.params);

    [UIView animateWithDuration:[self transitionDuration:ctx]
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        OBApplyParallax(1, fromView, toView, dim, self.edge, self.params);
    } completion:^(BOOL finished) {
        [dim removeFromSuperview];
        [ctx completeTransition:![ctx transitionWasCancelled]];
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
    }
    return self;
}

- (void)startInteractiveTransition:(id<UIViewControllerContextTransitioning>)ctx {
    _ctx = ctx;
    UIView *container = ctx.containerView;
    _fromView = [ctx viewControllerForKey:UITransitionContextFromViewControllerKey].view;
    _toView   = [ctx viewControllerForKey:UITransitionContextToViewControllerKey].view;

    if (_toView.superview != container) [container insertSubview:_toView atIndex:0];

    _dimView = [[UIView alloc] initWithFrame:container.bounds];
    _dimView.backgroundColor = [UIColor blackColor];
    _dimView.alpha = 0;
    [container insertSubview:_dimView aboveSubview:_toView];
    [container bringSubviewToFront:_fromView];

    [self applyShadowTo:_fromView];
    [self updateWithPercent:0];
}

- (void)applyShadowTo:(UIView *)v {
    v.layer.shadowColor = [UIColor blackColor].CGColor;
    v.layer.shadowOpacity = self.params.shadowEnabled ? self.params.shadowOpacity : 0.0;
    v.layer.shadowRadius = 12.0;
    v.layer.shadowOffset = CGSizeMake((self.edge == ObackEdgeLeft ? -6.0 : 6.0), 0.0);
    v.layer.masksToBounds = NO;
}

- (void)updateWithPercent:(CGFloat)percent {
    OBApplyParallax(percent, _fromView, _toView, _dimView, self.edge, self.params);
}

- (void)finish {
    [UIView animateWithDuration:self.params.duration
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        OBApplyParallax(1, _fromView, _toView, _dimView, self.edge, self.params);
    } completion:^(BOOL finished) {
        [_dimView removeFromSuperview];
        [_ctx completeTransition:YES];
    }];
}

- (void)cancel {
    [UIView animateWithDuration:self.params.duration
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        OBApplyParallax(0, _fromView, _toView, _dimView, self.edge, self.params);
    } completion:^(BOOL finished) {
        [_dimView removeFromSuperview];
        [_ctx completeTransition:NO];
    }];
}

@end
