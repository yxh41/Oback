//
//  ObackSettingsController.m
//  Oback 设置页主控制器 —— 由 Root.plist 描述所有开关/滑块/文本框，
//  域统一为 com.zlhkf.oback（与 ObackPreferences.m 的 initWithSuiteName 一致）。
//
//  滑块样式（仿截图）：每行右侧显示当前数值+单位（小字、靠上），
//  用户拖动滑块时即时跟手更新。
//

#import "ObackSettingsController.h"
#import <UIKit/UIKit.h>
#import <Preferences/PSSpecifier.h>
#import <objc/runtime.h>
#import "ObackPrefsBridge.h"   // 重置时同步清空全局 plist（绕过 roothide per-app NSUserDefaults 容器化）

// ⚠️ roothide 的 PSListController.h 未公开声明 setPreferenceValue:forSpecifier:，
// 但 PreferenceLoader 运行时确实实现该方法；补前向声明让 [super setPreferenceValue:...]
// 通过 -Werror 编译。否则 25c47cf 会因 "no visible @interface declares the selector" 编译失败、不出 .deb。
@interface PSListController (ObackSetPrefForward)
- (void)setPreferenceValue:(id)value forSpecifier:(PSSpecifier *)specifier;
@end

// PSSpecifier 头未声明 setProperty:forKey:，补声明以直接调用（避免 performSelector 泄漏警告 -Werror 编译失败）
@interface PSSpecifier (ObackSetProp)
- (void)setProperty:(id)property forKey:(NSString *)key;
@end

// PSListController 头未声明 reloadSpecifier:/cellForSpecifier:/indexPathForSpecifier:，补前向声明让刷新按钮标题在 -Werror 下编译通过
@interface PSListController (ObackCellRefresh)
- (void)reloadSpecifier:(PSSpecifier *)specifier;
- (UITableViewCell *)cellForSpecifier:(PSSpecifier *)specifier;
- (NSIndexPath *)indexPathForSpecifier:(PSSpecifier *)specifier;
@end

// [2026-08-23 精简] 原「弹窗返回增强设置」折叠机制已随面板精简整体移除：
// 阴影三滑块(shadowOffset/Radius/Opacity)、弹窗圆角(cardCornerEnabled/Value)、
// 弹性收尾(springEnabled)、返回灵敏度(commitRatio/commitVelocity)已从 Root.plist 删除
// （值仍由 ObackParams defaults 提供，行为与旧默认完全一致），故不再需要按开关显隐。
@interface ObackSettingsController ()
@end

// ── 每个滑块 key 对应的单位后缀 ──────────────────────────────
static NSDictionary *_obSliderUnits(void) {
    static NSDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = @{
            @"triggerWidth":    @" pt",
            @"duration":        @" s",
        };
    });
    return d;
}

@implementation ObackSettingsController {
    NSMutableDictionary<NSString *, UILabel *> *_valueLabels; // key → 右侧数值标签
}

#pragma mark - 跨 App 写入桥（roothide 容器隔离修复，与黑名单 adcaf5f 同思路）

// roothide 下 PreferenceLoader 的标准 cell 写入经 NSUserDefaults(suiteName:) 会落到「设置」App 自身容器副本，
// 而 tweak 注入其它 App 时读的是全局文件（见 ObackPreferences._mergedPrefs 优先读全局文件）。
// 故每个标准开关/滑块的变更都额外镜像写一份到全局文件，确保「设置」与「tweak」命中同一物理文件。
// 否则如「调试日志」开关会看似能拨动、tweak 却永远读不到（恒为默认 NO → 不写日志）。
- (void)setPreferenceValue:(id)value forSpecifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value forSpecifier:specifier];
    NSString *key = [specifier propertyForKey:@"key"];
    if (key) oback_setGlobalPref(key, value);
}

