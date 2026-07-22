//
//  ObackAppListController.m
//  Oback 设置页 —— App 选择器（黑白名单）
//
//  枚举设备上已安装的用户 App。
//  注意：iOS 11+ 起 LSApplicationWorkspace.allInstalledApplications 对非授权进程
//  返回空数组（需特定 entitlement），roothide 注入的设置 App 拿不到。
//  故这里改为扫描 /var/containers/Bundle/Application/*.app，零私有框架依赖，iOS 16 仍有效。
//
//  渲染策略（2026-07-23 重写）：移除自定义 cell / 图标加载 / cellClassForSpecifier:，
//  全部退回系统原生 PSSwitchCell（与设置页自身 cell 同源，iOS 16.4.1 / roothide 下最稳，
//  不会在渲染期崩溃）。App 名称与 bundle id 拼进 title 显示，便于识别。图标作为后续加分项。
//

#import "ObackAppListController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <Preferences/PSSwitchTableCell.h>
#import <UIKit/UIKit.h>

static NSString *const kDomain = @"com.zlhkf.oback";

#pragma mark - App 枚举（扫描文件系统，零私有框架依赖，全程容错）

@implementation ObackAppListController

- (NSArray *)_installedUserApps {
    @try {
        NSMutableArray *result = [NSMutableArray array];
        NSString *appDir = @"/var/containers/Bundle/Application";
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *uuids = [fm contentsOfDirectoryAtPath:appDir error:nil];
        for (NSString *uuid in uuids) {
            NSString *uuidPath = [appDir stringByAppendingPathComponent:uuid];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:uuidPath isDirectory:&isDir] || !isDir) continue;
            NSArray *entries = [fm contentsOfDirectoryAtPath:uuidPath error:nil];
            for (NSString *entry in entries) {
                if (![entry hasSuffix:@".app"]) continue;
                NSString *appPath = [uuidPath stringByAppendingPathComponent:entry];
                NSString *infoPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
                if (!info) continue;
                NSString *bid = info[@"CFBundleIdentifier"];
                if (!bid.length) continue;
                NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: bid;
                [result addObject:@{@"bundleID": bid, @"name": name}];
            }
        }
        [result sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]]];
        return result;
    } @catch (NSException *e) {
        (void)e;
        return @[];
    }
}

- (NSString *)_storeKey {
    return ([self.mode isEqualToString:@"white"] ? @"whitelistApps" : @"blacklistApps");
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        @try {
            NSMutableArray *specs = [NSMutableArray array];

            // 分组标题 + footer 说明（用标准 PSGroupCell，不依赖自定义 cell）
            PSSpecifier *top = [PSSpecifier preferenceSpecifierNamed:@""
                                                            target:self
                                                               set:nil
                                                               get:nil
                                                            detail:nil
                                                               cell:PSGroupCell
                                                               edit:nil];
            NSString *footer = ([self.mode isEqualToString:@"white"]
                                ? @"勾选的 App 启用边缘手势返回，其余一律不生效。"
                                : @"勾选的 App 不启用边缘手势返回，其余全部生效。");
            [top setProperty:footer forKey:@"footerText"];
            [specs addObject:top];

            for (NSDictionary *app in [self _installedUserApps]) {
                NSString *bid = app[@"bundleID"];
                NSString *name = app[@"name"];
                // 名称与 bundle id 拼进 title，便于在系统 cell 上识别 App
                NSString *title = [NSString stringWithFormat:@"%@  (%@)", name, bid];
                PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:title
                                                              target:self
                                                                 set:@selector(_setAppEnabled:specifier:)
                                                                 get:@selector(_isAppEnabled:)
                                                             detail:nil
                                                                 cell:PSSwitchCell
                                                                 edit:nil];
                [s setProperty:bid forKey:@"appBundleID"];
                [specs addObject:s];
            }
            _specifiers = specs;
        } @catch (NSException *e) {
            (void)e;
            // 兜底：任何异常都返回空数组，避免 table view 因 nil specifiers 崩溃
            _specifiers = [NSMutableArray array];
        }
    }
    return _specifiers;
}

#pragma mark - 开关存取（读写 NSUserDefaults 的 whitelistApps / blacklistApps 数组）

- (void)_setAppEnabled:(NSNumber *)value specifier:(PSSpecifier *)spec {
    NSString *bid = [spec propertyForKey:@"appBundleID"];
    if (!bid) return;
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    NSMutableArray *arr = [[d arrayForKey:[self _storeKey]] mutableCopy] ?: [NSMutableArray array];
    if ([value boolValue]) {
        if (![arr containsObject:bid]) [arr addObject:bid];
    } else {
        [arr removeObject:bid];
    }
    [d setObject:arr forKey:[self _storeKey]];
    [d synchronize];
}

- (id)_isAppEnabled:(PSSpecifier *)spec {
    NSString *bid = [spec propertyForKey:@"appBundleID"];
    if (!bid) return @NO;
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    NSArray *arr = [d arrayForKey:[self _storeKey]];
    return @([arr containsObject:bid]);
}

@end

#pragma mark - 薄子类（决定 mode）

@implementation ObackWhiteListController
- (id)init {
    if (self = [super init]) {
        self.mode = @"white";
    }
    return self;
}
@end

@implementation ObackBlackListController
- (id)init {
    if (self = [super init]) {
        self.mode = @"black";
    }
    return self;
}
@end
