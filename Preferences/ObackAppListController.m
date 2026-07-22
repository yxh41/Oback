//
//  ObackAppListController.m
//  Oback 设置页 —— App 选择器（黑白名单）
//
//  枚举设备上已安装的用户 App。
//  注意：iOS 11+ 起 LSApplicationWorkspace.allInstalledApplications 对非授权进程
//  返回空数组（需特定 entitlement），roothide 注入的设置 App 拿不到。
//  故这里改为扫描 /var/containers/Bundle/Application/*.app，零私有框架依赖，iOS 16 仍有效。
//  图标从目标 App 的 .app bundle 直接加载（支持 asset catalog 的 CFBundleIconName 与旧式 CFBundleIconFiles）。
//

#import "ObackAppListController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <Preferences/PSSwitchTableCell.h>
#import <UIKit/UIKit.h>

static NSString *const kDomain = @"com.zlhkf.oback";

#pragma mark - 图标加载（从目标 App bundle 读取，不依赖私有 API，全程容错）

static UIImage *ObackIconForAppPath(NSString *appPath) {
    @try {
        if (!appPath.length) return nil;
        NSBundle *b = [NSBundle bundleWithPath:appPath];
        if (!b) return nil;
        NSString *infoPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
        if (!info) return nil;
        NSString *iconName = info[@"CFBundleIconName"];
        if (!iconName.length) {
            NSDictionary *icons = info[@"CFBundleIcons"][@"CFBundlePrimaryIcon"];
            NSArray *files = icons[@"CFBundleIconFiles"];
            iconName = files.firstObject;
        }
        if (!iconName.length) return nil;
        UIImage *img = [UIImage imageNamed:iconName inBundle:b compatibleWithTraitCollection:nil];
        if (!img) {
            NSString *p = [appPath stringByAppendingPathComponent:iconName];
            img = [UIImage imageWithContentsOfFile:p];
        }
        if (!img) return nil;
        // 统一缩放到 29x29，圆角交给 cell 处理
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(29, 29)];
        return [r imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
            [img drawInRect:CGRectMake(0, 0, 29, 29)];
        }];
    } @catch (NSException *e) {
        (void)e;
        return nil;
    }
}

#pragma mark - 自定义 cell：系统原生 imageView 图标 + 名称(含 bundle id)

@interface ObackAppCell : PSSwitchTableCell
@end

@implementation ObackAppCell

// 不重写 layoutSubviews：完全交给 UITableViewCell / PSSwitchTableCell 的原生布局，
// 只设置内容，避免与父类内部布局冲突导致崩溃。
- (void)setSpecifier:(PSSpecifier *)specifier {
    [super setSpecifier:specifier];
    NSString *bid = [specifier propertyForKey:@"appBundleID"];
    NSString *appPath = [specifier propertyForKey:@"appPath"];
    NSString *name = specifier.name ?: bid;
    if (bid.length) {
        name = [NSString stringWithFormat:@"%@  (%@)", name, bid];
    }
    self.textLabel.text = name;
    UIImage *icon = ObackIconForAppPath(appPath);
    if (icon) {
        self.imageView.image = icon;
        self.imageView.layer.cornerRadius = 6;
        self.imageView.clipsToBounds = YES;
    }
}

@end

#pragma mark - 列表控制器

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
                [result addObject:@{@"bundleID": bid, @"name": name, @"path": appPath}];
            }
        }
        [result sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]]];
        return result;
    } @catch (NSException *e) {
        return @[];
    }
}

- (NSString *)_storeKey {
    return ([self.mode isEqualToString:@"white"] ? @"whitelistApps" : @"blacklistApps");
}

// 让 specifier 上设置的 cellClass 真正生效（否则框架用默认 PSSwitchCell，图标不会显示）。
// 注意：PSListController 头文件未声明 cellClassForSpecifier:，不能用 [super cellClassForSpecifier:]，
// 否则 theos 编译报「no visible @interface declares the selector」。默认分支直接返回 PSSwitchCell 即可，
// 因为 PSListController 默认实现本就会读取 specifier 的 cellClass 属性（我们已经设了）。
- (Class)cellClassForSpecifier:(PSSpecifier *)specifier {
    NSString *n = [specifier propertyForKey:@"cellClass"];
    if (n.length) {
        Class c = NSClassFromString(n);
        if (c) return c;
    }
    return NSClassFromString(@"PSSwitchCell");
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        @try {
            NSMutableArray *specs = [NSMutableArray array];

            PSSpecifier *top = [PSSpecifier groupSpecifierWithName:nil];
            NSString *footer = ([self.mode isEqualToString:@"white"]
                                ? @"勾选的 App 启用边缘手势返回，其余一律不生效。"
                                : @"勾选的 App 不启用边缘手势返回，其余全部生效。");
            [top setProperty:footer forKey:@"footerText"];
            [specs addObject:top];

            for (NSDictionary *app in [self _installedUserApps]) {
                NSString *bid = app[@"bundleID"];
                NSString *name = app[@"name"];
                NSString *path = app[@"path"];
                PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name
                                                              target:self
                                                                 set:@selector(_setAppEnabled:specifier:)
                                                                 get:@selector(_isAppEnabled:)
                                                             detail:nil
                                                                 cell:PSSwitchCell
                                                                 edit:nil];
                [s setProperty:bid forKey:@"appBundleID"];
                [s setProperty:path forKey:@"appPath"];
                [s setProperty:NSStringFromClass([ObackAppCell class]) forKey:@"cellClass"];
                [specs addObject:s];
            }
            _specifiers = specs;
        } @catch (NSException *e) {
            (void)e;
            // 兜底：任何异常都返回一个空数组，避免 table view 因 nil specifiers 崩溃
            _specifiers = [NSMutableArray array];
        }
    }
    return _specifiers;
}

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
