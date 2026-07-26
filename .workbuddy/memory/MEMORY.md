# Oback 项目记忆（roothide / iOS 16.4.1，开发者 zlhkf）

iOS 越狱 tweak，OPPO 风格边缘手势返回（左右边缘内滑+视差），全局注入，带 PreferenceLoader 设置面板。Theos(Logos)+ObjC，注入 `com.apple.UIKit`。Windows 生成，需 macOS+roothide theos 真机编译验证。

## 铁律：PreferenceLoader 设置面板（已稳定）
- **禁 `cellClassForSpecifier:` 换自定义 cell 类** → 框架发类型专有方法给自定义类 → 未识别 selector → SIGABRT 闪退。
- **头文件可用性（CI theos/headers 已核对）**：✅ 可用 `PSSwitchCell/PSGroupCell/PSTitleValueCell/PSLinkCell/PSButtonCell/PSStaticTextCell/PSSliderCell/PSEditTextCell/PSSegmentCell`；❌ **绝不能用 `PSApplicationCell`**（undeclared identifier → `-Werror` 编译失败、CI 不出 .deb）。
- App 图标列表用 `PSTitleValueCell` + `[s setProperty:icon forKey:@"iconImage"]`（用字面量，勿用可能未声明的 `PSIconImageKey`）；icon 用 `UIImage imageWithContentsOfFile:` 从 .app 包图标文件读（解析 `CFBundleIconName`/`CFBundleIcons`/`CFBundleIconFiles`，带 @2x/@3x 候选）。
- 点按切换**勿用 `[s setAction:]`**（未声明 → 编译失败），改由控制器 `tableView:didSelectRowAtIndexPath:` 重写；选中态借 `tableView:willDisplayCell:forRowAtIndexPath:` 设 `accessoryType=UITableViewCellAccessoryCheckmark`。
- **重写 `tableView:willDisplayCell:forRowAtIndexPath:` 绝不可调 `[super ...]`**（PSListController 继承链未实现该方法 → `doesNotRecognizeSelector` 闪退）；`didSelectRowAtIndexPath:` 也要 `if ([super respondsToSelector:@selector(...)])` 防护后再调。

## 铁律：modal / 转场禁区（黑屏根因）
- **禁止全局 `presentViewController:` 劫持**（e414382 引入 → 1dc096d 删）。给每个 present 换 `transitioningDelegate` 会破坏 pageSheet modal → 全 App 黑屏。这是"黑屏"的唯一根因。
- **modal dismiss 方案B（已实施，73531bd，安全）**：手势驱动 dismiss 时只移 `fromView`(sheet 滑出+缩 8%)，**绝不碰 `toView`(presenting)**，不加深遮罩。`ObackTransitioningDelegate`(Tweak.xm) 仅本次手势注入、保留 App 原生动画为 original。实测无黑屏。
- 注意："界面冻结/点不动、只能上滑回桌面"**不是** modal 问题，是 nav pop 交互转场 bug（见下条）。

## 铁律：交互转场冻结（点不动/只能上滑回桌面，oback_debug(6) 实锤）
- **根因**：`ObackInteractiveTransition` 原本是 `NSObject<UIViewControllerInteractiveTransitioning>`，手写 `startInteractiveTransition:` 存 `_ctx` + `finish/cancel` 里直接 `[_ctx completeTransition:]`——绕过了 `UIPercentDrivenInteractiveTransition` 的 `finishInteractiveTransition/cancelInteractiveTransition`。导航控制器一直卡在"交互进行中"态 → 界面 `userInteractionEnabled` 失效（点不动、只能上滑回桌面；上滑是系统 home 指示器手势，不受影响）。
- **正确写法**：`ObackInteractiveTransition` 必须继承 `UIPercentDrivenInteractiveTransition`；`updateWithPercent:`→`[self updateInteractiveTransition:]`、`finish`→`[self finishInteractiveTransition]`、`cancel`→`[self cancelInteractiveTransition]`；视差全部交给 `ObackAnimator.animateTransition:` 被它 scrub。**绝不可**手动调 `[_ctx completeTransition:]` 或重写 `startInteractiveTransition:` 不调 super（否则转场状态机不复位 → 冻结）。
- **触发时机铁律**：`popViewControllerAnimated:` / `dismissViewControllerAnimated:` 必须放在**首次横向拖动**（`updateTransition` 里 `p>0.001`）才调用，**绝不**在手势 `Began`(`beginTransition`) 就调用。否则纯点按/纵向滑动即取消，交互转场易卡在"进行中"态。
- 修复提交 `28fc77b`（CI 版本 `0.1.0+28fc77b`）。

