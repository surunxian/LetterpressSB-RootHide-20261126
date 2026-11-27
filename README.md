# Letterpress isolate4 — 保留计算／临时不绘制粒子的对照包

版本：`0.1.0~test8+isolate4`。这是 RootHide SpringBoard 插件的临时视觉隔离版，**不是已证实的亮屏修复版**。

## 与 isolate3 的唯一受控行为差异

以已交付的完整粒子30目标版 isolate3 为基线，在固定Vortex源码的Canvas回调中保留 `particleSystem.update(date:drawSize:)`，仅抑制紧随其后的逐粒子 `draw(...)` 调用。该差异从挂载起持续生效、贯穿整段锁屏和亮屏测试；没有“收到亮屏通知后等两秒”的定时门控。

- 保留 Timeline、Canvas入口、Reader、粒子系统初始化／参数／更新代码、原辅助歌词及布局动画。
- 保留 isolate3 的30目标以固定对照条件；本次不再试更低帧率。
- 窗口、scene、secure、SBS、截图容器、锁屏和钥匙串门控、媒体读取、播放器选择、设置默认与持久配置均不改。
- 不改physics、delta、burst规则或隐藏暂停；不移除Vortex分支，不混入宿主改造。
- 仅诊断报告构建身份随版本更新，诊断算法不改。**本次不要求再导出诊断JSON。**

**预期：没有粒子，辅助歌词可显示。** 不要把此现象当作显示故障，也不能把永久去掉粒子当最终解决。源码保留update不保证运行时调度／计算量完全相同；空绘制可能影响SwiftUI的优化和实际Canvas回调。

## 手动安装与有效对照

1. 覆盖安装本DEB，确认RootHide允许SpringBoard注入，并按原流程注销。不会自动安装或修改手机配置。
2. 保持同一播放器、同一首歌、原设置与粒子参数。若辅助歌词原本未开启，手动打开既有“启用辅助标签”；该默认值仍false，本包不替你改。
3. 确认**播放时确实出现辅助歌词**，而没有粒子。整页空白不能算有效的文字／运行对照。
4. 在持续播放情况下，锁屏5–10秒后亮屏，重复两轮。反馈：**整屏亮起是否还延迟、辅助歌词是否正常**。不用重复导诊断报告。
5. 若需与原完整效果复核，手动安装此前 isolate3 并注销，保持相同条件。需要回到歌词正常的无粒子挂载版本，可手动安装 isolate2 并注销。安装其他版本前确认是同一插件，不叠加多个实验副本。

若本版正常，只提高逐粒子绘制／符号解析／其合成交互的优先级，不能锁定具体GPU、RenderBox函数或排除宿主；若仍慢，继续细分Timeline／Canvas／模拟与宿主，而不是声称整个Vortex已排除。

## 发布与限制

身份不变：Letterpress／82Flex；包及偏好域 `com.82flex.letterpress`；保留既有资源与许可证。构建来自现有公开GitHub仓库的标准免费macOS runner，实际commit／run／签名检查以同目录 `build-run.json` 和 `RELEASE_CHECKS.json` 为准。源码ZIP包含本版构建适配脚本及精确哈希，旧发行不覆盖。

本版尚未经目标设备验证，不保证亮屏已修复，不证明update回调频率与完整绘制版一致，不采集或自动上传用户诊断。

## Build

Use the unchanged `apple-build.yml` workflow with macos-15 / Xcode 16.2. `Port/Build/build_macos.sh` verifies a fresh pinned Vortex checkout, copies it privately, adapts resources, then applies and records one reversible draw-call suppression. No physics or timing source edits are permitted. Native signatures, dSYM and package checks remain required.
