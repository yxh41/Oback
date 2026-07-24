# Oback 项目记忆（roothide / iOS 16.4.1，开发者 zlhkf）

iOS 越狱 tweak，OPPO 风格边缘手势返回（左右边缘内滑+视差），全局注入，带 PreferenceLoader 设置面板。Theos(Logos)+ObjC，注入 `com.apple.UIKit`。Windows 生成，需 macOS+roothide theos 真机编译验证。

## 铁律：PreferenceLoader 设置面板（已稳定）
- **禁 `cellClassForSpecifier:` 换自定义 cell 类** → 框架发类型专有方法给自定义类 → 未识别 selector → SIGABRT 闪退。
- **头文件可用性（CI theos/headers 已核对）**：✅ 可用 `PSSwitchCell/PSGroupCell/PSTitleValueCell/PSLinkCell/PSButtonCell/PSStaticTextCell/PSSliderCell/PSEditTextCell/PSSegmentCell`；❌ **绝不能用 `PSApplicationCell`**（undeclared identifier → `-Werror` 编译失败、CI 不出 .deb）。
- App 图标列表用 `PSTitleValueCell` + `[s setProperty:icon forKey:@"iconImage"]`（用字面量，勿用可能未声明的 `PSIconImageKey`）；icon 用 `UIImage imageWithContentsOfFile:` 从 .app 包图标文件读（解析 `CFBundleIconName`/`CFBundleIcons`/`CFBundleIconFiles`，带 @2x/@3x 候选）。
- 点按切换**勿用 `[s setAction:]`**（未声明 → 编译失败），改由控制器 `tableView:didSelectRowAtIndexPath:` 重写；选中态借 `tableView:willDisplayCell:forRowAtIndexPath:` 设 `accessoryType=UITableViewCellAccessoryCheckmark`。
- **重写 `tableView:willDisplayCell:forRowAtIndexPath:` 绝不可调 `[super ...]`**（PSListController 继承链未实现该方法 → `doesNotRecognizeSelector` 闪退）；`didSelectRowAtIndexPath:` 也要 `if ([super respondsToSelector:@selector(...)])` 防护后再调。

## 铁律：modal / 转场禁区（黑屏/无法操作根因）
- **禁止全局 `presentViewController:` 劫持**（e414382 引入 → 1dc096d 删）。给每个 present 换 `transitioningDelegate` 会破坏 pageSheet modal → 全 App 黑屏。
- **modal(`presentingViewController`) dismiss 禁止注入自定义视差转场**（8243bb8 根治）。把底层 presenting view 塞进 dismiss 转场容器做位移 → 层级错乱 → 黑屏/卡死。`oback_debug(3).log` 实锤微信 16:12 段 dismiss 连发 20+ 次且层级错乱。
- **正确做法**：modal dismiss 直接系统原生 `dismissViewControllerAnimated:YES completion:nil`（无跟手视差，100% 稳定）；手势**仅**给 nav pop 注入 `ObackAnimator` 视差（UIKit 管理干净、安全）。
- 方案B（未实施，备用）：若日后想恢复 modal 跟手视差，只移 fromView(sheet)、**绝不碰 toView(presenting)**。`ObackTransitioningDelegate`(Tweak.xm) 已留作 dead code 可复用。

## 铁律：系统进程 / 触发宽度 / nav
- 系统进程排除用 `if ([bid hasPrefix:@"com.apple."]) return;`（大小写无关，真实 SpringBoard bundle id 是小写 `springboard`）+ 包管理器集合（Sileo/Zebra/Cydia/Installer/Saily）。边返回只服务第三方 App。
- `triggerWidth` 默认 **40**（真机自然起滑点 x=25~32pt）；调小务必 ≥35，否则几乎触发不了。
- nav pop 动画**仅手势时**（`[ObackManager shared].interacting`）接管 `ObackAnimator`，系统返回按钮走原生。

## 铁律：默认全局生效 / 版本号 / MRC / 手势状态机
- `whitelistMode` 默认 `NO`（全局+黑名单）。`Root.plist`「启用白名单」`<default>`=`<false/>`。白名单是可选细化，非默认；否则主功能"没效果"。
- `control` 保持静态 `Version: 0.1.0`；CI 用 `sed -i '' "s|^Version:.*|Version: 0.1.0+$HASH|"` 注入哈希（`HASH=$(git rev-parse --short=7 HEAD)`）。本地构建保持 `0.1.0`。构建后 `echo "::notice::Oback package version = $(dpkg-deb -f "$ROOTHIDE_DEB" Version)"` 确认版本。
- **MRC 铁律**：tweak 入口 `.xm/.m` 未开 ARC，**禁止 `__weak` / `@property(weak)`**（`-Werror` 直接编译失败不出包）。block 引用改强引用+确认无反向持有，或 `__block`。提交前 grep `__weak` / `@property (weak)` 删掉。
- **手势状态机铁律**：自定义 `UIPanGestureRecognizer` 子类若在 `touchesMoved:` 里主动设 `self.state = Failed`（如纵向判定），则 `handlePan:` 的 switch **必须处理 `UIGestureRecognizerStateFailed`**——否则 Began 后 Failed 会导致胶囊/转场残留（endTransition 不被调用）。新增 `abortTransition:` 统一清理。

## 跨电脑续作交接
- 主线 `ac5b269`（已 push `main`，版本 `0.1.0+ac5b269`）。`.workbuddy/memory/` 已进 git，另一台 `git pull` 可见完整记忆与交接。
- 功能集：nav pop 视差+胶囊、modal dismiss 安全视差(方案B,只移 sheet 不碰 presenting)、返回灵敏度滑块真机可调(commitRatio/commitVelocity)、提交判定含惯性动量投影、扩展进程(NSExtension)跳过挂载、AppTool 冲突退避(仅 setDelegate 透传、手势不关)、triggerWidth=40、whitelistMode 默认 NO、MRC 禁 __weak。
- **待真机验证（最终集）**：① 各 App 边缘内滑返回灵敏（弹性阈值+滑块可调）；② 弹窗边缘滑 dismiss 带 sheet 视差无黑屏；③ 同时装 AppTool 不进安全模式；④ 设置面板滑块数值/极值显示正常。
- 诊断日志 `/var/mobile/oback_debug.log`（删旧 → 复现 → Filza 取回发我）。多版本混测靠「某次提交才加的日志行」区分新旧版现场。
- 构建：push `main` 自动 GitHub Actions 出 roothide `.deb`；或 macOS 本地 `make package`。
