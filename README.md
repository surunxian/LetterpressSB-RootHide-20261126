# Letterpress — RootHide SpringBoard port

基于 [owngoal-dev/Letterpress](https://github.com/owngoal-dev/Letterpress) 的实验性 SpringBoard 插件移植。上游源码固定为 `121b49873a4d6ff2a0cf87eb3ce6b643033fb0b8`。保留原版 SwiftUI/Vortex 渲染，提供设置 App 内的偏好页；不是独立 App 重打包，也不是 UIKit 近似重写。

## 当前状态

**源码已准备不等于构建成功，更不等于真机稳定。**

旧 `0.1.0~test1` 经 Linux 工具链构建，在 iOS 16.5.1 / iPhone XS 上的 SpringBoard 首次启动进入安全模式。已有崩溃分析定位到 Swift arm64e 跨 runtime 协议一致性描述符的指针认证问题。因此本仓库不携带任何旧对象、动态库、deb、SDK、工具链或设备崩溃日志。

test2/test3/test4 已实际使用 Apple Xcode 16.2 构建。用户在 2026-11-26 确认 test4 透明背景、自动出现和中文正常；这些反馈不代表其他边界均已验证。

当前候选为 `0.1.0~test8`，显示名称 **Letterpress**，作者/维护者 **82Flex**，包 ID `com.82flex.letterpress`，偏好域 `com.82flex.letterpress`（同名 `.plist`）。旧 `wiki.qaq.letterpress` 的已知偏好仅迁移缺失键，不覆盖新值；新包声明替换旧 `dev.letterpress.springboard`，避免两个插件同时加载。

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
