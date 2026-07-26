#import <Foundation/Foundation.h>
#import "ObackTransition.h"

// 从 PreferenceLoader 设置域实时读取参数（修改设置后下次手势即生效）
@interface ObackPreferences : NSObject
+ (ObackParams *)params;
+ (BOOL)isAllowed;        // 统一判断：当前 App 是否允许生效（白名单/黑名单模式）
+ (BOOL)isBlacklisted;    // 原黑名单逻辑（isAllowed 内部复用）
+ (BOOL)debugLogEnabled;  // 调试日志总开关（设置面板「调试日志」），默认关（批次A 改为关 + 缓存 + 30min 自动过期）
+ (BOOL)navParallaxEnabled;  // 导航视差实验开关（设置面板「导航视差（实验）」key=navParallax），默认关
+ (BOOL)doubleReturnDiagEnabled;  // 双返回诊断（设置面板「双返回诊断」），默认关
// 内部：合并后的偏好字典（全局文件优先 + NSUserDefaults 域兜底），供读取与诊断复用。
// roothide 下 NSUserDefaults(suiteName:) 的手动写入会落到「设置」App 的 per-app 容器副本，
// 注入到其它 App 的 tweak 读不到，故合并时全局 plist 文件优先。
+ (NSDictionary *)_mergedPrefs;
@end
