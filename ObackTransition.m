#import "ObackTransition.h"
#import "ObackManager.h"   // 读取松手速度/进度做动量继承（ObackManager.h 已 import ObackTransition.h，无循环依赖）

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
        // nav pop 路径无卡片圆角，确保无残留
        fromView.layer.cornerRadius = 0;
        fromView.layer.masksToBounds = NO;
    } else {
        // 方案B：底层 presenting 绝不碰（黑屏根因）；不加深遮罩，避免已可见背景闪暗
        toView.transform = CGAffineTransformIdentity;
        if (dimView) dimView.alpha = 0.0;
        // 弹窗 dismiss：可选卡片圆角（拉出时渐进圆角，模拟 iOS sheet 下拉手感）
        if (p.cardCornerEnabled) {
            CGFloat r = p.cardCornerValue * percent;   // p=0→0, p=1→最大值，拖动中由 CA 线性插值
            fromView.layer.cornerRadius = r;
            fromView.layer.masksToBounds = (r > 0.5);
        } else {
            fromView.layer.cornerRadius = 0;
            fromView.layer.masksToBounds = NO;
        }
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
    // 弹性补间：默认开。松手后按释放速度做动量继承的 spring 收尾，比线性 easeOut 更跟手、更高级。
    p.springEnabled    = YES;
    // 弹窗下拉卡片圆角：默认关（方案B 保守路径；开启后下拉 sheet 时渐进圆角，更贴近 iOS 原生 sheet）。
    p.cardCornerEnabled = NO;
    p.cardCornerValue   = 12.0;
    return p;
}
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

    // ① 方向性渐变遮罩（替代纯黑），沿边缘方向由深到浅，增强层叠纵深
    UIView *dim = [self _makeDimViewWithFrame:container.bounds edge:self.edge];
    dim.alpha = 0;
    dim.userInteractionEnabled = NO;   // 关键：遮罩绝不拦截触摸，即便残留也只是黑、不会"无法操作"
    [container insertSubview:dim aboveSubview:toView];
    [container bringSubviewToFront:fromView];

    [self applyShadowTo:fromView];
    OBApplyParallax(0, fromView, toView, dim, self.edge, self.params, self.parallaxToView);

    // 读松手时前向速度/进度（ObackManager 在 endTransition 写入，animateTransition 此时已异步读取）
    CGFloat vel    = [ObackManager shared].releaseVelocity;
    CGFloat startP = [ObackManager shared].releasePercent;
    BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    BOOL spring = self.params.springEnabled && !reduceMotion;

    void (^animations)(void) = ^{
        OBApplyParallax(1, fromView, toView, dim, self.edge, self.params, self.parallaxToView);
    };
    void (^completion)(BOOL) = ^(BOOL finished) {
        [dim removeFromSuperview];
        [ctx completeTransition:![ctx transitionWasCancelled]];
        OBLog(@"animator done (cancelled=%d finished=%d spring=%d vel=%.0f)",
              [ctx transitionWasCancelled], finished, spring, vel);
    };

    if (spring) {
        // ② 动量继承：前向速度换算为 spring 初速度（API 中 1 = 全程距离/秒）；按剩余进度动态时长。
        CGFloat w = fromView.window ? fromView.window.bounds.size.width : [UIScreen mainScreen].bounds.size.width;
        if (w <= 0) w = [UIScreen mainScreen].bounds.size.width;
        CGFloat remaining = MAX(0.0, 1.0 - startP);
        // 拉得越多（remaining 越小）收尾越快；范围 0.22~0.46s，配合 0.82 阻尼，松手即有"被吸过去"的高级感。
        CGFloat dur = MAX(0.22, MIN(0.46, self.params.duration * (0.55 + 0.45 * remaining)));
        CGFloat sv = (w > 0) ? (vel / w) : 0.0;   // 初速度（相对全程）
        sv = MAX(-2.0, MIN(2.0, sv));
        [UIView animateWithDuration:dur
                              delay:0
             usingSpringWithDamping:0.82
              initialSpringVelocity:sv
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:animations
                         completion:completion];
    } else {
        // ③ 关闭弹性 / 减弱动态效果 → 线性 easeOut 兜底（与旧版一致，稳）
        [UIView animateWithDuration:[self transitionDuration:ctx]
                              delay:0
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                         animations:animations
                         completion:completion];
    }
}

- (void)applyShadowTo:(UIView *)v {
    // 弹窗下拉卡片圆角开启时，圆角需 masksToBounds=YES 才能显示，会裁掉阴影；
    // 该路径下以圆角为主、放弃阴影，避免两者互相打架。
    BOOL cornering = (self.params.cardCornerEnabled && !self.parallaxToView);
    v.layer.shadowColor = [UIColor blackColor].CGColor;
    v.layer.shadowOpacity = (self.params.shadowEnabled && !cornering) ? self.params.shadowOpacity : 0.0;
    v.layer.shadowRadius = 12.0;
    v.layer.shadowOffset = CGSizeMake((self.edge == ObackEdgeLeft ? -6.0 : 6.0), 0.0);
    v.layer.masksToBounds = NO;
}

// 方向性渐变遮罩：替代纯黑 UIView。沿边缘方向由深到浅，给"被压在下方"的页面更自然的纵深感。
- (UIView *)_makeDimViewWithFrame:(CGRect)frame edge:(ObackEdge)edge {
    UIView *v = [[UIView alloc] initWithFrame:frame];
    v.userInteractionEnabled = NO;
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = frame;
    // 仅用黑→透明渐变；整体浓度仍由 OBApplyParallax 设置的 v.alpha 控制（0→dimAlpha）。
    CGColorRef dark = [UIColor colorWithWhite:0.0 alpha:1.0].CGColor;
    CGColorRef clear = [UIColor colorWithWhite:0.0 alpha:0.0].CGColor;
    g.colors = @[(__bridge id)dark, (__bridge id)clear];
    g.locations = @[@0.0, @0.55];
    if (edge == ObackEdgeLeft) {            // 当前页右移，上一页从左侧探出 → 左侧深
        g.startPoint = CGPointMake(0.0, 0.5);
        g.endPoint   = CGPointMake(1.0, 0.5);
    } else {                                // 当前页左移，上一页从右侧探出 → 右侧深
        g.startPoint = CGPointMake(1.0, 0.5);
        g.endPoint   = CGPointMake(0.0, 0.5);
    }
    [v.layer addSublayer:g];
    return v;
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

// 以下三个方法均走 UIPercentDrivenInteractiveTransition 标准实现：
// 由它来驱动 ObackAnimator 的 animateTransition: 动画进度，并在 finish/cancel 时
// 正确复位导航控制器的"交互中"状态（否则导航会一直卡在交互转场态 → 界面冻结、点不动）。
- (void)updateWithPercent:(CGFloat)percent {
    [self updateInteractiveTransition:percent];
}

- (void)finish {
    [self finishInteractiveTransition];
}

- (void)cancel {
    [self cancelInteractiveTransition];
}

@end
