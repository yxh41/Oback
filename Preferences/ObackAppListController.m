//
//  ObackAppListController.m
//  Oback 设置页 —— App 选择器（黑白名单）
//
//  枚举设备已装、桌面可见的 App，按「用户应用 / 越狱应用 / 巨魔应用 / 系统程序」四类分组，每行用系统原生
//  PSTitleValueCell 显示图标 + 名称，图标从 .app 包直接读取（**读不到只是这一行没图，不影响勾选与生效**）
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
#import <dlfcn.h>             // [applist3] dladdr：取本 bundle 自身加载路径 ⇒ 运行时定位 roothide 的随机 jbroot
#import "ObackPrefsBridge.h"   // 直接读写全局 plist（绕过 roothide per-app NSUserDefaults 容器化）

static NSString *const kDomain = @"com.zlhkf.oback";

// ─────────────────────────────────────────────────────────────────────────────
// [applist3 2026-09-18] jbroot 探测 —— roothide 的越狱根是**随机路径**，绝不能硬编码
// 现象：R26 交付后用户报「没看到越狱应用这个分组」。根因不是没装越狱 App，而是**越狱根扫错了**：
//   roothide（本机环境）把整套越狱环境装在
//       /var/containers/Bundle/Application/.jbroot-XXXXXXXXXXXXXXXX/
//   每次越狱重新随机，而且**故意不建 /var/jb** —— /var/jb 是 rootless 的软链约定（指向
//   /private/preboot/…），roothide 靠「路径不可预测」躲开 stat("/var/jb") 这类越狱检测。
//   ⇒ 原来只扫 /var/jb/Applications，在 roothide 上**恒为空**。
//   而 deb 里的 /Applications/X.app 在 roothide 下实际落到 <jbroot>/Applications/X.app
//   ⇒ Sileo / Filza / NewTerm 这些越狱 App 全在 <jbroot>/Applications 里，一个都没被扫到。
//   越狱桶空 ⇒ unselJail.count==0 ⇒ 分组头不渲染 ⇒ 看不到「越狱应用」。
//
// 探测两条路（A 优先、B 兜底；都不依赖私有 API，也都不硬编码随机路径）：
//   A. dladdr 取**本 bundle 自己**的加载路径。本 bundle 就装在 jbroot 里，路径里必然含
//      .jbroot-XXXX 这一段，从它截出根前缀（同样吃下未解析的 .jbroot 软链形态）。
//   B. 扫 jbroot 的实现位置 /var/containers/Bundle/Application，找名字以 .jbroot 开头、
//      且下面有 usr/bin/dpkg 的目录（用 dpkg 认门，排除同名巧合目录）。
// 只探测一次并缓存；两条都失败返回 nil ⇒ 调用方退回 /var/jb（rootless / 传统越狱）。
// 已知局限（接受）：探测失败时行为退回改动前 —— 越狱桶只剩 /var/jb 一条来源。
static char *obJbrootAnchor = NULL;   // 仅为给 dladdr 提供一个「落在本镜像内」的地址

static NSString *obJbrootPrefix(void) {
    static NSString *cached = nil;
    static BOOL probed = NO;
    if (probed) return cached;
    probed = YES;
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];

        // A. 从自身加载路径截取
        Dl_info info;
        if (dladdr((const void *)&obJbrootAnchor, &info) && info.dli_fname) {
            NSString *p = [NSString stringWithUTF8String:info.dli_fname];
            NSMutableString *acc = [NSMutableString string];
            for (NSString *c in [p componentsSeparatedByString:@"/"]) {
                if (!c.length) continue;                 // 跳过绝对路径开头的空段
                [acc appendFormat:@"/%@", c];
                if ([c hasPrefix:@".jbroot"]) {          // .jbroot-XXXX（真根）或 .jbroot（软链）
                    if ([fm fileExistsAtPath:acc]) cached = [acc copy];
                    break;
                }
            }
        }

        // B. 兜底：在 jbroot 的实现位置里找 .jbroot-* 目录，并以 usr/bin/dpkg 认门
        if (!cached) {
            NSString *base = @"/var/containers/Bundle/Application";
            for (NSString *e in [fm contentsOfDirectoryAtPath:base error:nil]) {
                if (![e hasPrefix:@".jbroot"]) continue;
                NSString *cand = [base stringByAppendingPathComponent:e];
                if ([fm fileExistsAtPath:[cand stringByAppendingPathComponent:@"usr/bin/dpkg"]]) {
                    cached = [cand copy];
                    break;
                }
            }
        }
    } @catch (NSException *e) { (void)e; }
    return cached;
}

// ─────────────────────────────────────────────────────────────────────────────
// [R26 2026-09-20] 巨魔（TrollStore）判定 —— 只看文件，零私有 API
// 为什么不能只看路径：TrollStore 把 App 装在**用户容器目录**（和 App Store 应用同一层），
// 容器文件系统里没有任何 per-app 标记文件，所以在路径上它与普通应用无法区分。
// 唯一能只看文件就判出来的可靠特征是**代码签名**：TrollStore 用 ldid 风格签名，
// entitlements 以 XML 明文写在签名里，其中含 platform-application / no-container
// 这类「系统应用才有的」权限 —— 这正是它能被 installd 当成 System 类型注册的原因。
// ⚠️ 若将来 TrollStore 改成只留 DER 编码（键名变 OID、明文不再出现），本判定会**失效并静默降级**
//    为「用户应用」，绝不会把普通应用误判成巨魔（宁可漏判，不可误判）。
//
// 判定特征串 = 两条「系统应用才有的」权限（普通 App Store 应用与 AltStore/Sideloadly 侧载都不带）：
static NSArray *obTrollMarkers(void) {
    static NSArray *m = nil;
    if (!m) {
        m = @[[@"platform-application" dataUsingEncoding:NSUTF8StringEncoding],
              [@"com.apple.private.security.no-container" dataUsingEncoding:NSUTF8StringEncoding]];
    }
    return m;
}

// 只读文件 [off, off+len) 一段。读不到 / 越界 / 抛异常一律返回 nil —— 列表构建绝不能被它打断。
static NSData *obReadAt(NSString *path, unsigned long long off, NSUInteger len) {
    if (!path.length || !len) return nil;
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return nil;
    NSData *d = nil;
    @try {
        [fh seekToFileOffset:off];
        d = [fh readDataOfLength:len];
    } @catch (NSException *e) { (void)e; d = nil; }
    @try { [fh closeFile]; } @catch (NSException *e) { (void)e; }
    return (d.length ? d : nil);
}

static uint32_t obU32(const uint8_t *p, BOOL big) {
    if (big) return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
    return ((uint32_t)p[3] << 24) | ((uint32_t)p[2] << 16) | ((uint32_t)p[1] << 8) | (uint32_t)p[0];
}

