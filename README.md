# HomeTV Android TV Remote API

使用 Android TV Remote Protocol v2，無需 ADB 或開發人員模式。電腦與電視必須在同一個區域網路。

## 設定

1. 複製 `.env.example` 為 `.env`，將 `TV_HOST` 改成 Android TV 的區網 IP。
2. 確認電視已安裝並啟用 Android TV Remote Service（多數 Android TV 預載）。
3. 啟動 API：

```powershell
$env:TV_HOST = "192.168.1.50"
.venv\Scripts\python.exe -m uvicorn main:app --host 0.0.0.0 --port 8000
```

首次使用請在瀏覽器開啟 `http://localhost:8000/docs`：

1. 呼叫 `POST /api/tv/pair/start`。
2. 將電視顯示的配對碼送到 `POST /api/tv/pair/finish`，Body 為 `{ "code": "123456" }`。
3. 配對憑證會儲存在 `data/cert.pem` 與 `data/key.pem`，之後可直接連線。

## 常用 API

- `GET /api/tv/discover?timeout=3`：掃描區網中的 Android TV
- `GET /api/tv/status`
- `POST /api/tv/keys/home`
- `POST /api/tv/keys/volume_up`
- `POST /api/tv/keys/volume_down`
- `POST /api/tv/keys/play_pause`
- `POST /api/tv/text`，Body：`{ "text": "Hello" }`
- `POST /api/tv/apps/launch`，Body：`{ "uri": "https://www.youtube.com" }`

API 目前只應在區網使用，尚未加入使用者驗證，不要設定路由器轉發到網際網路。
