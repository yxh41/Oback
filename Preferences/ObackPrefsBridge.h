//
//  ObackPrefsBridge.h
//  跨 App 偏好桥：roothide 下 NSUserDefaults(suiteName:) 的【手动写入】会落到「设置」App 自身的
//  容器副本，tweak 注入到其它 App 时读不到（黑名单/白名单因此永远无效）。本桥直接读写
//  PreferenceLoader 写入的全局 plist 文件，绕过 per-app 容器化，确保「设置」写入与「tweak」读取
//  命中同一物理文件。函数体为 static inline（ARC 安全），tweak 与设置 bundle 各自编一份、互不影响。
//
#import <Foundation/Foundation.h>

static NSString *const kOBGlobalPlist = @"/var/mobile/Library/Preferences/com.zlhkf.oback.plist";

// 读取全局偏好字典（文件不存在时返回空字典，调用方须判空）
static inline NSDictionary *oback_globalPrefs(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kOBGlobalPlist];
    return d ? d : @{};
}

// 写入单个 key（value 为 nil 表示删除）
static inline void oback_setGlobalPref(NSString *key, id value) {
    if (!key) return;
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:kOBGlobalPlist];
    if (!d) d = [NSMutableDictionary dictionary];
    if (value) d[key] = value; else [d removeObjectForKey:key];
    [d writeToFile:kOBGlobalPlist atomically:YES];
}

// 清空全部全局偏好（重置设置时使用）
static inline void oback_removeGlobalPrefs(void) {
    [@{} writeToFile:kOBGlobalPlist atomically:YES];
}
