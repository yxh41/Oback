#import <Foundation/Foundation.h>
#import "ObackTransition.h"

// 从 PreferenceLoader 设置域实时读取参数（修改设置后下次手势即生效）
@interface ObackPreferences : NSObject
+ (ObackParams *)params;
+ (BOOL)isBlacklisted;
@end
