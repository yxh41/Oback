# Oback 项目记忆（roothide / iOS 16.4.1，开发者 zlhkf）

iOS 越狱 tweak，OPPO 风格边缘手势返回（左右边缘内滑+视差），全局注入 `com.apple.UIKit`。
Theos(Logos)+ObjC(MRC)，Windows 编写，GitHub Actions(roothide theos, arm64e) 出 .deb，需 macOS 真机装包验证。
本地 git 易损坏（flaky），远程为准；`main(9bf479e)` 稳定不动，功能走 `feat/navbar-coordination`。

## 铁律（已稳定，勿破）
- **PreferenceLoader 面板**：禁 `cellClassForSpecifier:` 换自定义 cell（SIGABRT）；禁 `PSApplicationCell`（未声明→-Werror 不出包）；
  图标用 `PSTitleValueCell`+`setProperty:icon forKey:@"iconImage"`+`UIImage imageWithContentsOfFile:`；
  `willDisplayCell:` 绝不可调 `[super ...]`；`didSelectRowAtIndexPath:` 必须 `if([super respondsToSelector:...])` 防护。
- **modal 黑屏禁区**：禁全局 `presentViewController:` 劫持。dismiss 方案B=只移 sheet(缩8%)绝不碰 presenting/不加深遮罩。
- **交互转场冻结**：`ObackInteractiveTransition` 必须继承 `UIPercentDrivenInteractiveTransition`，用
  `update/finish/cancelInteractiveTransition`；绝不可手调 `[_ctx completeTransition:]` 或重写 `startInteractiveTransition:` 不调 super。
  pop/dismiss 只在首次横向拖动(p>0.001)触发，绝不 Began 即调。修复 `28fc77b`。
- **MRC**：禁 `__weak`/`@property(weak)`；`alloc` 交已 retain 宿主须 `autorelease`；类方法工厂返回须 `autorelease`；
  每个类 dealloc 释放所有 retain 属性。`autorelease]]` 多一个 `]` 即错（clang expected identifier）。
- **系统进程/triggerWidth/nav**：`com.apple.*`+包管理器排除；`triggerWidth` 默认 40（≥35）；nav pop 仅手势时接 `ObackAnimator`。
- **默认全局生效**：`whitelistMode` 默认 NO（全局+黑名单），否则主功能没效果。
- **版本号**：`control` 静态 `0.1.0`，CI 注入哈希成 `0.1.0+<sha>`；本地构建保持 `0.1.0`。

## 架构决策（feat/navbar-coordination）
- **方案A（默认，左缘 nav pop）**：纯系统原生 `handleNavigationTransition:`，零冻结/原生手感/最省电；灵敏度滑块对 nav pop 不生效（仅 modal dismiss 生效）。
- **方案B（modal dismiss）**：自定义 `ObackAnimator`+`ObackInteractiveTransition`，只移 sheet 不动 presenting，安全无黑屏。
- **实验（opt-in）**：`navParallaxEnabled` 默认关，自定义 nav 视差转场（parallaxToView=YES），验证前勿默认开。
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
