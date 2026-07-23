//
//  ObackAppListController.m
//  Oback 设置页 —— App 选择器（黑白名单）
//
//  枚举设备已装、桌面有图标的 App，按「用户应用 / 系统程序」分组，每行用系统原生
//  PSTitleValueCell 显示图标 + 名称，图标从 .app 包直接读取
//  （UIImage imageWithContentsOfFile:，无私有 API、零自定义 cell 类，roothide/iOS16.4.1 下稳定）。
//  注：PSApplicationCell 在本项目的 theos 头文件集合（theos/headers）未声明，
//  直接用会因 -Werror 编译失败、不出 .deb，故改用 PSTitleValueCell + 手动图标加载。
//  交互改为「点按某行 = 加入/移出名单」（无每行开关，因自定义 cell 类必崩）；
//  选中行借 willDisplayCell 显示勾选（√），顶部显示「已选 N 个」。
//
//  ⚠️ 稳定性铁律：本文件一律用系统原生 cell 类型（PSTitleValueCell / PSGroupCell / PSSwitchCell），
//  【绝不】自定义 cell 类、绝不 cellClassForSpecifier: 换类。新增 cell 类型前先确认 theos/headers 已声明。

#import "ObackAppListController.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

static NSString *const kDomain = @"com.zlhkf.oback";

@implementation ObackAppListController {
    NSDictionary *_allApps; // @{ @"user": [...], @"system": [...] }
    NSString *_searchText;
    NSSet *_homeScreenSet;   // 主屏可见的 bundle id 集合；nil = 读不到布局，回退显示全部
    NSMutableDictionary *_iconCache; // bid -> UIImage，避免每次 reload 重新读盘导致点按变慢
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

        // 仅保留主屏幕可见的 App（_homeScreenSet 为 nil 表示读不到布局，则显示全部）
        if (_homeScreenSet && ![_homeScreenSet containsObject:bid]) return;

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
        if (!_homeScreenSet) _homeScreenSet = [self _homeScreenBundleIDs];
        NSArray *userApps = [self _scanAppsAtPath:@"/var/containers/Bundle/Application"];
        NSArray *systemApps = [self _scanAppsAtPath:@"/Applications"];
        _allApps = @{@"user": userApps, @"system": systemApps};
    }
    return _allApps;
}

#pragma mark 仅显示主屏幕可见的 App（按 SpringBoard IconState 过滤）

// 读取 SpringBoard 主屏幕布局，收集所有「在主屏可见」的 bundle id（含 Dock 与文件夹内的）。
// 读不到（无权限/文件缺失/解析异常）时返回 nil，调用方据此回退为「显示全部」，避免把列表搞空。
- (NSSet *)_homeScreenBundleIDs {
    @try {
        NSDictionary *state = nil;
        NSArray *paths = @[
            @"/var/mobile/Library/SpringBoard/IconState.plist",
            @"/var/mobile/Library/SpringBoard/IconSupportState.plist"
        ];
        for (NSString *p in paths) {
            state = [NSDictionary dictionaryWithContentsOfFile:p];
            if (state) break;
        }
        if (!state) return nil;

        NSMutableSet *set = [NSMutableSet set];
        NSMutableArray *stack = [NSMutableArray array];
        id iconLists = state[@"iconLists"];
        if ([iconLists isKindOfClass:[NSArray class]]) [stack addObject:iconLists];
        id buttonBar = state[@"buttonBar"];
        if ([buttonBar isKindOfClass:[NSArray class]]) [stack addObject:buttonBar];

        while (stack.count) {
            id node = [stack lastObject];
            [stack removeLastObject];
            if ([node isKindOfClass:[NSArray class]]) {
                for (id item in node) [stack addObject:item];
            } else if ([node isKindOfClass:[NSDictionary class]]) {
                // 文件夹：递归其内部页面（iconLists / lists）
                id inner = node[@"iconLists"] ?: node[@"lists"];
                if ([inner isKindOfClass:[NSArray class]]) [stack addObject:inner];
            } else if ([node isKindOfClass:[NSString class]]) {
                [set addObject:node];
            }
        }
        return (set.count ? set : nil);
    } @catch (NSException *e) {
        (void)e;
        return nil;
    }
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

// 把「已在名单里」的 App 排到各组最前面（满足「选中的 App 置顶」）
- (NSArray *)_sortSelectedFirst:(NSArray *)apps {
    NSSet *sel = [NSSet setWithArray:[self _selectedApps]];
    if (sel.count == 0) return apps;
    return [apps sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL as = [sel containsObject:a[@"bundleID"]];
        BOOL bs = [sel containsObject:b[@"bundleID"]];
        if (as != bs) return as ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"name"] compare:b[@"name"] options:NSCaseInsensitiveSearch];
    }];
}

- (void)_addGroupHeader:(NSString *)title footer:(NSString *)footer toSpecifiers:(NSMutableArray *)specs {
    // ⚠️ 组标题必须用 specifier 的 name（第一个参数），不能用 setProperty:forKey:@"label"
    // —— PSGroupCell 读的是 name，设 label 会导致标题整片空白（之前「用户/系统」分类与顶部计数都不显示就是这原因）。
    PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:(title.length ? title : @"")
                                                        target:self
                                                           set:nil
                                                           get:nil
                                                        detail:nil
                                                           cell:PSGroupCell
                                                           edit:nil];
    if (footer.length) [group setProperty:footer forKey:@"footerText"];
    [specs addObject:group];
}