// 从已读入的 Mach-O 头部 + 加载命令区里找 LC_CODE_SIGNATURE(0x1d)，回填它指向的文件区间。
// 只走这一条路是为了**不把整个可执行文件读进内存**（App 的主二进制动辄几十 MB，逐个读会卡住列表）。
static BOOL obCodeSigRange(const uint8_t *mh, NSUInteger len, uint64_t *outOff, uint32_t *outSize) {
    if (len < 32) return NO;
    uint32_t magic = obU32(mh, NO);
    BOOL big;
    NSUInteger hdr;
    if (magic == 0xfeedface)      { big = NO;  hdr = 28; }   // 32 位小端
    else if (magic == 0xfeedfacf) { big = NO;  hdr = 32; }   // 64 位小端（arm64 走这条）
    else if (magic == 0xcefaedfe) { big = YES; hdr = 28; }
    else if (magic == 0xcffaedfe) { big = YES; hdr = 32; }
    else return NO;
    uint32_t ncmds = obU32(mh + 16, big);
    if (ncmds == 0 || ncmds > 4096) return NO;
    NSUInteger off = hdr;
    for (uint32_t i = 0; i < ncmds; i++) {
        if (off + 8 > len) return NO;
        uint32_t cmd = obU32(mh + off, big);
        uint32_t sz  = obU32(mh + off + 4, big);
        if (sz < 8) return NO;
        if (cmd == 0x1d) {                                   // LC_CODE_SIGNATURE
            if (off + 16 > len) return NO;
            *outOff  = (uint64_t)obU32(mh + off + 8,  big);   // linkedit_data_command.dataoff
            *outSize = obU32(mh + off + 12, big);             // ...datasize
            return (*outSize > 0);
        }
        off += sz;
    }
    return NO;
}

// 在 off 处的那个 Mach-O 切片里，取代码签名区并找标记。
static BOOL obSliceHasTrollMarker(NSString *exePath, uint64_t off) {
    NSData *hdr = obReadAt(exePath, off, 16384);
    if (!hdr || hdr.length < 32) return NO;
    uint64_t csOff = 0;
    uint32_t csSize = 0;
    if (!obCodeSigRange(hdr.bytes, hdr.length, &csOff, &csSize)) return NO;
    if (csSize > 262144) return NO;      // 异常值防护：正常签名 blob 远小于 256KB
    NSData *sig = obReadAt(exePath, off + csOff, csSize);
    if (!sig.length) return NO;
    NSRange whole = NSMakeRange(0, sig.length);
    for (NSData *mk in obTrollMarkers()) {
        if (mk.length && [sig rangeOfData:mk options:0 range:whole].location != NSNotFound) return YES;
    }
    return NO;
}

// 主可执行文件（thin / fat / fat64 都支持）的签名里是否带系统级权限特征。
static BOOL obExeHasTrollMarker(NSString *exePath) {
    NSData *head = obReadAt(exePath, 0, 4096);
    if (!head || head.length < 8) return NO;
    const uint8_t *p = head.bytes;
    uint32_t magicBE = obU32(p, YES);                 // fat 头是大端
    BOOL isFat   = (magicBE == 0xCAFEBABE || magicBE == 0xBEBAFECA);
    BOOL isFat64 = (magicBE == 0xCAFEBABF || magicBE == 0xBFBAFECA);
    if (isFat || isFat64) {
        BOOL big = (magicBE == 0xCAFEBABE || magicBE == 0xCAFEBABF);
        NSUInteger ent = isFat64 ? 32 : 20;
        uint32_t nfat = obU32(p + 4, big);
        if (nfat == 0 || nfat > 16) return NO;
        NSData *fh = obReadAt(exePath, 8, ent * nfat);
        if (!fh || fh.length < ent * nfat) return NO;
        const uint8_t *fp = fh.bytes;
        for (uint32_t i = 0; i < nfat; i++) {
            uint64_t coff;
            if (isFat64) {
                coff = ((uint64_t)obU32(fp + i * ent + 8, big) << 32) | obU32(fp + i * ent + 12, big);
            } else {
                coff = obU32(fp + i * ent + 8, big);
            }
            if (obSliceHasTrollMarker(exePath, coff)) return YES;
        }
        return NO;
    }
    return obSliceHasTrollMarker(exePath, 0);         // 非 fat：本身就是 Mach-O 头
}

@implementation ObackAppListController {
    NSDictionary *_allApps; // @{ @"user": [...], @"system": [...] }
    NSString *_searchText;
    NSSet *_homeScreenSet;   // 主屏可见的 bundle id 集合；nil = 读不到布局，回退显示全部
    NSMutableDictionary *_iconCache; // bid -> UIImage，避免每次 reload 重新读盘导致点按变慢
    NSMutableDictionary *_trollCache; // [R26] bid -> NSNumber(BOOL)：是否 TrollStore（巨魔）安装。
                                      // 判定要读主可执行文件的代码签名区，缓存后每次进页面只探测一次。
    // [applist3 2026-09-18] 置底诊断统计（重建 _allApps 时重算）
    NSString *_statLine;             // 拼好的统计文案
    NSUInteger _statContainer;       // 用户容器根命中数（已过主屏过滤）
    NSUInteger _statRootApps;        // /Applications 命中数
    NSUInteger _statJbrootApps;      // <jbroot>/Applications 命中数
    NSUInteger _statLegacyJbApps;    // /var/jb/Applications 命中数（rootless）
    NSUInteger _statDroppedByHome;   // 被主屏集合砍掉的条数
}

#pragma mark App 枚举

// 扫描指定目录，返回 App 数组（元素为 @{path, bundleID, name, exe}）。
// homeScreenOnly=YES 时只保留主屏可见的 App —— **只给用户容器根用**（理由见 _addAppAtPath:）。
- (NSArray *)_scanAppsAtPath:(NSString *)basePath homeScreenOnly:(BOOL)homeScreenOnly {
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
                    [self _addAppAtPath:[entryPath stringByAppendingPathComponent:sub]
                                 toArray:result homeScreenOnly:homeScreenOnly];
                }
            } else if ([entry hasSuffix:@".app"]) {
                [self _addAppAtPath:entryPath toArray:result homeScreenOnly:homeScreenOnly];
            }
        }

        [result sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]]];
        return result;
    } @catch (NSException *e) {
        (void)e;
        return @[];
    }
}