## 铁律：系统进程 / 触发宽度 / nav
- 系统进程排除用 `if ([bid hasPrefix:@"com.apple."]) return;`（大小写无关，真实 SpringBoard bundle id 是小写 `springboard`）+ 包管理器集合（Sileo/Zebra/Cydia/Installer/Saily）。边返回只服务第三方 App。
- `triggerWidth` 默认 **40**（真机自然起滑点 x=25~32pt）；调小务必 ≥35，否则几乎触发不了。
- nav pop 动画**仅手势时**（`[ObackManager shared].interacting`）接管 `ObackAnimator`，系统返回按钮走原生。

## 铁律：默认全局生效 / 版本号 / MRC / 手势状态机
- `whitelistMode` 默认 `NO`（全局+黑名单）。`Root.plist`「启用白名单」`<default>`=`<false/>`。白名单是可选细化，非默认；否则主功能"没效果"。
- `control` 保持静态 `Version: 0.1.0`；CI 用 `sed -i '' "s|^Version:.*|Version: 0.1.0+$HASH|"` 注入哈希（`HASH=$(git rev-parse --short=7 HEAD)`）。本地构建保持 `0.1.0`。构建后 `echo "::notice::Oback package version = $(dpkg-deb -f "$ROOTHIDE_DEB" Version)"` 确认版本。
- **MRC 铁律**：tweak 入口 `.xm/.m` 未开 ARC，**禁止 `__weak` / `@property(weak)`**（`-Werror` 直接编译失败不出包）。block 引用改强引用+确认无反向持有，或 `__block`。提交前 grep `__weak` / `@property (weak)` 删掉。
- **MRC 泄漏铁律（retain/release 平衡）**：`alloc` 后若交给已 retain 的宿主（`addSubview` / `objc_setAssociatedObject(RETAIN)` / `retain` 属性 setter / 系统框架），必须 `[... autorelease]` 平衡自身 +1；`retain` 属性赋值本地对象前先 `autorelease`（或确认 dealloc 释放）。**严禁**裸 `[[X alloc] init]` 直接赋给 `retain` 属性（会泄漏一实例）。`initWithEdge:params:` 类方法用 `self.params =`（setter retain），**勿** `_params =` 直接 ivar 赋值（不 retain → 悬垂）。每个类 dealloc 须 `[_xxx release]` 所有 retain 属性（`ObackAnimator`/`ObackInteractiveTransition` 的 `_params`、`ObackAnimator` 的 `_propertyAnimator`/`_navBarSnapshotView`）。`+defaults`/`+params` 等工厂方法返回的对象必须 `autorelease`（否则每次调用泄漏）。提交前 grep `alloc\]` 逐一核对有无对应的 `autorelease`/`release`。
- **手势状态机铁律**：自定义 `UIPanGestureRecognizer` 子类若在 `touchesMoved:` 里主动设 `self.state = Failed`（如纵向判定），则 `handlePan:` 的 switch **必须处理 `UIGestureRecognizerStateFailed`**——否则 Began 后 Failed 会导致胶囊/转场残留（endTransition 不被调用）。新增 `abortTransition:` 统一清理。

## 跨电脑续作交接
- 主线 `28fc77b`（已 push `main`，版本 `0.1.0+28fc77b`）。`.workbuddy/memory/` 已进 git，另一台 `git pull` 可见完整记忆与交接。
- 功能集：nav pop 视差+胶囊、modal dismiss 安全视差(方案B,只移 sheet 不碰 presenting)、返回灵敏度滑块真机可调(commitRatio/commitVelocity)、提交判定含惯性动量投影、扩展进程(NSExtension)跳过挂载、AppTool 冲突退避(仅 setDelegate 透传、手势不关)、triggerWidth=40、whitelistMode 默认 NO、MRC 禁 __weak。
- **待真机验证（最终集）**：① 各 App 边缘内滑返回灵敏（弹性阈值+滑块可调）；② 弹窗边缘滑 dismiss 带 sheet 视差无黑屏；③ 同时装 AppTool 不进安全模式；④ 设置面板滑块数值/极值显示正常；⑤ **界面不再冻结（28fc77b 已根治，重点验）**。
- 诊断日志 `/var/mobile/oback_debug.log`（删旧 → 复现 → Filza 取回发我）。多版本混测靠「某次提交才加的日志行」区分新旧版现场。
- 构建：push `main` 自动 GitHub Actions 出 roothide `.deb`；或 macOS 本地 `make package`。

## 稳定版架构决策（2026-07-26 整改，commit 59089cd / 包 0.1.0+59089cd，分支 feat/navbar-coordination）
> 原则：走过的坑能完美解决才碰，否则避开。默认路径只走最稳的「系统原生」，花哨动画作为 opt-in 实验。

