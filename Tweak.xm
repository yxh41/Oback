#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import "ObackManager.h"
#import "ObackTransition.h"
#import "ObackPreferences.h"

static void *kNavDelegateKey = &kNavDelegateKey;
extern void *kPanKey;   // 定义于 ObackManager.m：window 上挂载的 Oback 全屏 pan 手势

#pragma mark - 冲突插件检测（仅诊断，不再阻断）
// 已知与 Oback 可能共存的 tweak（如 AppTool）。以前命中即完全退避（setDelegate 透传），会掐掉
// Oback 的 nav 自定义动画。现已解除退避——ObackNavDelegate 安全转发，fd 必为最外层，动画接管由
// Oback 决定。此处仅保留运行时检测并打日志，供真机验证共存风险。
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
        ObackAnimator *a = [[ObackAnimator alloc] initWithEdge:[ObackManager shared].currentEdge
                                                      params:[ObackPreferences params]];
        a.parallaxToView = [ObackManager shared].currentParallaxToView;  // 弹窗 dismiss 置 NO(方案B: 只动 sheet)
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
    // [2026-07-25 变更] 解除 AppTool 退避：此前命中 AppTool 时完全透传、永不包装 ObackNavDelegate，
    // 导致 nav 自定义动画（视差/胶囊/动量）整个被掐掉。现改为即使检测到 AppTool 共存也正常包装 fd——
    // ObackNavDelegate 已实现 forwardingTargetForSelector:，对未实现方法安全转发回原 delegate，
    // 不会让 AppTool 收到 nil；且 fd 必为 nav.delegate 最外层，动画接管由 Oback 决定，AppTool 通过
    // forwarding 仍能收到 delegate 消息。与 AppTool 共存的手势双触发/卡死/黑屏风险需真机验证。
    // 当前 App 不在生效范围（白/黑名单）时，仍直接透传原方法，不做任何包装
    if (![ObackPreferences isAllowed]) {
        %orig;
        return;
    }
    if (oback_shouldBackOff()) {
        OBLog(@"oback: 检测到 AppTool 共存，已解除退避，正常包装 fd（共存风险待真机验证）");
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
    // 关闭系统自带左边缘返回，避免和我们手势双重触发
    self.interactivePopGestureRecognizer.enabled = NO;
    // 让原生手势"失败于"我们的 window pan：即使 App 后续把 enabled 重新置 YES（微信常这么做），
    // 原生手势的 begin 仍须等我们的手势先失败，从根上杜绝"一次滑动被两套手势各弹一层"的双返回。
    UIWindow *win = self.view.window;
    if (!win) win = self.topViewController.view.window;
    if (win) {
        id pans = objc_getAssociatedObject(win, kPanKey);
        if ([pans isKindOfClass:[NSArray class]]) {
            for (id pan in pans) {
                @try { [self.interactivePopGestureRecognizer requireGestureRecognizerToFail:pan]; }
                @catch (NSException *e) {}
            }
        } else if (pans) {
            @try { [self.interactivePopGestureRecognizer requireGestureRecognizerToFail:pans]; }
            @catch (NSException *e) {}
        }
    }
    %orig(fd);
}

- (void)viewDidLoad {
    %orig;
    // App 未在初始化时设置 delegate 时，也确保我们的转发器就位
    if (!self.delegate) {
        [self setDelegate:nil];
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
        // 注：手势(核心功能)始终启动；与 AppTool 的冲突只通过 setDelegate: 透传来规避，
        // 不在此处停掉手势，否则会连主功能一起关掉。
        [[ObackManager shared] start];
    }];
}
