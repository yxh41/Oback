//
//  ObackAppListController.h
//  Oback 设置 —— App 选择器（黑白名单）
//

#import <Preferences/PSListController.h>

@interface ObackAppListController : PSListController
// @"white" -> 白名单模式；@"black" -> 黑名单模式。由薄子类在 init 中设定。
@property (nonatomic, copy) NSString *mode;
@end

// 两个薄子类仅用于让入口链接指向不同 mode，免去在 plist 里传参。
@interface ObackWhiteListController : ObackAppListController
@end

@interface ObackBlackListController : ObackAppListController
@end
