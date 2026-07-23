# Project Memory

## Oback（手势目录）— 开发者 zlhkf
- iOS 越狱 tweak 项目，目标环境 **roothide / iOS 16.4.1**。
- 目标：类 OPPO 边缘手势返回（左右边缘内滑 + 视差动画），全局注入，带 PreferenceLoader 设置面板。
- 技术栈：Theos(Logos) + Objective-C；注入 `com.apple.UIKit`；自定义 `UIViewControllerAnimatedTransitioning` + 交互控制器实现视差。
- 工程由 Windows 环境生成，最终需在 macOS + roothide Theos 真机编译验证。

## ⚠️ PreferenceLoader 设置面板「自定义 cell 类」硬性禁令 + 头文件可用性铁律（实测 5+ 次）
- **绝对不要用 `cellClassForSpecifier:` 把 specifier 换成自定义 cell 类**。框架按 specifier 的 `cell` 类型向该 cell 发类型专有方法，自定义类不认 → 未识别 selector → SIGABRT 闪退（栈顶 `-[PSListController tableView:cellForRowAtIndexPath:]`）。`setValue:forUndefinedKey:` 只能挡 KVC、挡不住直接消息，无效。
- **头文件可用性（本仓库 CI 用的 theos/headers 集合，已逐一核对 PSSpecifier.h / PSTableCell.h）**：
  - ✅ 已声明、可放心用：`PSSwitchCell`、`PSGroupCell`、`PSTitleValueCell`、`PSLinkCell`、`PSButtonCell`、`PSStaticTextCell`、`PSSliderCell`、`PSEditTextCell`、`PSSegmentCell`。
  - ❌ **未声明、绝不能用**：`PSApplicationCell`（直接 `cell:PSApplicationCell` → undeclared identifier → `-Werror` 编译失败、CI 不出 .deb，用户装旧崩溃版 = 「还崩且无新日志」）。早前误判「PSTitleValueCell 可能未声明」是错的——它实际已声明可编译。
- **要显示 App 图标（黑白名单列表）的正确姿势**：用 `PSTitleValueCell`（roothide/headers 已声明）+ `[s setProperty:icon forKey:@"iconImage"]`（`PSIconImageKey` 可能未声明，用字面量最稳），`icon` 用 `UIImage imageWithContentsOfFile:` 从 `.app` 包图标文件直接读（解析 `CFBundleIconName`/`CFBundleIcons`/`CFBundleIconFiles`，带 @2x/@3x 候选），**无私有 API、不碰 PSApplicationCell**。点按切换**不要**用 `[s setAction:]`（roothide/headers 的 PSSpecifier 未声明该方法 → 编译失败），改由控制器 `tableView:didSelectRowAtIndexPath:` 重写处理；选中态借 `tableView:willDisplayCell:` 设 `accessoryType=UITableViewCellAccessoryCheckmark`。
- 对照事实：`2518905`(纯原生 PSSwitchCell) 用户确认「可以进了」；所有「换自定义 cell 类」版本全崩；`0019c06`(`PSApplicationCell` 未声明)、`7422326`/`e08f007`(真正原因 = `setAction:` 未声明，非 PSIconImageKey) 均 CI 失败不出包；最终修复版 `70b5167`（PSTitleValueCell+字面量 iconImage+`didSelectRowAtIndexPath` 切换）CI 已验证 success，为当前稳定版。
- **⚠️ 重写 PSListController 的 `tableView:willDisplayCell:forRowAtIndexPath:` 时【绝不可】调用 `[super ...]`**：本环境 `PSListController`（根链 PSListController→...→NSObject）**未实现**该方法，`[super tableView:willDisplayCell:...]` 会一路找不到 IMP → `doesNotRecognizeSelector` → `NSInvalidArgumentException` 闪退（栈顶 `ObackWhiteListController tableView:willDisplayCell:...: unrecognized selector`）。这是 `04a817e` 修掉的真·崩溃（用户装 `2e74dec` 进列表即崩的新日志 14:19 实锤）。`tableView:didSelectRowAtIndexPath:` 同理要 `if ([super respondsToSelector:@selector(...)])` 防护后再调 super。

