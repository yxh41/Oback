#import "ObackTransition.h"

// [2026-08-26 T3] 顶部空白自愈器(ObackTopBlankHealer)已退役；调试日志统一走 ObackManager.m 的 OBLog。
// [2026-08-23 T4] QQ/TIM 已内置排除（不再注入）。
// [方案B] 自定义转场(ObackAnimator / ObackInteractiveTransition / OBApplyParallax / applyShadowTo:)已整体移除：
//   - 左缘 nav pop 走系统原生交互转场(方案A，handleNavigationTransition:)
//   - 右缘走 rightSimplePop 非交互 pop（松手提交才 popViewControllerAnimated:）
//   - modal dismiss 交还系统/App 原生动画（ObackTransitioningDelegate 仅作透传）
// 仅保留 ObackParams（设置面板参数载体）。

@implementation ObackParams
+ (instancetype)defaults {
    ObackParams *p = [[[ObackParams alloc] init] autorelease];
    p.triggerWidth     = 40.0;   // 边缘触发宽度：24 太窄（用户常从 25~32pt 起滑，判为"不在边缘"），放宽到 40
    p.leftEnabled      = YES;
    p.rightEnabled     = YES;
    p.hapticEnabled    = YES;
    p.duration         = 0.32;
    // 提交阈值：偏灵敏（贴近 OPPO/系统边缘返回手感）。
    // 旧值 commitRatio=0.40 太严 —— 真机日志显示用户自然内滑大多只到
    // 0.34~0.38 就被判取消(6/7 次取消)，导致"主功能体验不好"。降到 0.30 让部分拖动即可提交；
    // commitVelocity 同步下调到 400，让一般甩动(flick)也能可靠提交。
    p.commitRatio      = 0.30;
    p.commitVelocity   = 400.0;
    return p;
}
@end
