> 此檔名為歷史保留；本版本說明統一使用繁體中文，主要入口為 [README.md](README.md)。

# Aircard · XiaoSha

**v1.2.4.114514** · macOS 14+ · Universal（arm64／x86_64）

**繁體中文** · [使用說明與疑難排解](docs/使用說明與疑難排解.md) · [免責聲明](DISCLAIMER.md)

> Apple Wallet 卡片外觀與鎖定畫面密碼主題工具的 XiaoSha 自訂版本。
> 原專案標示支援 iOS 18+；此自訂版曾在 iOS 27.0 上測試，但不保證所有裝置、卡片或操作皆相容。
> 基於 `airlift` AirTraffic 同步漏洞實作，無需越獄。

由 **[XiaoSha](https://github.com/XiaoSha-0711/AirCard)** 維護，以既有 AirCard 專案為基礎，整合繁體中文介面與下列自訂功能。


每次開啟 App 都會顯示免責聲明，閱讀並選擇繼續後即可進入主畫面。

---

## 此版本的自訂功能

- **全繁體中文介面與說明**：使用臺灣常用詞彙，提供繁體中文操作紀錄與疑難排解。
- **卡片本機改名**：自訂便於辨識的名稱，重新開啟後保留，不更動手機端卡片名稱。
- **上次寫入預覽**：分別顯示已成功寫入的外觀與待寫入圖片；預覽是本機紀錄。
- **卡號文字顏色**：設定 Wallet 卡片文字顏色，更新後需重新啟動 iPhone。
- **顯示末四碼設定**：可選「不變更」、「自訂」或「隱藏」；只修改顯示欄位，不變更實際付款卡號。
- **啟動免責聲明**：每次開啟先顯示，閱讀並選擇繼續後進入主畫面。
- **分階段更新紀錄**：顯示準備、寫入前比對、寫入及讀回驗證，失敗時附上排查提示。這些檢查不代表更新或還原必定成功。

## 原有功能

- 🎨 **自訂卡片外觀：** 為 Apple Pay 和錢包卡片設定圖片、紋理或銀行標誌。
- 🔢 **鎖定畫面密碼主題（.passthm）：** 將 `.passthm` 主題中的自訂按鍵圖片套用至 iOS 18+ 鎖定畫面密碼鍵盤。
- 🧩 **密碼主題編輯器：** 使用一張桌布產生無縫海報切片，或為每個按鍵單獨設定圖片。
- 🔍 **互動式圖片取景：** 在按鍵中平移、縮放圖片，並即時預覽 iPhone 鎖定畫面效果。
- ✏️ **編輯現有 .passthm 主題：** 在編輯器中開啟 Cowabunga 或 Nugget 主題包，修改按鍵圖片和取景位置，然後重新匯出或寫入手機。
- ⚡ **單卡與批次設定：** 為每張卡片設定不同外觀，或一鍵為選取卡片設定同一張圖片。
- 📱 **即時偵測卡片：** 在 iPhone 上輕點錢包卡片，即可掃描對應的卡片雜湊值。
- 🚀 **通用 macOS App：** 原生支援 **Apple Silicon** 和 **Intel（x86_64）** Mac，App 內附裝置通訊輔助工具和圖片處理功能。
- 📦 **無需額外設定：** 使用打包好的 App，無需安裝 Homebrew、額外 Python 套件或手動設定終端機環境。

---

## 安裝

### macOS 通用 DMG

1. 從 [Releases](https://github.com/XiaoSha-0711/AirCard/releases) 下載 `AirCard-v1.2.4.114514-universal.dmg`；自行建置的安裝檔位於 `build/AirCard.dmg`。
2. 開啟下載的 `.dmg`，將 **AirCard.app** 拖入**應用程式**資料夾。
3. 安裝檔同時包含 Apple Silicon 和 Intel Mac 版本。

> [!NOTE]
> **macOS 首次啟動提示（Gatekeeper）：**
> 如果首次啟動時提示無法驗證開發者，可嘗試以下方法：
> - **圖形介面：** 在「應用程式」中右鍵點擊（或按住 Control 點擊）`AirCard.app`，選擇**開啟**，再確認開啟。
> - **終端機：**
>   ```sh
>   sudo xattr -cr /Applications/AirCard.app
>   ```

---

## 自訂 Apple 錢包卡片

1. 將 iPhone 連接到 Mac，解鎖手機，並在出現提示時信任此電腦。
2. 在 AirCard 的**錢包卡片**頁面點擊**掃描卡片**。
3. 在 iPhone 上雙擊側邊按鈕開啟 Apple Pay，通過 Face ID 驗證後輕點卡片；如未偵測到，可再點一次。
4. 點擊卡片名稱旁的鉛筆，為卡片設定便於識別的名稱，例如「我的信用卡」。名稱僅儲存在本機，不會修改手機中的卡片；留空儲存可恢復預設名稱。
5. 點擊卡片預覽選擇圖片，或直接將圖片拖到卡片上。也可使用**批次設定外觀**。
6. 若要更改卡號文字顏色或末四碼，先在卡號顯示設定中選擇；末四碼可選擇保留、自訂四位數字或隱藏。
7. 選取需要更新的卡片，點擊**更新卡片**。
8. 寫入成功後，在 iPhone 上徹底關閉錢包 App 並重新開啟（或重新啟動手機），查看新外觀。

> [!TIP]
> 成功寫入的圖片會儲存為本機預覽，重新啟動 AirCard 後仍可查看。舊版未儲存的外觀紀錄，需要重新選擇圖片並成功寫入一次。取消待寫入的圖片後，會恢復顯示已有的上次寫入預覽。

如果操作失敗，請保留**執行紀錄**供排查；公開分享前請遮蔽裝置與卡片資訊。若出現還原失敗，請停止重試並保留復原檔，詳見[使用說明與疑難排解](docs/使用說明與疑難排解.md)。

修改文字顏色或顯示末四碼後，需重新啟動 iPhone。若 Wallet 空白，可在確認後端已結束後重新啟動手機，開啟 Wallet 等約一分鐘，再從多工畫面關閉並重新開啟；不保證每次還原錯誤都能自動恢復。

---

## 套用鎖定畫面密碼主題（.passthm）

1. 切換到頂部的**密碼主題（.passthm）**頁面。
2. 將 `.passthm` 檔案拖入 App，或點擊**選擇 .passthm 檔案**。
3. AirCard 會解析主題，並顯示密碼鍵盤的互動預覽。
4. 根據手機系統選擇目標版本、語言和字型樣式，然後點擊**寫入密碼主題**。
5. 重新啟動 iPhone，重新載入鎖定畫面快取後查看自訂密碼按鍵。

> [!TIP]
> **多語言與粗體支援：**
> AirCard 可產生不同系統語言及一般、粗體樣式對應的按鍵快取圖片（`--white` 和 `--white-bold`）。通用模式會寫入較多檔案；選擇手機實際使用的語言和字型樣式可縮短寫入時間。

## 製作與編輯密碼主題

1. 在密碼主題頁面切換到**主題編輯器**。
2. 選擇海報圖片進行切片，或為獨立按鍵分別新增圖示。
3. 在預覽中拖動圖片調整位置，使用滑桿縮放，並選擇無縫海報或圓形按鍵樣式。
4. 點擊**匯出 .passthm**儲存主題包，或點擊**寫入 iPhone**套用主題。

已載入的主題也可以通過**在編輯器中修改**繼續編輯。

---

## 從原始碼建置

在 macOS 上安裝 Xcode 或 Command Line Tools，然後執行：

```sh
git clone --branch xiaosha-v1.2.4.114514 https://github.com/XiaoSha-0711/AirCard.git
cd AirCard
chmod +x build.sh
./build.sh
```

此自訂版本目前位於 `xiaosha-v1.2.4.114514` 分支。建置腳本會編譯 `arm64` 與 `x86_64` 通用執行檔，產生 `build/AirCard.app` 與 `build/AirCard.dmg`。若只需要 App，可執行 `./build.sh --app-only`。


---

## 貢獻者

- **[XiaoSha](https://github.com/XiaoSha-0711/AirCard)**：此自訂版本、繁體中文介面與功能整合。

- **[@mak5er](https://github.com/mak5er)**：開發者 — [GitHub](https://github.com/mak5er) · [Twitter / X](https://x.com/mak5er)
- **[@Lumid-Off](https://github.com/Lumid-Off)**：貢獻者與開發者 — [GitHub](https://github.com/Lumid-Off) · [Twitter / X](https://x.com/LumidOff)
- **[@Wizzer](https://wizzer.cn)**：上游功能改進與中文化 — [GitHub](https://github.com/Wizzercn) · [Twitter / X](https://x.com/Wizzer_cn)
- **[AirLift](https://github.com/0xjohnnydev/airlift)**，作者 **[0xjohnny（@0xjohnnydev）](https://github.com/0xjohnnydev)**：提供原始 AirTraffic / ATAirlock 沙盒逃逸技術與概念驗證，是 `AirliftFFI` 的基礎。

## 致謝

核心技術基於 `airlift`（AirTraffic 同步沙盒逃逸）。


## 使用風險與問題回報

請先閱讀 [免責聲明](DISCLAIMER.md) 和 [使用說明與疑難排解](docs/使用說明與疑難排解.md)。本工具會修改手機資料；準備及讀取流程也可能暫時搬移檔案。若遇到還原失敗，請停止重試並保留復原檔。

如需回報問題，可至 [此 repo 的 Issues](https://github.com/XiaoSha-0711/AirCard/issues)，提供 App 版本、macOS／iOS 版本、操作步驟與已遮蔽敏感資訊的錯誤紀錄。請勿公開上傳完整 Wallet 資料庫、復原檔、裝置識別碼或卡片資訊。

## 授權

沿用原專案的 [MIT 授權](LICENSE)，保留原作者著作權與署名。

---

## 支持原作者

如果你覺得 AirCard 實用，可以透過原作者提供的以下管道支持後續開發：

- **PayPal**: [透過 PayPal 贊助](https://www.paypal.com/donate/?hosted_button_id=98QRTC2HFRA4Y)
- **TON**: `UQBm9KPhtMw-XVVjirUoa09wzrlyWsbeZhKfefl1Uw-qNZ-r`
- **USDT (TRC20)**: `TDkDMCyjYxgvkWUnQiF5Erk2RyPQMT6G1n`
- **USDT / BNB (BEP20)**: `0x0954dc491c502849d04956ef74634aa5931a08e8`
