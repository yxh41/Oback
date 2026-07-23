#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ObackManager.h"
#import "ObackTransition.h"
#import "ObackPreferences.h"

static void *kNavDelegateKey = &kNavDelegateKey;

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
    return [[ObackAnimator alloc] initWithEdge:[ObackManager shared].currentEdge
                                           params:[ObackPreferences params]];
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
        [[ObackManager shared] start];
    }];
}
