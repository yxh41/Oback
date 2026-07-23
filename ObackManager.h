#import <UIKit/UIKit.h>
#import "ObackTransition.h"
#import "ObackPreferences.h"

// 全局手势管理器单例：负责挂手势、判定边缘、路由到 nav pop / modal dismiss
@interface ObackManager : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)start;

@property (nonatomic, assign) ObackEdge currentEdge;                  // 本次手势触发边缘
@property (nonatomic, assign) BOOL interacting;                          // 是否正在交互返回
@property (nonatomic, retain) ObackInteractiveTransition *interactive; // 当前交互控制器
@property (nonatomic, retain) id currentTD;                             // 本次手势驱动的 modal dismiss 转场转发器
@property (nonatomic, assign) BOOL currentParallaxToView;               // 当前手势是否弹窗 dismiss(只动 sheet)
@end
