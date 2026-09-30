# Wallet 卡面文件与读取限制 · Wallet Card Artwork Files and Read Limitations

记录"银行卡的卡面到底存在哪里、怎么取出来"，以及实测得到的限制。内容与当前代码一一对应，供后续维护。
How a bank card's artwork is stored on the iPhone, how we get it out, and the limits we measured. Everything below matches the current code, for future maintenance.

实测机型 · Tested on：iPhone 14 Plus（iOS 26.7.1）、iPhone 18 Pro Max（iOS 27.0.1）

---

## 1. 范围 · Scope

只处理 **银行卡**（Apple Pay）。目标是卡包里的这一份文件：
Only **bank cards** (Apple Pay) are handled. The target is this one file inside the card bundle:

```
/var/mobile/Library/Passes/Cards/<卡ID>.pkpass/cardBackgroundCombined.png.urls
```

卡券 / 登机牌 / 票券一律跳过：不读取、不发网络请求、也不提供下载入口。不读 `pass.json`，不判断是否刷过皮肤。
Passes (store cards, boarding passes, tickets) are skipped entirely: no read, no network request, no download entry. `pass.json` is not read, and we do not care whether a skin was flashed.

银行卡的卡面图**不在手机上**：`.pkpass` 目录里只有这份文件和元数据（`signature`、`actions.json`、`icon@2x.png` 等），卡面由 Wallet 结合卡片数据与远端素材现渲染。
A bank card's artwork is **not stored on the phone**: the `.pkpass` directory holds only this manifest plus metadata (`signature`, `actions.json`, `icon@2x.png`, …). Wallet renders the artwork from the card's own data and a remote asset.

## 2. 原理：为什么要"先搬出来再读" · Why the file must be moved out before reading

**直接读不行**：手机的 AFC 服务（`afcd`）被系统沙箱限制，只允许碰 `Media/` 里面的东西；`Passes/…` 这类路径连属性都读不到（内核 `deny file-read-metadata`）。
**A direct read does not work**: the phone's AFC service (`afcd`) is sandboxed to `Media/`; for paths such as `Passes/…` even a metadata lookup is denied (kernel: `deny file-read-metadata`).

**能借的通道**：AirTraffic（Finder/iTunes 同步"图书"用的那条服务）会按登记清单，把受保护目录里的文件"同步"到 Media；文件一落在 Media，AFC 就能读了。整套读取就是围绕这一点搭的：
**The channel we borrow**: AirTraffic (the service Finder/iTunes uses to sync "Books") moves files out of protected directories according to a registered list. Once a file sits in `Media/`, AFC can read it. The whole read path is built around that:

1. **搭暂存目录 · Stage a directory**：`stage` 用 `com.apple.streaming_zip_conduit` 把一个小压缩包解到 `Media/airlift-src-<token>/`。包里有一个符号链接 `p0/p1/p2/link`，内容是相对路径 `../../../var/mobile/Library/Passes/Cards`。
   `stage` unpacks a small archive into `Media/airlift-src-<token>/` through `com.apple.streaming_zip_conduit`. The archive contains a symlink `p0/p1/p2/link` whose payload is the relative path `../../../var/mobile/Library/Passes/Cards`.
   这个 `../../../` 是**按搬走之后的位置**算的：链接最终落在 `Media/` 下面，往上三层正好是 `/`，于是指向真正的受保护目录；留在暂存目录里时它并不指向那里，所以只有被搬走才有用。
   That `../../../` is calibrated for **where the link ends up**: after the move it sits directly under `Media/`, so three levels up is `/` and it resolves to the real protected directory. While it still sits in the staging directory it points nowhere useful — which is why moving it is the whole point.
2. **登记要同步的路径 · Register the sync list**：同时把 `Books.plist` 换成一份清单（`build_books()`）。AirTraffic 的标识符以 `/var/mobile/Media/Airlock/Book` 为根，所以清单里写的是相对路径：
   `Books.plist` is replaced with our list (`build_books()`). AirTraffic identifiers are relative to `/var/mobile/Media/Airlock/Book`, so the list holds relative paths:
   - `../../airlift-src-<token>/p0/p1/p2/link` → `Media/airlift-link-<token>`（搬符号链接 / moves the symlink）
   - `../../Library/Passes/Cards/<卡ID>.pkpass/<文件名>` → `Media/airlift-recovered-<token>`（搬真文件 / moves the real file）