## ⚠️ 主 tweak 全局 `presentViewController:` 劫持 = 多 App 黑屏元凶（commit e414382 引入，1dc096d 根治）
- **现象**：不止包管理器——**任意第三方 App 做「弹出页面/操作」时整页黑屏**，非崩溃、可上滑回桌面；卸载插件或开白名单不选 App（isAllowed=NO）即正常。日志实测（`oback_debug.log` 2026-07-23）：`shouldBegin` 永远 `NO (不在边缘)`，且用户触摸点 x 多在 25~32pt。`Oback: 已注入 com.tencent.xin` 等第三方 App 都注入成功。
- **根因（更广）**：`%hook UIViewController presentViewController:...` 给**每一个**被 present 的 VC 换 `transitioningDelegate` 为自写 `ObackTransitioningDelegate`。iOS 13+ 绝大多数 modal 是 `UIModalPresentationPageSheet`，硬套我们的「全屏视差」`animationControllerForDismissedController:` 后，dismiss 转场损坏 → 黑屏。包管理器只是其中最显眼的一类。该 hook 被 `isAllowed` 门控，所以"白名单空→isAllowed=NO→不注入→正常"对得上。
- **根治（1dc096d）**：**彻底删除全局 `presentViewController:` hook**；改在 `ObackManager.beginTransition:` 检测到 modal dismiss 时，**仅手势触发那一刻**才给 `top.transitioningDelegate` 注入 `ObackTransitioningDelegate`（手势结束后 `_currentTD=nil` 释放）。这样普通 App 的 modal 转场完全不被打扰 → 黑屏消失；边缘滑动 dismiss 仍带视差。⚠️ **从此严禁再写全局 presentViewController 劫持**——任何"给所有 present 注入转场"的做法都会复现黑屏。
- **配套**：`ObackTransitioningDelegate` 的 `@interface` 移到 `ObackTransition.h`（Tweak.xm 与 ObackManager.m 共用），Tweak.xm 仅留 `@implementation`。

## ⚠️ 系统进程排除必须用前缀 `com.apple.*`（大小写陷阱，1dc096d 修）
- **现象/根因**：`%ctor` 原排除名单写 `com.apple.SpringBoard`（大写 S），但系统真实 bundle id 是 `com.apple.springboard`（**小写**），大小写不匹配 → SpringBoard 没被排除 → 误注入，连带 PosterBoard/Spotlight/各种 extension 等一堆系统进程都被挂手势（`oback_debug.log` 实锤：`start called, bid=com.apple.springboard` 且给 `SBCoverSheetWindow`/`SBMainSwitcherWindow` 等挂了 pan）。
- **修复**：`%ctor` 改用 `if ([bid hasPrefix:@"com.apple."]) return;` 排除一切 Apple 系统进程（最稳，无视大小写/新增 extension），再加包管理器集合（`org.coolstar.Sileo`/`com.sileo.sileo`/`xyz.willy.Zebra`/`com.saurik.cydia`/`org.telesphoreos.installer`/`com.aboutsy.saily`）。边返回只服务于第三方 App，系统 UI 不该挂手势。

## ⚠️ 边缘手势触发宽度 `triggerWidth` 不能太小（1dc096d 改 24→40）
- **现象/根因**：`ObackParams.defaults.triggerWidth=24`，但真机用户从屏幕"感觉是边缘"处起滑，实际触摸点 x 多在 **25~32pt**（日志实锤一堆 `shouldBegin=NO (不在边缘: x=25~32)`），刚好落在 24 之外 → 手势永不 begin → 主功能"没效果"、胶囊也不出现。
- **修复**：默认 `triggerWidth=40`（足够覆盖 25~32 的自然起滑点；仍由 scrollView 冲突判定让位横向滚动）。⚠️ 若以后调小，务必 >=35，否则真机几乎触发不了。

## ⚠️ nav pop 动画仅手势时接管（1dc096d 改）
- `ObackNavDelegate animationControllerForOperation:` 原来对所有 `UINavigationControllerOperationPop` 返回 `ObackAnimator`（即普通"返回按钮"也套视差）。改为**仅当 `[ObackManager shared].interacting`（手势驱动）时**才返回 `ObackAnimator`，否则 forward 给 original（App 原生转场）。降低回归面、避免潜在黑屏；边缘滑动返回仍带视差，系统返回按钮走原生。

## ⚠️ 主功能「没效果」头号坑：`whitelistMode` 默认误设为白名单模式（commit f834b31 修）
- **现象**：装了最新包、设置面板一切正常，但**所有 App 的边缘返回手势都不触发**——主功能"没效果"。
- **根因**：`ObackPreferences.isAllowed` 里 `whitelistMode` 默认是 `YES`（白名单模式），且 `Root.plist` 的「启用白名单」开关 `<default>` 也是 `<true/>`。白名单模式下 `isAllowed` 仅当当前 App 的 bundle id 在 `whitelistApps` 里才返回 YES；否则返回 NO → `ObackManager` 的 `gestureRecognizerShouldBegin:` 直接 NO → 手势永不启动。若用户没把测试 App 加进白名单（或白名单为空），**所有 App 都不生效**，完全符合"主功能没效果"。
- **与"全局注入"目标矛盾**：项目目标是「全局注入」的 OPPO 风格系统手势，白名单应是可选细化，不该是默认。
- **修复**：`isAllowed` 默认 `NO`（全局/黑名单模式，所有 App 生效、仅排除 `blacklistApps`），`Root.plist` 开关 `<default>` 改 `<false/>`，并更新 footer/footnote 文案说明默认全局。已落地 `f834b31`（CI run #47 success，版本 `0.1.0+f834b31`）。
- **验证要点**：默认（开关关）即所有 App 有边缘返回；用户若要"仅指定 App 生效"，才开「启用白名单」并去「选白名单程序」里勾选。改此项后无需碰手势代码本身——管道（window 级 pan → isAllowed 门控 → pop + 自定义转场）在全局模式下本身是对的。
- **设置列表 UI 同步优化（同 commit f834b31）**：① 图标从 40pt 缩到 **29pt**（同系统「设置」App 列表图标尺寸）；② 图标按 bundle id **缓存**（`_iconCache`），点按切换不再每次 reload 都重读 .app 包图标 → 选择明显变快；③ 选中项在各组**置顶**（`_sortSelectedFirst:`，toggle 时 `_specifiers=nil` 触发重建）；④ `reloadSpecifiers` 前清空 `_specifiers` 让排序生效。

