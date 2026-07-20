#import <Foundation/Foundation.h>
#import "ObackTransition.h"

// 从 PreferenceLoader 设置域实时读取参数（修改设置后下次手势即生效）
@interface ObackPreferences : NSObject
+ (ObackParams *)params;
+ (BOOL)isAllowed;        // 统一判断：当前 App 是否允许生效（白名单/黑名单模式）
+ (BOOL)isBlacklisted;    // 原黑名单逻辑（isAllowed 内部复用）
@end
