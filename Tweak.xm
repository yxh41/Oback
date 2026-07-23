#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import "ObackManager.h"
#import "ObackTransition.h"
#import "ObackPreferences.h"

static void *kNavDelegateKey = &kNavDelegateKey;

#pragma mark - 冲突插件退避
// 已知与 Oback 在系统进程/App 内交互、会因此触发对方插件 nil 崩溃（安全模式）的共存 tweak。
// 命中即本进程完全不激活 Oback（setDelegate 透传 + 不启动手势），避免双 tweak 打架把对方逼崩。
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
            if ([[name lastPathComponent] hasPrefix:n]) { _obackBackOff = YES; return YES; }
        }
    }
    _obackBackOff = NO;
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
    // 仅在我们手势驱动返回时接管 pop 动画；普通返回按钮走 App 原生转场（避免破坏/黑屏）
    if (operation == UINavigationControllerOperationPop && [ObackManager shared].interacting) {
        return [[ObackAnimator alloc] initWithEdge:[ObackManager shared].currentEdge
                                           params:[ObackPreferences params]];
    }
    if (_original && [_original respondsToSelector:_cmd])
        return [_original navigationController:nav animationControllerForOperation:operation
                            fromViewController:from toViewController:to];
    return nil;
}

- (id<UIViewControllerInteractiveTransitioning>)navigationController:(UINavigationController *)nav
                         interactionControllerForAnimationController:(id<UIViewControllerAnimatedTransitioning>)animator {
    if ([ObackManager shared].interacting && [animator isKindOfClass:[ObackAnimator class]])
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
    // 仅在手势驱动返回时接管 dismiss 动画；普通关闭按钮等系统 dismiss 走 App 原生动画，
    // 避免对 fullScreen / 系统自带 modal 强行套自定义转场导致黑屏（此前无条件返回是黑屏根因之一）
    if ([ObackManager shared].interacting) {
        ObackAnimator *a = [[ObackAnimator alloc] initWithEdge:[ObackManager shared].currentEdge
                                                      params:[ObackPreferences params]];
        a.parallaxToView = [ObackManager shared].currentParallaxToView;  // 弹窗 dismiss 置 NO(方案B: 只动 sheet)
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
    // 冲突插件退避：命中已知不兼容共存 tweak（如 AppTool）时完全透传，不做任何包装/禁用手势，
    // 避免双 tweak 交互触发对方 nil 崩溃（安全模式）。这是 Oback 在自己可控范围内能做的最大规避。
    if (oback_shouldBackOff()) {
        %orig;
        return;
    }
    // 当前 App 不在生效范围（白/黑名单）时，直接透传原方法，不做任何包装
    if (![ObackPreferences isAllowed]) {
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
    // 关闭系统自带左边缘返回，避免和我们手势双重触发
    self.interactivePopGestureRecognizer.enabled = NO;
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
