#import "ObackTransition.h"
#import "ObackManager.h"   // 读取松手速度/进度做动量继承（ObackManager.h 已 import ObackTransition.h，无循环依赖）

// 核心：根据百分比把"当前页"和"上一页"摆到位，模拟 OPPO 风格边缘返回
// 弹窗 dismiss 方案B：只动被 dismiss 的 fromView(sheet 滑出+轻微缩小)，
// 绝不碰底层 presenting(toView)（黑屏根因），也不加深遮罩（避免已可见背景闪暗）。
// 注：自定义 nav 视差（实验）功能已移除——nav pop 一律走系统原生转场（方案A），不再经本文件自定义动画。
static void OBApplyParallax(CGFloat percent,
                            UIView *fromView,
                            UIView *toView,
                            ObackEdge edge,
                            ObackParams *p) {
    CGFloat w = fromView.window ? fromView.window.bounds.size.width
                                : [UIScreen mainScreen].bounds.size.width;
    if (w <= 0) w = [UIScreen mainScreen].bounds.size.width;

    percent = MAX(0.0, MIN(1.0, percent));
    CGFloat dir = (edge == ObackEdgeLeft) ? 1.0 : -1.0;

    // 当前页/被 dismiss 的 sheet：始终按方向平移；方案B 下额外给一点点缩小增强"飞出"感
    CGFloat fromScale = 1.0 - 0.08 * percent;
    fromView.transform = CGAffineTransformConcat(
        CGAffineTransformMakeTranslation(dir * percent * w, 0),
        CGAffineTransformMakeScale(fromScale, fromScale));

    // 方案B：底层 presenting 绝不碰（黑屏根因）；不加深遮罩（避免已可见背景闪暗）。
    // 注：nav 视差（平移上一页+阴影渐隐）已移除，本函数现仅弹窗 dismiss(方案B) 使用。
    toView.transform = CGAffineTransformIdentity;
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

@implementation ObackParams
+ (instancetype)defaults {
    ObackParams *p = [[[ObackParams alloc] init] autorelease];
    p.triggerWidth     = 40.0;   // 边缘触发宽度：24 太窄（用户常从 25~32pt 起滑，判为"不在边缘"），放宽到 40
    p.leftEnabled      = YES;
    p.rightEnabled     = YES;
    p.hapticEnabled    = YES;
    p.shadowOffset   = 6.0;
    p.shadowRadius   = 12.0;
    p.shadowEnabled    = YES;
    p.shadowOpacity    = 0.25;
    p.duration         = 0.32;
    // 提交阈值：偏灵敏（贴近 OPPO/系统边缘返回手感）。
    // 旧值 commitRatio=0.40 太严 —— 真机日志(oback_debug(4).log)显示用户自然内滑大多只到
    // 0.34~0.38 就被判取消(6/7 次取消)，导致"主功能体验不好"。降到 0.30 让部分拖动即可提交；
    // commitVelocity 同步下调到 400，让一般甩动(flick)也能可靠提交。
    p.commitRatio      = 0.30;
    p.commitVelocity   = 400.0;
    // 弹性补间：默认开。松手收尾按释放速度动态调制时长（动量等效）——快甩更快归位、更跟手；
    // 关闭或系统减弱动态时降级为固定 0.22s 线性 easeOut。
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
        self.params = params ?: [ObackParams defaults];
    }
    return self;
}

- (NSTimeInterval)transitionDuration:(id<UIViewControllerContextTransitioning>)transitionContext {
    return self.params.duration;
}

