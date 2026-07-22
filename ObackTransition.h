#import <UIKit/UIKit.h>

// 触发边缘
typedef NS_ENUM(NSInteger, ObackEdge) {
    ObackEdgeLeft  = 0,  // 左边缘内滑 -> 当前页右移，上一页从左侧探出
    ObackEdgeRight = 1,  // 右边缘内滑 -> 当前页左移，上一页从右侧探出
};

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
+ (instancetype)defaults;
@end

// 非交互返回（例如点击系统返回按钮）使用的动画
@interface ObackAnimator : NSObject <UIViewControllerAnimatedTransitioning>
@property (nonatomic, assign) ObackEdge edge;
@property (nonatomic, retain) ObackParams *params;
- (instancetype)initWithEdge:(ObackEdge)edge params:(ObackParams *)params;
@end

// 手势拖动时按百分比驱动同一套视差动画
@interface ObackInteractiveTransition : NSObject <UIViewControllerInteractiveTransitioning>
@property (nonatomic, assign) ObackEdge edge;
@property (nonatomic, retain) ObackParams *params;
- (instancetype)initWithEdge:(ObackEdge)edge params:(ObackParams *)params;
- (void)updateWithPercent:(CGFloat)percent;  // 0~1
- (void)finish;   // 提交返回
- (void)cancel;   // 回弹取消
@end
