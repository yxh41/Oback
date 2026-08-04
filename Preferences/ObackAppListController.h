//
//  ObackAppListController.h
//  Oback 设置 —— App 选择器（黑白名单）
//

#import <Preferences/PSListController.h>

@interface ObackAppListController : PSListController <UISearchResultsUpdating>
// @"white" -> 白名单模式；@"black" -> 黑名单模式。由薄子类在 init 中设定。
@property (nonatomic, copy) NSString *mode;
@end

// 薄子类仅用于让入口链接指向不同 mode，免去在 plist 里传参。
@interface ObackWhiteListController : ObackAppListController
@end

@interface ObackBlackListController : ObackAppListController
@end

// 左缘排除列表：命中的 App 左缘交还系统原生返回（保留右缘+弹窗），用法同黑白名单。
@interface ObackLeftExcludeListController : ObackAppListController
@end

// 全局返回列表：命中的 App 启用全屏/任意位置返回（左缘交全屏 pan 接管、右缘 dismiss 保留），用法同黑白名单。
@interface ObackGlobalBackListController : ObackAppListController
@end

// 无动画修复列表：命中的 App 左缘/全局返回强制走 rightSimplePop 非交互标准滑出（系统交互转场不渲染的自定义 nav，如酷安），用法同黑白名单。
@interface ObackNavPopFallbackController : ObackAppListController
@end