- (void)animateTransition:(id<UIViewControllerContextTransitioning>)ctx {
    // 诊断：入口确定执行一次（每次转场开始）。注意此刻 releaseVelocity 仍为 beginTransition 清零后的 0，
    // 真实速度在 finish 时由 ObackManager 写入，并被 forceFinishIfNeeded 的动量等效收尾消费（按速度调制收尾时长）。
    // 非交互路径（点系统返回按钮）走此处；交互手势路径不经此方法，直接走 forceFinishIfNeeded。
    self.context = ctx;   // 记入上下文：兜底强制收尾时仍需它调 completeTransition
    CGFloat vel    = [ObackManager shared].releaseVelocity;
    CGFloat startP = [ObackManager shared].releasePercent;
    BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    BOOL spring = self.params.springEnabled && !reduceMotion;

    CGFloat _w = [UIScreen mainScreen].bounds.size.width;
    CGFloat _rem = MAX(0.0, 1.0 - startP);
    CGFloat _dur = spring ? MAX(0.22, MIN(0.46, self.params.duration * (0.55 + 0.45 * _rem)))
                          : self.params.duration;
    CGFloat _sv = (_w > 0) ? (vel / _w) : 0.0;
    _sv = MAX(-2.0, MIN(2.0, _sv));
    OBLog(@"animator start (edge=%@ spring=%d reduce=%d vel=%.0f startP=%.2f dur=%.2f sv=%.2f)",
          self.edge == ObackEdgeLeft ? @"左" : @"右", spring, reduceMotion, vel, startP, _dur, _sv);

    // 构建/取回中断式动画器：系统据 interruptibleAnimatorForTransition: 驱动它——交互时暂停并按百分比 scrub，
    // 非交互时直接跑到完成。视图层级(阴影/parallax)在该方法内搭建。
    [self interruptibleAnimatorForTransition:ctx];
}

