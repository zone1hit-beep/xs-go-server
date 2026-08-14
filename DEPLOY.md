# Deploy XS GO backend ra URL công khai

App điện thoại thật cần backend ở URL công khai (hiện mới chạy `localhost:8091`).
Đã có sẵn `Dockerfile` (Dart AOT + SQLite, cần volume `/data` để giữ DB).

## Phương án nhanh nhất (0đ để bắt đầu): Fly.io
Đã có sẵn `fly.toml` (region Singapore + volume `/data`) và `.dockerignore` → deploy
gần như 1 lệnh, không phải sửa file:
```bash
brew install flyctl           # (máy chưa có Homebrew thì cài trước)
fly auth signup               # tạo tài khoản (cần thẻ nhưng gói nhỏ miễn phí)
cd ~/development/xs_go_server
fly launch --copy-config --no-deploy   # dùng fly.toml sẵn có (giữ tên app/region)
fly volumes create data --size 1 --region sin
fly secrets set XSGO_JWT_SECRET=$(openssl rand -hex 32) \
               XSGO_ADMIN_EMAIL=<email-cua-sep> \
               ANTHROPIC_API_KEY=sk-ant-...        # ANTHROPIC_API_KEY: có thì bật AI, chưa có bỏ qua
fly deploy
```
→ được URL dạng `https://xs-go-server.fly.dev`.
> Nếu tên `xs-go-server` đã có người dùng, `fly launch` sẽ hỏi đổi tên — cứ đặt tên khác,
> URL đổi theo. `XSGO_ADMIN_EMAIL` là email sếp muốn tự động thành admin.

## Phương án khác
- **Google Cloud Run**: `gcloud run deploy` với Dockerfile này — nhưng SQLite trên
  Cloud Run không bền (filesystem tạm). Chỉ dùng nếu chuyển DB sang Cloud SQL/Turso.
- **VPS bất kỳ** (đã có Docker): `docker build -t xsgo . && docker run -d -p 8091:8091 -v xsgo-data:/data -e ANTHROPIC_API_KEY=... xsgo`
- **Test nhanh trên điện thoại cùng Wi-Fi (không cần deploy)**: chạy backend trên Mac
  rồi build app với IP LAN: `flutter run --dart-define=XSGO_API=http://192.168.x.x:8091`

## Sau khi có URL
Build app trỏ về URL đó:
```bash
flutter build apk --dart-define=XSGO_API=https://xs-go-server.fly.dev
```

## Biến môi trường production
| Biến | Bắt buộc? | Ghi chú |
|---|---|---|
| `XSGO_JWT_SECRET` | ✅ | ĐỔI khỏi dev secret — `openssl rand -hex 32` |
| `ANTHROPIC_API_KEY` | Nên có | Bật AI dịch + luyện nói + furigana phụ đề |
| `GROQ_API_KEY` | Nên có | Bật AI bóc tiếng (Whisper) để TẠO PHỤ ĐỀ tự động |
| `XSGO_AI_MODEL` | — | `claude-haiku-4-5` nếu muốn rẻ |
| `XSGO_DB` | — | Mặc định `/data/xs_go.db` trong Docker |

## Phase 3B — Apple notification policy/backlog

- Permanent malformed input (invalid/oversized JSON or missing/oversized
  `signedPayload`) and evidence rejected by the configured JWS verifier are
  acknowledged with HTTP 200 plus `discarded: true`. They cannot become valid
  through retry. Transient verifier/config/runtime failures return non-2xx so
  App Store Server Notifications V2 retries them. HTTP 429 is reserved for the
  deliberately wide per-IP abuse limit (600 requests/minute).
- **P3-2 — raw JWS retention:** `store_event_inbox.signed_payload` is currently
  retained for idempotency/reconciliation. Before production rollout, define a
  retention period and encrypted-at-rest archival/purge procedure; operational
  logs must continue to exclude raw JWS and transaction identifiers.
- **P3-3 — malformed retry operations:** the permanent/transient HTTP policy is
  implemented above. Before production rollout, add counters/alerts for each
  discard reason and transient failure class so verifier outages are distinct
  from hostile malformed traffic without logging payload contents.

## Apple verifier sidecar — deployment gate (chưa được thực hiện)

Phase sidecar chỉ chuẩn bị code; **không chạy các lệnh dưới đây** cho đến khi có
phê duyệt deploy riêng. Dart vẫn là public service ở `8091`; Node 22 chỉ nghe
`127.0.0.1:9000`. Docker supervisor chỉ khởi động Node khi toàn bộ Apple config
hợp lệ, nhưng Node chết không được làm Dart/container dừng: Apple verify trả 503
fail-closed còn Android/API vẫn phục vụ. Chỉ Dart chết mới terminate Node và
thoát container để Fly restart. Thiếu/partial config thì container chạy
Dart-only để bảo toàn Android.

Trước deploy Sandbox, owner phải:

1. Lấy App Store Connect In-App Purchase key `.p8`, Key ID và Issuer ID; xác
   nhận key có quyền gọi App Store Server API. File `.p8` không được commit,
   copy vào image hoặc ghi log.
2. Xác nhận Bundle ID, numeric Apple app ID, `SANDBOX`, và tạo shared token nội
   bộ ngẫu nhiên tối thiểu 32 ký tự.
3. Base64 key cục bộ, đặt nội dung đó vào Fly secret
   `APPLE_IAP_PRIVATE_KEY_BASE64`, đồng thời đặt
   `APPLE_IAP_KEY_PATH=/run/xsgo-secrets/apple-iap.p8`. Supervisor chỉ tạo file
   runtime mode `0600`.
4. Đặt các biến còn lại bằng `fly secrets set`: `APPLE_IAP_KEY_ID`,
   `APPLE_IAP_ISSUER_ID`, `APPLE_BUNDLE_ID`, `APPLE_APP_ID`,
   `APPLE_ENVIRONMENT`, `APPLE_IAP_KEY_PATH`,
   `XSGO_APPLE_VERIFIER_TOKEN`. Không đưa giá trị vào shell history/shared docs.
5. Cung cấp transaction Sandbox/TestFlight thật và cấu hình Notifications V2
   Sandbox URL sau khi deployment được duyệt. Chạy purchase/restore,
   notification lifecycle và reconciliation trước khi cân nhắc Production.

Get Transaction Info với ID giả chỉ kiểm tra credential/network/API auth. Lỗi
typed `TRANSACTION_ID_NOT_FOUND` là PASS cho lớp đó nhưng **không** chứng minh
JWS purchase verification. Production/selling phải tiếp tục OFF cho đến khi có
evidence end-to-end bằng transaction thật.
