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

// ── 每个滑块 key 对应的单位后缀 ──────────────────────────────
static NSDictionary *_obSliderUnits(void) {
    static NSDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = @{
            @"triggerWidth":    @" pt",
            @"parallaxOffset":  @"",
            @"previousScaleMin": @"",
            @"dimAlpha":        @"",
            @"duration":        @" s",
            @"commitRatio":     @"",
            @"commitVelocity":  @"",
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

    // 定位：右上角，垂直偏上（在滑块上方，不抢滑块视觉空间）
    CGFloat margin = 16;
    CGFloat w = cell.contentView.bounds.size.width;
    if (w > 0) {
        lbl.frame = CGRectMake(w - 60 - margin,
                               2,   // 贴顶，与 label 文字基线对齐
                               60, 18);
    }
}

// UISlider UIControlEventValueChanged 回调 —— 直接跟手更新标签
- (void)_obSliderChanged:(UISlider *)sender {
    NSString *key = objc_getAssociatedObject(sender, "ob_key");
    if (!key) return;
    UILabel *lbl = _valueLabels[key];
    if (!lbl) return;
    [self _obRefreshLabel:lbl key:key value:sender.value];
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

@end
