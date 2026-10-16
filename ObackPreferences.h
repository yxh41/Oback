#import <Foundation/Foundation.h>
#import "ObackTransition.h"

// 从 PreferenceLoader 设置域实时读取参数（修改设置后下次手势即生效）
@interface ObackPreferences : NSObject
+ (ObackParams *)params;
+ (BOOL)isAllowed;        // 统一判断：当前 App 是否允许生效（白名单/黑名单模式）
+ (BOOL)isSettingsApp;    // 当前进程是否为系统「设置」App（com.apple.Preferences）
+ (BOOL)settingsAppEnabled;  // 「设置 App 内生效」隐藏熔断键(key=settingsAppEnabled，面板无入口)，默认开；直读全局文件，可在 %ctor 阶段安全调用。应急：Filza 把该键置 0
+ (BOOL)isLeftEdgeExcluded;  // 左缘排除列表：命中 App 左缘交还系统原生返回（保留右缘+弹窗），≠ 全局黑名单
+ (BOOL)isLeftEdgeExcludedVC:(NSString *)className;  // [优化③] 左缘按页(VC)排除：类名子串(大小写不敏感)命中 leftEdgeExcludedVCs 时，该页左缘交还自身手势；仅作用于左缘，右缘/弹窗不受影响
+ (BOOL)isNavPopFallback; // 无动画修复列表：命中 App 左缘强制走 rightSimplePop 非交互标准滑出（系统交互转场不渲染的自定义 nav，如酷安），默认关、≠ 黑名单/左缘排除
+ (BOOL)debugLogEnabled;  // 调试日志总开关（设置面板「调试日志」），默认关（批次A 改为关 + 缓存 + 30min 自动过期）
+ (BOOL)debugLogEnabledLive;  // [v11] 实时读调试日志开关（去缓存，开关即生效）
+ (BOOL)doubleReturnDiagEnabled;  // 双返回诊断（设置面板「双返回诊断」），默认关
+ (BOOL)exclusivePopEnabled;  // [A'] 「接管即独占」（key=exclusivePop），默认关：Oback 确认接管本次返回手势期间，临时禁用 App 自带的返回手势（滚动/文本选择/左滑一律放行），松手后自动恢复
+ (BOOL)isExclusivePopExcluded;  // [R13] 「独占排除」名单（key=exclusivePopExcludeApps），默认空：命中 App 内 exclusivePop 视同关闭（只关独占，不动 Oback 基础返回/胶囊/其他名单）。
                                 // 排除列表语义（非白名单）⇒ 默认空 = 全局生效，行为与加本能力之前逐字一致。
+ (BOOL)fallbackBackEnabled;      // [兜底返回 2026-09-27] key=fallbackBack，默认关：在「nav 栈深 1（不可 pop）且无弹窗」的页面上，
                                  // 左缘改为查找并触发该页左上角的「返回 / 关闭」控件（这类页面系统不渲染返回箭头，
                                  // 原有三级动作派发——nav pop / modal dismiss / ——全部找不到目标 ⇒ 手势只能空转）。
+ (BOOL)fallbackBackCloseEnabled; // key=fallbackBackClose，默认开：上面的语义词表是否包含 关闭 / 取消 / ✕。关 ⇒ 只认 返回 / back / ‹ / ←。
+ (BOOL)fallbackBackWebEnabled;      // [P0-1 2026-10-16] key=fallbackBackWeb，默认关：上面找不到控件时，
+                                  // 改找最前面的 WKWebView，canGoBack==YES 就 goBack（系统布尔判定，非启发式）。
+                                  // 覆盖内嵌 H5 的详情页/活动页/文档页 —— 那类页面 UIKit 树里没有返回按钮。
+ (BOOL)fallbackBackViewTreeEnabled; // [2b-1 2026-10-16] key=fallbackBackViewTree，默认关：把控件搜索范围从
+                                  // nav.navigationBar 扩到 top VC 的 view 树左上区（x≤96 且 y≤176），
+                                  // 覆盖 bar.hidden 的自绘返回按钮。比 nav bar 版更严，右上角明确不做。
+ (BOOL)isFallbackBackExcluded;   // key=fallbackBackExcludeApps，默认空：命中 App 内兜底返回视同关闭（只关兜底，不动 Oback 基础返回 / 胶囊 / 其他名单）。
+ (BOOL)diagBannerEnabled;  // 诊断横幅独立隐藏开关（key=diagBanner），默认关；开→每次注入打印 [Oback-diag] 横幅，关→完全静默
+ (NSInteger)capsuleEffect;        // 胶囊特效（设置面板「胶囊风格」key=capsuleEffect），0=经典，1=发光，2=霓虹，3=流光，4=毛玻璃，5=呼吸
// 内部：合并后的偏好字典（全局文件优先 + NSUserDefaults 域兜底），供读取与诊断复用。
// roothide 下 NSUserDefaults(suiteName:) 的手动写入会落到「设置」App 的 per-app 容器副本，
// 注入到其它 App 的 tweak 读不到，故合并时全局 plist 文件优先。
+ (NSDictionary *)_mergedPrefs;
@end
