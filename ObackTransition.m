#import "ObackTransition.h"
#import "ObackManager.h"   // 读取松手速度/进度做动量继承（ObackManager.h 已 import ObackTransition.h，无循环依赖）

// 该 SDK 头未在本编译单元暴露 UIViewImplicitlyAnimating 协议的
// continueAnimationWithTimingParameters: 声明，-Werror 会把它误判为 error。
// 这里用分类声明让编译器识别（运行时该方法由系统实现，无冲突、无重复实现）。
@interface UIViewPropertyAnimator (ObackContinue)
- (void)continueAnimationWithTimingParameters:(id)parameters;
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
                            BOOL parallaxToView,
                            BOOL scaleToView) {
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
        // 上一页视差：仅作用于「截图层」(scaleToView=YES 时 toView 即截图)，真实底页保持 Identity 不缩放
        // → 其内部 scrollView 永不被 transform 扰动（根治华为健康底部错位）。scaleToView=NO（截图失败等
        // 兜底）则保持静止，退化为无缩放的安全铺底，不引入风险。
        if (scaleToView) {
            // 上一页从 previousScaleMin(0.92) 放大到 1.0、并随拖动做反向轻移，模拟 OPPO「上一页探出+放大」纵深感。
            CGFloat scale = p.previousScaleMin + (1.0 - p.previousScaleMin) * percent;
            CGFloat shift = -dir * (1.0 - percent) * p.parallaxOffset * w;   // dir=当前页方向，上一页反向探出
            toView.transform = CGAffineTransformConcat(
                CGAffineTransformMakeTranslation(shift, 0),
                CGAffineTransformMakeScale(scale, scale));
        } else {
            toView.transform = CGAffineTransformIdentity;
        }
        if (dimView) dimView.alpha = (1.0 - percent) * p.dimAlpha;
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
    ObackParams *p = [[[ObackParams alloc] init] autorelease];
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
        self.params = params ?: [ObackParams defaults];
        _parallaxToView = YES;   // 默认 nav pop 视差（安全且已验证）；弹窗 dismiss 由调用方置 NO
    }
    return self;
}

- (NSTimeInterval)transitionDuration:(id<UIViewControllerContextTransitioning>)transitionContext {
    return self.params.duration;
}

- (void)animateTransition:(id<UIViewControllerContextTransitioning>)ctx {
    // 诊断：入口确定执行一次（每次转场开始）。注意此刻 releaseVelocity 仍为 beginTransition 清零后的 0，
    // 真实速度在 finish 时写入并体现在「animator spring applied」日志里。此处仅确认走了弹簧/线性分支。
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
    // 非交互时直接跑到完成。视图层级(dim/阴影/parallax)在该方法内搭建。
    [self interruptibleAnimatorForTransition:ctx];
}

