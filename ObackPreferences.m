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

+ (BOOL)isBlacklisted {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    NSString *raw = [d stringForKey:@"blacklistRaw"];
    if (!raw.length) return NO;
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (!bid) return NO;
    NSArray *parts = [raw componentsSeparatedByString:@","];
    for (NSString *s in parts) {
        NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([t isEqualToString:bid]) return YES;
    }
    return NO;
}

@end
