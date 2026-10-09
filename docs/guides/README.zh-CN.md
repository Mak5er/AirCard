# AirCard 使用指南 🎴

**给 Apple 钱包换一张你喜欢的卡面。**

中文 · [English](README.en.md) · [下载 AirCard](https://github.com/Mak5er/AirCard/releases/latest) · [卡面素材](#卡面素材)

这份 **AirCard 中英文入门指南与素材说明**由 [BryceYuuu](https://github.com/BryceYuuu) 整理，帮助第一次使用 AirCard 的朋友完成安装与卡面更换。AirCard 由 [Mak5er](https://github.com/Mak5er/AirCard) 及贡献者开发。

## AirCard 能做什么？

AirCard 是一款 macOS 工具，通过 USB 连接 iPhone，自定义 Apple Wallet / Apple Pay 的卡面图片，也支持锁屏密码键盘主题（`.passthm`）及主题制作。本指南重点介绍**钱包卡面更换**。

卡面图片只用于外观展示，不会创建银行卡或改变卡片的支付权限。

## 卡面素材

卡面素材原图，点击下方链接即可下载。GitHub 若打开了图片预览页，可点击 **Download raw file**，或打开 **Raw** 后保存图片。

| 纸板信用卡 · Cardboard credit card | 极简 Apple 图案 · Minimal Apple artwork |
| :---: | :---: |
| <img src="../../assets/skins/cardboard-credit-card.png" alt="纸板质感卡面，印有 Official Credit Card 和 Trust Me 字样" width="400"> | <img src="../../assets/skins/apple-minimal.png" alt="浅灰背景中央的灰色 Apple 标志" width="300"> |
| [下载 PNG 原图](../../assets/skins/cardboard-credit-card.png) · 1411 × 1008 | [下载 PNG 原图](../../assets/skins/apple-minimal.png) · 1080 × 1080 |

| American Express 黑色卡面 · Amex black artwork | Trump Gold Card 金色卡面 · Trump Gold Card artwork |
| :---: | :---: |
| <img src="../../assets/skins/amex-black.png" alt="黑色 American Express 卡面图案，带芯片和百夫长头像" width="400"> | <img src="../../assets/skins/trump-gold-card.png" alt="金色 Trump Gold Card 图案，带特朗普肖像、自由女神像、鹰和 VISA 字样" width="400"> |
| [下载 PNG 原图](../../assets/skins/amex-black.png) · 844 × 540 | [下载 PNG 原图](../../assets/skins/trump-gold-card.png) · 1536 × 969 |

**裁切提示：** 当前程序会等比放大并居中裁剪图片，生成 **1536 × 969** 的横向卡面。这里展示的是原图，长宽比与目标不一致时会有裁切；正方形 Apple 素材会裁掉一部分上下区域，纸板素材的上下边缘也会被裁切。想保留特定构图，可先按约 **1.585:1** 的比例排版，再导入并查看预览。更多说明见 [素材说明](../../assets/skins/README.md)。

## 开始前准备

| 项目 | 说明 |
| --- | --- |
| 电脑 | Mac；上游提供支持 Apple Silicon 与 Intel 的通用 DMG |
| 手机 | iPhone；上游标注 iOS 18+、无需越狱，具体系统与机型的表现以实际测试为准 |
| 连接 | 一根支持数据传输的 USB 线，iPhone 保持解锁并信任这台 Mac |
| 卡片 | 已经添加到 Apple Wallet 的卡片 |
| 软件 | 从[原作者 Releases](https://github.com/Mak5er/AirCard/releases/latest)下载 `AirCard.dmg`；使用 DMG 无需另装 Homebrew 或 Python |

本指南依据 **AirCard v1.2.6** 整理（2026-10-04）。上游 README 标注曾在 iOS 27 测试；这不代表所有设备都已验证。本指南没有新增实机兼容性测试。

## 五步换卡面

### 1. 安装 AirCard

打开[官方下载页](https://github.com/Mak5er/AirCard/releases/latest)，在 **Assets** 中下载 `AirCard.dmg`。打开 DMG，将 `AirCard.app` 拖入 **Applications / 应用程序**，然后启动。

如果首次启动被 macOS 拦截，先确认文件来自上面的原作者仓库，再按[原作者安装说明](https://github.com/Mak5er/AirCard/blob/main/README.md#installation)处理。

### 2. 连接 iPhone

用 USB 线连接 iPhone 和 Mac。解锁 iPhone，出现提示时选择**信任此电脑**，并输入手机密码。

### 3. 扫描已有卡片

在 AirCard 的 **Apple Wallet** 页点击 **Scan Cards**。随后在 iPhone 上：

1. 双击侧边按钮，打开 Apple Pay。
2. 按提示完成身份验证（如 Face ID）。
3. 点选要更换卡面的卡片；必要时再次点选，或切换到另一张卡，再切回来。

等待卡片出现在 Mac 上的 AirCard 窗口中。

### 4. 选择素材

下载上方任意一张 PNG。点击 AirCard 里的目标卡片选择图片，或把图片直接拖到卡片上。检查预览与目标卡片是否正确；可以给不同卡片分别选择图片。

### 5. 应用并刷新

点击 **Flash Skins**，等待完成。然后在 iPhone 的多任务界面彻底关闭 **钱包 / Wallet**，再重新打开；如果没有更新，可尝试重启 iPhone。

## 深入使用

| 你想做什么 | 对应指南 |
| --- | --- |
| 解决连接、扫描、刷入或刷新失败 | [分阶段排障手册](TROUBLESHOOTING.zh-CN.md) |
| 管理多张卡片、换设备、处理批量中断 | [多卡操作与失败处理](MULTI-CARD.zh-CN.md) |
| 从整图或单键图片制作锁屏主题 | [Theme Creator 完整教程](THEME-CREATOR.zh-CN.md) |
| 查看已验证范围或提交设备测试结果 | [兼容性记录](COMPATIBILITY.zh-CN.md) · [反馈模板](compatibility-report-template.md) |
| 调整图片构图并导出标准尺寸卡面 | [离线卡面制作工具](../../tools/card-artwork/README.md) |

## 常见问题

### 扫描不到卡片？

确认数据线正常、手机已解锁并信任 Mac；开始扫描后，在 iPhone 上完成身份验证并实际点选或切换卡片。扫描中断时，重新连接、解锁，再扫描。

可以打开 **Log**，查看是否出现 `Connected to the unified device log stream`。被系统隐藏为 `<private>` 的值无法由扫描器恢复。更详细的测试范围见[上游扫描验证记录](../wallet-card-detection.md)：其中记录的 iPhone 15 Pro / iOS 18.6.2 测试验证了卡片检测，没有测试刷入卡面。

### 图片被裁掉了？

这是居中裁剪到横向卡面比例的结果。请按 **1536 × 969** 或相同比例准备图片，并将重要文字和图案放在中央。示例素材保留了原始尺寸，方便自行调整构图。

### 能一键恢复原卡面吗？
如果 AirCard 已在这台 Mac 上保存恢复点，可点击该卡的 **Restore Original**。恢复点会在此版本首次更改卡面前保存，并按 iPhone / 卡片保存在本地。卡面右上角的 ×（Remove skin）只清除 Mac 上待应用的图片。旧版或其他工具已覆盖的原始卡面无法重建，详见[多卡恢复限制](MULTI-CARD.zh-CN.md#卡片列表保存了什么)。

### Windows 或直接在 iPhone 上能用吗？

本指南介绍的是上游提供的 **macOS DMG + USB 连接 iPhone** 流程，不提供 Windows 或 iPhone 端独立安装教程。

### 锁屏密码键盘主题怎么用？

切换到 **Passcode (.passthm)**，导入 `.passthm` 文件，预览后点击 **Flash Passcode Theme**，完成后重启 iPhone。这里提供的 PNG 素材是卡面图片，并不是 `.passthm` 主题包。主题制作与源码构建请参阅[上游原始 README](https://github.com/Mak5er/AirCard/blob/main/README.md)。

## 反馈、更新与致谢

- **下载和版本更新：**[Mak5er/AirCard Releases](https://github.com/Mak5er/AirCard/releases)。安装包由原项目发布。
- **程序问题：** 查看[上游 Issues](https://github.com/Mak5er/AirCard/issues)。反馈时提供机型、iOS、macOS 和 AirCard 版本，以及简短错误信息；不要公开完整设备日志或卡片标识。
- **指南和素材说明：** 由 [BryceYuuu](https://github.com/BryceYuuu) 整理，独立教程仓库为 [AirCard-Guide](https://github.com/BryceYuuu/AirCard-Guide)。
- **原作者及贡献者：**[Mak5er](https://github.com/Mak5er)、[Lumid-Off](https://github.com/Lumid-Off)，以及提供底层 [AirLift](https://github.com/0xjohnnydev/airlift) 的 [0xjohnny](https://github.com/0xjohnnydev)。喜欢这个项目，可以给[原项目](https://github.com/Mak5er/AirCard)点个 Star，或通过[原作者支持入口](https://github.com/Mak5er/AirCard/blob/main/README.md#support)支持开发。

上游代码遵循 [MIT License](../../LICENSE)，原有版权声明保持不变。新增素材由 [BryceYuuu](https://github.com/BryceYuuu) 提供，不自动适用代码的 MIT 授权，详见[素材说明](../../assets/skins/README.md)。本指南及示例卡面不代表 Apple 或任何银行的官方产品。
