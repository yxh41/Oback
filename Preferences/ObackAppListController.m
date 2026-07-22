//
//  ObackAppListController.m
//  Oback 设置页 —— App 选择器（黑白名单）
//
//  枚举设备上已安装、且在桌面上有图标的 App。
//  注意：iOS 11+ 起 LSApplicationWorkspace.allInstalledApplications 对非授权进程
//  返回空数组（需特定 entitlement），roothide 注入的设置 App 拿不到。
//  故这里改为扫描 /var/containers/Bundle/Application/*.app，零私有框架依赖，iOS 16 仍有效。
//
//  渲染策略（2026-07-23 重写）：移除自定义 cell / 图标加载 / cellClassForSpecifier:，
//  全部退回系统原生 PSSwitchCell（与设置页自身 cell 同源，iOS 16.4.1 / roothide 下最稳，
//  不会在渲染期崩溃）。顶部加 UISearchController 用于按名称或 bundle id 快速过滤。
//

#import "ObackAppListController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <Preferences/PSSwitchTableCell.h>
#import <UIKit/UIKit.h>

static NSString *const kDomain = @"com.zlhkf.oback";

#pragma mark - App 枚举（扫描文件系统，零私有框架依赖，全程容错）

@implementation ObackAppListController {
    NSArray *_allApps;      // 所有有图标的 App（缓存）
    NSString *_searchText;  // 当前搜索关键字
}

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

                // 只保留在桌面上有图标的 App：过滤掉无 UI / 无图标的守护进程、插件、隐藏程序等。
                id iconName = info[@"CFBundleIconName"];
                id iconFiles = info[@"CFBundleIconFiles"];
                id icons = info[@"CFBundleIcons"];
                BOOL hasIcon = ([iconName isKindOfClass:[NSString class]] && [iconName length])
                            || ([iconFiles isKindOfClass:[NSArray class]] && [iconFiles count])
                            || ([icons isKindOfClass:[NSDictionary class]] && [icons count]);
                if (!hasIcon) continue;

                // 取 App 名称；跳过空字符串，避免标题只显示括号。
                NSString *name = info[@"CFBundleDisplayName"];
                if (![name isKindOfClass:[NSString class]] || !name.length) {
                    name = info[@"CFBundleName"];
                    if (![name isKindOfClass:[NSString class]] || !name.length) {
                        name = bid;
                    }
                }
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

- (void)viewDidLoad {
    [super viewDidLoad];

    UISearchController *searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    searchController.searchResultsUpdater = self;
    searchController.obscuresBackgroundDuringPresentation = NO;
    searchController.searchBar.placeholder = @"搜索应用名称或 bundle id";

    self.navigationItem.searchController = searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *text = [searchController.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] ?: @"";
    _searchText = text.length ? text : nil;
    _specifiers = nil;            // 强制 specifiers 重新生成
    [self reloadSpecifiers];      // PSListController 提供的刷新方法
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        @try {
            NSMutableArray *specs = [NSMutableArray array];

            // 分组标题 + footer 说明
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

            // 缓存所有 App（只扫一次）
            if (!_allApps) {
                _allApps = [self _installedUserApps];
            }

            // 按搜索关键字过滤（名称或 bundle id 包含即可，不区分大小写）
            NSArray *apps = _allApps;
            if (_searchText.length) {
                NSString *lowerQuery = [_searchText lowercaseString];
                apps = [_allApps filteredArrayUsingPredicate:
                        [NSPredicate predicateWithBlock:^BOOL(NSDictionary *app, NSDictionary *bindings) {
                    NSString *name = [app[@"name"] lowercaseString];
                    NSString *bid  = [app[@"bundleID"] lowercaseString];
                    return [name rangeOfString:lowerQuery].location != NSNotFound
                        || [bid rangeOfString:lowerQuery].location != NSNotFound;
                }]];
            }

            for (NSDictionary *app in apps) {
                NSString *bid = app[@"bundleID"];
                NSString *name = app[@"name"];
                // 名称与 bundle id 拼进 title，统一格式：Name (com.bundle.id)
                NSString *title = [NSString stringWithFormat:@"%@ (%@)", name, bid];
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