// [2026-08-23 精简] 面板已删除的废弃 key：这些项曾可调，旧用户的全局 plist / suite 里可能残留
// 自定义值，而 tweak 侧 ObackPreferences 仍会读取它们（例如残留 commitRatio=0.15 会继续覆盖默认 0.30）。
// 面板里已没有控件可改回去 → 必须在打开设置页时主动清除，让行为回落到 ObackParams defaults。
static NSArray *_obRetiredKeys(void) {
    static NSArray *a = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[@"sheetEnhanceEnabled",   // 折叠元开关（机制已移除）
              @"shadowOffset", @"shadowRadius", @"shadowOpacity",   // 阴影细节参数（固定为默认）
              @"cardCornerEnabled", @"cardCornerValue",             // 弹窗圆角（与阴影互斥的装饰）
              @"springEnabled",                                      // 弹性收尾（与 duration 耦合）
              @"commitRatio", @"commitVelocity",                     // 灵敏度（方案A 不消费 + QQ/TIM 被 MAX 夹死）
              @"doubleReturnDiag", @"diagBanner"];                   // 历史诊断开关
    });
    return a;
}

// 清理废弃 key（全局文件 + suite 两侧）。全局文件一次性读-改-写（避免逐 key 调 oback_setGlobalPref
// 触发多次全量写盘）；无残留时完全不写，进设置页零额外 IO。
- (void)_obPurgeRetiredKeys {
    NSArray *retired = _obRetiredKeys();
    NSMutableDictionary *g = [NSMutableDictionary dictionaryWithContentsOfFile:kOBGlobalPlist];
    BOOL gDirty = NO;
    if (g) {
        for (NSString *k in retired) {
            if ([g objectForKey:k]) { [g removeObjectForKey:k]; gDirty = YES; }
        }
        if (gDirty) [g writeToFile:kOBGlobalPlist atomically:YES];
    }
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.zlhkf.oback"];
    BOOL sDirty = NO;
    for (NSString *k in retired) {
        if ([d objectForKey:k]) { [d removeObjectForKey:k]; sDirty = YES; }
    }
    if (sDirty) [d synchronize];
}

// 兜底镜像：每次打开设置页，把各开关/滑块的当前值从「设置」App 自身容器(suite)同步到
// 跨 App 共享全局文件。roothide 下标准 cell 的写入经 NSUserDefaults(suiteName:) 落「设置」App
// 容器副本，tweak 注入其它 App 读的是全局文件（ObackPreferences._mergedPrefs 优先全局）；
// 若 PreferenceLoader 不回调 setPreferenceValue:（部分 roothide 版本），仅靠本兜底即可让
// 「设置」与「tweak」命中同一物理文件，避免「开关拨了但 tweak 读不到（恒为默认 NO → 不写日志）」。
// 配合 setPreferenceValue: 的实时镜像，覆盖「回调被调用」与「不被调用」两种情形。
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!_specifiers) [self specifiers];
    [self _obPurgeRetiredKeys];   // [2026-08-23] 先清废弃 key，再做镜像，避免把残留值又同步回全局文件
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.zlhkf.oback"];   // ARC bundle：不用 autorelease（会编译失败）
    for (PSSpecifier *spec in _specifiers) {
        NSString *key = [spec propertyForKey:@"key"];
        if (!key) continue;
        id val = [d objectForKey:key];
        if (val) oback_setGlobalPref(key, val);   // 仅镜像有显式值的 key；nil 跳过，避免清掉未设置项的默认
    }
    // [P9] 同步「调试日志」按钮标题（开关改为直写，标题反映文件真实状态）
    BOOL _dl = NO;
    NSDictionary *_dg = [NSDictionary dictionaryWithContentsOfFile:kOBGlobalPlist];
    if (_dg) { id _dv = [_dg objectForKey:@"debugLog"]; if (_dv) _dl = [_dv boolValue]; }
    for (PSSpecifier *spec in _specifiers) {
        if ([[spec propertyForKey:@"action"] isEqualToString:@"toggleDebugLog"]) {
            [spec setProperty:(_dl ? @"调试日志：开" : @"调试日志：关") forKey:@"label"];
            break;
        }
    }
}

// [2026-08-23 精简] 面板已删除全部「调了看不出/被夹死」的方案B 参数，无需再按开关过滤，
// 直接返回 Root.plist 的完整列表。
- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