- (void)_addAppAtPath:(NSString *)appPath toArray:(NSMutableArray *)result homeScreenOnly:(BOOL)homeScreenOnly {
    @try {
        NSString *infoPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
        if (!info) return;

        NSString *bid = info[@"CFBundleIdentifier"];
        if (!bid.length) return;

        // [applist3 2026-09-18] 主屏过滤**收窄到只作用于用户容器根**（homeScreenOnly）。
        // 为什么收窄：这道过滤原先对**所有**扫描根生效（R23 的「deb 装的应用搜不到」就是它干的），
        // 而越狱根 / 系统根里的 App 本来就是正经装上的、按「不在主屏」砍掉属于误伤 ——
        // 刚修好的 <jbroot>/Applications 会被它二次清空（越狱 App 一进 App 资源库就看不到）。
        // 用户容器根保留它，是因为那里可能残留无图标的隐藏条目。
        // _homeScreenSet 为 nil（读不到布局）时一律不过滤：宁可多列，不可漏列。
        if (homeScreenOnly && _homeScreenSet && ![_homeScreenSet containsObject:bid]) {
            _statDroppedByHome++;   // 诊断计数：底部统计行会显示被它砍掉多少条
            return;
        }

        // [P0 2026-09-19] 此处原有「只保留声明了图标键的 App」过滤（认 CFBundleIconName /
        // CFBundleIconFiles / CFBundleIcons），命中失败直接 return 丢弃整条。两处硬伤，已移除：
        //   ① 漏了**单数字段 CFBundleIconFile**（老 deb / 老 SDK 工程最常见的写法）⇒ 有图标也判「无」；
        //   ② 图标只是装饰，而「判无图标 = 整条丢弃」的代价是名单**结构性失效**：
        //      用户点名要屏蔽的 App（deb 装的、只在 App 资源库的、Info.plist 不规范的）根本加不进来，
        //      这比「少一张缩略图」严重得多。
        // 现在：能否配到图标由 _loadIconImageForApp: 单独负责，配不到只是这一行没图。
        // 「是否算已装可见 App」由上面的主屏过滤判据负责（且只对用户容器根生效，见该处说明），
        // 不再叠加图标键这道伪判据。

        NSString *name = info[@"CFBundleDisplayName"];
        if (![name isKindOfClass:[NSString class]] || !name.length) {
            name = info[@"CFBundleName"];
            if (![name isKindOfClass:[NSString class]] || !name.length) {
                name = bid;
            }
        }

        // [R26] 顺带存下主可执行文件名：巨魔判定要按名去读 <App>.app/<exe> 的代码签名，
        // 存这里可省掉「每个 App 再读一次 Info.plist」。
        NSString *exe = info[@"CFBundleExecutable"];
        if (![exe isKindOfClass:[NSString class]]) exe = @"";
        [result addObject:@{@"path": appPath, @"bundleID": bid, @"name": name, @"exe": exe}];
    } @catch (NSException *e) {
        (void)e;
    }
}

// 系统 App 候选根目录（越狱桶与系统程序桶都从这里出）：
//   ① /Applications          真实系统卷（rootfs）；roothide 下原样，**只有苹果 App**；
//   ② <jbroot>/Applications  运行时探测到的越狱根，第三方 / 越狱 App（Sileo 等）的实际落点；
//   ③ /var/jb/Applications   rootless 兜底（roothide 上不存在，扫到即空，无副作用）。
// ⚠️ 不要加 <jbroot>/rootfs/Applications：那是 bind mount 回真实根的同一条路径，
//    会被判成「越狱根」从而把苹果 App 塞进越狱桶。
// 不存在的根 contentsOfDirectoryAtPath 返回 nil，_scanAppsAtPath 返回空数组，无副作用。
- (NSArray *)_systemAppPaths {
    NSMutableArray *paths = [NSMutableArray arrayWithObject:@"/Applications"];
    NSString *jb = obJbrootPrefix();
    if (jb.length) [paths addObject:[jb stringByAppendingPathComponent:@"Applications"]];
    [paths addObject:@"/var/jb/Applications"];
    return paths;
}

// 「设置」App 兜底条目（com.apple.Preferences）。
// 背景：Oback 自 2c6b7f1 起在系统「设置」App 内也生效，用户需要在白名单/黑名单/左缘排除/全局返回等
// 列表里能勾到它。但目录扫描仍可能被主屏过滤挡掉，导致搜索「设置」搜不到：
//   _homeScreenSet：设置图标被移出主屏（进 App 资源库）时就不在 IconState.plist 里。
//（原先还有第二道 hasIcon 过滤，已在 build applist1 删除，不再是原因。）
// 故扫描不到时手工补一条：保证一定能被搜索到并勾选。图标读不到就无图标显示，不影响勾选与生效。
- (void)_ensureSettingsAppIn:(NSMutableArray *)apps {
    for (NSDictionary *a in apps) {
        if ([[a objectForKey:@"bundleID"] isEqualToString:@"com.apple.Preferences"]) return;
    }
    NSString *path = @"/Applications/Preferences.app";
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
    NSString *bid = info[@"CFBundleIdentifier"];
    if (![bid isKindOfClass:[NSString class]] || !bid.length) bid = @"com.apple.Preferences";
    NSString *name = info[@"CFBundleDisplayName"];
    if (![name isKindOfClass:[NSString class]] || !name.length) name = @"设置";
    [apps addObject:@{@"path": path, @"bundleID": bid, @"name": name}];
}

// [R26 2026-09-20] 四个分桶：用户应用 / 越狱应用 / 巨魔应用 / 系统程序。
// 分类口径（**零私有 API**，全部由「路径 + 文件内容」判出）：
//   · 用户应用：装在用户容器目录 /var/containers/Bundle/Application，且签名不带系统级权限；
//   · 巨魔应用：同一目录（TrollStore 就装这儿），但主可执行文件签名里带 platform-application /
//     com.apple.private.security.no-container。TrollStore 用 ldid 风格签名把 App 伪装成系统应用
//     （这正是它能以 System 类型被 installd 注册、从而「卸载不掉」的原因），容器文件系统里没有任何
//     per-app 标记文件 ⇒ **签名特征是唯一能只看文件判出来的可靠依据**。Apple 系统 App 也带该权限，
//     但它们不在用户容器目录 ⇒ 不会误判。
//   · 越狱应用：<jbroot>/Applications（**运行时探测**的随机越狱根，见文件头 jbroot 探测说明）
//     或 /var/jb/Applications（rootless 兜底），以及 /Applications 里 bid 不以 com.apple. 开头的第三方 App
//     （Apple 自家 App 的 bid 全是 com.apple.*，第三方出现在 /Applications 必然是越狱 / dump 安装）；
//   · 系统程序：/Applications 且 bid 以 com.apple. 开头。
- (NSDictionary *)_installedApps {
    if (!_allApps) {
        if (!_homeScreenSet) _homeScreenSet = [self _homeScreenBundleIDs];

        NSMutableArray *userApps = [NSMutableArray array];
        NSMutableArray *trollApps = [NSMutableArray array];
        NSMutableArray *jailApps = [NSMutableArray array];
        NSMutableArray *systemApps = [NSMutableArray array];

        _statDroppedByHome = 0;
        NSString *jbRootPath = obJbrootPrefix();

        // 1) 用户容器目录：App Store / 侧载 / 巨魔。逐个判是否 TrollStore 安装。
        //    这里是**唯一**保留主屏过滤的根（homeScreenOnly:YES）。
        NSArray *containerApps = [self _scanAppsAtPath:@"/var/containers/Bundle/Application"
                                        homeScreenOnly:YES];
        for (NSDictionary *app in containerApps) {
            if ([self _isTrollStoreApp:app]) [trollApps addObject:app];
            else [userApps addObject:app];
        }
        _statContainer = containerApps.count;

        // 2) 系统根：按「根 + bid 前缀」分类（越狱根一律越狱应用；/Applications 按 com.apple. 前缀取系统程序）。
        //    这些根一律 homeScreenOnly:NO —— 理由见 _addAppAtPath: 里的说明。
        NSMutableSet *seen = [NSMutableSet set];
        _statRootApps = 0;
        _statJbrootApps = 0;
        _statLegacyJbApps = 0;
        for (NSString *base in [self _systemAppPaths]) {
            BOOL jbRoot = ![base isEqualToString:@"/Applications"];
            NSArray *found = [self _scanAppsAtPath:base homeScreenOnly:NO];
            if (!jbRoot) {
                _statRootApps = found.count;
            } else if (jbRootPath.length && [base hasPrefix:jbRootPath]) {
                _statJbrootApps = found.count;
            } else {
                _statLegacyJbApps = found.count;
            }
            for (NSDictionary *app in found) {
                NSString *bid = app[@"bundleID"];
                if ([bid isKindOfClass:[NSString class]] && bid.length) {
                    if ([seen containsObject:bid]) continue;
                    [seen addObject:bid];
                }
                BOOL appleSystem = (!jbRoot && [[bid lowercaseString] hasPrefix:@"com.apple."]);
                [(appleSystem ? systemApps : jailApps) addObject:app];
            }
        }

        [self _ensureSettingsAppIn:systemApps];
        for (NSMutableArray *bucket in @[userApps, trollApps, jailApps, systemApps]) {
            [bucket sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]]];
        }
        _allApps = @{@"user": userApps, @"troll": trollApps, @"jailbreak": jailApps, @"system": systemApps};

        // [applist3] 置底诊断统计行。以后再报「某某 App 看不到」，一眼就能定性丢在哪一步：
        // 根压根没扫到 / 根扫到了但被主屏集合砍了 / 主屏集合就没读到 —— 不用再来一轮猜。
        NSMutableString *st = [NSMutableString string];
        [st appendFormat:@"扫描　用户容器 %lu ｜ /Applications %lu ｜ jbroot %lu",
                           (unsigned long)_statContainer, (unsigned long)_statRootApps,
                           (unsigned long)_statJbrootApps];
        if (_statLegacyJbApps) [st appendFormat:@" ｜ /var/jb %lu", (unsigned long)_statLegacyJbApps];
        [st appendFormat:@"　·　主屏集合 %@ ｜ 被主屏过滤丢弃 %lu",
                           (_homeScreenSet ? [NSString stringWithFormat:@"%lu 条", (unsigned long)_homeScreenSet.count]
                                           : @"未读到(不过滤)"),
                           (unsigned long)_statDroppedByHome];
        [st appendFormat:@"　·　jbroot %@", jbRootPath.length ? jbRootPath : @"未探测到（非 roothide？已退回 /var/jb）"];
        _statLine = [st copy];
    }
    return _allApps;
}