// 中断式动画器：系统对交互转场会暂停它并按 updateWithPercent 设定 fractionComplete，
// finish/cancel 时由 ObackInteractiveTransition 直接驱动 forceFinishIfNeeded 收尾（见下方）。
- (id<UIViewImplicitlyAnimating>)interruptibleAnimatorForTransition:(id<UIViewControllerContextTransitioning>)ctx {
    // 交互转场下系统不调 animateTransition:，必须在此存 context。
    // 关键：微信等 App 会 double-fetch（对同一转场调两次该方法），第二次 ctx 可能是 UIKit 重新封装的
    // 包装对象。只保存第一次的 context（与 UIKit 转场状态机绑定的那个），避免覆盖后 forceFinishIfNeeded
    // 对错误 context 调 completeTransition → UIKit 转场状态机不匹配 → 界面冻结。
    if (!_context) self.context = ctx;
    OBLog(@"interruptible ENTER (pa=%p ctx=%p context=%p)", _propertyAnimator, ctx, _context);
    if (_propertyAnimator) {
        // double-fetch（微信等 App 的 UIKit 会对同一转场调两次该方法）：
        // 缓存命中时确保动画器处于可 scrub 的 Active(paused) 态，
        // 避免"Active 且未 pause → continueAnimation 行为异常 → 动画器卡死不触发 completion"。
        if (_propertyAnimator.state == UIViewAnimatingStateActive) {
            [_propertyAnimator pauseAnimation];
        }
        OBLog(@"interruptible cached return pa=%p", _propertyAnimator);
        return _propertyAnimator;
    }

    UIView *container = ctx.containerView;
    UIViewController *from = [ctx viewControllerForKey:UITransitionContextFromViewControllerKey];
    UIViewController *to   = [ctx viewControllerForKey:UITransitionContextToViewControllerKey];
    UIView *fromView = from.view;
    UIView *toView   = to.view;

    // 弹窗 dismiss 方案B：底层 presenting(toView) 不碰 transform；目的页正常挂载。
    // 【黑屏修复】绝对不要无条件把 toView 塞进临时 container：
    //   - UIKit App：UIKit 已在转场开始时把 toView 预置进 container → superview==container，本就是空操作；
    //   - SwiftUI App(如 com.wangcaicalculator.wc，弹窗为 PresentationHostingController)：底层
    //     UIHostingController 视图挂在 window 下层、不在 container → 原代码 insert 会把它从真实
    //     层级抽进临时 container，dismiss 完成 UIKit 拆 container 时把它一并销毁 → 返回后整屏黑
    //     (进程活着、能上滑回桌面、不卡死)。故：仅当 toView 完全无宿主(superview==nil，被系统移出
    //     窗口、不装进 container 就全程不可见)才装入；否则保持原层级不动，底层自然可见。
    if (toView.superview == nil) [container insertSubview:toView atIndex:0];
    [container bringSubviewToFront:fromView];

    [self applyShadowTo:fromView];
    // 阴影方案：上一页用真实 toView（Identity，无缩放），doScale=NO
    OBApplyParallax(0, fromView, toView, self.edge, self.params);

    // 初速 0，damping 0.82 给出自然回弹手感
    UISpringTimingParameters *sp = [[UISpringTimingParameters alloc] initWithDampingRatio:0.82];
    UIViewPropertyAnimator *anim = [[[UIViewPropertyAnimator alloc]
        initWithDuration:self.params.duration
          timingParameters:sp] autorelease];
    [sp release];   // MRC：animator 内部已拷贝 timing，释放我们的所有权
    // MRC：禁用 __weak，用 __block 且 completion 内置 nil 打破 self->animator->block->self 循环引用
    __block ObackAnimator *blockSelf = self;
    [anim addAnimations:^{
        // 仅驱动 transform（UIView 属性，scrub 阶段 UIViewPropertyAnimator 插值可靠）。
        // 阴影渐隐不在这里做：手动 scrub 时 animator 对 CALayer.shadowOpacity 的逐帧插值不可靠
        // （真机实测拖动时阴影浓度恒定不衰减）。改由 updateWithPercent: 按 percent 确定性即时驱动，
        // 松手收尾由 forceFinishIfNeeded 的标准 UIView 动画平滑驱动（见下方）。两者作用于同一
        // fromView.layer.shadowOpacity，且 animator block 不再触碰阴影，故无 CA 动画占位冲突。
        CGFloat w = fromView.window ? fromView.window.bounds.size.width
                                    : [UIScreen mainScreen].bounds.size.width;
        CGFloat dir = (blockSelf.edge == ObackEdgeLeft) ? 1.0 : -1.0;
        CGFloat fromScale = 0.92;   // 方案B sheet 飞出终态缩小
        fromView.transform = CGAffineTransformConcat(
            CGAffineTransformMakeTranslation(dir * w, 0),
            CGAffineTransformMakeScale(fromScale, fromScale));
        toView.transform = CGAffineTransformIdentity;
    }];
    [anim addCompletion:^(UIViewAnimatingPosition finalPosition) {
        // 以 interactiveCancelled 为准（finish=NO/cancel=YES），避免反向动画 finalPosition 误判
        BOOL cancelled = blockSelf.interactiveCancelled || (finalPosition == UIViewAnimatingPositionStart);
        if (blockSelf.completed) { blockSelf = nil; return; }   // 已被 manager 兜底收尾 → 防重复 completeTransition
        blockSelf.completed = YES;
        if (blockSelf.context) [blockSelf.context completeTransition:!cancelled];
        if (toView) toView.hidden = NO;   // 还原真实底页可见
        OBLog(@"animator done (cancelled=%d)", cancelled);
        blockSelf = nil;   // 打破循环引用（MRC 无 __weak）
    }];
    self.propertyAnimator = anim;   // retain 属性赋值（anim 为 autorelease，直接赋 ivar 会在 drain 后野指针）
    OBLog(@"interruptible built pa=%p", _propertyAnimator);
    return anim;
}