- **架构分层（兼顾稳定 + 动画性能功耗）**：
  - **默认路径（navParallax=OFF，所有人）** = 方案A 纯系统原生 pop（仅左缘）。不进任何自定义转场 → 无空白/无导航栏损坏/无冻结；动画由 UIKit 合成器完成，零额外 CPU/绘制开销，最省电。灵敏度滑块对 nav pop 不生效（系统判定），只对 modal dismiss 生效——这是换"零冻结/原生手感"的取舍，绝不回退到自定义 nav 转场（那曾导致黑屏/冻结的根因）。
  - **实验路径（navParallax=ON，默认关，opt-in）** = OPPO 视差自定义转场（ef23435 已修空白：真实 toView 入 container + 导航栏协同引擎 restoreNavBar×3 收尾路径）。验证通过前勿默认开。
- **双返回根治（微信等，59089cd 修）**：根因 = App（微信）在其 VC 的 `viewDidAppear` 之后把系统 `interactivePopGestureRecognizer.enabled` 重新置 YES，一次性禁用（windowBecameKey/linkNav）被绕过 → 原生手势与我们的 pan 同触发=弹两层。三道防线（参考 FDFullscreenPopGesture 的 re-assert 套路）：
  1. Tweak.xm 既有 `viewDidLoad`/`viewDidAppear`/`viewDidLayoutSubviews` 持久 `enabled=NO` + `requireGestureRecognizerToFail` 我们的 pan；
  2. **【新增·即时禁用】** `gestureRecognizerShouldBegin:` nav 分支确认有效 pop 时，再 `nav.interactivePopGestureRecognizer.enabled = NO`（起滑瞬间压死事后重开）；
  3. **【新增】`gestureRecognizer:shouldRequireFailureOfGestureRecognizer:`** 让我们的边缘 pan 要求其它边缘返回手势(含系统 interactivePop 及 App/插件私有) + 所有 scrollView pan 先失败——OUR 自身 delegate 决策，对手无法否决（比单纯 API requireToFail 更稳）；语义安全：单层返回、不丢返回（最差优雅降级为 App 原生单层）。
  - 仍备「双返回诊断」开关（doubleReturnDiag）：开启后 `_diagLogEdgeGesturesInWindow:` 列出 window 内所有边缘手势类名，若仍双返回可定位"第二层"是谁。
- **右缘返回默认开（e53cbd7 已恢复 YES，覆盖 59089cd 的 NO）**：默认走方案A 系统原生 pop；但方案A 把右缘 pan 喂 `handleNavigationTransition:`（左原点语义，右滑 translation.x 为负→progress 钳0）→ 右缘"开着却触发不了/方向反"。**真正修法（待办，非简单开关）= 右缘 nav pop 改走自定义 `ObackAnimator`+`ObackInteractiveTransition` 全链路（不调 driveSystemNavPopBegin/handleNavigationTransition）**：`Tweak.xm:55` 条件加 `|| currentEdge==Right`；`ObackManager` begin 右缘不启动系统原生、改 `popViewControllerAnimated:` 触发；update/end 右缘走 `self.interactive` scrub 而非 `_callSystemNavPop:`。镜像数学已就绪（`OBApplyParallax` 的 `dir`/`_makeDimViewWithFrame`/`applyShadowTo` 均按 edge 分左右），无需重写动画。唯一待真机确认项：右缘自定义 pop 的导航栏是否跟手/不隐藏（当前 ObackTransition.m 搜不到 restoreNavBar 实现，需复核日 line 32-33 记录的"已落地"是否在本分支）。建议独立 commit、`rightEnabled` 默认保持 YES 但验前别指望好用。
- **性能/功耗基线（已满足，保持）**：调试日志默认关且 30 分钟自动过期；胶囊 CADisplayLink 仅手势中跑、结束即停；默认路径无 per-frame drawViewHierarchy / 无 timer 轮询；实验路径真实 toView(无快照绘制)。
- **GitHub 参考（2026-07-25/26 调研）**：FDFullscreenPopGesture（push 时 re-assert 禁用系统手势 + 自建同 view pan 调 handleNavigationTransition:，_isTransitioning 门控）、TZScrollViewPopGesture（边缘手势优先级 `shouldBeRequiredToFailByGestureRecognizer` + scrollView 共存）、PanCake（越狱全局注入+键盘禁用手势）、SwipeBackKit（双缘 + UIPercentDrivenInteractiveTransition + 右缘镜像）。详见 `REFERENCE_GITHUB.md`。
