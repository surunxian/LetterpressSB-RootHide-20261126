# Letterpress isolate5 — 完整基线上的单项计算隔离

版本 `0.1.0~test8+isolate5`，RootHide SpringBoard 插件。用户在2026-11-27确认 isolate4 仍有亮屏延迟后，要求先恢复完整状态，再逐项测试。本包不是正式修复版。

## 先完整恢复，再只改变一项

共同基线使用已冻结的 test8+diag2 完整实现：原绘制调用恢复、原 Vortex 目标60恢复，不沿用 isolate3 的30目标或 isolate4 的停绘制。HudFirefliesView、歌词、窗口、安全保护、SBS、scene、媒体、配置与默认值均与完整基线相同。

本次唯一受控行为改动：在私有固定 Vortex 副本的 Canvas 回调中，省略一处 `particleSystem.update(date:drawSize:)`。保留 Timeline、Canvas、symbols、Reader、原 draw 调用、初始化、参数和 burst 代码；不同时暂停 Timeline 或移除 Canvas。测试之间从共同完整基线重新派生，不累计上一包的删改。

**注意：保留粒子视图不等于恢复了正常动画。** 因每帧计算被停，本包粒子可能静止或不出现；辅助歌词仍应可显示。原 burst/属性回调仍在，不能把本实验叫作“所有粒子活动完全停止”。60只是原调度目标，不是设备实测帧率；跳过 update 也可能影响实际SwiftUI调度和负载。

## 手动安装与反馈

1. 同包ID覆盖安装，确认RootHide允许SpringBoard注入，按原流程注销。不自动安装，不删除或重置偏好。
2. 保持同一播放器、歌曲和原设置。如原“启用辅助标签”关闭，可手动打开；确认播放时真实辅助歌词出现。
3. 持续播放，锁屏5–10秒后亮屏，重复两轮。只需反馈整屏亮起是否仍延迟、歌词是否正常；不要求重复导JSON。
4. 不要因粒子静止或没有粒子就判断运行失败；也不要以整页空白算有效文字对照。

## 如何解释结果

若正常，仅支持 update 的执行及其引发的工作在此组合下值得重点排查，不证明物理算法哪一行就是根因；若仍延迟，说明仅跳过 update 仍不足，后续再独立测试时间轴或Canvas/符号视图与宿主的关系。Timeline驱动Canvas，Canvas提供绘制上下文，三者不是可随意互换的独立开关；后续实验需说明结构依赖，不能同时删除多项后作单一归因。

本包尚未经目标设备验证，不保证亮屏已修复。构建保持现有公开仓库、标准免费macos-15/Xcode16.2流程；不上传设备诊断。实际commit、run、签名、dSYM和69项源码校验见同目录报告。旧发行保留不覆盖。身份继续Letterpress/82Flex，包及偏好域com.82flex.letterpress，保留许可证。

## Build

The existing macos-15/Xcode16.2 workflow and build_macos.sh are byte-identical to the complete diag2 baseline. The private dependency adapter records exactly one omitted update call; all original draw code and default target60 are retained. No production upstream checkout is modified.
