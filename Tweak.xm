#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import "ObackManager.h"
#import "ObackTransition.h"
#import "ObackPreferences.h"

static void *kNavDelegateKey = &kNavDelegateKey;
extern void *kPanKey;   // 定义于 ObackManager.m：window 上挂载的 Oback 全屏 pan 手势

#pragma mark - 冲突插件检测（命中即退避）
// 已知与 Oback 可能共存的 tweak（AppTool）。2026-07-25 曾解除退避（仅诊断），
// 但真机证实 AppTool 共存会令 QQ 在注入期进程秒杀（无 .ips/无日志，Choicy 禁其注入即恢复）。
// 故恢复退避：命中即整体不注入（setDelegate 透传 + 不启动手势管理器 + 不挂边缘 pan），
// 彻底规避与 AppTool 在 QQ 进程内的冲突。需用 AppTool 的用户可用 Choicy 二选一。
// 检测在运行时（App 启动后所有 dylib 已加载）惰性解析一次并缓存，避免 %ctor 阶段顺序问题导致漏检。
static BOOL _obackBackOffResolved = NO;
static BOOL _obackBackOff = NO;

static BOOL oback_shouldBackOff(void) {
    if (_obackBackOffResolved) return _obackBackOff;
    _obackBackOffResolved = YES;
    NSArray<NSString *> *incompatible = @[ @"AppTool" ];
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *img = _dyld_get_image_name(i);
        if (!img) continue;
        NSString *name = [NSString stringWithUTF8String:img];
        if (!name) continue;
        for (NSString *n in incompatible) {
            if ([[name lastPathComponent] hasPrefix:n]) { _obackBackOff = YES; OBLog(@"oback backoff resolved = 1 (检测到 %@)", n); return YES; }
        }
    }
    _obackBackOff = NO;
    OBLog(@"oback backoff resolved = 0 (无冲突插件)");
    return NO;
}

#pragma mark - UINavigationController delegate 转发器

// 包一层 delegate：保留 App 原有 delegate，同时注入我们的 pop 动画/交互
@interface ObackNavDelegate : NSObject <UINavigationControllerDelegate>
@property (nonatomic, assign) id<UINavigationControllerDelegate> original;
@property (nonatomic, assign) UINavigationController *nav;
@end

@implementation ObackNavDelegate

- (id<UIViewControllerAnimatedTransitioning>)navigationController:(UINavigationController *)nav
                                  animationControllerForOperation:(UINavigationControllerOperation)operation
                                               fromViewController:(UIViewController *)from
                                                 toViewController:(UIViewController *)to {
    BOOL interacting = [ObackManager shared].interacting;
    OBLog(@"nav-anim query (op=%ld interacting=%d)", (long)operation, interacting);
    [ObackManager shared].currentAnimator = nil;   // 先清，避免残留上一轮动画器
    // 仅在我们手势驱动返回时接管 pop 动画；普通返回按钮走 App 原生转场（避免破坏/黑屏）
    if (operation == UINavigationControllerOperationPop && interacting) {
        // 方案 A：返回 nil → 系统原生交互 pop（toView 由 UIKit 原生处理，
        // 根除自定义转场 reparent toView 进 containerView 导致的空白 / 导航栏损坏 / scrollView 错位）。
        // 系统默认转场由 _UINavigationInteractiveTransition 驱动，ObackManager 已用
        // handleNavigationTransition: 把 window pan 喂给它做 scrub。
        if ([ObackManager shared].navPopUseObackAnimator) {
            // QQ/TIM：自定义交互 nav pop（阴影渐隐，上一页 Identity 天然可见），跟手，
            // 规避 NTPushPopLib 等自研转场不跟手 scrub。interactionControllerForAnimationController:
            // 对 ObackAnimator 自动返回 self.interactive，无需额外接线。
            ObackAnimator *a = [[[ObackAnimator alloc] initWithEdge:[ObackManager shared].currentEdge
                                                               params:[ObackPreferences params]] autorelease];
            a.navPop = YES;   // nav pop 模式：纯平移+阴影渐隐，不缩放
            [ObackManager shared].interactive.animator = a;
            [ObackManager shared].currentAnimator = a;
            OBLog(@"nav-anim -> ObackAnimator (QQ/TIM 自定义 nav pop)");
            return a;
        }
        OBLog(@"nav-anim -> nil (方案A: 系统原生 pop)");
        return nil;
    }
    id ret = nil;
    if (_original && [_original respondsToSelector:_cmd])
        ret = [_original navigationController:nav animationControllerForOperation:operation
                            fromViewController:from toViewController:to];
    OBLog(@"nav-anim -> %@ (original/nil path)", ret ? NSStringFromClass([ret class]) : @"nil");
    return ret;
}