// 中断式动画器：速度感知弹簧的核心。系统对交互转场会暂停它并按 updateWithPercent 设定 fractionComplete，
// finish 时 ObackInteractiveTransition 调 [animator applyReleaseVelocity] 更新弹簧初速度后由系统续完。
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

    UIView *dim = nil;
    UIView *toParallaxView = toView;   // 上一页视差实际作用视图（默认真实 toView；截图成功则改截图层）
    BOOL doScale = NO;                 // 是否对上一页施加缩放视差（截图成功才 YES，失败退化为安全静止）
    if (self.parallaxToView) {
        // nav pop：底页(toView) 真实视图入 container 作底（Identity，零 transform，scrollView 安全，
        // 兼修 reparent 黑屏）；其上叠加一张 toView 的静态截图 snap 作为「缩放视差层」——
        // 只对 snap 施加 0.92→1.0 缩放+位移，真实 toView 始终 Identity 不缩放 → 内部 scrollView 永不被
        // 扰动（根治华为健康底部错位），同时恢复 OPPO 风格上一页缩放视差。
        // 截图时机：toView 入 container 并 layoutIfNeeded 后再拍，确保取到已布局内容（旧版
        // drawViewHierarchyInRect 在 toView 未入窗时拍到空白→右缘空白）。
        if (fromView.superview != container) [container addSubview:fromView];
        if (toView && toView.superview != container) {
            toView.frame = container.bounds;
            [toView layoutIfNeeded];
            [container insertSubview:toView atIndex:0];
        }
        if (toView && !_toViewSnapshot) {
            UIView *snap = [toView snapshotViewAfterScreenUpdates:NO];
            if (snap) {
                snap.frame = toView.frame;
                _toViewSnapshot = [snap retain];   // MRC：snapshot 默认 autorelease，retain 持有
                [container insertSubview:_toViewSnapshot aboveSubview:toView];
                toView.hidden = YES;               // 隐藏真实底页，避免缩放 snap 周围透出未缩放底页
                toParallaxView = _toViewSnapshot;
                doScale = YES;
                OBLog(@"nav pop 截图层创建成功 (snap=%p) → 启用缩放视差", _toViewSnapshot);
            } else {
                OBLog(@"nav pop 截图层创建失败 → 退化为真实 toView 静止铺底(无缩放)");
            }
        }
    } else {
        // 弹窗 dismiss 方案B：底层 presenting(toView) 不碰 transform；目的页正常挂载，
        // dim 置于二者之间（presenting 不加深遮罩，避免已可见背景闪暗）。
        // 【黑屏修复】绝对不要无条件把 toView 塞进临时 container：
        //   - UIKit App：UIKit 已在转场开始时把 toView 预置进 container → superview==container，本就是空操作；
        //   - SwiftUI App(如 com.wangcaicalculator.wc，弹窗为 PresentationHostingController)：底层
        //     UIHostingController 视图挂在 window 下层、不在 container → 原代码 insert 会把它从真实
        //     层级抽进临时 container，dismiss 完成 UIKit 拆 container 时把它一并销毁 → 返回后整屏黑
        //     (进程活着、能上滑回桌面、不卡死)。故：仅当 toView 完全无宿主(superview==nil，被系统移出
        //     窗口、不装进 container 就全程不可见)才装入；否则保持原层级不动，底层自然可见。
        if (toView.superview == nil) [container insertSubview:toView atIndex:0];
        dim = [self _makeDimViewWithFrame:container.bounds edge:self.edge];
        dim.alpha = 0;
        dim.userInteractionEnabled = NO;   // 遮罩绝不拦截触摸
        // toView 可能不在 container 内(SwiftUI 挂在 window 下层)：此时 aboveSubview 无意义，
        // 退化为放到 container 最底层；随后 bringSubviewToFront(fromView) 保证 sheet 在 dim 之上，
        // 底层经透明 container 透出。避免传 nil 给 aboveSubview(部分 iOS 版本不安全)。
        if (toView.superview == container) [container insertSubview:dim aboveSubview:toView];
        else [container insertSubview:dim atIndex:0];
    }
    [container bringSubviewToFront:fromView];

    // ── 导航栏协同引擎（实验 nav 视差专用）──────────────────────────────
    // 自定义 nav pop 转场中，live UINavigationBar 由 nav controller 私有持有、不随 container 的
    // fromView/toView 移动 → 转场期间导航栏不跟手、转场后易损坏/消失。故：快照真实 bar，挂到
    // fromView 上随其平移（OBApplyParallax 平移 fromView 时 snapshot 作为子视图一起动），转场结束
    // （含 cancel / watchdog 兜底 / dealloc）由 _restoreNavBar 还原真实 bar。仅 nav pop(parallaxToView=YES) 触发。
    if (self.parallaxToView && !_navBarSnapshot) {
        UINavigationController *navC = from.navigationController ?: to.navigationController;
        UINavigationBar *realBar = navC.navigationBar;
        if (navC && realBar && !navC.navigationBarHidden) {
            _navBarWasHidden = realBar.hidden;
            _navBarSnapshot = [[realBar snapshotViewAfterScreenUpdates:NO] retain];   // MRC：snapshot 默认 autorelease，retain 持有
            _navBarSnapshot.userInteractionEnabled = NO;
            _navBarSnapshot.frame = [realBar convertRect:realBar.bounds toView:fromView];
            [fromView addSubview:_navBarSnapshot];   // 作为 fromView 子视图，随其 transform 平移
            realBar.hidden = YES;                    // 隐藏真实 bar，避免转场期间重复/错位
            _navBarNav = navC;                        // assign，不 retain（避免循环引用）
            OBLog(@"navBar 快照: 隐藏真实 bar，挂载 snapshot 到 fromView (nav=%@)",
                  NSStringFromClass([navC class]));
        }
    }

    if (dim) [dim release];   // MRC：已加入 container 被其 retain，释放我们的所有权（nil 时跳过）

    [self applyShadowTo:fromView];
    OBApplyParallax(0, fromView, toParallaxView, dim, self.edge, self.params, self.parallaxToView, doScale);

    // 初速 0（真实速度在 finish 时经 applyReleaseVelocity 更新），damping 0.82 给出自然回弹手感
    UISpringTimingParameters *sp = [[UISpringTimingParameters alloc] initWithDampingRatio:0.82];
    UIViewPropertyAnimator *anim = [[[UIViewPropertyAnimator alloc]
        initWithDuration:self.params.duration
          timingParameters:sp] autorelease];
    [sp release];   // MRC：animator 内部已拷贝 timing，释放我们的所有权
    // MRC：禁用 __weak，用 __block 且 completion 内置 nil 打破 self->animator->block->self 循环引用
    __block ObackAnimator *blockSelf = self;
    [anim addAnimations:^{
        UIView *tpView = blockSelf.toViewSnapshot ?: toView;
        BOOL tpScale = (blockSelf.parallaxToView && blockSelf.toViewSnapshot != nil);
        OBApplyParallax(1, fromView, tpView, dim, blockSelf.edge, blockSelf.params, blockSelf.parallaxToView, tpScale);
    }];
    [anim addCompletion:^(UIViewAnimatingPosition finalPosition) {
        [dim removeFromSuperview];
        // 以 interactiveCancelled 为准（finish=NO/cancel=YES），避免反向动画 finalPosition 误判
        BOOL cancelled = blockSelf.interactiveCancelled || (finalPosition == UIViewAnimatingPositionStart);
        if (blockSelf.completed) { blockSelf = nil; return; }   // 已被 manager 兜底收尾 → 防重复 completeTransition
        blockSelf.completed = YES;
        if (blockSelf.context) [blockSelf.context completeTransition:!cancelled];
        [blockSelf _restoreNavBar];   // 还原真实导航栏（实验 nav 视差）
        [blockSelf _cleanupToViewSnapshot:toView];   // 还原真实底页可见 + 移除截图层
        OBLog(@"animator done (cancelled=%d)", cancelled);
        blockSelf = nil;   // 打破循环引用（MRC 无 __weak）
    }];
    self.propertyAnimator = anim;   // retain 属性赋值（anim 为 autorelease，直接赋 ivar 会在 drain 后野指针）
    OBLog(@"interruptible built pa=%p", _propertyAnimator);
    return anim;
}

