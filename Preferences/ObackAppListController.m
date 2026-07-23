//
//  ObackAppListController.m
//  Oback 设置页 —— App 选择器（黑白名单）
//
//  枚举设备上已安装、且在桌面上有图标的 App，按「用户应用 / 系统程序」分组展示。
//  注意：iOS 11+ 起 LSApplicationWorkspace.allInstalledApplications 对非授权进程
//  返回空数组（需特定 entitlement），roothide 注入的设置 App 拿不到。
//  故这里改为扫描文件系统，零私有框架依赖，iOS 16 仍有效。
//
//  ⚠️ 稳定性铁律（本环境实测 4 次闪退后定论）：
//  roothide / iOS 16.4.1 / PreferenceLoader 下，用 cellClassForSpecifier: 把 specifier
//  换成【自定义 cell 类】必崩——框架按 specifier 的 cell 类型向 cell 发送该类型专有方法，
//  自定义类不认 → 未识别 selector → 消息转发 → SIGABRT 闪退。setValue:forUndefinedKey:
//  只能挡 KVC，挡不住直接消息，故无效。
//  因此本文件一律使用系统原生 cell 类型（PSSwitchCell），【绝不】自定义 cell 类、绝不重写
//  cellClassForSpecifier:。图标/灰色副标题在此环境无法稳定实现，bundle id 直接并入标题。

#import "ObackAppListController.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

static NSString *const kDomain = @"com.zlhkf.oback";

@implementation ObackAppListController {
    NSDictionary *_allApps; // @{ @"user": [...], @"system": [...] }
    NSString *_searchText;
}

#pragma mark App 枚举

// 扫描指定目录，返回有桌面图标的 App 数组（元素为 @{path, bundleID, name}）。
- (NSArray *)_scanAppsAtPath:(NSString *)basePath {
    @try {
        NSMutableArray *result = [NSMutableArray array];
        if (!basePath.length) return result;

        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *entries = [fm contentsOfDirectoryAtPath:basePath error:nil];

        for (NSString *entry in entries) {
            NSString *entryPath = [basePath stringByAppendingPathComponent:entry];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:entryPath isDirectory:&isDir] || !isDir) continue;

            // /var/containers/Bundle/Application 下还有一层 UUID
            if ([basePath isEqualToString:@"/var/containers/Bundle/Application"]) {
                NSArray *subEntries = [fm contentsOfDirectoryAtPath:entryPath error:nil];
                for (NSString *sub in subEntries) {
                    if (![sub hasSuffix:@".app"]) continue;
                    [self _addAppAtPath:[entryPath stringByAppendingPathComponent:sub] toArray:result];
                }
            } else if ([entry hasSuffix:@".app"]) {
                [self _addAppAtPath:entryPath toArray:result];
            }
        }

        [result sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]]];
        return result;
    } @catch (NSException *e) {
        (void)e;
        return @[];
    }
}

- (void)_addAppAtPath:(NSString *)appPath toArray:(NSMutableArray *)result {
    @try {
        NSString *infoPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
        if (!info) return;

        NSString *bid = info[@"CFBundleIdentifier"];
        if (!bid.length) return;

        // 只保留在桌面上有图标的 App
        id iconName = info[@"CFBundleIconName"];
        id iconFiles = info[@"CFBundleIconFiles"];
        id icons = info[@"CFBundleIcons"];
        BOOL hasIcon = ([iconName isKindOfClass:[NSString class]] && [iconName length])
                    || ([iconFiles isKindOfClass:[NSArray class]] && [iconFiles count])
                    || ([icons isKindOfClass:[NSDictionary class]] && [icons count]);
        if (!hasIcon) return;

        NSString *name = info[@"CFBundleDisplayName"];
        if (![name isKindOfClass:[NSString class]] || !name.length) {
            name = info[@"CFBundleName"];
            if (![name isKindOfClass:[NSString class]] || !name.length) {
                name = bid;
            }
        }

        [result addObject:@{@"path": appPath, @"bundleID": bid, @"name": name}];
    } @catch (NSException *e) {
        (void)e;
    }
}

- (NSDictionary *)_installedApps {
    if (!_allApps) {
        NSArray *userApps = [self _scanAppsAtPath:@"/var/containers/Bundle/Application"];
        NSArray *systemApps = [self _scanAppsAtPath:@"/Applications"];
        _allApps = @{@"user": userApps, @"system": systemApps};
    }
    return _allApps;
}

#pragma mark 搜索与列表生成

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
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (NSArray *)_filteredApps:(NSArray *)apps {
    if (!_searchText.length) return apps;
    NSString *lowerQuery = [_searchText lowercaseString];
    return [apps filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSDictionary *app, NSDictionary *bindings) {
        NSString *name = [app[@"name"] lowercaseString];
        NSString *bid  = [app[@"bundleID"] lowercaseString];
        return [name rangeOfString:lowerQuery].location != NSNotFound
            || [bid rangeOfString:lowerQuery].location != NSNotFound;
    }]];
}

- (void)_addGroupHeader:(NSString *)title footer:(NSString *)footer toSpecifiers:(NSMutableArray *)specs {
    PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@""
                                                        target:self
                                                           set:nil
                                                           get:nil
                                                        detail:nil
                                                           cell:PSGroupCell
                                                           edit:nil];
    if (title.length) [group setProperty:title forKey:@"label"];
    if (footer.length) [group setProperty:footer forKey:@"footerText"];
    [specs addObject:group];
}

// 系统原生 PSSwitchCell（稳定，不带自定义 cell 类）。标题行直接并入 bundle id。
- (void)_addAppSpecifier:(NSDictionary *)app toSpecifiers:(NSMutableArray *)specs {
    NSString *bid = app[@"bundleID"];
    NSString *name = app[@"name"];
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

- (NSArray *)specifiers {
    if (!_specifiers) {
        @try {
            NSMutableArray *specs = [NSMutableArray array];

            NSDictionary *apps = [self _installedApps];
            NSArray *userApps = [self _filteredApps:apps[@"user"]];
            NSArray *systemApps = [self _filteredApps:apps[@"system"]];

            if (userApps.count) {
                [self _addGroupHeader:@"用户应用" footer:@"" toSpecifiers:specs];
                for (NSDictionary *app in userApps) {
                    [self _addAppSpecifier:app toSpecifiers:specs];
                }
            }

            if (systemApps.count) {
                [self _addGroupHeader:@"系统程序" footer:@"" toSpecifiers:specs];
                for (NSDictionary *app in systemApps) {
                    [self _addAppSpecifier:app toSpecifiers:specs];
                }
            }

            // 搜索无结果时给个提示分组
            if (!userApps.count && !systemApps.count) {
                [self _addGroupHeader:@"" footer:@"未找到匹配的应用" toSpecifiers:specs];
            }

            _specifiers = specs;
        } @catch (NSException *e) {
            (void)e;
            _specifiers = [NSMutableArray array];
        }
    }
    return _specifiers;
}

#pragma mark 开关存取（原生 PSSwitchCell 接线）

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
