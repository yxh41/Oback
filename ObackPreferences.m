#import "ObackPreferences.h"

// 与设置面板 Root.plist 的 suite / key 保持一致
static NSString *const kDomain = @"com.zlhkf.oback";

@implementation ObackPreferences

+ (ObackParams *)params {
    ObackParams *p = [ObackParams defaults];
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    id v;
    if ((v = [d objectForKey:@"triggerWidth"]))     p.triggerWidth     = [v doubleValue];
    if ((v = [d objectForKey:@"parallaxOffset"]))   p.parallaxOffset   = [v doubleValue];
    if ((v = [d objectForKey:@"previousScaleMin"])) p.previousScaleMin = [v doubleValue];
    if ((v = [d objectForKey:@"dimAlpha"]))         p.dimAlpha         = [v doubleValue];
    if ((v = [d objectForKey:@"shadowEnabled"]))    p.shadowEnabled    = [v boolValue];
    if ((v = [d objectForKey:@"shadowOpacity"]))    p.shadowOpacity    = [v doubleValue];
    if ((v = [d objectForKey:@"duration"]))         p.duration         = [v doubleValue];
    if ((v = [d objectForKey:@"commitRatio"]))      p.commitRatio      = [v doubleValue];
    if ((v = [d objectForKey:@"commitVelocity"]))   p.commitVelocity   = [v doubleValue];
    if ((v = [d objectForKey:@"leftEnabled"]))      p.leftEnabled      = [v boolValue];
    if ((v = [d objectForKey:@"rightEnabled"]))     p.rightEnabled     = [v boolValue];
    if ((v = [d objectForKey:@"hapticEnabled"]))    p.hapticEnabled    = [v boolValue];
    return p;
}

// 解析逗号/换行分隔的 bundle id 列表，命中返回 YES
+ (BOOL)_bundleId:(NSString *)bid inList:(NSString *)raw {
    if (!raw.length || !bid) return NO;
    NSArray *parts = [raw componentsSeparatedByCharactersInSet:
                      [NSCharacterSet characterSetWithCharactersInString:@",\n"]];
    for (NSString *s in parts) {
        NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length && [t isEqualToString:bid]) return YES;
    }
    return NO;
}

// 是否允许当前 App 生效：
//  - whitelistMode 未设置或 YES：只有白名单内的 App 生效（空白名单 = 全部不生效）
//  - whitelistMode == NO：回到全局生效 + 黑名单排除（原逻辑）
//  新版用 whitelistApps / blacklistApps 数组（设置页 App 选择器写入）；
//  旧版用 whitelistRaw / blacklistRaw 逗号分隔字符串，做了兼容。
+ (BOOL)isAllowed {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (!bid) return NO;

    id wm = [d objectForKey:@"whitelistMode"];
    BOOL whitelistMode = wm ? [wm boolValue] : NO;   // 未设置 → 默认全局生效（黑名单模式），符合"全局注入"设计

    if (whitelistMode) {
        NSArray *white = [d arrayForKey:@"whitelistApps"];
        if (white) return [white containsObject:bid];
        // 兼容旧版字符串
        return [self _bundleId:bid inList:[d stringForKey:@"whitelistRaw"]];
    } else {
        NSArray *black = [d arrayForKey:@"blacklistApps"];
        if (black) {
            if (black.count == 0) return YES;
            return ![black containsObject:bid];
        }
        // 兼容旧版字符串
        NSString *raw = [d stringForKey:@"blacklistRaw"];
        if (!raw.length) return YES;
        return ![self _bundleId:bid inList:raw];
    }
}

+ (BOOL)isBlacklisted {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (!bid) return NO;
    NSArray *black = [d arrayForKey:@"blacklistApps"];
    if (black) return [black containsObject:bid];
    // 兼容旧版字符串
    NSString *raw = [d stringForKey:@"blacklistRaw"];
    if (!raw.length) return NO;
    return [self _bundleId:bid inList:raw];
}

@end
