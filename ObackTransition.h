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
// 松手速度/进度，由 ObackManager 在 endTransition 写入，finish 时经 applyReleaseVelocity 用于动量继承
@property (nonatomic, assign) CGFloat releaseVelocity;
@property (nonatomic, assign) CGFloat releasePercent;
- (instancetype)initWithEdge:(ObackEdge)edge params:(ObackParams *)params;
// 在 finish/cancel 前调用：用真实松手速度更新弹簧初速度（速度感知弹簧的关键；取消时速度已清零→温和回弹）
- (void)applyReleaseVelocity;
@end

// 手势拖动时按百分比驱动同一套视差动画
// 关键：必须是 UIPercentDrivenInteractiveTransition 子类，才能用标准的
// updateInteractiveTransition: / finishInteractiveTransition / cancelInteractiveTransition
// 驱动 UIKit 复位导航控制器的"交互中"状态；否则导航会一直卡在交互转场态 → 界面冻结。
@interface ObackInteractiveTransition : UIPercentDrivenInteractiveTransition
@property (nonatomic, assign) ObackEdge edge;
@property (nonatomic, retain) ObackParams *params;
// 同 ObackAnimator.parallaxToView 含义
@property (nonatomic, assign) BOOL parallaxToView;
// 反向引用当前动画器，finish/cancel 时用来更新弹簧速度（assign：避免与动画器互相 retain 成环，MRC 无 __weak）
@property (nonatomic, assign) ObackAnimator *animator;
- (instancetype)initWithEdge:(ObackEdge)edge params:(ObackParams *)params;
- (void)updateWithPercent:(CGFloat)percent;  // 0~1
- (void)finish;   // 提交返回
- (void)cancel;   // 回弹取消
@end