#pragma mark - PSSliderCell delegate（端点文字）

// 端点值保持简洁：>=1 整数，<1 两位小数
- (NSString *)slider:(id)slider titleForMinimumValue:(float)value {
    return [self _obFormatValue:value];
}
- (NSString *)slider:(id)slider titleForMaximumValue:(float)value {
    return [self _obFormatValue:value];
}

// 当前值也格式化一下（PSSliderCell 自身也可能显示）
- (NSString *)slider:(id)slider titleForCurrentValue:(float)value {
    return [self _obFormatValue:value];
}

#pragma mark - 右侧实时数值标签 + UISlider 监听

/*  布局示意：
 *
 *  ┌──────────────────────────────────────────┐
 *  │ 触发宽度 (pt)                   40 pt   │  ← label 行(小字,靠上)
 *  │  [───●──────────────────────────]        │  ← PSSliderCell 滑块
 *  └──────────────────────────────────────────┘
 *
 *  willDisplayCell: 里做两件事：
 *  1. 找到 PSSliderCell 内嵌的 UISlider，从 .value 读真值初始化标签
 *  2. 给 UISlider 加 UIControlEventValueChanged → _obSliderChanged: 跟手更新
 */

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    // ⚠️ 绝不调 [super ...] —— PSListController 未实现该方法，调用会 doesNotRecognizeSelector 闪退
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    if (!spec) return;

    NSString *key = [spec propertyForKey:@"key"];
    if (!_obSliderUnits()[key]) return;   // 非滑块行，跳过

    // ── 在 PSSliderCell 内部找到 UISlider ──
    UISlider *slider = nil;
    for (UIView *sub in cell.contentView.subviews) {
        if ([sub isKindOfClass:[UISlider class]]) { slider = (UISlider *)sub; break; }
        // 某些版本 PSSliderCell 可能包一层容器
        for (UIView *deep in sub.subviews) {
            if ([deep isKindOfClass:[UISlider class]]) { slider = (UISlider *)deep; break; }
        }
        if (slider) break;
    }
    if (!slider) return;

    // ── 创建/复用右侧数值标签（小字、靠上、紧凑） ──
    UILabel *lbl = _valueLabels[key];
    if (!lbl || !lbl.superview) {
        lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 60, 18)];
        lbl.textAlignment = NSTextAlignmentRight;
        lbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        if (@available(iOS 13.0, *)) {
            lbl.textColor = [UIColor secondaryLabelColor];
        } else {
            lbl.textColor = [UIColor darkGrayColor];
        }
        lbl.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [cell.contentView addSubview:lbl];
        if (!_valueLabels) _valueLabels = [NSMutableDictionary dictionary];
        _valueLabels[key] = lbl;

        // 监听 slider 值变化（跟手更新，比 slider:titleForCurrentValue: 可靠得多）
        [slider addTarget:self action:@selector(_obSliderChanged:) forControlEvents:UIControlEventValueChanged];
        // 用关联对象把 key 绑到 slider 上，_obSliderChanged: 可直接取
        objc_setAssociatedObject(slider, "ob_key", key, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }

    // 从 slider.value 读真值（滑块位置永远是对的，不依赖 UserDefaults 默认值注册）
    [self _obRefreshLabel:lbl key:key value:slider.value];

    // 定位：右上角，垂直偏上（在滑块上方，不抢滑块视觉空间）；按文字自适应宽度防裁切
    CGFloat margin = 16;
    CGFloat w = cell.contentView.bounds.size.width;
    if (w > 0) {
        [lbl sizeToFit];
        CGFloat lw = lbl.frame.size.width;
        lbl.frame = CGRectMake(w - lw - margin, 2, lw, 18);
    }
}

