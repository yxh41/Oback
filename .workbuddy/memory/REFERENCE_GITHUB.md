# Oback 参考调研：GitHub 同类项目与架构借鉴

> 调研时间：2026-07-25
> 目的：为 Oback（roothide iOS 16.4.1 边缘返回 tweak）寻找可借鉴的成熟方案，解决当前"底部空白/残留/冻结"并预防未来同类问题。

## 一句话结论

Oback 当前架构（自定义 `UIViewControllerAnimatedTransitioning` 把目的页 `toView` reparent 进 `containerView`）
**本身就是 bug 温床**。GitHub 上所有成熟的"边缘/全屏返回"库（FDFullscreenPopGesture、YLFullscreenSlider、BBGestureBack、PanCake）
**都不自己实现自定义转场**，而是**直接劫持系统原生的 `interactivePopGestureRecognizer`**。这样 `toView` 永远由 UIKit 原生处理，
根本不会出现空白 / 导航栏损坏 / scrollView 错位。这正是根治当前问题的方向。

## 核心可借鉴技术：驱动系统原生 interactivePop 手势

```objc
// 取系统手势的私有 target + action（所有成熟库的共同做法）
id targets = [nav.interactivePopGestureRecognizer valueForKey:@"_targets"];
id target  = [targets.firstObject valueForKey:@"target"];
SEL action  = NSSelectorFromString(@"handleNavigationTransition:");
// 自己的边缘 pan 挂到系统手势的 view 上，调用同一个 action
UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:target action:action];
[nav.interactivePopGestureRecognizer.view addGestureRecognizer:pan];
```

→ 系统原生 pop 转场运行，`toView` 由 UIKit 原生呈现与清理 → 彻底消除空白/导航栏损坏/scrollView 错位。

## 参考项目清单

| 项目 | 类型 | 可借鉴点 |
|------|------|----------|
| **FDFullscreenPopGesture** (wangyingbo) | 最流行库 | scrollView 冲突正解：`gestureRecognizer:shouldRecognizeSimultaneouslyWithGestureRecognizer:` 在 `contentOffset.x<=0` 时返回 YES（朋友圈/横向滚动问题） |
| **YLFullscreenSlider** | 系统手势劫持 | 9 行核心代码；**明确警告"根控制器触发返回会假死"** → 手势 `viewControllers.count<2` 时必须 NO |
| **BBGestureBack** (FKLam) | 全屏返回 | TabBar 磨砂布局错乱修复（iOS12+）；scrollView/tableView/CollectionView 同时识别；iPhone X 圆角风格参数 |
| **PanCake** (lwlsw) | **越狱插件** | 全局手势注入 + 设置(灵敏度) + **键盘弹出禁用手势**（防误触丢输入）。最接近 Oback 的越狱全局场景 |
| **Protip blog + StackOverflow** | 技术文 | 自定义转场正确顺序：先 `[container addSubview:toView]` + `layoutIfNeeded` + `finalFrameForViewController:`，**再** `snapshotViewAfterScreenUpdates:YES`，最后动画快照（d3842e0 用错参数：NO 且没先 add toView） |

## 当前空白 bug 的两种根治架构

**方案 A（强烈推荐，最稳）—— 驱动系统原生 interactivePop**
- nav pop 不再走 `ObackAnimator` 自定义转场；左右边缘各挂一个 pan 调 `handleNavigationTransition:`。
- 边缘胶囊指示器（`ObackEdgeIndicator`）保留作视觉反馈；系统自带温和视差。
- 顺带根治：导航栏损坏、TabBar 磨砂错乱、scrollView 错位 —— 全部由 UIKit 原生处理。
- 根控制器 / 横向滚动冲突 / 键盘误触 等未来问题也一并规避（见下）。

**方案 B（保留 OPPO 强视差）—— 修正现有快照顺序**
1. `[container addSubview:toView]`
2. `toView.frame = [ctx finalFrameForViewController:toVC]; [toView setNeedsLayout]; [toView layoutIfNeeded];`
3. `UIView *snap = [toView snapshotViewAfterScreenUpdates:YES];`
4. `toView.hidden = YES;` 动画快照（像素，安全）
5. 收尾：移除快照、`toView.hidden = NO`、`completeTransition:`

> 注：d3842e0 实际误用了 `snapshotViewAfterScreenUpdates:NO` 且未先 add toView，故快照恒为 nil、每次回退重挂载真实 toView —— 与未修无异。

## 未来会遇到的问题（参考已踩过的坑）+ 预防

1. **导航栏在快速交互 pop 时损坏** → transitionCoordinator 监控 + 修复 nav bar layer 动画（已知 issue）。方案 A 天然规避。
2. **根控制器触发返回 → 假死**（YLFullscreenSlider 明确警告）→ shouldBegin 里 `viewControllers.count<2` 直接 NO。
3. **scrollView 横向冲突（朋友圈）** → 用 `shouldRecognizeSimultaneouslyWithGestureRecognizer:` 模式（FDFullscreenPopGesture），比 Oback 的 shouldBegin 让步判断健壮。
4. **键盘弹出误触返回丢输入** → PanCake 方案：键盘可见时禁用手势。
5. **TabBar 磨砂布局错乱**（iOS12+）→ 方案 A 规避；方案 B 需额外处理。
6. **RTL 布局** → FMFullscreenPopGesture 已支持。
7. **导航栏显示/隐藏切换转场**（with bar ↔ without bar）→ FDFullscreenPopGesture view-controller-based 方案。

## 建议

先把 nav pop 切到**方案 A**（驱动系统手势）—— 一次性根除当前所有空白/残留/冻结类问题，与社区十年经验一致。
OPPO 的"强视差"可先用边缘胶囊 + 系统视差顶着，真机验证稳定后再决定是否上方案 B 做增强。

**待决策**：要我直接重构 nav pop 到方案 A，还是保留 OPPO 强视差、先用方案 B 的正确快照顺序修掉当前空白？
