#import <UIKit/UIKit.h>

// 诊断日志（实现见 ObackManager.m，写共享文件 /var/mobile/oback_debug.log + syslog）
// extern "C" 守卫：Tweak.xm 被 Theos 当 ObjC++ 编译，无此声明会按 C++ 链接查 mangled 名导致链接失败
#ifdef __cplusplus
extern "C" {
#endif
void OBLog(NSString *fmt, ...);
#ifdef __cplusplus
}
#endif

// 触发边缘
typedef NS_ENUM(NSInteger, ObackEdge) {
    ObackEdgeLeft  = 0,  // 左边缘内滑 -> 当前页右移，上一页从左侧探出
    ObackEdgeRight = 1,  // 右边缘内滑 -> 当前页左移，上一页从右侧探出
};

// 模态 dismiss 转场转发器：仅在手势触发时注入，保留 App 原有转场，避免干扰其自带 modal 动画
@interface ObackTransitioningDelegate : NSObject <UIViewControllerTransitioningDelegate>
@property (nonatomic, assign) id<UIViewControllerTransitioningDelegate> original;
@end

@class ObackAnimator;   // 供 ObackInteractiveTransition 反向引用（下方声明）

// 动画/手势参数（可被设置面板实时覆盖）
@interface ObackParams : NSObject
@property (nonatomic, assign) CGFloat triggerWidth;     // 边缘触发宽度 (pt)
@property (nonatomic, assign) BOOL    leftEnabled;       // 左边缘返回
@property (nonatomic, assign) BOOL    rightEnabled;      // 右边缘返回
@property (nonatomic, assign) BOOL    hapticEnabled;     // 触感反馈
@property (nonatomic, assign) CGFloat parallaxOffset;    // 上一页视差位移比例 (0~0.6)
@property (nonatomic, assign) CGFloat previousScaleMin;  // 上一页最小缩放 (0.8~1)
@property (nonatomic, assign) CGFloat dimAlpha;          // 遮罩浓度 (0~0.8)
@property (nonatomic, assign) BOOL    shadowEnabled;     // 当前页阴影
@property (nonatomic, assign) CGFloat shadowOpacity;     // 阴影浓度
@property (nonatomic, assign) NSTimeInterval duration;   // 释放后补间时长 (s)
@property (nonatomic, assign) CGFloat commitRatio;       // 提交返回的最小位移比例
@property (nonatomic, assign) CGFloat commitVelocity;    // 提交返回的最小速度 (pt/s)
@property (nonatomic, assign) BOOL    springEnabled;     // 释放后弹性补间(动量继承)，默认开
@property (nonatomic, assign) BOOL    cardCornerEnabled; // 弹窗下拉时卡片圆角(模拟 iOS sheet 下拉)，默认关
@property (nonatomic, assign) CGFloat cardCornerValue;   // 弹窗圆角最大值 (pt)
+ (instancetype)defaults;
@end

// 非交互返回（例如点击系统返回按钮）使用的动画
@interface ObackAnimator : NSObject <UIViewControllerAnimatedTransitioning>
@property (nonatomic, assign) ObackEdge edge;
@property (nonatomic, retain) ObackParams *params;
// YES=nav pop 视差(移动上一页)；NO=弹窗 dismiss 方案B(只动被 dismiss 的 sheet，绝不碰底层 presenting，避免黑屏)
@property (nonatomic, assign) BOOL parallaxToView;
// 速度感知弹簧核心：中断式动画器由 interruptibleAnimatorForTransition: 构建并缓存
@property (nonatomic, retain) UIViewPropertyAnimator *propertyAnimator;
// 转场上下文（animateTransition: 时记入，finish/cancel 动画器若未能自行收尾由兜底强制 completeTransition）
@property (nonatomic, assign) id<UIViewControllerContextTransitioning> context;
// 防重复：completeTransition 只准调一次（动画器 completion 与 manager 兜底定时器互斥）
@property (nonatomic, assign) BOOL completed;
// 松手速度/进度，由 ObackManager 在 endTransition 写入，finish 时经 applyReleaseVelocity 用于动量继承
@property (nonatomic, assign) CGFloat releaseVelocity;
@property (nonatomic, assign) CGFloat releasePercent;
// finish=NO / cancel=YES：供 completion 决定 completeTransition 方向（避免反向动画 finalPosition 误判导致取消却提交了 pop）
@property (nonatomic, assign) BOOL interactiveCancelled;
// 导航栏协同（实验）：nav pop 自定义转场时，隐藏活的导航栏、叠加其快照随内容淡出，
// 转场结束恢复活 bar，消除"内容/bar 不同步"的导航栏损坏。仅 navParallax 开启且 parallaxToView=YES 时启用。
@property (nonatomic, retain) UIView *navBarSnapshotView;                 // 活 bar 的快照叠加层（retain）
@property (nonatomic, assign) UINavigationController *navControllerForBar; // 转场结束恢复活 bar（assign 避免成环，MRC 无 __weak）
- (void)restoreNavBar;   // 恢复活 bar 并移除快照（幂等）
- (instancetype)initWithEdge:(ObackEdge)edge params:(ObackParams *)params;
// 在 finish/cancel 前调用：用真实松手速度更新弹簧初速度（速度感知弹簧的关键；取消时速度已清零→温和回弹）
- (void)applyReleaseVelocity;
// 兜底收尾：若动画器因状态错位（continueAnimation 空操作等）未能自行触发 completion，
// 由 manager 定时器调用，按 interactiveCancelled 一次性 completeTransition，杜绝"转场孤儿化→界面冻结"。
- (void)forceFinishIfNeeded;
@end

// 手势拖动时按百分比驱动同一套视差动画（中断式动画器）。
// 因 ObackAnimator 实现了 interruptibleAnimatorForTransition:，按 Apple 推荐模式：
// 交互控制器直接驱动其 UIViewPropertyAnimator 的 fractionComplete，并在 finish/cancel 时
// 续跑/反向续跑它；completeTransition 由动画器 completion 自动调用（见 ObackAnimator）。
// 不再继承 UIPercentDrivenInteractiveTransition —— 它内部靠驱动 animateTransition: 里的 UIView 动画，
// 而本 tweak 的动画在中断式动画器里，二者并存时部分 App(如微信自定义 nav)下动画器不被续跑
// → completeTransition 永不触发 → 界面冻结。直接驱动可消除该冲突。
@interface ObackInteractiveTransition : NSObject <UIViewControllerInteractiveTransitioning>
@property (nonatomic, assign) ObackEdge edge;
@property (nonatomic, retain) ObackParams *params;
// 同 ObackAnimator.parallaxToView 含义
@property (nonatomic, assign) BOOL parallaxToView;
// 反向引用当前动画器，finish/cancel 时用来更新弹簧速度/续跑（assign：避免与动画器互相 retain 成环，MRC 无 __weak）
@property (nonatomic, assign) ObackAnimator *animator;
- (instancetype)initWithEdge:(ObackEdge)edge params:(ObackParams *)params;
- (void)updateWithPercent:(CGFloat)percent;  // 0~1
- (void)finish;   // 提交返回
- (void)cancel;   // 回弹取消
@end
