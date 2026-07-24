//
//  ObackSettingsController.m
//  Oback 设置页主控制器 —— 由 Root.plist 描述所有开关/滑块/文本框，
//  域统一为 com.zlhkf.oback（与 ObackPreferences.m 的 initWithSuiteName 一致）。
//
//  滑块样式（仿截图）：每行左侧显示参数名称，右侧实时显示当前数值+单位，
//  用户拖动滑块时右侧数值即时更新，一眼就知道在调什么、调了多少。
//

#import "ObackSettingsController.h"
#import <UIKit/UIKit.h>
#import <Preferences/PSSpecifier.h>

// ── 每个滑块 key 对应的 (格式化串, 单位后缀) ──────────────────────────────
static NSDictionary *_obSliderFormats(void) {
    static NSDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = @{
            @"triggerWidth":    @[@"%.0f", @" pt"],      // 触发宽度 → "40 pt"
            @"parallaxOffset":  @[@"%.2f", @""],          // 视差位移 → "0.30"
            @"previousScaleMin": @[@"%.2f", @""],          // 上一页缩放 → "0.92"
            @"dimAlpha":        @[@"%.2f", @""],          // 遮罩浓度 → "0.35"
            @"duration":        @[@"%.2f", @" s"],        // 动画时长 → "0.32 s"
            @"commitRatio":     @[@"%.2f", @""],          // 提交位移阈值 → "0.30"
            @"commitVelocity":  @[@"%.0f", @""]           // 提交速度阈值 → "400"
        };
    });
    return d;
}

@implementation ObackSettingsController {
    NSMutableDictionary<NSString *, UILabel *> *_valueLabels; // key → 右侧数值标签
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

#pragma mark - PSSliderCell delegate（min/max/current 文字）

// 端点值保持简洁：>=1 整数，<1 两位小数
- (NSString *)slider:(id)slider titleForMinimumValue:(float)value {
    return [self _obFormatValue:value];
}
- (NSString *)slider:(id)slider titleForMaximumValue:(float)value {
    return [self _obFormatValue:value];
}

// 当前值——除了返回给滑块自用的文字外，同时刷新我们的右侧数值标签（实时跟手）
- (NSString *)slider:(id)slider titleForCurrentValue:(float)value {
    NSString *key = [self _obKeyForSlider:slider];
    if (key) [self _obUpdateValueLabelForKey:key value:value];
    return [self _obFormatValue:value];
}

#pragma mark - 右侧实时数值标签（截图样式核心）

/*  布局示意（仿用户截图）：
 *
 *  ┌──────────────────────────────────────────────┐
 *  │ 触发宽度                        40 pt       │  ← 标签名(左) + 数值+单位(右)
 *  │  [───●─────────────────────────]             │  ← PSSliderCell 自带滑块
 *  └──────────────────────────────────────────────┘
 *
 *  在 willDisplayCell: 里给每个 PSSliderCell 的 contentView
 *  右上角挂一个 UILabel，通过 slider:titleForCurrentValue: 实时更新。
 */

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    // ⚠️ 绝不调 [super ...] —— PSListController 未实现该方法，调用会 doesNotRecognizeSelector 闪退
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    if (!spec) return;

    NSString *key = [spec propertyForKey:@"key"];
    NSArray *fmt = _obSliderFormats()[key];
    if (!fmt) return;   // 非滑块行，跳过

    // 从 UserDefaults 读当前真实值
    float value = [[NSUserDefaults standardUserDefaults] floatForKey:key];
    NSString *text = [self _obTextForKey:key value:value];

    // 复用或创建右侧数值标签
    UILabel *lbl = _valueLabels[key];
    if (!lbl || !lbl.superview) {
        lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 72, 28)];
        lbl.textAlignment = NSTextAlignmentRight;
        lbl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        // iOS 13+ secondaryLabelColor / 兼容旧版 darkGrayColor
        if (@available(iOS 13.0, *)) {
            lbl.textColor = [UIColor secondaryLabelColor];
        } else {
            lbl.textColor = [UIColor darkGrayColor];
        }
        lbl.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [cell.contentView addSubview:lbl];
        if (!_valueLabels) _valueLabels = [NSMutableDictionary dictionary];
        _valueLabels[key] = lbl;
    }
    lbl.text = text;

    // 定位到 cell 右上角（避开 accessory 区域）
    CGFloat margin = (cell.accessoryView || cell.accessoryType != UITableViewCellAccessoryNone) ? 48 : 12;
    CGFloat w = cell.contentView.bounds.size.width;
    if (w > 0) {
        lbl.frame = CGRectMake(w - 72 - margin,
                               (cell.contentView.bounds.size.height - 28) * 0.5,
                               72, 28);
    }
}

#pragma mark - 内部辅助

// 简单格式化（仅用于滑块端点/自身文字）：>=1 整数，<1 两位小数（字面量格式串，安全）
- (NSString *)_obFormatValue:(float)v {
    return (v >= 1.0f)
        ? [NSString stringWithFormat:@"%.0f", v]
        : [NSString stringWithFormat:@"%.2f", v];
}

// 组合「数值 + 单位」显示文本（用 NSNumberFormatter 绕过 -Wformat-security 检查）
- (NSString *)_obTextForKey:(NSString *)key value:(float)value {
    NSArray *fmt = _obSliderFormats()[key];
    if (!fmt) return [self _obFormatValue:value];

    NSNumberFormatter *nf = [[NSNumberFormatter alloc] init];
    nf.numberStyle = NSNumberFormatterDecimalStyle;
    nf.maximumFractionDigits = (value >= 1.0f) ? 0 : 2;
    nf.minimumFractionDigits = (value >= 1.0f) ? 0 : 2;
    NSString *num = [nf stringFromNumber:@(value)];
    return [num stringByAppendingString:fmt[1]];
}

// 通过遍历 specifiers 找到包含该 UISlider 的那一行的 key
// （PSSliderCell 把 UISlider 作为子视图嵌入；slider 参数即该 UISlider 实例）
- (NSString *)_obKeyForSlider:(UISlider *)slider {
    if (!slider || ![slider isKindOfClass:[UISlider class]]) return nil;
    for (PSSpecifier *spec in self.specifiers) {
        if (![[spec propertyForKey:@"cell"] isEqualToString:@"PSSliderCell"]) continue;
        UITableViewCell *cell = [self cachedCellForSpecifier:spec];
        if (!cell) continue;
        for (UIView *sub in cell.contentView.subviews) {
            if ([sub isEqual:slider]) return [spec propertyForKey:@"key"];
            if ([sub isKindOfClass:[UISlider class]]) {
                for (UIView *deep in sub.subviews) {
                    if ([deep isEqual:slider]) return [spec propertyForKey:@"key"];
                }
            }
        }
    }
    return nil;   // 找不到就跳过（不影响功能）
}

// 刷新指定 key 的右侧数值标签
- (void)_obUpdateValueLabelForKey:(NSString *)key value:(float)value {
    UILabel *lbl = _valueLabels[key];
    if (!lbl) return;
    lbl.text = [self _obTextForKey:key value:value];
}

@end
