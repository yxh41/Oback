# Oback 项目记忆（roothide / iOS 16.4.1，开发者 zlhkf）

iOS 越狱 tweak，OPPO 风格边缘手势返回（左右边缘内滑+视差），全局注入 `com.apple.UIKit`。
Theos(Logos)+ObjC(MRC)，Windows 编写，GitHub Actions(roothide theos, arm64e) 出 .deb，需 macOS 真机装包验证。
本地 git 易损坏（flaky），远程为准；`main` 为已验证稳定主线（手势修复经 58~63 日志多轮真机收敛），历史上功能走 `feat/navbar-coordination`。分支策略见下方"分支策略"小节（严禁合并 feat→main）。

## 铁律（已稳定，勿破）
- **PreferenceLoader 面板**：禁 `cellClassForSpecifier:` 换自定义 cell（SIGABRT）；禁 `PSApplicationCell`（未声明→-Werror 不出包）；
  图标用 `PSTitleValueCell`+`setProperty:icon forKey:@"iconImage"`+`UIImage imageWithContentsOfFile:`；
  `willDisplayCell:` 绝不可调 `[super ...]`；`didSelectRowAtIndexPath:` 必须 `if([super respondsToSelector:...])` 防护。
- **modal 黑屏禁区**：禁全局 `presentViewController:` 劫持。dismiss 方案B=只移 sheet(缩8%)绝不碰 presenting/不加深遮罩。
- **交互转场冻结（架构）**：`ObackInteractiveTransition` **不继承** `UIPercentDrivenInteractiveTransition`（早期用它 →
  与中断式动画器并存时部分 App(微信自定义 nav)动画器不被续跑 → `completeTransition` 永不触发 → 冻结，见 `ObackTransition.h` 注释）。
  改为遵循 `UIViewControllerInteractiveTransitioning`，在 `updateWithPercent:` 直接驱动 `animator.propertyAnimator.fractionComplete`
  （Apple 推荐模式，且 `ObackAnimator` 已实现 `interruptibleAnimatorForTransition:`）。`completeTransition` 仅由
  `ObackAnimator` completion + `forceFinishIfNeeded` 的 `dispatch_after` 双重保险调用，交互控制器绝不手调（防双重/漏调）。
  pop/dismiss 只在首次横向拖动(p>0.001)触发，绝不 Began 即调。修复 `28fc77b`。
- **UIViewPropertyAnimator 手动 scrub 不插值 CALayer 阴影属性**：手动设 `fractionComplete` 拖动时，animator 对
  `layer.shadowOpacity` 等 CALayer 属性**不会逐帧插值**（暂停态 CA 动画"按住"presentation 值），真机阴影浓度恒定不变（即「没有渐隐的变化」）。
  要在拖动中让阴影随进度变化，必须在 `updateWithPercent:` 用 `CATransaction(disableActions)` **显式**按 percent 设 `shadowOpacity=base*(1-percent)`，
  且 animator 的 `addAnimations` block **不得触碰该阴影属性**（否则占位冲突盖掉显式赋值）。松手收尾走标准 UIView 动画（CATransaction 对阴影插值可靠）。见修复 `de704fb`。
- **MRC（仅 tweak 本体 `.dylib`）**：禁 `__weak`/`@property(weak)`；`alloc` 交已 retain 宿主须 `autorelease`；类方法工厂返回须 `autorelease`；
  每个类 dealloc 释放所有 retain 属性。`autorelease]]` 多一个 `]` 即错（clang expected identifier）。
  ⚠️ **Preferences bundle（`ObackSettingsController.m` / `ObackAppListController.m` / `ObackPreferences.m` 等 Preferences target）是 ARC 编译**——
  显式 `autorelease`/`retain`/`release` 会被 `-Werror` 直接拒（`error: 'autorelease' is unavailable: not available in automatic reference counting mode`）。
  **两套 target 编译标志不同**：tweak 本体 MRC，Preferences bundle ARC。在 Preferences 文件里一律用 ARC 形式（`[[X alloc] init]`，不写 autorelease），
  注释可标「ARC bundle：不用 autorelease」。tweak 本体 MRC 文件里仍可正常 autorelease。本次 d295c98 编译失败正是因我在 ARC 的
  `ObackSettingsController.m` 里手写了 4 处 autorelease（line 245/247/255/258）。
- **系统进程/triggerWidth/nav**：`com.apple.*`+包管理器排除；`triggerWidth` 默认 40（≥35）；nav pop 仅手势时接 `ObackAnimator`。
- **默认全局生效**：`whitelistMode` 默认 NO（全局+黑名单），否则主功能没效果。
- **黑名单失效排查铁律**：黑名单「拦不住」但 App 里仍有胶囊/仍崩 → 99% 是「列表存的 bid ≠ App 运行时 `mainBundle.bundleIdentifier`」
  （大小写/后缀变体/同名不同 bid 两个包），**不是守卫没生效**。所有注入入口
  （start / attachToWindow / _linkNavPopGesturesInWindow / shouldBegin / Tweak 的 viewDidLoad·viewDidAppear·setDelegate）
  均有 `isAllowed` 守卫，返回 0 时绝不可能出现胶囊或崩溃。确证手段：删 `oback_debug.log`→冷启目标 App→复现
  →看首行 `[oback-diag] bid=<真实bid> isAllowed=0/1`。（1f3efa1 起 isAllowed 大小写不敏感+点分隔前缀兜底，
  且设置面板每行显示真实 bundle id，便于核对/补选。）
- **版本号**：`control` 静态 `0.1.0`，CI 注入哈希成 `0.1.0+<sha>`；本地构建保持 `0.1.0`。

