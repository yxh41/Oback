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

#pragma mark - 图标加载（从目标 App bundle 读取，不依赖私有 API）

static UIImage *ObackIconForAppPath(NSString *appPath) {
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
    UIImage *img = nil;
    if (iconName.length) {
        img = [UIImage imageNamed:iconName inBundle:b compatibleWithTraitCollection:nil];
        if (!img) {
            NSString *p = [appPath stringByAppendingPathComponent:iconName];
            img = [UIImage imageWithContentsOfFile:p];
        }
    }
    return img;
}

#pragma mark - 自定义 cell：图标 + 名称 + bundle id 副标题

@interface ObackAppCell : PSSwitchTableCell {
    UILabel *_obDetail;
}
@end

@implementation ObackAppCell

- (UILabel *)obDetail {
    if (!_obDetail) {
        _obDetail = [[UILabel alloc] init];
        _obDetail.font = [UIFont systemFontOfSize:11];
        if (@available(iOS 13.0, *)) {
            _obDetail.textColor = [UIColor secondaryLabelColor];
        } else {
            _obDetail.textColor = [UIColor grayColor];
        }
        _obDetail.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_obDetail];
    }
    return _obDetail;
}

- (void)setSpecifier:(PSSpecifier *)specifier {
    [super setSpecifier:specifier];
    NSString *bid = [specifier propertyForKey:@"appBundleID"];
    NSString *appPath = [specifier propertyForKey:@"appPath"];
    self.textLabel.text = specifier.name ?: bid;
    self.textLabel.font = [UIFont systemFontOfSize:17];
    if (bid) {
        self.obDetail.text = bid;
        UIImage *icon = ObackIconForAppPath(appPath);
        if (icon) {
            CGSize sz = CGSizeMake(29, 29);
            UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sz];
            UIImage *scaled = [r imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
                [icon drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
            }];
            self.imageView.image = scaled;
            self.imageView.layer.cornerRadius = 6;
            self.imageView.clipsToBounds = YES;
        }
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = CGRectGetHeight(self.contentView.bounds);
    CGFloat iconSize = 29;
    if (self.imageView.image) {
        self.imageView.frame = CGRectMake(15, (h - iconSize) / 2, iconSize, iconSize);
    }
    CGFloat textX = 15 + iconSize + 10;
    CGFloat rightPad = 70; // 给右侧开关留位
    CGFloat w = CGRectGetWidth(self.contentView.bounds) - textX - rightPad;
    self.textLabel.frame = CGRectMake(textX, 7, w, 22);
    self.obDetail.frame = CGRectMake(textX, 30, w, 15);
}

@end

#pragma mark - 列表控制器

@implementation ObackAppListController

- (NSArray *)_installedUserApps {
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
}

- (NSString *)_storeKey {
    return ([self.mode isEqualToString:@"white"] ? @"whitelistApps" : @"blacklistApps");
}

- (NSArray *)specifiers {
    if (!_specifiers) {
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
