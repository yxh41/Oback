#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ObackManager.h"
#import "ObackTransition.h"
#import "ObackPreferences.h"

static void *kNavDelegateKey = &kNavDelegateKey;
static void *kTDKey = &kTDKey;

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
    if (operation == UINavigationControllerOperationPop) {
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

// 包一层 transitioningDelegate：保留原有，注入我们的 dismiss 动画/交互
@interface ObackTransitioningDelegate : NSObject <UIViewControllerTransitioningDelegate>
@property (nonatomic, assign) id<UIViewControllerTransitioningDelegate> original;
@end

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

%hook UIViewController

- (void)presentViewController:(UIViewController *)vc animated:(BOOL)animated completion:(void (^)(void))completion {
    // 当前 App 不在生效范围时，直接透传原方法
    if (![ObackPreferences isAllowed]) {
        %orig;
        return;
    }
    // 给被 present 的 VC 注入我们的 dismiss 转场（跳过 alert）
    if (vc && ![vc isKindOfClass:[UIAlertController class]]) {
        ObackTransitioningDelegate *td = [[ObackTransitioningDelegate alloc] init];
        td.original = vc.transitioningDelegate;
        vc.transitioningDelegate = td;
        objc_setAssociatedObject(vc, kTDKey, td, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig;
}

%end

%end

%ctor {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    // 系统进程不注入手势逻辑，避免干扰/闪退（设置、桌面、backboardd 等）
    NSSet *systemBundles = [NSSet setWithObjects:
        @"com.apple.Preferences",
        @"com.apple.SpringBoard",
        @"com.apple.backboardd",
        nil];
    if ([systemBundles containsObject:bid]) {
        return;
    }
    %init(Oback);
    // 每个 App 启动完成后启动手势管理器
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note){
        [[ObackManager shared] start];
    }];
}
