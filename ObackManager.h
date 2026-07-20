#import <UIKit/UIKit.h>
#import "ObackTransition.h"
#import "ObackPreferences.h"

// 全局手势管理器单例：负责挂手势、判定边缘、路由到 nav pop / modal dismiss
@interface ObackManager : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)start;

@property (nonatomic, assign) ObackEdge currentEdge;                  // 本次手势触发边缘
@property (nonatomic, assign) BOOL interacting;                          // 是否正在交互返回
@property (nonatomic, strong) ObackInteractiveTransition *interactive; // 当前交互控制器
@end