- (id<UIViewControllerInteractiveTransitioning>)navigationController:(UINavigationController *)nav
                         interactionControllerForAnimationController:(id<UIViewControllerAnimatedTransitioning>)animator {
    BOOL interacting = [ObackManager shared].interacting;
    OBLog(@"nav-intc query (animator=%@ interacting=%d)", NSStringFromClass([animator class]), interacting);
    if (interacting && [animator isKindOfClass:[ObackAnimator class]])
        return [ObackManager shared].interactive;
    if (_original && [_original respondsToSelector:_cmd])
        return [_original navigationController:nav interactionControllerForAnimationController:animator];
    return nil;
}

- (id)forwardingTargetForSelector:(SEL)sel {
    return [_original respondsToSelector:sel] ? _original : nil;
}

- (BOOL)respondsToSelector:(SEL)sel {
    if (sel == @selector(navigationController:animationControllerForOperation:fromViewController:toViewController:) ||
        sel == @selector(navigationController:interactionControllerForAnimationController:))
        return YES;
    return [_original respondsToSelector:sel];
}

@end

#pragma mark - UIViewController transitioning delegate 转发器

// ObackTransitioningDelegate 的 @interface 已移至 ObackTransition.h（Tweak.xm 与 ObackManager.m 共用）
@implementation ObackTransitioningDelegate

- (id<UIViewControllerAnimatedTransitioning>)animationControllerForDismissedController:(UIViewController *)dismissed {
    [ObackManager shared].currentAnimator = nil;   // 先清，避免残留上一轮动画器
    // 仅在手势驱动返回时接管 dismiss 动画；普通关闭按钮等系统 dismiss 走 App 原生动画，
    // 避免对 fullScreen / 系统自带 modal 强行套自定义转场导致黑屏（此前无条件返回是黑屏根因之一）
    if ([ObackManager shared].interacting) {
        ObackAnimator *a = [[[ObackAnimator alloc] initWithEdge:[ObackManager shared].currentEdge
                                                           params:[ObackPreferences params]] autorelease];
        [ObackManager shared].interactive.animator = a;   // 反向引用，finish/cancel 时改弹簧速度
        [ObackManager shared].currentAnimator = a;
        return a;
    }
    if (_original && [_original respondsToSelector:_cmd])
        return [_original animationControllerForDismissedController:dismissed];
    return nil;
}

- (id<UIViewControllerInteractiveTransitioning>)interactionControllerForDismissal:(id<UIViewControllerAnimatedTransitioning>)animator {
    if ([ObackManager shared].interacting && [animator isKindOfClass:[ObackAnimator class]])
        return [ObackManager shared].interactive;
    if (_original && [_original respondsToSelector:_cmd])
        return [_original interactionControllerForDismissal:animator];
    return nil;
}

- (id)forwardingTargetForSelector:(SEL)sel {
    return [_original respondsToSelector:sel] ? _original : nil;
}

- (BOOL)respondsToSelector:(SEL)sel {
    if (sel == @selector(animationControllerForDismissedController:) ||
        sel == @selector(interactionControllerForDismissal:))
        return YES;
    return [_original respondsToSelector:sel];
}