#pragma mark 巨魔（TrollStore）判定

// 判定某个 App 是否为 TrollStore（巨魔）安装。结果按 bid 缓存（一次进页面只探测一次）。
// 签名解析细节见文件作用域里的 obExeHasTrollMarker 系列自由函数。
- (BOOL)_isTrollStoreApp:(NSDictionary *)app {
    NSString *bid = app[@"bundleID"];
    if ([bid isKindOfClass:[NSString class]] && bid.length) {
        NSNumber *cached = _trollCache[bid];
        if (cached) return [cached boolValue];
    }
    BOOL troll = NO;
    @try {
        NSString *path = app[@"path"];
        NSString *exe  = app[@"exe"];
        if (![exe isKindOfClass:[NSString class]] || !exe.length) exe = @"";
        if (exe.length && [path isKindOfClass:[NSString class]] && path.length) {
            troll = obExeHasTrollMarker([path stringByAppendingPathComponent:exe]);
        }
    } @catch (NSException *e) { (void)e; troll = NO; }
    if ([bid isKindOfClass:[NSString class]] && bid.length) {
        if (!_trollCache) _trollCache = [NSMutableDictionary dictionary];
        _trollCache[bid] = @(troll);
    }
    return troll;
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
    if ([self.mode isEqualToString:@"white"])      return @"whitelistApps";
    if ([self.mode isEqualToString:@"leftedge"])   return @"leftEdgeExcludeApps";
    if ([self.mode isEqualToString:@"globalback"]) return @"globalBackApps";
    if ([self.mode isEqualToString:@"navpopfallback"]) return @"navPopFallbackApps";
    if ([self.mode isEqualToString:@"exclusiveexclude"]) return @"exclusivePopExcludeApps";   // [R13]
    return @"blacklistApps";
}

- (NSArray *)_selectedApps {
    // 优先读全局文件（跨 App 真相源），兜底 NSUserDefaults 域
    NSArray *g = oback_globalPrefs()[[self _storeKey]];
    if ([g isKindOfClass:[NSArray class]]) return g;
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

// [P0 2026-09-19] 每次进入本页**重新扫描**。
// 此前 _allApps 是实例级缓存（只在控制器重建时刷新），而 updateSearchResults... 只清 _specifiers、
// 不清 _allApps ⇒ 停留本页期间新装的 App / 新做的改动永远搜不到（必须杀掉设置 App 重开才行）。
// 重扫不额外读图标：图标另有 bid 级缓存 _iconCache。
// ⚠️ super 可以调：只有 willDisplayCell 不能调 super（本环境 PSListController 未实现该方法），
//    viewWillAppear: 是 UIViewController 的标准方法，必然实现。
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _allApps = nil;
    _specifiers = nil;
    [self reloadSpecifiers];
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

    // 显示名称后附 bundle id，便于核对黑名单选中的是否就是 App 实际运行的 bid
    //（避免「列表里看着是拼多多商家版、实际运行 bid 不同」导致黑名单拦不住）。
    NSString *title = [NSString stringWithFormat:@"%@  (%@)", name, bid];

    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:title
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
        if (![n isKindOfClass:[NSString class]] || ![n length]) return;
        // [P0 2026-09-19] CFBundleIconFile 的值常**自带 .png 扩展名**（如 "Icon.png"），
        // 而下面的加载端还会再补 ""/".png"、并生成 @2x/@3x 变体 ⇒ 必须先剥掉扩展名，
        // 否则会拼出 "Icon.png.png" / "Icon.png@2x" 这类永远读不到的路径。
        NSString *base = n;
        if ([[base lowercaseString] hasSuffix:@".png"]) base = [base substringToIndex:base.length - 4];
        if (!base.length) return;
        [candidates addObject:base];
        [candidates addObject:[NSString stringWithFormat:@"%@@2x", base]];
        [candidates addObject:[NSString stringWithFormat:@"%@@3x", base]];
    };

    // 现代：CFBundleIconName
    addName(info[@"CFBundleIconName"]);
    // [P0 2026-09-19] 老式**单数字段** CFBundleIconFile：老 deb / 老 SDK 产物最常见的写法，
    // 此前完全没被读取 ⇒ 即使图就散放在 .app 里也配不出来。
    addName(info[@"CFBundleIconFile"]);
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

// 把图标缩放到合适的行内尺寸（与系统「设置」App 列表图标同尺寸 29pt）。
// ⚠️ 单位陷阱：UIGraphicsImageRenderer 的 initWithSize: 收的是【点(pt)】，会按设备 scale 自动出视网膜图；
// 之前误把 target 写成 pt*scale(像素) 且用像素去和 img.size(点) 比较，导致比较阈值变成 87pt、
// 目标尺寸也变成 87pt —— 大图标几乎都"<=阈值"被原样返回、即便缩放也是缩到 87pt，所以图标显得很大。
// 修正：阈值与目标统一用 29pt(点)，渲染器自行处理 scale。
- (UIImage *)_scaledIcon:(UIImage *)img {
    if (!img) return nil;
    CGFloat pt = 29.0; // 与系统「设置」App 列表图标同尺寸
    if (img.size.width <= pt && img.size.height <= pt) return img;
    CGSize target = CGSizeMake(pt, pt); // 点；渲染器按设备 scale 出图
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:target];
    return [r imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
        [img drawInRect:CGRectMake(0, 0, target.width, target.height)];
    }];
}

