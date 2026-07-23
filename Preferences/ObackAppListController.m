//
//  ObackAppListController.m
//  Oback 设置页 —— App 选择器（黑白名单）
//
//  枚举设备上已安装、且在桌面上有图标的 App，按「用户应用 / 系统程序」分组展示。
//  注意：iOS 11+ 起 LSApplicationWorkspace.allInstalledApplications 对非授权进程
//  返回空数组（需特定 entitlement），roothide 注入的设置 App 拿不到。
//  故这里改为扫描文件系统，零私有框架依赖，iOS 16 仍有效。
//

#import "ObackAppListController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UIKit/UIKit.h>

static NSString *const kDomain = @"com.zlhkf.oback";

#pragma mark - 自定义 cell：图标 + 名称 + bundle id 副标题 + 开关
// 关键结论（真机多轮验证）：在 roothide / iOS 16.4.1 下，只要 specifier 的 cell 类型是
// PSSwitchCell 且用 cellClassForSpecifier: 强换成自定义类，框架会按「开关 cell」做 KVC 接线
// （_switch / control / get / set），自定义类不认这些消息 → 消息转发 → 闪退。
// 故：① specifier cell 类型改用中性、无控件接线的 PSTitleValueCell（框架不做开关接线）；
//     ② 开关走 accessoryView，框架自动定位右侧，cell 自行管理；
//     ③ 加 setValue:forUndefinedKey: 防御，吞掉框架任何未预期 KVC，双保险。

@interface ObackAppSwitchCell : PSTableCell
@property (nonatomic, strong) UISwitch *switchView;
@end

@implementation ObackAppSwitchCell

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    // Subtitle 样式让 detailTextLabel 显示 bundle id
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier specifier:specifier];
    return self;
}

// 防御：roothide/iOS16 的 PSListController 可能对非开关型 cell 发送自定义类不认识的 KVC
// 消息（如 setTitleValue: / setValue: 等）。吞掉未定义 key，避免再次闪退。
- (void)setValue:(id)value forUndefinedKey:(NSString *)key {}
- (id)valueForUndefinedKey:(NSString *)key { return nil; }

- (void)setSpecifier:(PSSpecifier *)specifier {
    [super setSpecifier:specifier];

    // 懒创建开关，挂到 accessoryView（框架自动定位到右侧）
    if (!_switchView) {
        _switchView = [[UISwitch alloc] init];
        [_switchView addTarget:self action:@selector(_onSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        self.accessoryView = _switchView;
    }

    NSString *bid = [specifier propertyForKey:@"appBundleID"];
    if (bid.length) self.detailTextLabel.text = bid;

    UIImage *icon = [specifier propertyForKey:@"appIcon"];
    if (icon) {
        self.imageView.image = [self _resizedIcon:icon];
        self.imageView.layer.cornerRadius = 6.0;
        self.imageView.clipsToBounds = YES;
    }

    NSString *storeKey = [specifier propertyForKey:@"storeKey"];
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    _switchView.on = [[d arrayForKey:storeKey] containsObject:bid];
}

// 把任意尺寸的 App 图标缩到固定 29pt，避免大图撑破行高（不重写 layoutSubviews，
// 那是之前崩溃的诱因之一；直接约束 image 资源尺寸最稳）。
- (UIImage *)_resizedIcon:(UIImage *)icon {
    if (!icon) return nil;
    CGSize target = CGSizeMake(29, 29);
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:target];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [icon drawInRect:CGRectMake(0, 0, target.width, target.height)];
    }];
}

- (void)_onSwitchChanged:(UISwitch *)sw {
    NSString *bid = [self.specifier propertyForKey:@"appBundleID"];
    NSString *storeKey = [self.specifier propertyForKey:@"storeKey"];
    if (!bid || !storeKey) return;
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    NSMutableArray *arr = [[d arrayForKey:storeKey] mutableCopy] ?: [NSMutableArray array];
    if (sw.on) {
        if (![arr containsObject:bid]) [arr addObject:bid];
    } else {
        [arr removeObject:bid];
    }
    [d setObject:arr forKey:storeKey];
    [d synchronize];
}

