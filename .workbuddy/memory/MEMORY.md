# Oback 项目记忆（roothide/iOS 16.4.1/zlhkf）
越狱 tweak，OPPO 风格边缘手势返回，全局注入 com.apple.UIKit。Theos(Logos)+ObjC(MRC)，Windows 编写→GitHub Actions(roothide theos,arm64e) 出 .deb，macOS 真机验证。远程 github.com/yxh41/Oback.git；push main 自动出包。版本号 control 静态 0.1.0，CI 注入哈希→0.1.0+<sha>。本地 git 易损，远程为准。

## 铁律（勿破）
- 私有类(UIScrollViewPanGestureRecognizer 等)公共 SDK 头未声明→用 NSClassFromString 取 Class+isKindOfClass 判，禁硬编码 [Cls class]（799cd13）。
- PreferenceLoader：禁 cellClassForSpecifier 换 cell(SIGABRT)/禁 PSApplicationCell；图标 PSTitleValueCell+setProperty:icon+UIImage imageWithContentsOfFile；willDisplayCell 禁调 super；didSelect 须 respondsToSelector 防护。
- modal 黑屏禁区：禁全局 presentViewController 劫持；dismiss 只移 sheet(缩8%)，不碰 presenting/不加深遮罩。
- 交互转场冻结架构：ObackInteractiveTransition 不继承 UIPercentDrivenInteractiveTransition（早期→微信冻结）；改遵循 UIViewControllerInteractiveTransitioning，updateWithPercent 直接驱 animator.propertyAnimator.fractionComplete；completeTransition 仅由 ObackAnimator completion+forceFinishIfNeeded dispatch_after 双保险，交互控制器绝不手调；pop/dismiss 仅首次横向拖动触发（28fc77b）。
- 阴影 CALayer 坑：UIViewPropertyAnimator 手动 scrub 不插值 shadowOpacity；拖动中须 CATransaction(disableActions) 显式按 percent 设 shadowOpacity=base*(1-percent)，addAnimations block 不得碰该属性（de704fb）。
- MRC（仅 tweak .dylib）：禁 __weak/weak 属性；alloc 交已 retain 宿主须 autorelease；类工厂返回须 autorelease；dealloc 释放所有 retain。⚠️ Preferences bundle 是 ARC（ObackSettingsController.m 等），显式 autorelease 被 -Werror 拒——两套 target 标志不同，Preferences 用 ARC 形式不写 autorelease（d295c98）。
- 系统进程(com.apple.*)+包管理器排除；triggerWidth 默认 40(≥35)；nav pop 仅手势时接 ObackAnimator。
- 默认 whitelistMode=NO（全局+黑名单），否则主功能无效。
- 黑名单失效：99% 列表 bid≠运行时 mainBundle.bundleIdentifier（大小写/后缀/同名不同 bid），非守卫失效。确证：删 oback_debug.log→冷启→看首行 [oback-diag] bid=.. isAllowed（1f3efa1 起大小写不敏感+点前缀兜底）。