3. **先拍快照 · Snapshot first**：`snapshot-books` 把会被覆盖的 6 个 Books 文件（`Books/Books.plist`、`Books/Sync/Books.plist`、`Books/Sync/Upload.plist`、`Books/Sync/Database/OutstandingAssets_4.sqlite` 及其 `-shm`/`-wal`）复制出来，合计约 2.25 MB。`stage` 动手前会核对设备当前状态与这份快照一致，并校验生成名与目标路径都是干净的。
   `snapshot-books` copies the six Books files it is about to overwrite (`Books/Books.plist`, `Books/Sync/Books.plist`, `Books/Sync/Upload.plist`, `Books/Sync/Database/OutstandingAssets_4.sqlite` plus its `-shm`/`-wal`), roughly 2.25 MB in total. Before touching anything, `stage` verifies the device state still matches that snapshot and that both the generated names and the target paths are clean.
4. **执行搬移 · Run the sync**：`airtraffic_host` 按清单搬。搬完，目标文件已经在 Media 里。
   `airtraffic_host` performs the moves. When it returns, the file we want is in `Media/`.
5. **读取 · Read**：`afc-read` 读 Media 里那一份（沙箱允许）——这就是要的内容。
   `afc-read` reads that copy (`Media/` is allowed by the sandbox) — those bytes are what we want.
6. **写回 · Write back**：`write_file` / `write_files_batch` 反着做一次：把内容做成 payload 放进新的暂存目录，借上一步的符号链接把它搬回受保护目录，覆盖原路径。
   `write_file` / `write_files_batch` do the same in reverse: the bytes become a payload in a fresh staging directory and are moved back through that symlink, overwriting the original path.
7. **收尾 · Clean up**：`finish-write` 删掉搬出来的临时文件与整个暂存目录（`RemoveGeneratedTree`），等 2 秒，再从快照恢复 Books。
   `finish-write` deletes the recovered files and the whole staging tree (`RemoveGeneratedTree`), waits two seconds, and restores Books from the snapshot.

由此可以直接解释几个现象 · Consequences this explains:

- **查属性很便宜**：符号链接搬到 Media 之后，`afc-stat` 顺着它就能看到受保护目录里的名字和大小，不用搬任何东西——探测就是靠这个（暖路径 0.3 s）。但**打开这条链接读内容会被沙箱拒绝**，所以读内容必须走上面第 2–5 步。
  **Metadata is cheap**: once the symlink lives in `Media/`, `afc-stat` resolves through it and reports names and sizes without moving anything — that is what probing uses (0.3 s warm). **Opening that link to read data is denied**, so content always goes through steps 2–5.
- **每次 8–13 s 是固定的**：快照 2.25 MB、zip 通道、同步握手、收尾固定等待，和文件大小无关。
  **The 8–13 s per operation is fixed cost**: the 2.25 MB snapshot, the zip channel, the sync handshake and the fixed cleanup wait — independent of file size.
- **留着链接就快**：把 `Media/airlift-link-<token>` 留下，之后的查询只要一次 AFC 调用（8 s → 0.4 s）；`--release-artwork-link` 负责删掉它。
  **Keeping the link makes it fast**: leaving `Media/airlift-link-<token>` in place turns later lookups into a single AFC call (8 s → 0.4 s); `--release-artwork-link` removes it.
- **批量为什么能省一趟**：清单里可以一次登记 N 组搬移，N 份文件在同一趟里搬进 `<source>/out/`；因为 `out/` 就在暂存目录内部，收尾时随 `RemoveGeneratedTree` 一起消失，不会在 Media 根目录留下一堆 `airlift-recovered-*`。
  **Why batching saves round trips**: one list can register N moves at once, so N files land in `<source>/out/` in a single pass; because `out/` is inside the staging tree, `RemoveGeneratedTree` removes it with everything else and no pile of `airlift-recovered-*` is left at the root of `Media/`.