// 统一收尾（finish/cancel/watchdog 共用）：
// 不再依赖 UIViewPropertyAnimator 的 continueAnimation（double-fetch 时会阻塞主线程 →
// watchdog 定时器无法触发 → 冻结/闪退）。改为：停止 property animator（彻底释放它对 layer
// 的动画控制，避免与 UIView 动画冲突）→ 用标准 UIView 动画把视图归位到终态 → 在动画
// completion 里做 cleanup；completeTransition 由 completion + dispatch_after(0.3s) 双重
// 保险确保一定被调用，避免某些 App 中 completion 延迟 1~2 秒导致界面冻结。
// _completed 守卫防重复（finish/cancel 先调一次，watchdog 0.5s 后调则直接返回）。

- (void)forceFinishIfNeeded {
    if (_completed) return;
    _completed = YES;

    id<UIViewControllerContextTransitioning> ctx = _context;
    if (!ctx) {
        OBLog(@"animator forceFinish SKIP (context=nil, cancelled=%d)", _interactiveCancelled);
        return;
    }

    UIViewController *fromVC = [ctx viewControllerForKey:UITransitionContextFromViewControllerKey];
    UIViewController *toVC   = [ctx viewControllerForKey:UITransitionContextToViewControllerKey];
    UIView *fromView = fromVC.view;
    UIView *toView   = toVC.view;
    UIView *container = ctx.containerView;

    // 停止并释放 property animator，彻底释放它对 layer 属性的控制，避免与我们的 UIView 动画冲突。
    // 关键区别：stopAnimation:NO 保持当前属性值（从当前中间态继续动画），
    // stopAnimation:YES 会恢复到 pre-animation 值（导致 toView 跳回缩放到 0.92 的初始态，
    // 视觉上突兀跳跃，且可能触发某些 App 的渲染/layout 异常 → 按钮空白/残留）。
    // 实测 pauseAnimation 会让 paused animator 仍"持有"动画状态 → 与 UIView 动画打架 →
    // completion 延迟 1~2 秒甚至永不触发 → 界面冻结/残留。
    if (_propertyAnimator) {
        if (_propertyAnimator.state != UIViewAnimatingStateInactive) {
            [_propertyAnimator stopAnimation:NO];
        }
        [_propertyAnimator release];
        _propertyAnimator = nil;
    }

    BOOL commit = !_interactiveCancelled;
    OBLog(@"animator forceFinish animating (commit=%d edge=%@ toViewInContainer=%d)",
          commit, self.edge == ObackEdgeLeft ? @"左" : @"右",
          (toView.superview == container));

    __block BOOL transitionFinished = NO;

    // 动量等效收尾：取消时 ObackManager 已把 releaseVelocity 清零→温和回弹；
    // 提交时带入真实前向速度→快甩更快归位（更跟手）。
    // 注：目标 CI 的 iOS SDK 未暴露 UISpringTimingParameters.initialVelocity 与
    // +runningPropertyAnimatorWithDuration:...（-Werror 下编译失败），无法用真弹簧初速做动量继承；
    // 故改用「按释放速度动态缩短/延长收尾时长」的等效方案，基础时长取自 self.params.duration
    // （即设置面板「动画时长」滑块，范围 0.15–0.6s，尊重用户设置），甩得越猛收尾越短，
    // 同样达到"快甩更跟手"的观感，且对现有功能零影响、零 SDK 兼容性风险。
    CGFloat w = fromView.window ? fromView.window.bounds.size.width
                                : [UIScreen mainScreen].bounds.size.width;
    CGFloat sv = (w > 0) ? (self.releaseVelocity / w) : 0.0;   // 归一化到全程比例
    sv = MAX(-2.0, MIN(2.0, sv));                              // 限幅，防极端速度
    BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    BOOL springLike = self.params.springEnabled && !reduceMotion;
    // 动态时长：基础时长取自「动画时长」滑块；|sv| 越大（甩得越猛）收尾越短 → 更跟手；sv≈0（轻拖/取消）保持基础时长。
    // 这是把 duration 接进手指交互松手路径的关键——此前该滑块只在非交互转场（点系统返回按钮）生效。
    CGFloat baseDur = self.params.duration;                   // 接上滑块（非交互+交互松手全状态生效）
    CGFloat asv = (sv > 0) ? sv : -sv;
    CGFloat dur = baseDur / (1.0 + asv * 0.8);                 // sv=±2 → ≈ baseDur*0.385；sv=0 → baseDur
    dur = MAX(0.10, MIN(baseDur, dur));                        // 不超过基础时长，且不低于 0.1s 防过短
    if (!springLike) dur = baseDur;                            // 关闭弹性/减弱动态→用基础时长固定 easeOut
    OBLog(@"animator momentum-eased (springLike=%d vel=%.0f sv=%.2f dur=%.2f baseDur=%.2f)", springLike, self.releaseVelocity, sv, dur, baseDur);

    // 标准 UIView 动画收尾（基础 API，SDK 全版本可用）；时长由释放速度调制。
    [UIView animateWithDuration:dur delay:0
                         options:UIViewAnimationOptionCurveEaseOut
                      animations:^{
        // OBApplyParallax(1)=提交终态, OBApplyParallax(0)=取消回初始态
        UIView *tpView = toView;
        OBApplyParallax(commit ? 1.0 : 0.0, fromView, tpView,
                        self.edge, self.params);
        // 取消回弹时阴影随页面滑回一同淡出到 0；提交时 OBApplyParallax(1) 已将阴影置 0。
        if (!commit) fromView.layer.shadowOpacity = 0.0;
        // 自定义子视图淡出（阴影等）
        for (UIView *sub in container.subviews) {
            if (sub != fromView && sub != toView) sub.alpha = 0.0;
        }
    } completion:^(BOOL finished) {
        if (transitionFinished) return;
        transitionFinished = YES;
        // 清理圆角/阴影残留（取消返回时 fromView 留在屏上，须清掉投影避免永久残留）
        fromView.layer.cornerRadius = 0;
        fromView.layer.masksToBounds = NO;
        fromView.layer.shadowOpacity = 0.0;
        // 双保险：无论动画是否完成，收尾前强制上一页 transform 归位为 identity，
        // 杜绝 dispatch_after/异常路径下 toView 残留缩放态（scrollView 错位/空白）。
        toView.transform = CGAffineTransformIdentity;
        @try {
            [ctx completeTransition:commit];
        } @catch (NSException *exception) {
            OBLog(@"forceComplete completeTransition CRASH: %@", exception.reason);
        }
        if (toView) toView.hidden = NO;   // 还原真实底页可见
        // 显式清理所有非 from/to 子视图（遮罩等）
        NSArray *subs = [[container.subviews copy] autorelease];
        for (UIView *sub in subs) {
            if (sub != fromView && sub != toView) [sub removeFromSuperview];
        }
        OBLog(@"animator forceComplete done (completion, cancelled=%d)", !commit);
    }];

    // 保险：动画视觉完成后若 completion 仍未触发，强制完成转场（防冻结双保险，原样保留）。
    // safetyDelay 取最终 dur + 0.12s 余量（且不低于 0.35s），确保不会在收尾动画进行中（尤其 duration 调大时）提前打断。
    CGFloat safetyDelay = MAX(0.35, dur + 0.12);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(safetyDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (transitionFinished) return;
        transitionFinished = YES;
        // 同上：强制上一页 transform 归位，防止收尾残留缩放态
        toView.transform = CGAffineTransformIdentity;
        @try {
            [ctx completeTransition:commit];
        } @catch (NSException *exception) {
            OBLog(@"forceComplete completeTransition CRASH (dispatch_after): %@", exception.reason);
        }
        if (toView) toView.hidden = NO;   // 还原真实底页可见
        NSArray *subs = [[container.subviews copy] autorelease];
        for (UIView *sub in subs) {
            if (sub != fromView && sub != toView) [sub removeFromSuperview];
        }
        fromView.layer.cornerRadius = 0;
        fromView.layer.masksToBounds = NO;
        fromView.layer.shadowOpacity = 0.0;
        OBLog(@"animator forceComplete done (dispatch_after, cancelled=%d)", !commit);
    });
}