// 点按切换：加入 / 移出当前名单（whitelistApps / blacklistApps）
- (void)_toggleApp:(PSSpecifier *)spec {
    NSString *bid = [spec propertyForKey:@"appBundleID"];
    if (!bid) return;
    // [P0 2026-09-19] 读源改为 _selectedApps（**全局文件优先**、suite 仅兜底），不再直接读 NSUserDefaults。
    // 原写法在 roothide 下若 suite 副本为空、而全局文件里已有名单，就会把「空数组 + 本次 bid」
    // 整份写回全局文件 ⇒ 静默清空用户此前选的全部条目（同类坑见 ObackPreferences.m 顶部注释）。
    NSMutableArray *arr = [[self _selectedApps] mutableCopy] ?: [NSMutableArray array];
    if ([arr containsObject:bid]) [arr removeObject:bid];
    else [arr addObject:bid];
    [self _writeList:arr];
    _specifiers = nil;   // 清空以触发重建，使「选中项置顶」排序生效
    [self reloadSpecifiers];
}

#pragma mark 手动添加 bundle id（扫描/过滤拿不到时的兜底入口）

// [P0 2026-09-19] 顶部那一行「＋ 手动输入 bundle id 添加」。
// ⚠️ 刻意用 PSTitleValueCell 而不是 PSButtonCell：本仓库 theos/headers 未声明 setAction:，
//    按钮行在 -Werror 下编译不过；且本文件所有行本来就统一走 didSelectRow 这一条已验证路径。
- (PSSpecifier *)_manualAddSpecifier {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:@"＋ 手动输入 bundle id 添加"
                                                  target:self
                                                     set:nil
                                                     get:nil
                                                 detail:nil
                                                     cell:PSTitleValueCell
                                                     edit:nil];
    [s setProperty:@(YES) forKey:@"obManualAdd"];
    return s;
}

// 写名单：suite + 全局文件**双写**（roothide 下跨 App 真相源是全局文件，suite 仅兜底）。
- (void)_writeList:(NSArray *)arr {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    [d setObject:(arr ?: @[]) forKey:[self _storeKey]];
    [d synchronize];
    oback_setGlobalPref([self _storeKey], (arr ?: @[]));
}

- (void)_addBidToStore:(NSString *)bid {
    NSMutableArray *arr = [[self _selectedApps] mutableCopy] ?: [NSMutableArray array];
    if (![arr containsObject:bid]) [arr addObject:bid];
    [self _writeList:arr];
}