// UISlider UIControlEventValueChanged 回调 —— 直接跟手更新标签
- (void)_obSliderChanged:(UISlider *)sender {
    NSString *key = objc_getAssociatedObject(sender, "ob_key");
    if (!key) return;
    UILabel *lbl = _valueLabels[key];
    if (!lbl) return;
    [self _obRefreshLabel:lbl key:key value:sender.value];
    // 拖动时数值长度可能变化（如 9→10、0.25→1），重新自适应宽度并右对齐，防裁切
    UIView *sup = lbl.superview;
    CGFloat w = sup ? sup.bounds.size.width : 0;
    if (w > 0) {
        [lbl sizeToFit];
        CGFloat lw = lbl.frame.size.width;
        lbl.frame = CGRectMake(w - lw - 16, 2, lw, 18);
    }
}

#pragma mark - 内部辅助

// 格式化：>=1 整数，<1 两位小数
- (NSString *)_obFormatValue:(float)v {
    return (v >= 1.0f)
        ? [NSString stringWithFormat:@"%.0f", v]
        : [NSString stringWithFormat:@"%.2f", v];
}

// 刷新标签文字：数值 + 单位
- (void)_obRefreshLabel:(UILabel *)lbl key:(NSString *)key value:(float)value {
    NSString *unit = _obSliderUnits()[key] ?: @"";
    NSString *num = [self _obFormatValue:value];
    lbl.text = [num stringByAppendingString:unit];
}

#pragma mark - 重置设置