## 架构决策
- 方案A(默认左缘 nav pop)：纯系统 handleNavigationTransition:，零冻结/原生手感；灵敏度滑块对 nav pop 不生效(仅 modal)。
- 方案B(modal dismiss)：自定义 ObackAnimator+ObackInteractiveTransition，只移 sheet。
- 实验 navParallaxEnabled 默认关：已改「阴影渐隐」(当前页平移+左右缘阴影随进度1→0渐隐)，不截图/缩放，去底页空白/scrollView错位/导航栏消失坑（1bd8aec/602d444，阴影默认 offset6/radius12）。验证前勿默认开。
- 右缘 rightSimplePop(07-26)：shouldBegin 置 rightSimplePop=YES，updateTransition 仅更胶囊，松手 endTransition 才 popViewControllerAnimated: 非交互返回——零空白/方向正确/不坏导航栏。
- QQ/TIM 自定义交互 nav pop(74760e8+ae5d15f，仅圈 com.tencent.mqq/com.tencent.tim)：根因 QQ 自研 NTPushPopLib.NTPushPopTransition 接管交互返回，方案A 喂系统 handleNavigationTransition: 无法 scrub→瞬返。修法=复活 ObackAnimator 自定义交互 nav 转场(interruptibleAnimatorForTransition 返可 scrub UIViewPropertyAnimator)，navPop=YES 纯平移+阴影渐隐。左缘需镜像右缘对手手势压制(_obLinkLeftEdgeOpponentPansInWindow，仅 QQ/TIM)独占左缘。
- 全屏返回坑(344693d→4a4140a→a959693，已根治)：QQ 聊天任意位置全屏返回(NTPushPopLib 挂 scroll/容器)与 Oback 全屏 panG 抢转场→瞬返。三层：①热区(344693d) panG 仅左1/3→跳过热区任意位置识别；②压制时机+漏压 scroll(4a4140a)→attach+linkNav+shouldBegin 三时机建压制且不再跳 scroll 类；③nav 解析失败(a959693 真因) panG 挂 window 无 kObackNavKey，topMost 解析 QQ 自定义容器 VC 得 nil→return NO→panG 永不 begin；修法 QQ/TIM 下 topMost 解析不到时兜底遍历同 window Oback 边缘 pan 借其关联 nav 并写回 panG.kObackNavKey。爆炸半径仅 QQ/TIM。CI 出 0.1.0+a959693。
  **④全局返回开启时仍瞬返（ecb1352 实机日志 (9) 证实，2026-08-06 根治）**：`_attachNavPanToNav` 在全局返回开启时 `if([ObackPreferences isGlobalBackEnabled]) continue`（ObackManager.m:526）跳过挂载 nav.view 边缘 pan；而 a959693 的「借 nav」正是靠这些边缘 pan 的 `kObackNavKey`——边缘 pan 缺席→借不到→nav 永远 nil→panG 不 begin→QQ 原生 NTPushPopLib 瞬返。(9) 日志特征：`globalShouldBegin: QQ/TIM 全屏 pan 不限热区` 多次打印但全无 `解析/借用 nav` 行与 `handleGlobalPan Began`。修复：借边缘 pan 落空时兜底 `_topNavControllerInWindow:` 递归窗口 VC 树解析顶层 UINavigationController（兼容 QQ/TIM 自定义容器），已写入 ObackManager.m。

## 894346d(已落地)
微信双返回+QQ右缘冲突：改 gestureRecognizer:shouldRequireFailureOf: 单向让步(对手识别→我们取消，对手不识别→我们接管)，移除显式 requireToFail 枚举防互锁。右缘空白=rightSimplePop。黑名单：start/attachToWindow/_linkNavPopGesturesInWindow 顶部 isAllowed 早退，黑名单 App 完全不注入。MRC 守恒无 __weak。

## 待真机验证
- a959693(QQ/TIM 全屏中间返回 nav 解析修复)：装 0.1.0+a959693，QQ/TIM 聊天界面中间任意位置横滑应跟手；验三件套(底部空白/导航栏损坏/scrollView错位)+聊天列表纵向滚动+图片查看器横向滑是否误触返回。
- 07-24 抓的 oback_debug(7)(QQ,全局返回ON)/(8)(TIM,全局返回OFF) 均无线全屏 pan 活动(panG 未 attach/未 begin)，属 344693d 之前的预特性包，无法验证全屏修复——需装 a959693 重抓。

## 构建/CI
push main 自动出 .deb；feature 分支需 workflow_dispatch(POST actions/workflows/build.yml/dispatches {"ref":"feat/..."} 需 PAT)。本地 git 损：远程干净克隆再覆盖编辑后直推。诊断日志 /var/mobile/oback_debug.log(删旧→复现→Filza 取回)。

## 分支策略
main 为唯一稳定主线。feat/navbar-coordination 已于 2026-07-29 经用户确认作废删除。今后功能直接在 main 做，勿开长期 feature 分支。

## 验证纪律
用户按构建版本实测；要其重测前必须先确认「已装构建哈希是否含对应修复」，否则用户会认为在重复无效测试而反感。日志签名判定版本：含全屏 pan 必有 globalShouldBegin / handleGlobalPan Began / 借 nav 日志；全无即预特性包（瞬返=对手原生手势，Oback 全屏 pan 未介入）。