- **生成名为什么必须严格**：暂存目录、符号链接、搬出的临时文件，名字都由工具生成（前缀 + **恰好 20 位小写十六进制**）；`stage` 和 `finish-write` 只肯操作这种名字，避免误删用户数据。
  **Why generated names are strict**: staging directories, symlinks and recovered files are all named by the tool (prefix + **exactly 20 lowercase hex digits**); `stage` and `finish-write` refuse anything else, so user data cannot be deleted by accident.
- **失败时为什么保留现场**：读失败或写回失败时，原件正躺在暂存目录里，删掉就等于丢数据，所以宁可留下（`airlift-src-*` 这类残留就是这么来的）。
  **Why failures leave files behind**: on a failed read or write-back the original is inside the staging tree; deleting it would destroy data, so we keep it (`airlift-src-*` leftovers come from exactly this).

## 3. 这份文件的格式 · Format of the manifest

```json
{"cardBackgroundCombined@2x.png": {"url": "https://.../assets/<id>",
                                   "size": 453184,
                                   "sha1": "0b8274b3..."}}
```

- 解析用 `card_artwork.manifest_entries()`，另外兼容 binary plist 和只含裸 URL 的情况（`manifest_url()`）。
  Parsed by `card_artwork.manifest_entries()`; binary plists and bare-URL payloads are covered too (`manifest_url()`).
- 地址必须是 `https`，且主机名以 `.apple.com` 结尾（`download_asset()` 会校验）。主机名每张卡不同（如 `pr-pod11-…`、`nc-pod11-…`），无法推测，必须从手机上读。
  The URL must be `https` and its host must end in `.apple.com` (`download_asset()` enforces this). Host names differ per card (`pr-pod11-…`, `nc-pod11-…`) and cannot be guessed — they must be read from the phone.
- 素材本身没有扩展名，Content-Type 也不可靠，所以格式按**文件头字节**判断（PNG / PDF / JPEG / GIF）。
  The asset has no file extension and its Content-Type is unreliable, so the format is decided by **magic bytes** (PNG / PDF / JPEG / GIF).
- 下载后按文件里声明的 `size` 和 `sha1` 核对（`verify_declared()`）。返回 `verified: true` 表示保存下来的字节与声明完全一致。
  After downloading, the bytes are checked against the declared `size` and `sha1` (`verify_declared()`). `verified: true` means the saved bytes match the declaration exactly.

## 4. 能读与不能读（实测） · What works and what does not (measured)

| 操作 · Operation | 结果 · Result |
| --- | --- |
| 直接读受保护路径（`Passes/…`）<br>Direct read of a protected path | ❌ 被沙箱拒绝（`deny file-read-metadata`）<br>Denied by the sandbox |
| 通过搬到 Media 的符号链接**查属性**<br>**Metadata** through the relocated symlink | ✅ 可用；据此判断某张卡的 `.urls` 在不在<br>Works; this is how we check whether a card has a `.urls` |
| 通过该链接**读文件 / 列目录**<br>**Read a file / list a directory** through that link | ❌ 读失败 / `could not open directory` → 无法列出 `Cards/`<br>Read fails / `could not open directory` → `Cards/` cannot be listed |
| 把**文件**搬到 Media 再读<br>Move a **file** into Media, then read | ✅ 唯一能取到内容的办法，读完必须写回<br>The only way to get content; it must be written back |
| 把**目录**搬出去再搬回<br>Move a **directory** out and back | ❌ 绝不使用（曾因此丢掉一整张卡的文件）<br>Never used (it once destroyed every file of a card) |

由此得到的限制 · Resulting constraints:

- **手机必须解锁且亮屏**：否则读取一律失败。要用 `file_service_available()` 把它和"这张卡没有素材"区分开。
  **The iPhone must be unlocked with the screen on**, otherwise every read fails. `file_service_available()` is what separates that from "this card has no artwork".
- **`afcStatus` 的含义**：`8` = 确实没有；`10` = 被拒绝，算"**可能还在**"（探测据此判断能不能下载）。
  **Meaning of `afcStatus`**: `8` = genuinely missing; `10` = denied, treated as "**possibly present**" (this is what the probe uses to decide download availability).
- **扫描日志和读文件不能同时进行**：两者争用设备通道，读取会返回空 → App 在下载前会自动暂停扫描。
  **Log scanning and file reads cannot run at the same time**: they contend for the device transport and reads come back empty → the app pauses scanning before a download.