// 系统原生 PSTitleValueCell（theos/headers 已声明，编译稳定）：
// 图标从 .app 包直接读（imageWithContentsOfFile:），名称作标题。
// 点按 = 切换该 App 的名单归属（action 选择器）。
- (void)_addAppSpecifier:(NSDictionary *)app toSpecifiers:(NSMutableArray *)specs {
    NSString *bid = app[@"bundleID"];
    NSString *name = app[@"name"];

    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name
                                                  target:self
                                                     set:nil
                                                     get:nil
                                                 detail:nil
                                                     cell:PSTitleValueCell
                                                     edit:nil];
    // 手动加载 App 图标（不依赖 PSApplicationCell / 无私有 API）。
    // 注意：用字面量 @"iconImage" 而非 extern 常量 PSIconImageKey，
    // 因为 PSIconImageKey 在本仓库 CI 的 theos 头文件集合里可能未声明，
    // 直接用会因 -Werror 编译失败、不出 .deb。
    // 点按切换不靠 specifier 的 setAction:（roothide/headers 的 PSSpecifier 未声明该方法），
    // 改由控制器 tableView:didSelectRowAtIndexPath: 处理。
    UIImage *icon = [self _iconImageForApp:app];
    if (icon) [s setProperty:icon forKey:@"iconImage"];
    [s setProperty:bid forKey:@"appBundleID"];
    [specs addObject:s];
}

// 从 .app 包直接读取图标文件（无私有 API，iOS16 受限环境下也稳）。
// 结果按 bundle id 缓存，避免每次 reload 都重新读盘导致点按选择变慢。
- (UIImage *)_iconImageForApp:(NSDictionary *)app {
    NSString *bid = app[@"bundleID"];
    if ([bid isKindOfClass:[NSString class]] && bid.length) {
        UIImage *cached = _iconCache[bid];
        if (cached) return cached;
    }
    UIImage *img = [self _loadIconImageForApp:app];
    if (img && [bid isKindOfClass:[NSString class]] && bid.length) {
        if (!_iconCache) _iconCache = [NSMutableDictionary dictionary];
        _iconCache[bid] = img;
    }
    return img;
}

- (UIImage *)_loadIconImageForApp:(NSDictionary *)app {
    NSString *appPath = app[@"path"];
    if (![appPath isKindOfClass:[NSString class]] || !appPath.length) return nil;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"Info.plist"]];
    if (![info isKindOfClass:[NSDictionary class]]) return nil;

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    void (^addName)(id) = ^(id n) {
        if ([n isKindOfClass:[NSString class]] && [n length]) {
            [candidates addObject:n];
            [candidates addObject:[NSString stringWithFormat:@"%@@2x", n]];
            [candidates addObject:[NSString stringWithFormat:@"%@@3x", n]];
        }
    };

    // 现代：CFBundleIconName
    addName(info[@"CFBundleIconName"]);
    // CFBundleIcons -> PrimaryIcon（CFBundleIconName / CFBundleIconFiles）
    id icons = info[@"CFBundleIcons"];
    if ([icons isKindOfClass:[NSDictionary class]]) {
        id primary = icons[@"CFBundlePrimaryIcon"];
        if ([primary isKindOfClass:[NSDictionary class]]) {
            addName(primary[@"CFBundleIconName"]);
            id files = primary[@"CFBundleIconFiles"];
            if ([files isKindOfClass:[NSArray class]]) {
                for (id f in files) addName(f);
            }
        }
    }
    // 旧式：CFBundleIconFiles
    id legacy = info[@"CFBundleIconFiles"];
    if ([legacy isKindOfClass:[NSArray class]]) {
        for (id f in legacy) addName(f);
    }

    for (NSString *cand in candidates) {
        for (NSString *name in @[cand, [cand stringByAppendingString:@".png"]]) {
            UIImage *img = [UIImage imageWithContentsOfFile:[appPath stringByAppendingPathComponent:name]];
            if (img) return [self _scaledIcon:img];
        }
    }
    return nil;
}

// 把图标缩放到合适的行内尺寸（默认不缩放时 PSTitleValueCell 会把原图撑得过大）
- (UIImage *)_scaledIcon:(UIImage *)img {
    if (!img) return nil;
    CGFloat scale = [[UIScreen mainScreen] scale] ?: 1.0;
    CGFloat pt = 29.0; // 与系统「设置」App 列表图标同尺寸
    CGSize target = CGSizeMake(pt * scale, pt * scale);
    if (img.size.width <= target.width && img.size.height <= target.height) return img;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:target];
    return [r imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
        [img drawInRect:CGRectMake(0, 0, target.width, target.height)];
    }];
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
    _specifiers = nil;   // 清空以触发重建，使「选中项置顶」排序生效
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
            NSArray *userApps = [self _sortSelectedFirst:[self _filteredApps:apps[@"user"]]];
            NSArray *systemApps = [self _sortSelectedFirst:[self _filteredApps:apps[@"system"]]];

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
    // ⚠️ 不要调用 [super tableView:willDisplayCell:...]：本环境的 PSListController 未实现该方法，
    // super 调用会触发 unrecognized selector 闪退（崩溃日志实测）。只做我们自己的勾选逻辑。
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    NSString *bid = [spec propertyForKey:@"appBundleID"];
    if (bid.length) {
        BOOL selected = [[self _selectedApps] containsObject:bid];
        cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    }
}

#pragma mark 点按行切换名单（不依赖 setAction:，roothide/headers 的 PSSpecifier 未声明该方法）

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    NSString *bid = [spec propertyForKey:@"appBundleID"];
    if (bid.length) {
        [self _toggleApp:spec];
    } else if ([super respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
        // PSListController 未实现该方法时跳过，避免踩与 willDisplayCell 相同的 unrecognized selector 坑。
        [super tableView:tableView didSelectRowAtIndexPath:indexPath];
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