// 在 finish/cancel 前由 ObackInteractiveTransition 调用：用真实松手速度更新弹簧初速度，实现动量继承。
// 取消时 ObackManager 已把 releaseVelocity 清零→温和回弹；提交时带入真实速度→快甩更快归位。
- (void)applyReleaseVelocity {
    if (!_propertyAnimator) {
        OBLog(@"applyReleaseVelocity SKIP (propertyAnimator=nil)");
        return;
    }
    BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    BOOL spring = self.params.springEnabled && !reduceMotion;
    CGFloat w = [UIScreen mainScreen].bounds.size.width;
    CGFloat sv = (w > 0) ? (self.releaseVelocity / w) : 0.0;
    sv = MAX(-2.0, MIN(2.0, sv));   // 弹簧初速度（相对全程）
    NSObject<UITimingCurveProvider> *tp;
    if (spring) {
        tp = [[UISpringTimingParameters alloc] initWithDampingRatio:0.82
                                                       initialVelocity:CGVectorMake(sv, 0.0)];
    } else {
        // 关闭弹性 / 减弱动态效果 → 线性 easeOut 兜底（与旧版一致）
        tp = [[UICubicTimingParameters alloc] initWithAnimationCurve:UIViewAnimationCurveEaseOut];
    }
    OBLog(@"animator spring applied (spring=%d vel=%.0f startP=%.2f sv=%.2f)",
          spring, self.releaseVelocity, self.releasePercent, sv);
    [_propertyAnimator continueAnimationWithTimingParameters:tp];
    [tp release];   // MRC：alloc 所得；方法内部已拷贝 timing，此处释放所有权
}

// 统一收尾（finish/cancel/watchdog 共用）：
// 不再依赖 UIViewPropertyAnimator 的 continueAnimation（double-fetch 时会阻塞主线程 →
// watchdog 定时器无法触发 → 冻结/闪退）。改为：停止 property animator（彻底释放它对 layer
// 的动画控制，避免与 UIView 动画冲突）→ 用标准 UIView 动画把视图归位到终态 → 在动画
// completion 里做 cleanup；completeTransition 由 completion + dispatch_after(0.3s) 双重
// 保险确保一定被调用，避免某些 App 中 completion 延迟 1~2 秒导致界面冻结。
// _completed 守卫防重复（finish/cancel 先调一次，watchdog 0.5s 后调则直接返回）。
// 还原真实导航栏（与 _navBarSnapshot 配对）：转场完成/取消/watchdog 兜底、dealloc 均调用，
// 确保真实 bar 必还原（hidden 写回原值），杜绝导航栏永久消失。_navBarSnapshot 非空才执行（幂等）。
- (void)_restoreNavBar {
    if (!_navBarSnapshot) return;
    [_navBarSnapshot removeFromSuperview];
    [_navBarSnapshot release];
    _navBarSnapshot = nil;
    if (_navBarNav) {
        @try { _navBarNav.navigationBar.hidden = _navBarWasHidden; }
        @catch (NSException *e) { OBLog(@"restoreNavBar hidden 写回异常: %@", e.reason); }
        _navBarNav = nil;
    }
    OBLog(@"navBar 还原: 真实 bar 显示恢复 (hidden=%d)", _navBarWasHidden);
}