- (void)dealloc {
    if (_params) [_params release];
    [_propertyAnimator release];
    [super dealloc];
}

- (void)applyShadowTo:(UIView *)v {
    // 弹窗下拉卡片圆角开启时，圆角需 masksToBounds=YES 才能显示，会裁掉阴影；
    // 该路径下以圆角为主、放弃阴影，避免两者互相打架。
    BOOL cornering = self.params.cardCornerEnabled;
    v.layer.shadowColor = [UIColor blackColor].CGColor;
    v.layer.shadowOpacity = (self.params.shadowEnabled && !cornering) ? self.params.shadowOpacity : 0.0;
    v.layer.shadowRadius = self.params.shadowRadius;
    v.layer.shadowOffset = CGSizeMake((self.edge == ObackEdgeLeft ? -1.0 : 1.0) * self.params.shadowOffset, 0.0);
    v.layer.masksToBounds = NO;
}

@end

@implementation ObackInteractiveTransition

- (instancetype)initWithEdge:(ObackEdge)edge params:(ObackParams *)params {
    if (self = [super init]) {
        _edge = edge;
        self.params = params ?: [ObackParams defaults];
    }
    return self;
}

#pragma mark - UIViewControllerInteractiveTransitioning
// 必选方法。交互转场入口：把 context 交给 animator（animateTransition: 在交互模式下不会被调用），
// forceFinishIfNeeded 依赖它调 completeTransition。
- (void)startInteractiveTransition:(id<UIViewControllerContextTransitioning>)transitionContext {
    // 交互转场入口：系统不调 animateTransition:，在此把 context 交给 animator，
    // 确保 forceFinishIfNeeded 能拿到 context 调 completeTransition。
    self.animator.context = transitionContext;
    OBLog(@"startInteractiveTransition (ctx=%p animator=%p)", transitionContext, self.animator);
}

