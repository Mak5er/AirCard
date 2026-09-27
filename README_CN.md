# AirCard 🎴 中文使用指南与架构解析

> **项目名称**：AirCard  
> **开源地址**：[https://github.com/Mak5er/AirCard](https://github.com/Mak5er/AirCard)  
> **本地部署路径**：`/Volumes/ZHUOLIN/Project/air card`  
> **本地构建版本**：**全界面深度汉化版 (Simplified Chinese)**  
> **支持系统**：iOS 18+ / macOS 12+ (Apple Silicon 原生适配 / Intel 双架构通用)  
> **核心特性**：**无需越狱 (No Jailbreak)**、**不破坏银行级安全**、**支持锁屏密码按键主题 (.passthm)**

---

## 一、项目简介与工作原理

### 1. 这是个什么项目？
**AirCard** 是近期在 iOS 折腾圈与 GitHub 上备受关注的开源美化工具。它允许用户在**无需越狱**的前提下，随心所欲地为 iPhone 的 **Apple Pay / Apple Wallet 绑定的信用卡和借记卡更换自定义卡面皮肤**（如二次元、赛博朋克、定制黑金等），同时还支持自定义锁屏拨号按键主题（`.passthm`）。

### 2. 底层黑科技原理剖析
AirCard 能在不越狱的闭源 iOS 上实现卡面替换，其核心依赖于以下技术链条：

1. **AirTraffic 同步协议逃逸 (`airlift` / `ATAirlock`)**：
   - 基于开源项目 `airlift`（作者 0xjohnnydev），利用苹果官方用于有线同步媒体资产的 `AirTraffic` 守护进程与 `ATAirlock` 协议。
   - 通过精心构造的同步归档包与符号链接机制，实现在免越狱受限沙盒内向系统缓存区写入更新文件的能力。
2. **Apple Pay 卡片 Hash 实时捕获**：
   - 工具直接调用 macOS 系统的私有框架 `MobileDevice.framework`，通过 USB 接口监听 iOS 系统的统一设备日志流（Unified Log Stream）。
   - 当你在 iPhone 上双击电源键呼出 Apple Pay 并通过 Face ID 验证后轻触卡片，系统 Passbook 进程会触发本地卡面资源的查找事件，AirCard 即可瞬间精准抓取对应卡片的唯一 Hash 标识符。
3. **渲染缓存热替换**：
   - 抓取到 Hash 后，工具利用 macOS 内置图形管线将你上传的图片处理成 `@2x`、`@3x` 高清 PNG 以及 PDF 矢量资源，并通过同步机制精准覆写 `/var/mobile/Library/Caches/` 下该卡片对应的视觉渲染缓存（`FrontFace`、`PlaceHolder`、`Preview`）。
   - 强退钱包 App 或重启后，系统直接加载新的渲染缓存，自定义卡面立刻呈现。

---

## 二、安全性与隐私疑问说明（安全无忧）

* 🛡️ **银行卡安全会受影响吗？**  
  **绝对不会**。Apple Pay 的核心安全机制依赖于苹果设备内置的独立安全芯片（Secure Element, SE）以及与银联/Visa/MasterCard 交互的设备账户号码（Tokenization 令牌化技术）。AirCard **仅修改了本地界面的位图缓存图层**，根本无法也无需触碰 Secure Element、真实卡号、有效期、CVV 或任何加密密钥。所有的支付、刷卡消费、云端风控、银行扣款逻辑 100% 保持原生不变。
* 🌐 **离线本地运行**：  
  整个项目 100% 运行在本地 Mac 与有线连接的 iPhone 之间，无需依赖外部服务器，无任何个人数据上传风险。
* ⚠️ **当前限制**：  
  目前仅支持借记卡（Debit）和信用卡（Credit）。交通卡（如各类公交卡、八达通、Suica）和车钥匙（Car Key）由于在 PassKit 中的渲染逻辑与安全级别不同，暂不支持修改。

---

## 三、部署与构建产物说明

本项目已为你完整克隆并成功完成了原生编译构建：

* **源码根目录**：[`/Volumes/ZHUOLIN/Project/air card`](file:///Volumes/ZHUOLIN/Project/air%20card)
* **独立原生应用**：[`/Volumes/ZHUOLIN/Project/air card/build/AirCard.app`](file:///Volumes/ZHUOLIN/Project/air%20card/build/AirCard.app)  
  * 已包含 Apple Silicon (arm64) 与 Intel (x86_64) 通用 Universal 二进制；
  * 内置已签名构建的 `device_helper` 与 `airtraffic_host`，无需额外安装 Python 第三方包或 Homebrew 依赖。
* **独立安装镜像**：[`/Volumes/ZHUOLIN/Project/air card/build/AirCard.dmg`](file:///Volumes/ZHUOLIN/Project/air%20card/build/AirCard.dmg)（约 2.6MB，支持直接双击挂载）。

---

## 四、超详细使用步骤（新手必读）

### 步骤 1：连接与信任
1. 使用 USB 数据线将 iPhone 连接至 Mac。
2. 保持 iPhone 处于解锁状态，如弹出提示请点击**“信任此电脑”**并输入锁屏密码。

### 步骤 2：启动 AirCard
* 直接双击运行 [`build/AirCard.app`](file:///Volumes/ZHUOLIN/Project/air%20card/build/AirCard.app)（如遇 Gatekeeper 拦截，右键点击 App 选择“打开”即可）。

### 步骤 3：嗅探卡片 Hash
1. 在 AirCard 软件界面中保持在 **Wallet Cards** 选项卡。
2. 点击软件上的 **【Scan Cards】** 按钮。
3. **在 iPhone 上操作**：
   - 双击电源键唤起 Apple Pay；
   - 通过 Face ID 完成面容解锁；
   - **轻触你想更换卡面的那张卡片**（可多点几下或切换一下卡片）；
   - 此时 Mac 端的 AirCard 界面会自动捕获到该卡片，并生成一个卡片卡位！

### 步骤 4：上传并烧录自定义卡面
1. 将你准备好的图片（建议比例约为 **1.58:1**，标准尺寸推荐 1014x642 或更高比例）直接拖拽到 AirCard 对应的卡片预览框中。
2. 确认图片位置无误后，点击 **【Flash Skins】** 按钮进行写入。

### 步骤 5：刷新生效
1. 写入完成后，在 iPhone 屏幕底部上滑呼出后台多任务管理，**强制划掉“钱包 (Wallet)”App**。
2. 重新打开钱包 App，或双击电源键唤起 Apple Pay，即可看到全新炫酷的专属卡面！  
   *(注：若未立即生效，重启一次 iPhone 刷新系统缓存即可)*

---

## 五、额外玩法：锁屏密码按键主题 (.passthm)

除了 Apple Pay 卡面，AirCard 还能美化 iOS 18+ 的锁屏密码九宫格按键：
1. 切换到顶部的 **Passcode Themes** 选项卡。
2. 直接拖入任何支持 Cowabunga / Nugget 的 `.passthm` 主题包，或使用内置的 **Theme Creator** 用单张壁纸自动切片生成按键。
3. 点击 **【Apply Passcode Theme】**，写入后重启 iPhone 即可体验个性化按键！

---

## 六、如何还原官方原版卡面？

如果不想要自定义卡面，恢复默认非常简单：
* 在 AirCard 的对应卡片设置中点击重置/清除缓存，或者在 iPhone 的【设置】->【钱包与 Apple Pay】中将该卡片移除后重新添加绑卡，即可立刻恢复发卡行官方初始卡面。
