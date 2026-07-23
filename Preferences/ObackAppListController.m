//
//  ObackAppListController.m
//  Oback 设置页 —— App 选择器（黑白名单）
//
//  枚举设备已装、桌面有图标的 App，按「用户应用 / 系统程序」分组，每行用系统原生
//  PSApplicationCell 显示图标 + 名称 + 副标题（按 applicationIdentifier 自动加载，
//  零自定义 cell 类，roothide/iOS16.4.1 下稳定）。
//  交互改为「点按某行 = 加入/移出名单」（无每行开关，因自定义 cell 类必崩）；
//  选中行借 willDisplayCell 显示勾选（√），顶部显示「已选 N 个」。
//
//  ⚠️ 稳定性铁律：本文件一律用系统原生 cell 类型（PSApplicationCell / PSGroupCell），
//  【绝不】自定义 cell 类、绝不 cellClassForSpecifier: 换类。

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

#pragma mark 存储与列表生成

- (NSString *)_storeKey {
    return ([self.mode isEqualToString:@"white"] ? @"whitelistApps" : @"blacklistApps");
}

- (NSArray *)_selectedApps {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    return [d arrayForKey:[self _storeKey]] ?: @[];
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

// 系统原生 PSApplicationCell：按 applicationIdentifier 自动加载图标 + 名称 + 副标题。
// 点按 = 切换该 App 的名单归属（action 选择器）。
- (void)_addAppSpecifier:(NSDictionary *)app toSpecifiers:(NSMutableArray *)specs {
    NSString *bid = app[@"bundleID"];
    NSString *name = app[@"name"];

    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name
                                                  target:self
                                                     set:nil
                                                     get:nil
                                                 detail:nil
                                                     cell:PSApplicationCell
                                                     edit:nil];
    [s setProperty:bid forKey:@"applicationIdentifier"];
    [s setProperty:bid forKey:@"appBundleID"];
    [s setAction:@selector(_toggleApp:)];
    [specs addObject:s];
}

// 点按切换：加入 / 移出当前名单（whitelistApps / blacklistApps）
- (void)_toggleApp:(PSSpecifier *)spec {
    NSString *bid = [spec propertyForKey:@"appBundleID"];
    if (!bid) return;
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    NSMutableArray *arr = [[d arrayForKey:[self _storeKey]] mutableCopy] ?: [NSMutableArray array];
    if ([arr containsObject:bid]) [arr removeObject:bid];
    else [arr addObject:bid];
    [d setObject:arr forKey:[self _storeKey]];
    [d synchronize];
    [self reloadSpecifiers];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        @try {
            NSMutableArray *specs = [NSMutableArray array];

            // 顶部：已选数量
            NSUInteger cnt = [[self _selectedApps] count];
            [self _addGroupHeader:[NSString stringWithFormat:@"已选 %lu 个应用", (unsigned long)cnt]
                           footer:@"" toSpecifiers:specs];

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

#pragma mark 选中态勾选（不自定义 cell 类，借 willDisplayCell 设 accessoryType）

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    [super tableView:tableView willDisplayCell:cell forRowAtIndexPath:indexPath];
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    NSString *bid = [spec propertyForKey:@"appBundleID"];
    if (bid.length) {
        BOOL selected = [[self _selectedApps] containsObject:bid];
        cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    }
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