@end

#pragma mark - Hook

%group Oback

%hook UINavigationController

- (void)setDelegate:(id)delegate {
    // [2026-07-25 变更] 曾解除 AppTool 退避（改为正常包装 ObackNavDelegate），但真机证实 AppTool 共存
    // 会令 QQ 注入期进程秒杀（无 .ips/无日志，Choicy 禁其注入即恢复）。
    // [2026-08-13 回退] 恢复退避：命中 AppTool 即完全透传（见下方 oback_shouldBackOff 分支），
    // 不再包装 fd，彻底规避与 AppTool 在 QQ 进程内的冲突。代价是 AppTool 在场时 Oback 在 QQ 内不生效
    // （用户可用 Choicy 二选一）。当前 App 不在生效范围（白/黑名单）时，仍直接透传原方法，不做任何包装
    if (![ObackPreferences isAllowed]) {
        %orig;
        return;
    }
    if (oback_shouldBackOff()) {
        // [2026-08-13 修复] AppTool 共存实测令 QQ 注入期进程秒杀（无 .ips/无日志），Choicy 禁其注入即恢复。
        // 恢复退避：命中即完全透传、不包装 ObackNavDelegate，彻底规避与 AppTool 在 QQ 进程内的冲突。
        OBLog(@"oback: 检测到 AppTool 共存，已退避（不包装 nav delegate，规避共存崩溃）");
        %orig;
        return;
    }
    // 避免递归：已是我们自己的转发器时直接调用原方法（透传原参数）
    if ([delegate isKindOfClass:[ObackNavDelegate class]]) {
        %orig;
        return;
    }

    ObackNavDelegate *fd = objc_getAssociatedObject(self, kNavDelegateKey);
    if (!fd) {
        fd = [[ObackNavDelegate alloc] init];
        fd.nav = self;
        objc_setAssociatedObject(self, kNavDelegateKey, fd, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    fd.original = delegate;
    // 关闭系统自带左边缘返回（避免和我们手势同时驱动 handleNavigationTransition: 造成双返回）。
    // 不再对其设 requireGestureRecognizerToFail: —— 让步改由 ObackManager 的
    // gestureRecognizer:shouldRequireFailureOfGestureRecognizer: 单向处理（OUR delegate 决策，
    // 对手无法否决，且避免与系统手势互锁导致两边都不 begin）。微信等事后重开 enabled 时，
    // 我们的边缘 pan 会让步给它（单层原生返回），绝不会双触发。
    if (![ObackPreferences isLeftEdgeExcluded]) {
        self.interactivePopGestureRecognizer.enabled = NO;
    }
    %orig(fd);
}

- (void)viewDidLoad {
    %orig;
    // App 未在初始化时设置 delegate 时，也确保我们的转发器就位
    if (!self.delegate) {
        [self setDelegate:nil];
    }
    // [2026-07-25 修复 朋友圈] 双 hook（viewDidLoad + viewDidAppear）确保微信 MMUINavigationController
    // 无论在哪一处调用 super 都能挂上边缘 pan（幂等，重复挂无效）；绕过自定义容器枚举遗漏。
    if (![ObackPreferences isAllowed] || oback_shouldBackOff()) return;
    [[ObackManager shared] _attachNavPanToNav:self win:self.view.window];
    if (![ObackPreferences isLeftEdgeExcluded]) {
    self.interactivePopGestureRecognizer.enabled = NO;
    }
    OBLog(@"swizzle nav viewDidLoad: nav=%@ 已挂 oback 边缘 pan", NSStringFromClass([self class]));
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // [2026-07-25 修复 朋友圈] swizzle UINavigationController 基类：任意子类（含微信 MMUINavigationController）
    // 一显示即自动挂边缘 pan 到 nav.view 并关掉系统原生 interactivePop——绕过自定义容器枚举遗漏
    // （朋友圈所在 nav 不在 win.rootViewController 标准 childViewControllers 链上，旧枚举永远漏挂 → 无返回）。
    if (![ObackPreferences isAllowed] || oback_shouldBackOff()) return;
    [[ObackManager shared] _attachNavPanToNav:self win:self.view.window];
    if (![ObackPreferences isLeftEdgeExcluded]) {
    self.interactivePopGestureRecognizer.enabled = NO;
    }
    // 全窗口链接：每 nav 显示跑一次（非每次手势），让原生 interactivePop / 插件边缘手势 /
    // 已存在的 scrollView 失败于我们的 pan（成对依赖持久）。晚到的 scrollView 由 shouldBegin 精准补链覆盖。
    UIWindow *lnkWin = self.view.window;
    if (lnkWin) [[ObackManager shared] _linkNavPopGesturesInWindow:lnkWin];
    OBLog(@"swizzle nav viewDidAppear: nav=%@ 已挂 oback 边缘 pan", NSStringFromClass([self class]));
}

- (void)viewDidLayoutSubviews {
    %orig;
    // [2026-07-25 加固] 第 3 挂载点：viewDidLoad 时 view.window 常为 nil 而早退，viewDidAppear 又
    // 可能被子类不调 super → 朋友圈等 nav 漏挂。viewDidLayoutSubviews 在 view 已布局、window 就绪后
    // 几乎必调，作为兜底挂载点（幂等：已挂过则 _attachNavPanToNav 直接 return）。此处只挂 pan +
    // 关原生 interactivePop，不做全窗口链接（layout 调用频次高，链接已在 viewDidAppear / windowBecameKey
    // 各跑一次，且晚到 scrollView 由 shouldBegin 精准补链）。
    if (![ObackPreferences isAllowed] || oback_shouldBackOff()) return;
    if (self.view.window) {
        [[ObackManager shared] _attachNavPanToNav:self win:self.view.window];
        if (![ObackPreferences isLeftEdgeExcluded]) {
        self.interactivePopGestureRecognizer.enabled = NO;
        }
    }
}

%end

%end

%ctor {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    // 不注入任何 Apple 系统进程（SpringBoard/设置/海报/Spotlight/各种 extension 等）。
    // 系统进程 bundle id 大小写不固定（如 SpringBoard 实为 com.apple.springboard），
    // 用前缀匹配最稳，避免误注入导致系统 UI 异常/黑屏。
    if ([bid hasPrefix:@"com.apple."]) {
        NSLog(@"[Oback] %@ 是系统进程，不注入", bid);
        return;
    }
    // 包管理器：其「确认安装/Depiction」等页面用自定义 present 转场，
    // 我们的转场会把它渲染成黑屏（非崩溃、可上滑回桌面）。直接不注入。
    NSSet *pkgManagers = [NSSet setWithObjects:
        @"org.coolstar.Sileo",
        @"com.sileo.sileo",
        @"xyz.willy.Zebra",
        @"com.saurik.cydia",
        @"org.telesphoreos.installer",
        @"com.aboutsy.saily",
        nil];
    if ([pkgManagers containsObject:bid]) {
        NSLog(@"[Oback] %@ 是包管理器，不注入", bid);
        return;
    }
    NSLog(@"[Oback] 已注入 %@, 启动手势管理器", bid);
    %init(Oback);
    // 每个 App 启动完成后启动手势管理器
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note){
        // [2026-08-13 修复] AppTool 共存会令进程秒杀，故检测到即整体退避（不启动手势管理器），
        // 与下方 nav hook 的退避一致，彻底规避冲突。Choicy 禁 AppTool 注入时本检测为假，Oback 正常生效。
        if (oback_shouldBackOff()) {
            OBLog(@"oback: 检测到 AppTool 共存，已退避，不启动手势管理器（规避共存崩溃）");
            return;
        }
        [[ObackManager shared] start];
    }];
}
