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
@property (nonatomic, assign) ObackAnimator *currentAnimator;           // 当前手势驱动的动画器（finish 前用于改弹簧速度；assign 避免成环，MRC 无 __weak）
@property (nonatomic, retain) id currentTD;                             // 本次手势驱动的 modal dismiss 转场转发器
@property (nonatomic, assign) BOOL currentParallaxToView;               // 当前手势是否弹窗 dismiss(只动 sheet)
@property (nonatomic, assign) CGFloat releaseVelocity;  // 松手时前向(朝返回方向)速度 (pt/s)，供 ObackAnimator 做动量继承
@property (nonatomic, assign) CGFloat releasePercent;   // 松手时拖动进度 (0~1)，供 ObackAnimator 计算动态收尾时长
@end