// PSButtonCell 的 action 会打到本控制器（无参调用，安全）
- (void)resetSettings {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"重置设置"
                         message:@"将清空所有 Oback 设置并恢复默认（含已选的白/黑名单程序），确定吗？"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重置"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [self _obPerformReset];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 立即打印诊断

// PSButtonCell 的 action 会打到本控制器（无参调用，安全）。向所有已注入 Oback 的 App 广播一次诊断请求，
// 各 App 的 ObackManager 收到后把 [Oback-diag] 写入手机本地文件 /var/mobile/oback_diag.log（含前台/后台 App 真实 bid），
// 无需重启 App，也无需 Mac（设置面板本身被排除注入，无法在此打印自身诊断，故改用跨进程写文件 + 手机上展示）。
- (void)dumpDiagnostics {
    // 先清空上次诊断文件，便于本次拿到干净快照
    NSString *path = @"/var/mobile/oback_diag.log";
    [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    // 广播：各 App 的 ObackManager 收到后把诊断行追加写入上述文件
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.zlhkf.oback.diagNow"),
                                         NULL, NULL, TRUE);
    // 等各 App 写完（~1s）再读文件并在手机上展示，完全不依赖 Mac。
    // 用 performSelector:afterDelay: 而非 dispatch_after —— 避免依赖 <dispatch/dispatch.h>
    // （theos 精简头文件子集不一定透传，DISPATCH_TIME_NOW/NSEC_PER_SEC 会成未声明标识符导致 -Werror 编译失败）。
    [self performSelector:@selector(_obShowDiagFile) withObject:nil afterDelay:1.0];
}

#pragma mark - [v11] 显示调试日志（App 内弹窗，绕开沙盒文件隔离）

// 广播 showLog 通知：后台的 Oback App 收到后注册「回到前台」监听，用户切回该 App 时自动弹出内存日志。
- (void)showDebugLog {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.zlhkf.oback.showLog"),
                                         NULL, NULL, TRUE);
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"调试日志"
                         message:@"已请求各 App 显示内存中的调试日志。请切回目标 App（如 QQ/TIM），它回到前台时会自动弹出日志窗口；长按文本框全选复制，发我即可定位文本选择等问题。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好"
                                          style:UIAlertActionStyleDefault
                                        handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

// [P9] 调试日志开关改为按钮直写：点按直接 oback_setGlobalPref 写全局文件，
// 不依赖 PreferenceLoader 的 setPreferenceValue: 回调（用户 roothide 下该回调不可靠，开关拨了 tweak 读不到）。
// 复用与黑名单相同的写路径（ObackAppListController 直写，已证明 tweak 可读到），确保 toggle 一定生效。
- (void)toggleDebugLog {
    BOOL cur = NO;
    NSDictionary *g = [NSDictionary dictionaryWithContentsOfFile:kOBGlobalPlist];
    if (g) { id v = [g objectForKey:@"debugLog"]; if (v) cur = [v boolValue]; }
    BOOL next = !cur;
    oback_setGlobalPref(@"debugLog", @(next));
    // [P11] 刷新「调试日志」按钮标题：仅改 spec.label 不会刷新已显示的 cell（PSButtonCell 在
    // setSpecifier: 时读 label 作标题，后续不变），故必须 reload 该行或直设 cell.textLabel。
    // 之前无论开/关都显示「关」即此因——点按后 alert 弹窗盖住旧 cell，关掉后 cell 仍是 plist 静态文案。
    NSString *newTitle = (next ? @"调试日志：开" : @"调试日志：关");
    for (PSSpecifier *spec in _specifiers) {
        if ([[spec propertyForKey:@"action"] isEqualToString:@"toggleDebugLog"]) {
            [spec setProperty:newTitle forKey:@"label"];
            break;
        }
    }
    // [P14] 整表重建以刷新 PSButtonCell 标题。PSButtonCell 的标题渲染在内部按钮(_button)上，
    // 本 roothide PreferenceLoader 下 reloadSpecifier:/cellForSpecifier:/indexPathForSpecifier:
    // 均不更新按钮标题（P11/P13 实测无效），且 self.tableView 不返回真实 tableView。唯一可靠路径是
    // 直接 reload 整个 UITableView，重建所有 cell 重走 setSpecifier: 从已改的 spec.label 读新标题。
    // 设置页 specifier 数量极少，整表重建无性能/视觉负担。
    UITableView *tv = nil;
    @try { tv = [self valueForKey:@"table"]; } @catch (NSException *e) { tv = nil; }
    if (tv && [tv respondsToSelector:@selector(reloadData)]) {
        [tv reloadData];
    }
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"调试日志"
                         message:(next ? @"已开启。回 QQ 做几次手势，再用「显示调试日志」查看内存日志。" : @"已关闭。")
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

// 读本地诊断文件并在手机上以文本框展示（无 Mac 也能看）；空文件给排查提示
- (void)_obShowDiagFile {
    NSString *path = @"/var/mobile/oback_diag.log";
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!content.length) {
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"诊断"
                             message:@"尚未收到任何 App 的诊断数据。请确认：\n① 已注入 Oback 的 App 正在运行（前台或后台）；\n② 这些 App 至少做过一次边缘手势（此时才会注册诊断观察者）。"
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    UIViewController *vc = [[UIViewController alloc] init];   // ARC bundle：禁止 autorelease（否则 -Werror 编译失败）
    vc.title = @"Oback 诊断（各 App）";
    UITextView *tv = [[UITextView alloc] initWithFrame:vc.view.bounds];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIFont *tvFont = [UIFont fontWithName:@"Menlo" size:11];
    if (!tvFont) tvFont = [UIFont systemFontOfSize:11];
    tv.font = tvFont;
    tv.text = content;
    tv.editable = NO;
    [vc.view addSubview:tv];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                           target:self
                                                                           action:@selector(_obDismissDiag)];
    vc.navigationItem.rightBarButtonItem = done;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)_obDismissDiag {
    [self dismissViewControllerAnimated:YES completion:nil];
}

// 真正执行重置：清空 com.zlhkf.oback 域 → 重建 specifiers → 表格回弹默认值
- (void)_obPerformReset {
    NSString *domain = @"com.zlhkf.oback";
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:domain];
    [d removePersistentDomainForName:domain];
    [d synchronize];
    // 同步清空全局文件（roothide 跨 App 共享来源）：否则 tweak 侧仍读得到旧黑名单/白名单
    oback_removeGlobalPrefs();

    // 丢掉缓存的右侧数值标签（reload 后 willDisplayCell: 会按新默认值重建）
    _valueLabels = [NSMutableDictionary dictionary];

    // 重建 specifiers 并刷新表格：所有开关/滑块回到 Root.plist 的 <default>
    // [2026-08-23] 显式清空缓存——本类 specifiers 有 `if (!_specifiers)` 缓存，
    // 若 reloadSpecifiers 未内部置 nil，会拿到旧列表导致重置后表格不回默认。
    _specifiers = nil;
    [self reloadSpecifiers];
}

@end