## ⚠️ Theos `control` 文件版本号注入坑（commit dc6842d 实测）
- **Theos 的 `control` 不支持项目级 Makefile 变量替换**：在 `control` 里写 `Version: $(OBACK_VERSION)` 并在 Makefile 顶部定义 `OBACK_VERSION := ...` 会被替换成**空字符串**，导致 `ERROR: package version  doesn't contain any digits` → 构建失败（`dc6842d` 实测）。Theos 在独立 make 求值上下文处理 control，读不到项目级变量。
- **正确做法**：`control` 保持静态 `Version: 0.1.0`；在 CI（build.yml）构建前用 `sed -i '' "s|^Version:.*|Version: 0.1.0+$HASH|" control` 直接注入 git 短哈希（`HASH=$(git rev-parse --short=7 HEAD)`）。已落地 `2e74dec`，构建成功且 notice 注解确认版本 = `0.1.0+<短哈希>`。本地构建保持 `0.1.0`。
- 验证技巧：在 build.yml 构建步骤末尾 `echo "::notice::Oback package version = $(dpkg-deb -f "$ROOTHIDE_DEB" Version)"`，可通过匿名可读的 check-run notice 注解确认实际打出的版本号（普通 stdout 匿名访问 403 读不到）。

## ⚠️ MRC 铁律：tweak 是手动引用计数，绝对禁止 `__weak`（commit 5acd91a 实测）
- **现象/根因**：CI 编译 `ObackManager.m` 报 `error: cannot create __weak reference in file using manual reference counting`（行 253）。tweak 入口 `.xm`/`.m` **未开 `-fobjc-arc`**，整个工程是 **MRC（手动引用计数）**。`__weak` 在 MRC 文件里**直接编译失败**（并非 warning，`-Werror` 下必挂、不出 .deb）。`@property (weak)` 在 MRC 下合成同样报错。
- **为什么之前没踩**：之前写 block（如 dismiss completion）习惯用 `__weak` 防循环引用，是 ARC 思维惯性；MRC 下这套写法立刻编译失败。
- **正确写法**：MRC 下若要 block 引用对象且担心循环引用，改**强引用 + 确认无反向持有**（block 由系统 API（如 `dismissViewControllerAnimated:completion:`）短暂持有，被引用对象不反向持有该 block 即无环，也不会泄漏）；或 MRC 下用 `__block`（不 retain）。**绝不要写 `__weak`**。`.h` 的 property 统一用 `assign`/`retain`（本工程已统一 `assign`，如 `ObackTransitioningDelegate.original`）。
- **加固经验**：bc0e014 给 modal dismiss 的 completion 写 `__weak UIViewController *weakTop = top`，5acd91a 改成直接强引用 `top`（无环），编译通过。
- **⚠️ 改代码自检**：任何新增/修改的 `.m`/`.xm`/`.h`，提交前 grep 一遍 `__weak` / `@property (weak`，有就删掉换成强引用或 `assign`。CI 默认 `-Werror`，任何 MRC 违例都会编译失败不出包、用户装旧版=「还崩/没效果但无新日志」。

## 🌙 跨电脑续作交接（2026-07-23 晚，更新至 5acd91a）
- 最新主线 commit = `5acd91a`（已 push `main`，版本 `0.1.0+5acd91a`）。本仓库 `.workbuddy/memory/` 已通过 `.gitignore` 放行进 git，另一台电脑 `git pull` 后可见完整项目记忆与交接状态（README.md 末尾也有同题人肉可读章）。
- 待真机验证：`5acd91a`（= bc0e014 黑屏/无法操作加固 + MRC __weak 编译修复）。核心修复：① `_dimView` 遮罩关触摸拦截；② modal dismiss 转场加 `interacting` 闸门（与 nav 对齐）；③ dismiss 完成安全还原 delegate；④ 补转场完成/取消诊断日志。回家第一件事：装 `0.1.0+5acd91a` 验证返回后不黑屏、界面可操作；若仍复现，取 `/var/mobile/oback_debug.log` 发我（新日志含 `interactive transition finished/cancelled`）。
- 诊断日志：`/var/mobile/oback_debug.log`（删旧 → 复现 → Filza 取回发我）。
- 构建：push `main` 自动 GitHub Actions 出 roothide `.deb`；或 macOS + roothide theos 本地 `make package`。
- 改代码前必读上方「⚠️」各硬规则节（presentViewController 劫持禁用 / 自定义 cell 类禁用 / PSApplicationCell 未声明 / setAction: 未声明 / willDisplayCell [super] 必崩 / triggerWidth≥35 / control 用 sed 注入 / **MRC 禁止 `__weak`**）。