- (void)_alertInvalidBid:(NSString *)bid {
    NSString *msg = bid.length
        ? [NSString stringWithFormat:@"「%@」不像 bundle id。只能含字母、数字、点(.)、连字符(-)，例如 com.example.app。", bid]
        : @"没有输入内容。bundle id 形如 com.example.app —— 可在 Filza 打开该 App 的 Info.plist 看 CFBundleIdentifier。";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"格式不对"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

// [P0] 手动添加：UIAlertController 文本框（标准 UIKit，必定可用；与 _editNoteForBid: 同款，
// 刻意不用 PSTextFieldCell —— 本环境 PreferenceLoader 的文本框 cell 存在填不进去的问题）。
// 校验字符集：bundle id 只允许 [A-Za-z0-9.-]；挡掉中文/空格/换行等手滑输入（写进去也永不命中）。
- (void)_promptManualAddBid {
    NSString *key = [self _storeKey];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"手动添加 bundle id"
                                                               message:[NSString stringWithFormat:@"填 App 的 bundle id（如 com.example.app），确定后写入「%@」。\n可在 Filza 打开该 App 的 Info.plist 查看 CFBundleIdentifier。", key]
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"com.example.app";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.keyboardType = UIKeyboardTypeASCIICapable;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        UITextField *tf = [[a textFields] firstObject];
        NSString *bid = nil;
        if (tf) bid = [tf.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSCharacterSet *okSet = [NSCharacterSet characterSetWithCharactersInString:
                                 @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"];
        BOOL bad = (!bid.length || [bid rangeOfCharacterFromSet:[okSet invertedSet]].location != NSNotFound);
        if (bad) { [self _alertInvalidBid:bid]; return; }
        [self _addBidToStore:bid];
        _allApps = nil;   // 让新加的 bid 在「已选」分组里以 name=bid 形式立即可见
        _specifiers = nil;
        [self reloadSpecifiers];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        @try {
            NSMutableArray *specs = [NSMutableArray array];

            // 顶部：已选数量（下方即「已选应用」独立成列）
            NSUInteger cnt = [[self _selectedApps] count];
            [self _addGroupHeader:[NSString stringWithFormat:@"已选 %lu 个应用", (unsigned long)cnt]
                           footer:(cnt ? @"（以下为已加入本名单的应用，与下方列表分开）" : @"（尚未选择任何应用）") toSpecifiers:specs];

            // [P0 2026-09-19] 手动添加入口：扫描根之外 / 被过滤 / Info.plist 不规范的 App
            // （典型：deb 装到 /var/jb/Applications、只进 App 资源库、老 SDK 无图标键）一律可手填 bid 入名单。
            // 位置固定在顶部且**不受搜索影响**——「搜不到」正是它要被用到的场景，
            // 若跟着搜索一起被过滤掉，用户搜索无结果时就永远看不到它了。
            [specs addObject:[self _manualAddSpecifier]];

            NSDictionary *apps = [self _installedApps];
            // [R26] 四个分桶（顺序即下方分组显示顺序）
            NSArray *userApps   = [self _filteredApps:apps[@"user"]];
            NSArray *jailApps   = [self _filteredApps:apps[@"jailbreak"]];
            NSArray *trollApps  = [self _filteredApps:apps[@"troll"]];
            NSArray *systemApps = [self _filteredApps:apps[@"system"]];
            NSSet *sel = [NSSet setWithArray:[self _selectedApps]];

            // 选中项【单独成列】：各分类的已选项合并、按名称排序，列在顶部「已选 N 个应用」之下，
            // 不再混入下面各分类原列表（之前是在原列表内置顶，不符合预期）。
            NSMutableArray *selApps = [NSMutableArray array];
            NSMutableArray *unselUser = [NSMutableArray array];
            NSMutableArray *unselJail = [NSMutableArray array];
            NSMutableArray *unselTroll = [NSMutableArray array];
            NSMutableArray *unselSystem = [NSMutableArray array];
            // [R26] 四桶统一走一遍：命中名单的进「已选」，其余进各自未选组。
            NSArray<NSArray *> *buckets = @[userApps, jailApps, trollApps, systemApps];
            NSArray<NSMutableArray *> *sinks = @[unselUser, unselJail, unselTroll, unselSystem];
            for (NSUInteger bi = 0; bi < buckets.count; bi++) {
                for (NSDictionary *app in buckets[bi]) {
                    if ([sel containsObject:app[@"bundleID"]]) [selApps addObject:app];
                    else [sinks[bi] addObject:app];
                }
            }
            // [P0 2026-09-19] 已选、但**不在扫描结果里**的 bid 也必须显示出来。
            // 反例（用户实测 + 手动改 plist 场景）：名单里有它、顶部计数也 +1，但列表里既看不到、
            // 也无法取消 ⇒ 名单堆着一批「隐形条目」，只能靠 Filza 改 plist 才能清掉。
            // 这里把它们补成 name=bid 的条目并入「已选」分组，点按即可移除。
            NSMutableSet *scannedBIDs = [NSMutableSet set];
            for (NSArray *bucket in buckets) {
                for (NSDictionary *app in bucket) {
                    NSString *b = app[@"bundleID"];
                    if ([b isKindOfClass:[NSString class]] && b.length) [scannedBIDs addObject:b];
                }
            }
            for (NSString *selBID in sel) {
                if (![selBID isKindOfClass:[NSString class]] || !selBID.length) continue;
                if ([scannedBIDs containsObject:selBID]) continue;
                [selApps addObject:@{@"path": @"", @"bundleID": selBID, @"name": selBID}];
            }
            [selApps sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]]];
            if (selApps.count) {
                for (NSDictionary *app in selApps) [self _addAppSpecifier:app toSpecifiers:specs];
            }

            // [R26] 未选中项按四类分列：用户应用 -> 越狱应用 -> 巨魔应用 -> 系统程序（空组不显示）
            if (unselUser.count) {
                [self _addGroupHeader:@"用户应用" footer:@"App Store / 侧载安装"
                         toSpecifiers:specs];
                for (NSDictionary *app in unselUser) [self _addAppSpecifier:app toSpecifiers:specs];
            }
            if (unselJail.count) {
                [self _addGroupHeader:@"越狱应用" footer:@"装在 jbroot（<jbroot>/Applications，随机路径），或 /Applications 里的第三方 App"
                         toSpecifiers:specs];
                for (NSDictionary *app in unselJail) [self _addAppSpecifier:app toSpecifiers:specs];
            }
            if (unselTroll.count) {
                [self _addGroupHeader:@"巨魔应用" footer:@"TrollStore 安装（签名伪装成系统应用）"
                         toSpecifiers:specs];
                for (NSDictionary *app in unselTroll) [self _addAppSpecifier:app toSpecifiers:specs];
            }
            if (unselSystem.count) {
                [self _addGroupHeader:@"系统程序" footer:@"" toSpecifiers:specs];
                for (NSDictionary *app in unselSystem) [self _addAppSpecifier:app toSpecifiers:specs];
            }

            // 搜索无结果时给个提示分组
            if (!userApps.count && !jailApps.count && !trollApps.count && !systemApps.count) {
                [self _addGroupHeader:@"" footer:@"未找到匹配的应用" toSpecifiers:specs];
            }

            // [applist3] 常驻诊断统计行：永久置底、不受搜索影响（搜不到时最需要它）
            if (_statLine.length) {
                [self _addGroupHeader:@"" footer:_statLine toSpecifiers:specs];
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
    // [P0 2026-09-19] 顶部「手动输入 bundle id」行：走同一套 didSelectRow 机制
    //（不用 PSButtonCell + setAction:：本仓库 theos/headers 未声明 setAction:，-Werror 下编译不过）。
    if ([[spec propertyForKey:@"obManualAdd"] boolValue]) {
        [self _promptManualAddBid];
        return;
    }
    NSString *bid = [spec propertyForKey:@"appBundleID"];
    if (bid.length) {
        [self _toggleApp:spec];
    } else if ([super respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
        // PSListController 未实现该方法时跳过，避免踩与 willDisplayCell 相同的 unrecognized selector 坑。
        [super tableView:tableView didSelectRowAtIndexPath:indexPath];
    }
}

@end

#pragma mark - 胶囊特效选择器（替代 PSMultiValueCell）

// 边缘指示胶囊的视觉风格选择器。
// ⚠️ 为何不用 PSMultiValueCell：本环境（roothide / iOS 16.4.1 / 当前 PreferenceLoader）下
// PSMultiValueCell 点击后 push 不出子列表、点了没反应；改用自定义 PSListController + 勾选，
// 与黑白名单（ObackAppListController）同一套已验证稳定的写法。
// 通过 oback_setGlobalPref 写全局文件（跨 App 真相源），tweak 侧 ObackPreferences.capsuleEffect 即可读到。
@interface ObackCapsuleEffectController : PSListController
@end

@implementation ObackCapsuleEffectController {
    NSArray *_titles;
    NSArray *_values;
}

- (NSInteger)_currentEffect {
    // 优先读跨 App 全局文件（真相源），兜底 NSUserDefaults 域；未设置 → 默认 0（经典）
    id v = oback_globalPrefs()[@"capsuleEffect"];
    if (v) return [v integerValue];
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.zlhkf.oback"];
    return [d integerForKey:@"capsuleEffect"];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _titles = @[@"经典", @"发光", @"霓虹", @"流光渐变", @"毛玻璃", @"呼吸", @"液态液滴"];
        _values = @[@0, @1, @2, @3, @4, @5, @6];
        NSMutableArray *specs = [NSMutableArray array];

        PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"胶囊风格"
                                                            target:self
                                                               set:nil
                                                               get:nil
                                                          detail:nil
                                                               cell:PSGroupCell
                                                               edit:nil];
        [group setProperty:@"选择边缘指示的视觉风格，修改后下一次边缘手势即生效。\n「液态液滴」为 ColorOS 观感：一枚深色细长柳叶形贴在屏幕边缘，随手指从边缘「长」出来 —— 贴边侧平整压在屏幕边线上，外侧向屏内鼓起成饱满叶形，上下两端收成尖，松手即收回。"
                  forKey:@"footerText"];
        [specs addObject:group];

        for (NSUInteger i = 0; i < _titles.count; i++) {
            PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:_titles[i]
                                                          target:self
                                                             set:nil
                                                             get:nil
                                                        detail:nil
                                                             cell:PSTitleValueCell
                                                             edit:nil];
            [s setProperty:_values[i] forKey:@"effectValue"];
            [specs addObject:s];
        }
        _specifiers = specs;
    }
    return _specifiers;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    // ⚠️ 不调 super：本环境 PSListController 未实现该方法，super 调用会 unrecognized selector 闪退。
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    NSNumber *v = [spec propertyForKey:@"effectValue"];
    if (v) {
        cell.accessoryType = ([v integerValue] == [self _currentEffect])
            ? UITableViewCellAccessoryCheckmark
            : UITableViewCellAccessoryNone;
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    NSNumber *v = [spec propertyForKey:@"effectValue"];
    if (v) {
        // 写跨 App 全局文件（真相源）+ suite 兜底，tweak 注入其它 App 即能读到
        oback_setGlobalPref(@"capsuleEffect", v);
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.zlhkf.oback"];
        [d setObject:v forKey:@"capsuleEffect"];
        [d synchronize];
        _specifiers = nil;   // 触发重建，刷新勾选
        [self reloadSpecifiers];
    } else if ([super respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
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

@implementation ObackLeftExcludeListController
- (id)init {
    if (self = [super init]) {
        self.mode = @"leftedge";
    }
    return self;
}
@end

@implementation ObackGlobalBackListController
- (id)init {
    if (self = [super init]) {
        self.mode = @"globalback";
    }
    return self;
}
@end

@implementation ObackNavPopFallbackController
- (id)init {
    if (self = [super init]) {
        self.mode = @"navpopfallback";
    }
    return self;
}
@end

@implementation ObackExclusiveExcludeListController
- (id)init {
    if (self = [super init]) {
        self.mode = @"exclusiveexclude";
    }
    return self;
}
@end

#pragma mark - 左缘·按页排除：VC 类名点选列表（方案A，取代单行文本框）

// 取代原来的单行 PSTextFieldCell：tweak 侧（ObackManager 的 OBRecordVCChain）把左缘遇到的
// VC 类名写入 /var/mobile/oback_vc_seen.plist；本页列出「检测到的页面」，点按即加入/移出排除，
// 用户不必开调试日志、不必 Filza 手抄类名，类名多了也能搜索。
// 沿用 ObackAppListController 已验证稳定的写法：系统原生 PSTitleValueCell + didSelectRow 切换
// + willDisplayCell 画勾选 + 搜索；⚠️ 绝不自定义 cell 类。
// 写入走 oback_setGlobalPref（跨 App 真相源）+ suite 兜底，确保 tweak 注入其它 App 读得到。

static NSString *const kOBVCSeeNFile = @"/var/mobile/oback_vc_seen.plist";

// 与 ObackPreferences.isLeftEdgeExcludedVC: 的分隔规则保持一致（逗号/换行 + 去首尾空白）
static NSArray *_obParseVCNames(id raw) {
    if ([raw isKindOfClass:[NSArray class]]) {
        NSMutableArray *o = [NSMutableArray array];
        for (id e in (NSArray *)raw) {
            if ([e isKindOfClass:[NSString class]] && [e length]) [o addObject:e];
        }
        return o;
    }
    if (![raw isKindOfClass:[NSString class]] || ![raw length]) return @[];
    NSArray *parts = [raw componentsSeparatedByCharactersInSet:
                      [NSCharacterSet characterSetWithCharactersInString:@",\n"]];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *s in parts) {
        NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length) [out addObject:t];
    }
    return out;
}

@interface ObackVCExcludeListController : PSListController <UISearchResultsUpdating>
@end

@implementation ObackVCExcludeListController {
    NSArray *_excluded;    // 已排除的类名（逗号串解析结果）
    NSArray *_seen;        // tweak 记录到的条目 @{vc,bid,c}（倒序，最近遇到的在前）
    NSString *_searchText;
}

- (NSArray *)_excludedNames {
    id v = oback_globalPrefs()[@"leftEdgeExcludedVCs"];
    if (!v) {
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
        v = [d objectForKey:@"leftEdgeExcludedVCs"];
    }
    return _obParseVCNames(v);
}

// 读取 tweak 记录：新格式为 @{vc,bid,c} 字典；兼容旧版纯字符串条目（无 App 归属/无冲突标记）。
- (NSArray *)_seenEntries {
    NSArray *a = [NSArray arrayWithContentsOfFile:kOBVCSeeNFile];
    if (![a isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id e in a) {
        if ([e isKindOfClass:[NSDictionary class]]) {
            NSString *v = [(NSDictionary *)e objectForKey:@"vc"];
            if ([v isKindOfClass:[NSString class]] && [v length]) { [out addObject:e]; continue; }
        } else if ([e isKindOfClass:[NSString class]] && [e length]) {
            [out addObject:@{@"vc": e, @"bid": @"", @"c": @NO}];
        }
    }
    return [[out reverseObjectEnumerator] allObjects];
}

#pragma mark bid 备注（用户自定义别名，替代全量 App 扫描 —— 零开销）

// 备注存在 vcBidNotes（bid → 备注）。不再扫描 /var/containers/Bundle/Application 下所有 .app 的
// Info.plist（那要读上百个文件、首次进页面会卡顿），可读性改由用户自己的备注保证。
- (NSDictionary *)_notes {
    id v = oback_globalPrefs()[@"vcBidNotes"];
    if (!v) {
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
        v = [d objectForKey:@"vcBidNotes"];
    }
    return [v isKindOfClass:[NSDictionary class]] ? v : @{};
}

- (void)_saveNotes:(NSDictionary *)n {
    oback_setGlobalPref(@"vcBidNotes", n);
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    [d setObject:n forKey:@"vcBidNotes"];
    [d synchronize];
}

// 分组标题：有备注显示备注，否则回退显示 bid
- (NSString *)_displayNameForBid:(NSString *)bid {
    if (![bid isKindOfClass:[NSString class]] || !bid.length) return @"未知来源";
    NSString *note = [[self _notes] objectForKey:bid];
    return ([note isKindOfClass:[NSString class]] && note.length) ? note : bid;
}

// 备注编辑：用 UIAlertController 的文本框（标准 UIKit，必定可用）——
// 不用 PSTextFieldCell：本环境 PreferenceLoader 的文本框 cell 存在填不进去的问题。
- (void)_editNoteForBid:(NSString *)bid {
    NSString *cur = [[self _notes] objectForKey:bid];
    if (![cur isKindOfClass:[NSString class]]) cur = @"";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"备注"
                                                               message:[NSString stringWithFormat:@"给 %@ 起个好认的名字，显示在分组标题上。", bid]
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = cur;
        tf.placeholder = @"例如：拼多多商家版";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        NSMutableDictionary *n = [[self _notes] mutableCopy];
        [n removeObjectForKey:bid];
        [self _saveNotes:n];
        _specifiers = nil;
        [self reloadSpecifiers];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        NSString *t = @"";
        UITextField *tf = [[a textFields] firstObject];
        if (tf) {
            t = [tf.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!t) t = @"";
        }
        NSMutableDictionary *n = [[self _notes] mutableCopy];
        if (t.length) [n setObject:t forKey:bid]; else [n removeObjectForKey:bid];
        [self _saveNotes:n];
        _specifiers = nil;
        [self reloadSpecifiers];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (PSSpecifier *)_noteSpec:(NSString *)bid {
    NSString *note = [[self _notes] objectForKey:bid];
    BOOL has = ([note isKindOfClass:[NSString class]] && note.length);
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:(has ? [NSString stringWithFormat:@"备注：%@", note] : @"＋ 添加备注")
                                                  target:self
                                                     set:nil
                                                     get:nil
                                                  detail:nil
                                                     cell:PSTitleValueCell
                                                     edit:nil];
    [s setProperty:bid forKey:@"vcBidNote"];
    return s;
}

- (void)_saveExcluded:(NSArray *)names {
    NSString *joined = [names componentsJoinedByString:@","];
    oback_setGlobalPref(@"leftEdgeExcludedVCs", joined);
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    [d setObject:joined forKey:@"leftEdgeExcludedVCs"];
    [d synchronize];
}

#pragma mark 搜索

- (void)viewDidLoad {
    [super viewDidLoad];
    UISearchController *sc = [[UISearchController alloc] initWithSearchResultsController:nil];
    sc.searchResultsUpdater = self;
    sc.obscuresBackgroundDuringPresentation = NO;
    sc.searchBar.placeholder = @"搜索类名";
    self.navigationItem.searchController = sc;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    NSString *t = [sc.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] ?: @"";
    _searchText = t.length ? t : nil;
    _specifiers = nil;
    [self reloadSpecifiers];
}

#pragma mark 列表构建

// 单行：VC 类名；冲突行加 ⚠️ 并在 willDisplayCell 里标红
- (PSSpecifier *)_entrySpec:(NSDictionary *)e {
    NSString *vc = [e objectForKey:@"vc"];
    if (![vc isKindOfClass:[NSString class]] || !vc.length) vc = @"";
    BOOL conflict = [[e objectForKey:@"c"] boolValue];
    NSString *title = conflict ? [vc stringByAppendingString:@"   ⚠️"] : vc;
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:title
                                                  target:self
                                                     set:nil
                                                     get:nil
                                                  detail:nil
                                                     cell:PSTitleValueCell
                                                     edit:nil];
    [s setProperty:vc forKey:@"vcName"];
    [s setProperty:@(conflict) forKey:@"vcConflict"];
    return s;
}

- (PSSpecifier *)_groupSpec:(NSString *)title footer:(NSString *)footer {
    // ⚠️ 组标题必须用 specifier 的 name（第一个参数），设 label 会导致标题整片空白（与 App 选择器同坑）。
    PSSpecifier *g = [PSSpecifier preferenceSpecifierNamed:(title ?: @"")
                                                  target:self
                                                     set:nil
                                                     get:nil
                                                  detail:nil
                                                     cell:PSGroupCell
                                                     edit:nil];
    if (footer.length) [g setProperty:footer forKey:@"footerText"];
    return g;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        @try {
            _excluded = [self _excludedNames];
            _seen = [self _seenEntries];

            NSUInteger conflictCnt = 0;
            for (NSDictionary *e in _seen) if ([[e objectForKey:@"c"] boolValue]) conflictCnt++;

            NSMutableArray *specs = [NSMutableArray array];
            [specs addObject:[self _groupSpec:@"按页排除（按 App 分组）"
                                       footer:[NSString stringWithFormat:
                @"在目标页面从屏幕左缘滑一下，其 VC 类名会记录到对应 App 分组下。共 %lu 条记录，"
                @"其中 %lu 条标红 ⚠️ = 该页左缘被页面自身占用（横向滚动 / 轮播 / 侧栏），"
                @"会导致左缘异常，优先排除这些。点按即加入/移出排除（子串匹配、大小写不敏感）。",
                (unsigned long)_seen.count, (unsigned long)conflictCnt]]];

            // 按 bid 分组（组顺序保持「最近遇到」的先后）
            NSMutableDictionary *byBid = [NSMutableDictionary dictionary];
            NSMutableArray *bidOrder = [NSMutableArray array];
            for (NSDictionary *e in _seen) {
                NSString *bid = [e objectForKey:@"bid"];
                if (![bid isKindOfClass:[NSString class]]) bid = @"";
                NSMutableArray *arr = [byBid objectForKey:bid];
                if (!arr) {
                    arr = [NSMutableArray array];
                    [byBid setObject:arr forKey:bid];
                    [bidOrder addObject:bid];
                }
                [arr addObject:e];
            }

            BOOL anyRow = NO;
            NSString *q = [_searchText lowercaseString];
            for (NSString *bid in bidOrder) {
                NSMutableArray *f = [NSMutableArray array];
                NSUInteger cCnt = 0;
                for (NSDictionary *e in [byBid objectForKey:bid]) {
                    NSString *v = [e objectForKey:@"vc"];
                    if (![v isKindOfClass:[NSString class]] || !v.length) continue;
                    if (q.length && [[v lowercaseString] rangeOfString:q].location == NSNotFound) continue;
                    [f addObject:e];
                    if ([[e objectForKey:@"c"] boolValue]) cCnt++;
                }
                if (!f.count) continue;
                anyRow = YES;
                NSString *title = [NSString stringWithFormat:@"%@  (%lu%@)",
                                   [self _displayNameForBid:bid],
                                   (unsigned long)f.count,
                                   (cCnt ? [NSString stringWithFormat:@"，%lu 个冲突", (unsigned long)cCnt] : @"")];
                [specs addObject:[self _groupSpec:title footer:@""]];
                [specs addObject:[self _noteSpec:bid]];   // 备注行：点按可给该 App 起别名
                for (NSDictionary *e in f) [specs addObject:[self _entrySpec:e]];
            }

            if (!anyRow) {
                [specs addObject:[self _groupSpec:@""
                                           footer:(_seen.count ? @"（无匹配结果）"
                                                               : @"（暂无记录：去目标页面从屏幕左缘滑一下即可）")]];
            }
            _specifiers = specs;
        } @catch (NSException *e) {
            (void)e;
            _specifiers = [NSMutableArray array];
        }
    }
    return _specifiers;
}

#pragma mark 勾选 / 冲突标红 / 点按

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    // ⚠️ 不调 super：本环境 PSListController 未实现该方法，super 调用会 unrecognized selector 闪退（崩溃日志实测）。
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    // 备注行（App 别名）：不打勾，次要色
    if ([spec propertyForKey:@"vcBidNote"]) {
        cell.accessoryType = UITableViewCellAccessoryNone;
        if (@available(iOS 13.0, *)) {
            cell.textLabel.textColor = [UIColor secondaryLabelColor];
        } else {
            cell.textLabel.textColor = [UIColor grayColor];
        }
        return;
    }
    NSString *name = [spec propertyForKey:@"vcName"];
    if (name.length) {
        cell.accessoryType = [[self _excludedNames] containsObject:name]
            ? UITableViewCellAccessoryCheckmark
            : UITableViewCellAccessoryNone;
        // 冲突 = 该页左缘被页面自身占用（会导致左缘异常）→ 标红
        if ([[spec propertyForKey:@"vcConflict"] boolValue]) {
            cell.textLabel.textColor = [UIColor systemRedColor];
        } else {
            // cell 复用，非冲突行必须显式恢复默认色，否则滚动后会串色
            if (@available(iOS 13.0, *)) {
                cell.textLabel.textColor = [UIColor labelColor];
            } else {
                cell.textLabel.textColor = [UIColor blackColor];
            }
        }
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    // 备注行 → 弹输入框编辑 App 别名
    NSString *bid = [spec propertyForKey:@"vcBidNote"];
    if (bid) {
        [self _editNoteForBid:bid];
        return;
    }
    NSString *name = [spec propertyForKey:@"vcName"];
    if (name.length) {
        NSMutableArray *arr = [[self _excludedNames] mutableCopy];
        if ([arr containsObject:name]) [arr removeObject:name];
        else [arr addObject:name];
        [self _saveExcluded:arr];
        _specifiers = nil;   // 触发重建：勾选随之刷新
        [self reloadSpecifiers];
    } else if ([super respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
        [super tableView:tableView didSelectRowAtIndexPath:indexPath];
    }
}

@end

