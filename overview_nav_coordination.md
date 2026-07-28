# 导航栏协同引擎 — 落地完成（feat/navbar-coordination 分支）

> 状态：**未编译原型**。Windows 无法编译 iOS tweak，需 macOS + roothide theos + iOS 16.4.1 真机验证。
> 分支 `feat/navbar-coordination`，`main` 未动（仍为稳定基线 `9bf479e` / `0.1.0+9bf479e`）。

## 问题回顾
「导航视差（实验）」开关（`navParallaxEnabled`）此前有两个未解病灶：
1. **双驱动打架**：开启时 `beginTransition` 仍调系统私有 `handleNavigationTransition:` 启动原生交互 pop，同时自定义 `ObackAnimator` 也被 `updateWithPercent:` 驱动 → 两源争抢 `fractionComplete`（抖动/不稳定）。
2. **导航栏损坏（固有风险）**：纯自定义 nav 转场只拿到 `fromView/toView`，活 `UINavigationBar` 由 nav controller 私有持有、不随内容转场 → "内容/bar 不同步"。这正是 `60352e6` 当初证伪纯自定义方案的根因。

## 本次完成的两件事

### 1. 双驱动根治（ObackManager.m）
- `beginTransition`：`if (currentParallaxToView)` → `if (currentParallaxToView && ![ObackPreferences navParallaxEnabled])` 才启动系统原生 pop。
- `triggerTransitionInWindow:` nav 分支：`if (self.interacting)` → `if (self.interacting && ![ObackPreferences navParallaxEnabled])` 才忽略重复 `popViewControllerAnimated:`；否则开启时由 `popViewControllerAnimated:` 触发**纯自定义交互转场**（ObackNavDelegate 返回自定义 animator + interactive controller，单驱动）。
- 默认（关）路径字节级不变，零回归。

### 2. 导航栏协同引擎真正接入（ObackTransition.m / .h / Tweak.xm）
此前 `restoreNavBar` 已定义却**从未调用** → 自定义 pop 后活 bar 会永久隐藏。本次补齐调用：
- `interruptibleAnimatorForTransition:` 的 `addCompletion:`（防御性）
- `forceFinishIfNeeded` 的 UIView completion 块（主路径）
- `forceFinishIfNeeded` 的 `dispatch_after(0.3s)` 保险块（防 completion 不触发时 bar 永久隐藏）

**引擎机制**：
- `_setupNavBarCoordinationFromVC:toVC:container:`（仅 navParallax 开 + `parallaxToView=YES`）：`snapshotViewAfterScreenUpdates:NO` 拍活 bar 快照 → 隐藏活 bar → 快照以 `zPosition=1000` 叠到 container 顶层。
- 转场中快照随内容淡出（`addAnimations:` 设 alpha→0；`forceFinishIfNeeded` 通用子视图淡出循环同样覆盖）。
- `restoreNavBar`（幂等）：移除快照 + 恢复活 bar。

**Tweak.xm**：同步更新 `animationControllerForOperation:` 注释，说明开启路径不再走 `handleNavigationTransition:`、改由 `popViewControllerAnimated:` 单驱动。

## 改动文件
| 文件 | 改动 |
|------|------|
| `ObackTransition.h` | 新增 `navBarSnapshotView`(retain) / `navControllerForBar`(assign) 属性 + `restoreNavBar` 声明 |
| `ObackTransition.m` | `#import ObackPreferences.h`；`_setupNavBarCoordination…` / `restoreNavBar` 两方法；三处收尾接入 `restoreNavBar`；快照淡出 |
| `ObackManager.m` | `beginTransition` + `triggerTransitionInWindow:` 两处 `navParallaxEnabled` 门控 |
| `Tweak.xm` | `animationControllerForOperation:` 注释同步 |

## 待办（验收前勿 merge main）
1. macOS 本地 `make package` 或 push 触发 CI 出 roothide `.deb`。
2. 真机 iOS 16.4.1 装包、**开启「导航视差（实验）」**，多 App 验：
   - 导航栏标题/返回按钮是否跟手、有无跳变（协同核心）；
   - 离屏图铺底分支（Filza/微信/普通 App）有无空白/错位；
   - 冻结/底部空白。
3. 验收通过后再决定是否 merge 或保留分支。
4. 临时 PAT（见 memory）仍须去 GitHub revoke。
