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

// 模态 dismiss 转场转发器：仅在手势触发时注入，保留 App 原有转场，避免干扰其自带 modal 动画。
// [方案B] 不再创建自定义 ObackAnimator：dismiss 动画交还系统/App 原生（返回 _original 或 nil）。
@interface ObackTransitioningDelegate : NSObject <UIViewControllerTransitioningDelegate>
@property (nonatomic, assign) id<UIViewControllerTransitioningDelegate> original;
@end

// 动画/手势参数（可被设置面板实时覆盖）
@interface ObackParams : NSObject
@property (nonatomic, assign) CGFloat triggerWidth;     // 边缘触发宽度 (pt)
@property (nonatomic, assign) BOOL    leftEnabled;       // 左边缘返回
@property (nonatomic, assign) BOOL    rightEnabled;      // 右边缘返回
@property (nonatomic, assign) BOOL    hapticEnabled;     // 触感反馈
@property (nonatomic, assign) CGFloat shadowOffset;   // 阴影水平偏移(pt)，控制"抬起"纵深感（0~20）
@property (nonatomic, assign) CGFloat shadowRadius;    // 阴影模糊半径(pt)，控制柔和度（0~40）
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
