#import <Foundation/Foundation.h>
#import "ObackTransition.h"

// 从 PreferenceLoader 设置域实时读取参数（修改设置后下次手势即生效）
@interface ObackPreferences : NSObject
+ (ObackParams *)params;
+ (BOOL)isAllowed;        // 统一判断：当前 App 是否允许生效（白名单/黑名单模式）
+ (BOOL)isLeftEdgeExcluded;  // 左缘排除列表：命中 App 左缘交还系统原生返回（保留右缘+弹窗），≠ 全局黑名单
+ (BOOL)isGlobalBackEnabled; // 全局返回列表：命中 App 启用全屏/任意位置返回（左缘交全屏 pan 接管、右缘 dismiss 保留），默认关、≠ 黑名单
+ (BOOL)debugLogEnabled;  // 调试日志总开关（设置面板「调试日志」），默认关（批次A 改为关 + 缓存 + 30min 自动过期）
+ (BOOL)doubleReturnDiagEnabled;  // 双返回诊断（设置面板「双返回诊断」），默认关
+ (BOOL)diagBannerEnabled;  // 诊断横幅独立隐藏开关（key=diagBanner），默认关；开→每次注入打印 [Oback-diag] 横幅，关→完全静默
+ (NSInteger)capsuleEffect;        // 胶囊特效（设置面板「胶囊风格」key=capsuleEffect），0=经典，1=发光，2=霓虹，3=流光，4=毛玻璃，5=呼吸
// 内部：合并后的偏好字典（全局文件优先 + NSUserDefaults 域兜底），供读取与诊断复用。
// roothide 下 NSUserDefaults(suiteName:) 的手动写入会落到「设置」App 的 per-app 容器副本，
// 注入到其它 App 的 tweak 读不到，故合并时全局 plist 文件优先。
+ (NSDictionary *)_mergedPrefs;
@end
