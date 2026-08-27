#import <UIKit/UIKit.h>
#import "ObackTransition.h"
#import "ObackPreferences.h"

// 全局手势管理器单例：负责挂手势、判定边缘、路由到 nav pop / modal dismiss
@interface ObackManager : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)start;
- (void)_attachNavPanToNav:(UINavigationController *)nav win:(UIWindow *)win;  // 给 nav.view 挂左右边缘 pan（swizzle UINavigationController 时调用）
- (void)_linkNavPopGesturesInWindow:(UIWindow *)win;   // 全窗口链接（禁用原生 interactivePop / 让插件边缘手势与 scrollView 失败于我们的 pan）；每 window/nav 出现跑一次，不在手势热路径

@property (nonatomic, assign) ObackEdge currentEdge;                  // 本次手势触发边缘
@property (nonatomic, assign) BOOL interacting;                          // 是否正在交互返回
@property (nonatomic, retain) id currentTD;                             // 本次手势驱动的 modal dismiss 转场转发器
@property (nonatomic, assign) BOOL currentParallaxToView;               // 当前手势是否弹窗 dismiss(只动 sheet)
@property (nonatomic, assign) BOOL rightSimplePop;                       // 右缘非交互 pop 标记（不走系统交互驱动，避免几何错配空白）
@end
