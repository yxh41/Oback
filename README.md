# Oback — OPPO 风格边缘手势返回（roothide / iOS 16.4.1）

在 iOS 16.4.1 **roothide** 越狱环境下实现类 OPPO 的「边缘内滑返回」：
左右边缘内滑触发返回，当前页平移、上一页带**阴影 + 轻微缩放 + 遮罩**从对侧探出（视差动画）。
全局注入所有 App，支持导航栈 `pop` 与模态 `dismiss`，并带 PreferenceLoader 设置面板。

---

## 工程结构

```
手势/
├── Makefile                      # roothide 打包配置
├── control                       # Debian 包信息
├── Oback.plist                # 注入过滤（com.apple.UIKit → 全局）
├── Tweak.xm                      # 注入点：nav delegate / present / 启动管理器
├── ObackManager.h/.m          # 全局手势管理器：边缘判定 / 路由 / 黑名单
├── ObackTransition.h/.m       # OPPO 视差动画引擎（动画 + 交互控制器）
├── ObackPreferences.h/.m      # 从设置域实时读取参数
├── layout/Library/PreferenceLoader/Preferences/ObackSettings.plist   # PreferenceLoader 入口(isController 风格)
├── Preferences/                  # 设置子工程（编译型 bundle，由 SUBPROJECTS 随 tweak 一起打进 roothide .deb）
│   ├── Makefile                  # BUNDLE_NAME = ObackSettings → 安装到 /Library/PreferenceBundles
│   ├── ObackSettings.plist       # bundle 的 Info.plist（CFBundleIdentifier=com.zlhkf.oback, NSPrincipalClass=ObackSettingsController）
│   ├── ObackSettingsController.h/.m  # PSListController 子类，从 Resources/Root.plist 加载控件
│   └── Resources/Root.plist      # 设置面板定义（每个控件 cell 带 defaults=com.zlhkf.oback，与 ObackPreferences.m 读取域一致）
└── README.md
```

## 构建（需在 macOS + roothide Theos 上执行）

1. 安装 roothide 版 Theos：
   ```bash
   bash -c "$(curl -fsSL https://raw.githubusercontent.com/roothide/theos/master/bin/install-theos)"
   ```
2. 编译并打包（Makefile 已写死 `THEOS_PACKAGE_SCHEME := roothide`）：
   ```bash
   cd 手势
   make clean
   make package
   ```
   若想用环境变量方式，也可：
   ```bash
   THEOS_PACKAGE_SCHEME=roothide make package
   ```
3. 产物在 `packages/` 下（`.deb`），用 Sileo/Zebra 安装，或 `make install`（需配 THEOS_DEVICE_IP）。

> 注：当前工程是在 Windows 环境生成的，**未经过真机编译**。请在 Mac 上 `make` 通过后，用 Xcode 组织区 / 设备日志排查编译错误再上机。

## 真机验证步骤

1. 安装 deb，重启 backboardd（安装后自动执行 `killall -9 backboardd`）。
2. 进入「设置 → Oback」确认开关已开。
3. 打开任意带导航栏的 App（如设置、备忘录），从**左/右边缘**内滑：
   - 应看到当前页右移、上一页带阴影+缩放从左侧探出；
   - 滑动超过约 40% 或快速一甩即返回，否则回弹。
4. 模态页面（如分享面板）从边缘内滑应能 dismiss。

## 已知需真机调优点（务必上机后处理）

- **取消后的视图恢复**：`ObackInteractiveTransition` 在 `cancel` 时调用
  `completeTransition:NO`，部分导航栈/模态下可能出现上一页残影或当前页未归位。
  如遇到，尝试在 `cancel` 的 completion 里显式把 `toView` 从 container 移除，
  或改为只重置 transform 不重排视图层级。
- **与原生手势冲突**：已在 `setDelegate:` 里关闭系统 `interactivePopGestureRecognizer`；
  但 iOS 13+ 的模态下滑 dismiss 仍可能与右边缘手势叠加，必要时在 `presentViewController:` 里
  对特定 `modalPresentationStyle` 跳过注入。
- **横滑列表冲突**：已对「左边缘且横向已滚动」的情况放行，右边缘未做同样处理，可按需补充。
- **键盘/弹窗窗口**：手势会挂到所有 keyWindow 上，键盘窗口无 rootViewController 会自动跳过。
- **present 样式**：对 `formSheet`/`popover` 注入转场可能表现异常，可加白名单过滤。

## 设计要点

- **动画引擎**（`ObackTransition`）：不依赖私有 API。`OBApplyParallax` 按百分比
  摆位当前页（平移）与上一页（对侧探出 + 缩放 + 遮罩），`ObackAnimator` 负责按钮触发的
  非交互动画，`ObackInteractiveTransition` 负责手势拖动的百分比驱动，二者共用同一套视差。