// 实验 nav 视差清理（与 _toViewSnapshot 配对）：还原真实底页可见、移除并释放截图层。
// 转场完成/取消/watchdog 兜底、dealloc 前的各出口均调用，确保真实底页必现、截图层不泄漏。
- (void)_cleanupToViewSnapshot:(UIView *)realToView {
    if (_toViewSnapshot) {
        [_toViewSnapshot removeFromSuperview];
        [_toViewSnapshot release];
        _toViewSnapshot = nil;
    }
    if (realToView) realToView.hidden = NO;
}

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
    OBLog(@"animator forceFinish animating (commit=%d edge=%@ parallaxToView=%d toViewInContainer=%d)",
          commit, self.edge == ObackEdgeLeft ? @"左" : @"右",
          self.parallaxToView, (toView.superview == container));

    __block BOOL transitionFinished = NO;

    // 用标准 UIView 动画把视图从当前中间态归位到终态（0.22s easeOut）
    [UIView animateWithDuration:0.22 delay:0
                         options:UIViewAnimationOptionCurveEaseOut
                      animations:^{
        // OBApplyParallax(1)=提交终态, OBApplyParallax(0)=取消回初始态
        UIView *tpView = self.toViewSnapshot ?: toView;
        BOOL tpScale = (self.parallaxToView && self.toViewSnapshot != nil);
        OBApplyParallax(commit ? 1.0 : 0.0, fromView, tpView, nil,
                        self.edge, self.params, self.parallaxToView, tpScale);
        // 遮罩/自定义子视图淡出（dim、阴影等）
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
        [self _restoreNavBar];   // 还原真实导航栏（实验 nav 视差）
        [self _cleanupToViewSnapshot:toView];   // 还原真实底页可见 + 移除/释放截图层
        // 显式清理所有非 from/to 子视图（dim 遮罩等）
        NSArray *subs = [[container.subviews copy] autorelease];
        for (UIView *sub in subs) {
            if (sub != fromView && sub != toView) [sub removeFromSuperview];
        }
        OBLog(@"animator forceComplete done (completion, cancelled=%d)", !commit);
    }];

    // 保险：0.3 秒后如果 completion 仍未触发，强制完成转场。
    // 避免某些 App 中 UIView 动画 completion 延迟 1~2 秒甚至永不触发导致界面冻结。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
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
        [self _restoreNavBar];   // 还原真实导航栏（实验 nav 视差）
        [self _cleanupToViewSnapshot:toView];   // 还原真实底页可见 + 移除/释放截图层
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
    if (_navBarSnapshot) [_navBarSnapshot release];   // 兜底（正常路径已在 _restoreNavBar 释放）
    if (_toViewSnapshot) [_toViewSnapshot release];   // 兜底（正常路径已在 _cleanupToViewSnapshot 释放）
    [super dealloc];
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
    UIView *v = [[[UIView alloc] initWithFrame:frame] autorelease];
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
        self.params = params ?: [ObackParams defaults];
        _parallaxToView = YES;   // 默认 nav pop 视差；弹窗 dismiss 由调用方置 NO
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
    // 不再调 applyReleaseVelocity/continueAnimation —— 后者在 double-fetch(微信等)时会
    // 阻塞主线程，watchdog 定时器无法触发 → 冻结/闪退。
    ObackAnimator *anim = self.animator ?: [ObackManager shared].currentAnimator;
    OBLog(@"oback-intc finish (self=%p animator=%p)", self, anim);
    anim.interactiveCancelled = NO;
    [anim forceFinishIfNeeded];
}

- (void)cancel {
    // 取消回弹：直接调 forceFinishIfNeeded 做 UIView 动画归位(回初始态) + completeTransition:NO。
    // 不再调 continueAnimationWithTimingParameters: —— 同 finish 的根因。
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