## 架构决策（feat/navbar-coordination）
- **方案A（默认，左缘 nav pop）**：纯系统原生 `handleNavigationTransition:`，零冻结/原生手感/最省电；灵敏度滑块对 nav pop 不生效（仅 modal dismiss 生效）。
- **方案B（modal dismiss）**：自定义 `ObackAnimator`+`ObackInteractiveTransition`，只移 sheet 不动 presenting，安全无黑屏。
- **实验（opt-in）**：`navParallaxEnabled` 默认关，自定义 nav 转场（`parallaxToView=YES`）。**实现已改为「阴影渐隐」方案**（当前页平移 + 左/右缘阴影随进度 1→0 渐隐，上一页保持 Identity 天然可见），不再截图/缩放——去掉底页空白/scrollView 错位/导航栏消失整类坑（commit `1bd8aec`）。**阴影参数可调**：`shadowOffset`(0~20pt 纵深) / `shadowRadius`(0~40pt 柔和度)，默认 6/12（commit `602d444`）。验证前勿默认开。
- **右缘（2026-07-26 改 rightSimplePop）**：右缘不再喂系统左原点 `handleNavigationTransition:`（算错底页坐标→空白），也不进自定义视差。
  shouldBegin 右缘置 `rightSimplePop=YES`(currentParallaxToView=NO)；updateTransition 仅更新胶囊；
  endTransition 松手提交才 `popViewControllerAnimated:` 非交互返回——零空白、方向正确、不破坏导航栏。
  （旧计划"右缘改自定义 ObackAnimator 全链路"已废弃，改为本非交互方案。）

## 2026-07-26 四修复（commit 894346d，父 5674b9a）
1. **微信双返回 + QQ 右缘冲突**：移除 setDelegate / _linkNavPopGesturesInWindow 里对系统 interactivePop 及窗口边缘手势的
   `requireGestureRecognizerToFail:` 显式枚举（易与对手 delegate 互锁、微信重开 enabled 后失效）；
   改 `gestureRecognizer:shouldRequireFailureOfGestureRecognizer:` 单向让步（OUR delegate 决策，对手不可否决，无死锁）。
   对手识别→我们取消（单层原生）；对手不识别→我们接管（单层 Oback）。scrollView 的 requireToFail 保留（非边缘，单向无死锁）。
   （纠正旧记：shouldRequireFailureOf 此前仅"计划"，本次 894346d 才真正落地；5674b9a 仅落了 shouldBegin 里的即时 `enabled=NO`，
   但单靠它+显式 requireToFail 仍不足以根治双返回。）
2. **右缘底部空白**：见上"右缘"条目（rightSimplePop 非交互 pop）。
   （纠正旧记：并非"真实 toView 铺底"，该路径未实施；本次改为右缘非交互 pop。）
3. **黑名单失效（拼多多商家版闪退）**：start / attachToWindow / _linkNavPopGesturesInWindow 顶部 `isAllowed` 早退，
   黑名单 App 完全不注入（不挂手势/不关系统手势/不链 nav）。OBLog 打印 bid 便于核对黑名单 bundle id 是否写准。
4. **MRC 守恒**：未改 autorelease（ObackManager.m 7 处、Tweak.xm 2 处），无 __weak。

## 待真机验证（894346d）
① 微信双返回消失；② 右缘无空白/方向正确；③ QQ 右缘不冲突（边缘=Oback、中间=QQ 原手势）；
④ 黑名单 App（如拼多多商家版）不注入不闪退；⑤ 多 App 无回归；⑥ 界面不冻结（28fc77b 已根治）。

## 构建/CI / 续作
- 远程 `https://github.com/yxh41/Oback.git`。push `main` 自动出 .deb；feature 分支需 `workflow_dispatch`
  （POST `actions/workflows/build.yml/dispatches` `{"ref":"feat/navbar-coordination"}`，需 PAT）。
- 本地 git 损坏时：从远程干净克隆 feature 分支，再覆盖编辑文件后提交直推（勿用损坏的本地仓库）。
- 诊断日志 `/var/mobile/oback_debug.log`（删旧→复现→Filza 取回）。参考调研见 `REFERENCE_GITHUB.md`。

## 分支策略（2026-07-29 澄清）
- **历史**：`feat/navbar-coordination` 仅在早期 `3a520cf`（`Merge branch 'feat/navbar-coordination'`）合并过一次；此后 `main` 与 `feat` **分叉并行**：`main` 继续推进全套已验证手势修复（流光/`cdd4046`/`5d050a3`/`7168514`/`a1c79d7`…）、图标 `layout/` 下发、`diagBanner` 横幅；`feat` 在自己分支新增 6 个 main 没有的提交。
- **严禁合并 feat → main**：feat 上的 `7ad634e`（左缘 nav pop 对 App 自带全屏返回 QQ/TIM“整体让步”）与 main 已验证方案（`cdd4046` 同时识别 + `5d050a3` `shouldBeRequiredToFailBy` 压制）是**相反手势策略且未经验证**；合并会用未验证方案覆盖已验证稳定方案，重引双返回/不返回/闪退。
- feat 独有提交：`bea1d8c`（入口 plist 加 icon 键）、`7c210a7`/`4199406`/`6dab632`（设置入口图标 icon@3x/@2x/icon.png 29pt，与 main 的 `layout/` 下发方式不同）、`7ad634e`（整体让步策略）、`f93969a`（去重 AppTool 日志）。
- 处置：`main` 为唯一稳定主线。**`feat/navbar-coordination` 已于 2026-07-29 经用户确认作废并删除（本地 `bea1d8c` + 远程）**。今后功能直接在 `main` 上做，勿再开长期 feature 分支以免再次分叉冲突。