- **转发代理**：`ObackNavDelegate` / `ObackTransitioningDelegate` 保留 App 原有
  delegate，只拦截 pop / dismiss 的动画与交互方法，向前兼容 App 自身逻辑。
- **全局注入**：filter 挂 `com.apple.UIKit`，所有 App 进程都会加载；管理器在
  `UIApplicationDidFinishLaunchingNotification` 后把全屏 `UIPanGestureRecognizer` 挂到 keyWindow，
  并用 `UIWindowDidBecomeKeyNotification` 跟随窗口切换。

## 参考仓库

- [LuckyPia/Flashback](https://github.com/LuckyPia/Flashback) — 第三方全局手势返回库（管理器/配置项思路）
- [forkingdog/FDFullscreenPopGesture](https://github.com/forkingdog/FDFullscreenPopGesture) — 全屏返回、破解系统边缘限制
- [banchichen/TZScrollViewPopGesture](https://github.com/banchichen/TZScrollViewPopGesture) — scrollView 与返回手势共存
- [AnthoPakPak/PanCake](https://github.com/AnthoPakPak/PanCake) — tweak 层全局 interactive dismiss
- 掘金《iOS 手势滑动返回总结》—「截图栈 + 视差」经典实现思路
- [roothide/Developer](https://github.com/RootHide/Developer) — roothide tweak 构建文档

## 免责声明

本工程仅用于学习与研究，请在自己拥有且已越狱的设备上使用。roothide 默认不注入 SpringBoard，
手势工作在 UIKit 层（App 内）生效。

---

## 🌙 跨电脑续作交接（2026-07-23 晚）

> zlhkf 在 A 电脑推进到此处，今晚回家用 B 电脑继续。本仓库已开启 CI 自动构建（push 到 `main` 即触发 GitHub Actions 出 roothide `.deb`）。

### 当前最新状态
- **最新 commit**：`1dc096d`（已 push 到 `main`，远端 HEAD = `1dc096d`）
- **最新出包版本号**：`0.1.0+1dc096d`（CI 自动把 commit 短哈希注入 `control`，下 artifact 时认这个号区分新旧）
- **用户尚未真机验证 `1dc096d`**（这版修了两大问题：黑屏 + 边缘触发宽度）

### `1dc096d` 修了什么（根因级）
1. 删除全局 `presentViewController:` 劫持 → 普通 App 弹窗不再黑屏（之前任意 App 弹页面都黑屏、可上滑回桌面）。
2. modal dismiss 的视差转场改为「仅手势触发那一刻」注入，手势结束自动释放 → 边缘滑动返回照样有动画。
3. `%ctor` 系统进程排除改用前缀 `com.apple.*`（修掉 `com.apple.SpringBoard` 大写 S 误注入、导致一堆系统进程被挂手势）。
4. `triggerWidth` 24 → 40（用户自然起滑点多在 25~32pt，现在能稳稳触发，胶囊也会显示）。
5. nav pop 动画仅手势驱动时接管，系统返回按钮走原生（求稳，避免回归）。

### 回家第一件事：真机验证 `1dc096d`
- 装 `0.1.0+1dc096d`：任意 App 进二级页，从屏幕最左/最右 40pt 内滑 → 应见胶囊箭头 + 上一页被拉出。
- 做「弹出页面」操作（如弹窗）→ 应**不再黑屏**。
- 系统 UI（桌面/设置/控制中心）不受影响。
- 诊断日志仍在写 `/var/mobile/oback_debug.log`；复现问题前用 Filza 删旧日志、复现后取回发我。

### 待办 / 可能下一步
- 若某 App 边缘返回仍无效：看日志 `shouldBegin=YES` 是否出现；个别 App 可能内部禁用返回或自定义转场。
- 想要「点系统返回按钮也带视差」可后续单加（当前为求稳，按钮走原生）。
- 设置面板黑白名单 UI 已稳定（29pt 图标、用户/系统分类、选中置顶、顶部计数），要调大小再改。

### 硬规则（改代码前必读，详见 `.workbuddy/memory/MEMORY.md`）
- **禁用全局 `presentViewController:` 劫持**（必黑屏，已踩过）。
- **禁用自定义 cell 类 / `cellClassForSpecifier:` 换类**（必 SIGABRT）。
- **`PSApplicationCell` 未声明**（编译失败）；用 `PSTitleValueCell` + 手动图标。
- **`setAction:` 未声明**（编译失败）；点按切换走 `didSelectRowAtIndexPath:`。
- **`PSListController` 未实现 `willDisplayCell:`**（`[super ...]` 必崩）；`triggerWidth` 勿 < 35。
- **`control` 版本号用 CI `sed` 注入**，勿用 `$(VAR)`（Theos 读不到项目级 Makefile 变量）。