// 直接驱动中断式动画器的 fractionComplete（Apple 推荐：实现 interruptibleAnimatorForTransition: 时
// 不要用 UIPercentDrivenInteractiveTransition，改为手动设 fractionComplete）。
- (void)updateWithPercent:(CGFloat)percent {
    UIViewPropertyAnimator *pa = self.animator.propertyAnimator;
    if (!pa) return;
    if (pa.state == UIViewAnimatingStateInactive) {
        [pa pauseAnimation];   // inactive -> 启动并立即暂停，进入可 scrub 态
    }
    pa.fractionComplete = percent;

    
}

- (void)finish {
    // 提交返回：直接调 forceFinishIfNeeded 做 UIView 动画归位 + completeTransition。
    // （旧版曾用中断式动画续跑接口(interruptible animator)，但它在 double-fetch(微信等)时会
    // 阻塞主线程，watchdog 定时器无法触发 → 冻结/闪退，故废弃。）
    ObackAnimator *anim = self.animator ?: [ObackManager shared].currentAnimator;
    OBLog(@"oback-intc finish (self=%p animator=%p)", self, anim);
    anim.interactiveCancelled = NO;
    [anim forceFinishIfNeeded];
}

- (void)cancel {
    // 取消回弹：直接调 forceFinishIfNeeded 做 UIView 动画归位(回初始态) + completeTransition:NO。
    // （中断式动画续跑接口已废弃，同 finish 根因。）
    ObackAnimator *anim = self.animator ?: [ObackManager shared].currentAnimator;
    anim.interactiveCancelled = YES;
    OBLog(@"oback-intc cancel (self=%p animator=%p)", self, anim);
    [anim forceFinishIfNeeded];
}

- (void)dealloc {
    if (_params) [_params release];
    [super dealloc];
}

@end
