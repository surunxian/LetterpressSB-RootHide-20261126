# Letterpress — RootHide SpringBoard port

基于 [owngoal-dev/Letterpress](https://github.com/owngoal-dev/Letterpress) 的实验性 SpringBoard 插件移植。上游源码固定为 `121b49873a4d6ff2a0cf87eb3ce6b643033fb0b8`。保留原版 SwiftUI/Vortex 渲染，提供设置 App 内的偏好页；不是独立 App 重打包，也不是 UIKit 近似重写。

## 当前状态：test8 + diagnostic2（渲染等待验证，非已证实修复版）

**源码已准备不等于构建成功，更不等于真机稳定。**

本版 `0.1.0~test8+diag2` 以已交付 diag1 为冻结基线，只增强手动诊断。保持 SwiftUI/Vortex、粒子时间、歌词、窗口安全/注册/可见性、媒体桥及原设置值不变。没有通过猜测函数名来修补 RenderBox，也未移除截图保护。下文 test8 还原过程是基线历史，不代表本版修复了亮屏。

操作：覆盖安装，确认 SpringBoard 注入后注销；设置 → Letterpress → 唤醒采样与导出诊断 → 开始 90 秒采样；确认 recording 后播放音乐，锁屏约 5–10 秒再亮屏，重复两轮；返回此页，停止并保存，待 completed 后导出 JSON。若已自动完成，按页面提示导出已有报告。二版严格要求 schema 2 / diag2，旧报告不能冒充新报告。

采样只在手动请求后运行：90 秒、最多24个主线程样本、每busy最多6个、250ms间隔，主线程FP链上限48帧。若同一busy有连续两次成功样本为同一PC/LR等待态且有效年龄至少500ms，后台最多补抓4组工作线程快照，每busy最多尝试一次。每组轮转扫描最多96个线程，择优保留最多24个，每线程最多24帧；软预算20ms，系统调用不保证硬实时，报告实际耗时、覆盖缺口和错误。不会暂停线程，worker栈没有pthread栈边界保证，仅读取有界FP/返回地址对；不是同时原子快照，也没有内核等待对象/owner或GPU状态。

事件环2048、镜像192/最多检查4096头，可执行范围每镜像最多4段，JSON小于1MiB。镜像收集/符号归属检查放在停止后；主线程采样和工作线程快照只保留数值，不写日志或文件。黑屏不阻止采样；>300ms定时器gap后重新观察250ms，不直接把睡眠算成工作。

报告含时间、进程内地址、镜像基址/UUID/文件名、线程ID/状态及窗口标量，可能披露运行环境；不采集歌词、账号、聊天、线程名称或原始内存块。线程名称如用于候选优先级，仅在诊断队列临时读取并转成数值，不进入报告。没有自动联网或公开上传，只通过你选择的系统分享目的地导出。额外Mach查询会产生开销并可能改变时序；所有错误、配额、预算和截断必须结合分析，不能把没有采到工作线程当作没有等待。本版需真机复测。

旧 `0.1.0~test1` 经 Linux 工具链构建，在 iOS 16.5.1 / iPhone XS 上的 SpringBoard 首次启动进入安全模式。已有崩溃分析定位到 Swift arm64e 跨 runtime 协议一致性描述符的指针认证问题。因此本仓库不携带任何旧对象、动态库、deb、SDK、工具链或设备崩溃日志。

test2/test3/test4 已实际使用 Apple Xcode 16.2 构建。用户在 2026-11-26 确认 test4 透明背景、自动出现和中文正常；这些反馈不代表其他边界均已验证。

当前诊断候选为 `0.1.0~test8+diag2`（diag1 基线已交付，本诊断版并非已证实的亮屏修复版），显示名称 **Letterpress**，作者/维护者 **82Flex**，包 ID `com.82flex.letterpress`，偏好域 `com.82flex.letterpress`（同名 `.plist`）。旧 `wiki.qaq.letterpress` 的已知偏好仅迁移缺失键，不覆盖新值；新包声明替换旧 `dev.letterpress.springboard`，避免两个插件同时加载。

2026-11-27 用户确认 test7 仍有播放音乐后约两秒整屏才点亮的问题，并要求先完整对照固定原版，撤销无原版依据的修改。test8 不再追加延迟优化：撤销 test6 隐藏时保留粒子子树及 test7 的暂停、隐藏迸发丢弃和补帧限制；恢复原版包含可见性的四路激活订阅及 0.5 秒节流、原始字幕/取色语义、原 HUD/容器/截图保护层级，并按原版由根视图而非整扇窗口控制策略隐藏。Vortex 仅保留动态库资源定位与 PNG 打包适配，不改粒子时间或绘制算法。恢复设置颜色的内存编辑及提交时机，保留已确认的用户定制。没有设备时序或新日志，不能将这些源码还原称为两秒亮屏已修复。

仍有不能隐去的移植边界：原 TrollStore App 和独立 HUD 进程被 SpringBoard 注入及 Settings 偏好页替代，没有原 App 前台预览、保活与 TIPA 更新；媒体读取保留异步桥接，锁/blank 未知时保守隐藏，不在 SpringBoard 强制设备旋转。设置页使用原生 Preferences/UIKit 而非原 SwiftUI 外壳。源码对齐不等于宿主时序、全部 UI 或真机效果已经 1:1；截图保护、旋转几何和物理亮屏均待设备验证。

设置图标只在原“字”图基础上添加透明圆角；应用选择不再内置默认九项，不删除用户显式保存的选择，也不从实际安装应用列表隐藏这九个应用；删除设置页底部原项目版权到真机验证的说明文字，分发包仍保留原 LICENSE 和第三方许可。保留7字体/2分词、四颜色选择与重置功能。没有本轮崩溃日志或设备时序数据，不将候选修复称为真机已解决；只有该提交的 workflow 成功且下载验包通过后才可交付其新 DEB。

## 构建

在 Actions 中手动运行 **Build LetterpressSB with Apple Xcode**。工作流没有 push、定时或 pull-request 自动触发器。

- 标准 `macos-15` runner，固定 `/Applications/Xcode_16.2.app` 和 iPhoneOS 18.2 SDK。
- XcodeGen 2.42.0 官方 release zip，固定 SHA-256；不依赖 Homebrew 最新版。
- Vortex 和 DominantColors 固定 commit，全部由 Apple 工具链重编。
- 构建前保存最小 Swift arm64e 探针作为 ABI 证据；不以 CPU subtype 或签名通过冒充运行正确。
- 不需要 Apple Developer 证书，产物为 ad-hoc 签名。
- 仓库必须公开；只使用标准 runner，不启用付费或更大 runner。
- 产物/日志作为 Actions artifact 保留 3 天，不自动创建 Release，不上传设备，不自动安装、注销或重启。

构建失败时也会保留可用日志，供继续迭代。一次真实构建仍可能暴露尚未验证的 Xcode/SPM/资源或运行时问题。

## 真机反馈

结构、代码签名哈希、架构和依赖检查只覆盖静态属性。即使云构建成功，仍须先检查最小 ABI 探针，再由拥有目标设备的测试者验证首次资源初始化、SwiftUI/Vortex、媒体变化、锁屏/解锁和设置同步。不要在缺少恢复手段时启用实验插件；旧 test1 应保持停用。

## 许可证及资源

Letterpress 的 MIT 许可证位于 `Port/LICENSE`；Vortex 和 DominantColors 的原许可证保留在 `THIRD_PARTY_LICENSES/`。原项目的资源与原生辅助文件按原目录保留。`SOURCE_MANIFEST.json` 记录导出源码的哈希；不包含令牌、设备日志或无关项目。
