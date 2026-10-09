# 卡面排障：先确认卡在哪一步

[返回中文指南](README.zh-CN.md) · [English](TROUBLESHOOTING.en.md) · [多卡操作与失败处理](MULTI-CARD.zh-CN.md)

本页依据当前仓库的 macOS 图形界面和后端代码整理。**连接成功、扫描到卡片、后端写入成功、手机显示新卡面是四个不同结果**，请分别记录；本文没有增加实机兼容性结论。

## 1. 无法连接 iPhone

| 界面或 Log 提示 | 检查与下一步 | 此阶段通过的标志 |
| --- | --- | --- |
| `No iPhone found. Please connect via USB.` / `No iPhone connected.` | 使用支持数据传输的 USB 线；解锁手机并确认“信任此电脑”；重新插拔后点击连接区域的刷新按钮。连接多台设备时，先仅保留目标 iPhone。 | 显示 `Connected to …`，机型和 iOS 信息与目标设备一致。 |
| `Device tools are missing from this build.` | 当前安装包缺少可执行的 `device_helper`。重新下载[原作者发布的 DMG](https://github.com/Mak5er/AirCard/releases/latest)，复制完整的 app 到 Applications。源码构建则检查[构建说明](https://github.com/Mak5er/AirCard/blob/main/README.md)。 | 工具缺失提示消失，能检测到目标手机。 |
| `Device detection failed: …` | 保留错误末尾的具体信息；检查是否移动或只复制了 app 内的部分文件，重新安装完整发布包后再试。 | 设备检测正常结束。 |

连接状态不是写入兼容性证明。后端会单独探测 AirLift，但图形界面的 `Connected` 只表示设备检测成功。

## 2. 已连接，但扫描不到卡片

1. 在 **Apple Wallet** 页点击 **Scan Cards**，打开 **Log**。
2. 查找 `Connected to the unified device log stream`。出现这行说明日志通道已连接，**不代表已经发现卡片**。
3. 在 iPhone 上双击侧边按钮，按提示完成身份验证，点选目标卡片；也可切换到另一张再切回来。
4. 查找新的 `Found card: …`。卡片列表可能是以前保存的记录，不能仅凭窗口里有卡片判断本次扫描成功。

| 提示或现象 | 下一步 |
| --- | --- |
| `Could not start card scanning.` / `Syslog monitor failed to start: …` | 查看后面的启动错误；确认 app 包完整、手机仍连接，再重试。 |
| `Card scanning ended. Check the log and reconnect the iPhone to retry.` | 日志进程已经退出。记录退出状态；重新连接、解锁，刷新连接后重新扫描。 |
| `Card scanning failed. Check the log and retry.` | 查看 `Syslog monitor stopped: …` 后面的原因，再重连并扫描。 |
| 通道已连接，但没有新卡片 | 确认在扫描期间实际点选了卡片；已经保存的同一标识会去重，不会再次显示 `Found card`。iOS 隐藏为 `<private>` 的值无法由扫描器恢复。 |

需要排除旧记录时，可先停止扫描，再用 **Clear All** 清空 Mac 上的卡片列表后重新扫描。它不会删除 iPhone 钱包里的卡，也不会恢复原卡面；详见[按钮含义](MULTI-CARD.zh-CN.md#容易混淆的按钮)。

实测范围请看[上游扫描验证记录](../wallet-card-detection.md)：iPhone 15 Pro / iOS 18.6.2 的记录验证了检测，没有验证卡面刷入。

## 3. 按钮不可用、图片准备失败或构图不对

| 提示或现象 | 下一步 |
| --- | --- |
| **Flash Skins** 灰色，或 `Please assign a skin image to at least one selected card.` | 至少一张卡必须同时满足“已勾选”和“已分配图片”。核对底部的 `ready to flash` 数量以及设备连接状态。 |
| 刚才还有预览，现在找不到原图 | 将图片保存到 Mac 的固定文件夹，确认可以用预览 app 打开，再重新选图。图形界面在刷入时会再次读取文件，不能仅凭旧预览判断文件仍可用。 |
| `Image file not found` / `Failed to prepare card artwork` | 重新导出为可正常打开的 PNG，优先使用 **1536 × 969**，重新分配后先单卡重试。后一条错误也可能来自后端将 PNG 转换为 PDF 的步骤。 |
| 内容被裁切 | 原生图像准备会按比例放大并居中裁切到 **1536 × 969**；使用[离线卡面工具](../../tools/card-artwork/README.md)提前调整这一尺寸的构图，避免重要内容贴边。 |

`Image file not found` 是后端错误；当前界面不一定逐字显示它，也可能只显示最终失败。界面的图片准备降级路径没有完整检查其返回结果，因此“到了写入步骤”不能作为图像准备成功的证据。先确认源文件有效，再重新选图；不要把无效文件用于重复尝试。原生准备和 Pillow 路径保持比例并裁切，最后的 `sips` 降级路径则直接缩放到目标尺寸，可能产生拉伸。

## 4. 写入过程中失败

打开 **Log**，先找到最后一条 `Flashing card [n/total]: …`，确认是第几张，再看它后面的错误。

| 提示 | 含义与下一步 |
| --- | --- |
| `Failed to launch card flasher: …` | 刷入后端进程没能启动。保留具体错误，检查安装完整性后再尝试。 |
| `Card update failed for …` / `Failed to apply card skins.` | 本张卡的后端非零退出，或刷入进程未启动。检查前面的准备、写入、缓存信息；恢复连接、重新选图后只选这一张重试。 |
| `One or more cards could not be updated. Check the log and try again.` | 批次没有全部成功。不要据此认定所有卡均未变化；前面的卡可能已写入，当前失败卡也可能部分写入。 |

后端先尝试批量写入一张卡的素材，失败后再逐文件写入。这是**同一张卡内部的回退**，不是多张卡之间的撤销。多卡队列在首张失败卡之后停止；按[部分失败处理流程](MULTI-CARD.zh-CN.md#中途失败后怎么处理)核对结果。

## 5. 缓存失败，或完成后手机仍显示旧图

| 提示或现象 | 含义与下一步 |
| --- | --- |
| `Could not clear Wallet cache (.cache); card was not reported as updated.` | 素材写入后，缓存清理未成功；后端会把整张卡标为失败。`.pkcache` 的同类提示含义相同。先恢复连接并确认目标卡，再单卡重试完整流程。 |
| `Successfully updated …`，手机还是旧卡面 | 这是后端报告成功，尚需目视确认。按 app 的提示，从多任务界面彻底关闭 Wallet 再打开；仍未刷新可尝试重启，记录结果。 |
| 重启后仍不对 | 记录是否出现缓存错误、目标卡是否对应、其他卡是否受影响，再提交分阶段反馈。不要通过删除再添加银行账户卡片来猜测修复。 |

后端会写入 PNG/PDF 素材，并清理 `.cache` 和 `.pkcache` 中的渲染文件；进度达到 100% 本身不等于成功。请同时看最终提示和手机实际显示。如果这台 Mac 在首次更改卡面前已保存 **Restore Original** 恢复点，可点击该卡片的恢复按钮，然后强制关闭 Wallet 并检查手机；本地快照会保留以便再次恢复。单独重启只能尝试刷新 Wallet，不能恢复原图。保存恢复点之前已被修改的卡片，AirCard 无法重建其原图。

## 反馈时提供什么

可直接复制[双语反馈模板](compatibility-report-template.md)，参照[兼容性记录](COMPATIBILITY.zh-CN.md)填写。提供 AirCard 版本或提交、iPhone 机型、iOS 与 macOS 版本，分别写明“连接 / 扫描 / 写入 / 显示”结果，附上最早的相关错误和单卡重试结果即可。卡片标识和设备 UDID 用 `<redacted>` 替换；不要附完整设备日志、完整卡号或付款信息。

## 代码与验证依据

- [AirCardApp.swift](../../AirCardApp.swift)：`checkDevice`、`startCardScanning`、`prepareCardImage`、`applySkin` 和日志处理。
- [aircard_backend.py](../../aircard_backend.py)：`cmd_device`、`cmd_prepare_image`、`cmd_flash`；[card_assets.py](../../card_assets.py)：PNG/PDF 素材与缓存文件名。
- [卡面后端测试](../../tests/test_card_flash.py)：模拟素材写入、PDF 转换和缓存失败；[扫描器测试](../../tests/test_card_scanner.py)：协议与合成卡片路径。自动化检查不代表真机写入验证。
