//
//  ObackSettingsController.m
//  Oback 设置页主控制器 —— 由 Root.plist 描述所有开关/滑块/文本框，
//  域统一为 com.zlhkf.oback（与 ObackPreferences.m 的 initWithSuiteName 一致）。
//

#import "ObackSettingsController.h"
#import <UIKit/UIKit.h>

@implementation ObackSettingsController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

#pragma mark - 滑块数值显示（两端最小/最大值 + 当前值）
// PSSliderCell 默认不显示任何文字，需由承载它的 PSListController 实现这三个 delegate 方法。
// 本控制器以 target:self 加载 specifier，故每个滑块 cell 的 delegate 即 self，方法会被调用。
// 区分规则：值 >=1 的滑块(提交速度阈值 100~1000)按整数显示；<1 的(提交位移阈值 0.1~0.5)保留两位小数。
- (NSString *)slider:(id)slider titleForMinimumValue:(float)value {
    return [self _obFormatSliderValue:value];
}

- (NSString *)slider:(id)slider titleForMaximumValue:(float)value {
    return [self _obFormatSliderValue:value];
}

- (NSString *)slider:(id)slider titleForCurrentValue:(float)value {
    return [self _obFormatSliderValue:value];
}

- (NSString *)_obFormatSliderValue:(float)value {
    if (value >= 1.0f) return [NSString stringWithFormat:@"%.0f", value];
    return [NSString stringWithFormat:@"%.2f", value];
}

@end
