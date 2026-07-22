//
//  ObackAppListController.m
//  Oback 设置页 —— App 选择器（黑白名单）
//
//  枚举设备上已安装的用户 App，每个 App 一个开关，开关状态分别存入
//  NSUserDefaults(suite=com.zlhkf.oback) 的 whitelistApps / blacklistApps 数组。
//  图标通过 LSApplicationProxy（私有 API，roothide 下可用）加载。
//

#import "ObackAppListController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <Preferences/PSSwitchTableCell.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>

static NSString *const kDomain = @"com.zlhkf.oback";

#pragma mark - 图标加载（私有 API）

static UIImage *ObackIconForBundle(NSString *bid) {
    if (!bid.length) return nil;
    Class proxyCls = NSClassFromString(@"LSApplicationProxy");
    if (!proxyCls) return nil;
    SEL appSel = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (![proxyCls respondsToSelector:appSel]) return nil;
    id proxy = [proxyCls performSelector:appSel withObject:bid];
    if (!proxy) return nil;

    // 1) icon 属性（UIImage）
    SEL iconSel = NSSelectorFromString(@"icon");
    if ([proxy respondsToSelector:iconSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        UIImage *img = [proxy performSelector:iconSel];
#pragma clang diagnostic pop
        if (img) return img;
    }
    // 2) iconDataForVariant:（NSData，variant 传 0 取主图标）
    SEL dataSel = NSSelectorFromString(@"iconDataForVariant:");
    if ([proxy respondsToSelector:dataSel]) {
        NSData *(*fn)(id, SEL, NSInteger) = (NSData *(*)(id, SEL, NSInteger))objc_msgSend;
        NSData *data = fn(proxy, dataSel, 0);
        if (data) {
            UIImage *img = [UIImage imageWithData:data];
            if (img) return img;
        }
    }
    return nil;
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
    self.textLabel.text = specifier.name ?: bid;
    self.textLabel.font = [UIFont systemFontOfSize:17];
    if (bid) {
        self.obDetail.text = bid;
        UIImage *icon = ObackIconForBundle(bid);
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
    Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
    if (!wsCls) return @[];
    SEL defSel = NSSelectorFromString(@"defaultWorkspace");
    if (![wsCls respondsToSelector:defSel]) return @[];
    id ws = [wsCls performSelector:defSel];
    if (!ws) return @[];
    SEL allSel = NSSelectorFromString(@"allApplications");
    if (![ws respondsToSelector:allSel]) allSel = NSSelectorFromString(@"allInstalledApplications");
    NSArray *apps = [ws performSelector:allSel];
    if (![apps isKindOfClass:[NSArray class]]) return @[];

    NSMutableArray *result = [NSMutableArray array];
    for (id app in apps) {
        // 只保留用户安装的 App（过滤系统 / 隐藏）
        SEL typeSel = NSSelectorFromString(@"applicationType");
        NSString *type = nil;
        if ([app respondsToSelector:typeSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            type = [app performSelector:typeSel];
#pragma clang diagnostic pop
        }
        if (type && ![type isEqualToString:@"User"]) continue;

        SEL bidSel = NSSelectorFromString(@"bundleIdentifier");
        SEL nameSel = NSSelectorFromString(@"localizedName");
        NSString *bid = nil, *name = nil;
        if ([app respondsToSelector:bidSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            bid = [app performSelector:bidSel];
            if ([app respondsToSelector:nameSel]) name = [app performSelector:nameSel];
#pragma clang diagnostic pop
        }
        if (!bid) continue;
        if (!name) name = bid;
        [result addObject:@{@"bundleID": bid, @"name": name}];
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
            PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name
                                                           target:self
                                                              set:@selector(_setAppEnabled:specifier:)
                                                              get:@selector(_isAppEnabled:)
                                                          detail:nil
                                                              cell:PSSwitchCell
                                                              edit:nil];
            [s setProperty:bid forKey:@"appBundleID"];
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