- **卡片只能从手机日志里发现**：目录无法列出，卡 ID 只能来自 Wallet 写出的日志行；而 iOS 会遮蔽动态内容（实测一次抓取里，wallet 相关日志约 18% 含 `<private>`），所以一次扫描不一定凑齐所有卡。Mac 上的 `~/Library/Passes/RemoteDevices.archive` 是补齐银行卡的第二个来源（该文件缺失时这条路径失效）。
  **Cards can only be discovered from the phone log**: the directory cannot be listed, so card IDs come from lines Wallet writes. iOS redacts dynamic content (in one measured capture about 18% of wallet-related lines contained `<private>`), so a single scan may not find every card. On the Mac, `~/Library/Passes/RemoteDevices.archive` is the second source for filling the gaps (it is unusable while that file is absent).
- 每次设备调用上限 60 s（`apply_card_skin.native`）；手机刚连上或刚解锁时可能超时一次，App 会自动重试。
  Each device call has a 60 s limit (`apply_card_skin.native`); right after connecting or unlocking it may time out once, and the app retries automatically.

## 5. 代码对应关系 · How the code is organised

```
card_artwork.py        解析清单 / 选择素材 / 核对 size+sha1 / 下载 / 判断格式（只用标准库）
                       manifest parsing, asset choice, size+sha1 check, download, format detection (stdlib only)
card_assets.py         判断是否 PNG、读取 PNG 尺寸（is_png / png_dimensions）
                       PNG detection and dimensions (is_png / png_dimensions)
apply_card_skin.py     stat_paths：用符号链接查属性（探测用）
                       stat_paths: metadata through the symlink (used by probing)
                       read_files_batch：一趟设备往返读多份文件并写回
                       read_files_batch: read several files and write them back in one round trip
aircard_backend.py     --probe-card-artwork / --fetch-card-artwork / --fetch-card-artworks
                       --release-artwork-link
AirCardApp.swift       探测调度、单卡与批量下载按钮、下载时暂停扫描、换手机时清理链接
                       probe scheduling, single and batch download buttons, scan pausing, link cleanup
```

- **探测 · Probe**：`--probe-card-artwork <udid> <卡ID...>`，用保留的符号链接加 `afc-stat-many`；属性存在或 `afcStatus == 10` 都算可下载。
  `--probe-card-artwork <udid> <card-id...>` uses the kept symlink plus `afc-stat-many`; a present attribute or `afcStatus == 10` counts as downloadable.
- **单卡下载 · Single download**：`--fetch-card-artwork <udid> <卡ID> <路径>` → `read_files_batch`（一份文件，一趟往返，同一趟写回）→ 下载 → 核对 → **按原格式保存**。
  `--fetch-card-artwork <udid> <card-id> <path>` → `read_files_batch` (one file, one round trip, written back in the same pass) → download → verify → **saved in its original format**.
- **批量下载 · Batch download**：`--fetch-card-artworks <udid> <目录> <卡ID...>` → 所有文件在**同一趟**往返里读出，逐张下载，最后一次性写回；单张失败不影响其它卡。文件名为 `AirCard-<卡ID前12位><实际扩展名>`。
  `--fetch-card-artworks <udid> <dir> <card-id...>` reads every manifest in **one** round trip, downloads them one by one and writes them all back at once; one failing card does not stop the others. Files are named `AirCard-<first 12 chars of the card id><real extension>`.
- **不转换格式 · No format conversion**：按实际格式保存（PNG/PDF/JPEG/GIF）；无法识别的内容直接判失败，不会存成 `.png`。界面上单卡保存时，如果所选后缀和实际不符会自动改名并写日志。
  Bytes are stored in the format they arrive in (PNG/PDF/JPEG/GIF); unrecognised content fails instead of being saved as `.png`. In the UI, a single-card save is renamed and logged when the chosen extension does not match reality.