@end

#pragma mark - App 列表控制器

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

#pragma mark 图标加载

- (UIImage *)_iconForAppPath:(NSString *)appPath info:(NSDictionary *)info {
    @try {
        NSBundle *bundle = [NSBundle bundleWithPath:appPath];
        if (!bundle) return nil;

        // 1. 尝试 asset catalog（CFBundleIconName）
        NSString *iconName = info[@"CFBundleIconName"];
        if ([iconName isKindOfClass:[NSString class]] && iconName.length) {
            UIImage *img = [UIImage imageNamed:iconName inBundle:bundle compatibleWithTraitCollection:nil];
            if (img) return img;
        }

        // 2. 尝试 CFBundleIconFiles
        NSArray *iconFiles = info[@"CFBundleIconFiles"];
        if (![iconFiles isKindOfClass:[NSArray class]] || !iconFiles.count) {
            NSDictionary *icons = info[@"CFBundleIcons"];
            NSDictionary *primary = [icons isKindOfClass:[NSDictionary class]] ? icons[@"CFBundlePrimaryIcon"] : nil;
            iconFiles = [primary isKindOfClass:[NSDictionary class]] ? primary[@"CFBundleIconFiles"] : nil;
        }

        for (NSString *name in iconFiles) {
            if (![name isKindOfClass:[NSString class]] || !name.length) continue;

            // 先尝试 imageNamed:inBundle:
            UIImage *img = [UIImage imageNamed:name inBundle:bundle compatibleWithTraitCollection:nil];
            if (img) return img;

            // 再尝试直接读文件（png / jpg / 无扩展名）
            NSString *path = [bundle pathForResource:name ofType:@"png"];
            if (!path) path = [bundle pathForResource:name ofType:@"jpg"];
            if (!path) path = [bundle pathForResource:name ofType:nil];
            if (path) {
                img = [UIImage imageWithContentsOfFile:path];
                if (img) return img;
            }
        }

        return nil;
    } @catch (NSException *e) {
        (void)e;
        return nil;
    }
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

- (Class)cellClassForSpecifier:(PSSpecifier *)specifier {
    NSString *className = [specifier propertyForKey:@"cellClass"];
    if (className.length) {
        Class c = NSClassFromString(className);
        if (c) return c;
    }
    return NSClassFromString(@"PSSwitchCell");
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

- (void)_addAppSpecifier:(NSDictionary *)app toSpecifiers:(NSMutableArray *)specs {
    NSString *bid = app[@"bundleID"];
    NSString *name = app[@"name"];
    NSString *appPath = app[@"path"];

    // 注意：cell 类型用中性、无控件接线的 PSTitleValueCell（绝不用 PSSwitchCell）。
    // PSSwitchCell 会让框架做开关接线，而我们换成自定义 cell 类后会因不认那些消息而闪退。
    // 开关的「初始状态 + 状态存储」完全由自定义 cell（ObackAppSwitchCell）在
    // setSpecifier: / _onSwitchChanged: 内自行处理，set/get 置 nil。
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name
                                                  target:self
                                                     set:nil
                                                     get:nil
                                                 detail:nil
                                                     cell:PSTitleValueCell
                                                     edit:nil];
    [s setProperty:bid forKey:@"appBundleID"];
    [s setProperty:bid forKey:@"value"]; // PSTitleValueCell 的右侧/副值；与下方 detailTextLabel 设成同一值，避免被框架覆盖
    [s setProperty:[self _storeKey] forKey:@"storeKey"];
    [s setProperty:@"ObackAppSwitchCell" forKey:@"cellClass"];

    // 加载图标并挂到 specifier 上，cell 初始化时会读取
    if (appPath.length) {
        NSString *infoPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
        UIImage *icon = [self _iconForAppPath:appPath info:info];
        if (icon) [s setProperty:icon forKey:@"appIcon"];
    }

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