- **失败不冒险 · Failures never risk data**：某份文件读不出来或写回失败时，暂存目录（`airlift-src-*`）会**刻意保留**，因为里面可能有还没写回手机的原始内容；成功时不留下任何东西，只留一个用于查属性的符号链接，`--release-artwork-link <udid>` 可以删掉它（App 换到别的手机后首次探测时会自动清理上一台的）。
  When a file cannot be read or written back, the staging tree (`airlift-src-*`) is **deliberately kept**, because it may still hold content that never made it back to the phone. A successful run leaves nothing except the symlink used for metadata lookups; `--release-artwork-link <udid>` removes it (the app cleans up the previous phone's link on the first probe after switching devices).
- **探测时机 · When probing happens**：识别到新卡会请求探测，但做了 1.2 s 防抖，一次扫描只跑一次；并发只排队不堆积。
  Detecting a card requests a probe, but requests are debounced by 1.2 s, so one scan runs it once; concurrent requests queue instead of piling up.

### 批量为什么把文件放进 `out/` 子目录 · Why the batch uses an `out/` subdirectory

设备端 `stage` 会校验生成名：前缀之后必须是**恰好 20 位小写十六进制**，不能带 `-0` 这类后缀。所以批量把搬出的文件放进**暂存目录内的 `out/`**，清理交给 `finish-write` 的 `RemoveGeneratedTree`，不在 Media 根目录另造多个 `airlift-recovered-*`。
On the device, `stage` validates generated names: after the prefix there must be **exactly 20 lowercase hex digits**, with no `-0` style suffix. The batch therefore moves files into **`out/` inside the staging tree** and lets `finish-write`'s `RemoveGeneratedTree` clean it up, instead of creating several `airlift-recovered-*` entries at the root of `Media/`.

## 6. 实测耗时 · Measured timings

| 场景 · Case | 耗时 · Time |
| --- | --- |
| 探测 · 冷（要新建符号链接）<br>Probe, cold (a new symlink is staged) | ~8–11 s |
| 探测 · 暖（复用已保留的链接）<br>Probe, warm (the kept link is reused) | 0.4–1.1 s（21 条路径的 `afc-stat-many` 约 0.3 s / about 0.3 s for 21 paths in one `afc-stat-many`） |
| 单卡下载 · Single download | 11–14 s |
| 批量下载 2–3 张（一趟往返）<br>Batch of 2–3 cards (one round trip) | 12.5–15 s |

时间几乎都花在第 2 节说的"快照 + zip 通道 + 同步 + 收尾"上。
Almost all of it is the "snapshot + zip channel + sync + cleanup" described in section 2.

## 7. 常见问题 · Troubleshooting

| 现象 · Symptom | 含义与处理 · Meaning and fix |
| --- | --- |
| 提示 "Unlock the iPhone…"<br>"Unlock the iPhone…" | 手机锁屏或未连接；解锁并保持亮屏后重试<br>The iPhone is locked or not connected; unlock it, keep the screen on, and retry |
| 某张卡没有下载按钮<br>A card has no download button | 日志里 `N card(s) can download original card artworks.` 说明探测成功；N=0 表示已知的卡里都没有这份文件<br>The log line `N card(s) can download original card artworks.` means probing succeeded; N=0 means none of the known cards has the manifest |
| 下载报 "no remote card artwork"<br>Download reports "no remote card artwork" | 这份文件读不到：该卡在这台手机上没打开过（去 Wallet 打开一次），或者确实没有<br>The manifest cannot be read: the card has never been opened on this iPhone (open it once in Wallet), or it truly has none |
| 下载报 "usable image (PNG, PDF, JPEG or GIF expected)"<br>Download reports "usable image (PNG, PDF, JPEG or GIF expected)" | 远端返回的不是图片（例如错误页），不会保存<br>The remote host returned something that is not an image (an error page, for example); nothing is saved |
| 手机上出现 `airlift-src-*` / `airlift-link-*`<br>`airlift-src-*` / `airlift-link-*` appear on the phone | 失败时刻意保留的暂存内容；符号链接可用 `--release-artwork-link` 清掉<br>Staging content kept on purpose after a failure; the symlink can be removed with `--release-artwork-link` |

> `.cache` / `FrontFace` 等渲染缓存的格式细节不再记录：相关解码代码已随旧的本地导出路径一起删除，当前实现只走远端的那份文件。
> Format details of the rendered caches (`.cache` / `FrontFace`) are no longer documented: that decoding code was removed together with the old local export path, and the current implementation only uses the remote manifest.
