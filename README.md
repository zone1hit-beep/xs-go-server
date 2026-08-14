# XS GO Backend (Dart)

Backend mới cho app XS GO — **thay thế backend Replit cũ**. API chính viết bằng
Dart. Apple IAP có một verifier Node 22 tùy chọn trong cùng container vì XS GO
dùng thư viện server chính thức của Apple thay vì tự viết X.509/JWS trust.

## Stack
- **shelf + shelf_router** — HTTP server.
- **SQLite** (package `sqlite3`) — DB file `xs_go.db`, tự tạo + seed khi chạy lần đầu. Không cần cài server DB.
- **JWT auth** (tự cài HS256 trong `lib/security.dart`) + mật khẩu băm PBKDF2-HMAC-SHA256 → gỡ đúng điểm chặn "auth mobile" của backend Replit cũ (session cookie).
- **AI** qua **Claude API** (`lib/ai.dart`, gọi HTTP tới api.anthropic.com). Chưa có API key thì tự **fallback mock** để dev không tốn tiền.

## Chạy
```bash
export PATH="$HOME/development/flutter/bin:$PATH"   # có sẵn dart
cd ~/development/xs_go_server
dart pub get            # ⚠️ pub hay treo socket — kill & chạy lại vài lần (giống app Flutter)
dart run bin/server.dart
```
Mặc định lắng nghe `http://0.0.0.0:8091`.

### Biến môi trường
| Biến | Ý nghĩa | Mặc định |
|---|---|---|
| `ANTHROPIC_API_KEY` | Bật AI dịch + luyện nói thật | (trống → fallback mock) |
| `XSGO_AI_MODEL` | Model Claude | `claude-opus-4-8` |
| `XSGO_JWT_SECRET` | Khóa ký JWT (đổi khi lên production) | dev secret |
| `XSGO_DB` | Đường dẫn file SQLite | `xs_go.db` |
| `PORT` | Cổng | `8091` |

### Apple verifier tùy chọn

Apple IAP mặc định fail-closed và không ảnh hưởng API Google Billing hiện hữu.
Sidecar chỉ được supervisor khởi động khi toàn bộ cấu hình dưới đây hợp lệ; nếu
thiếu hoặc chỉ cấu hình một phần, Dart vẫn chạy bình thường trên `8091` và Apple
verify tiếp tục trả unavailable, không cấp entitlement.

| Biến | Ý nghĩa |
|---|---|
| `APPLE_IAP_KEY_PATH` | File private `.p8` chỉ tồn tại ở runtime |
| `APPLE_IAP_KEY_ID` | App Store Connect In-App Purchase Key ID |
| `APPLE_IAP_ISSUER_ID` | App Store Connect Issuer ID |
| `APPLE_BUNDLE_ID` | Bundle ID đã đăng ký |
| `APPLE_APP_ID` | Numeric Apple app ID |
| `APPLE_ENVIRONMENT` | `SANDBOX` hoặc `PRODUCTION` |
| `XSGO_APPLE_VERIFIER_TOKEN` | Shared token ngẫu nhiên tối thiểu 32 ký tự, chỉ từ ENV |
| `APPLE_IAP_PRIVATE_KEY_BASE64` | Tùy chọn cho Fly: key base64 được materialize mode `0600` vào `APPLE_IAP_KEY_PATH` |

Node chỉ bind `127.0.0.1:9000`; Fly/public network không expose port này. `GET
/health` của sidecar chỉ trả readiness, không trả credential metadata.

> 💡 Dịch phụ đề là tác vụ khối lượng lớn. Nếu muốn rẻ hơn Opus, đặt
> `XSGO_AI_MODEL=claude-haiku-4-5`. Bản dịch được **cache trong SQLite** nên mỗi
> câu chỉ gọi AI một lần.

## API
| Method | Path | Mô tả |
|---|---|---|
| GET | `/health` | Kiểm tra server + trạng thái AI |
| POST | `/auth/register` | `{email,password,nativeLang,level}` → `{token,user}` |
| POST | `/auth/login` | `{email,password}` → `{token,user}` |
| POST | `/auth/social` | `{provider,providerId,email?}` → `{token,user}` (Google/Apple/Facebook; upsert theo provider) |
| GET | `/videos` | Danh sách video |
| GET | `/videos/:id?lang=vi` | Chi tiết video + câu (tokens furigana, words, bản dịch) |
| POST | `/videos/:id/translate` | `{lang}` → dịch các câu sang ngôn ngữ đó (AI, cache lại) |
| POST | `/translate` | `{texts:[...], lang}` → dịch chuỗi UI/giáo trình sang ngôn ngữ user (cache theo hash; lang=vi hoặc AI off → giữ nguyên nguồn) |
| GET | `/speaking/scenarios` | Danh sách tình huống luyện nói |
| POST | `/speaking` | `{scenario,message,lang}` → `{reply}` (AI) |
| GET | `/vocab` | (Bearer) kho từ vựng của user |
| POST | `/vocab` | (Bearer) `{term,reading,meaning,jlpt}` → thêm (không trùng term) |
| DELETE | `/vocab/:id` | (Bearer) xoá 1 từ |
| GET | `/progress` | (Bearer token) tiến độ học |
| POST | `/progress` | (Bearer token) `{goalWords?,wordsLearned?}` → cập nhật streak/từ |

Auth: gửi header `Authorization: Bearer <token>` cho các route `/progress`.

## Nối với app Flutter
App gọi qua `lib/services/api.dart`, `baseUrl` mặc định `http://localhost:8091`
(override: `flutter run --dart-define=XSGO_API=https://...`). Video list + Study +
Luyện nói đã nối; nếu backend không chạy, app **tự fallback dữ liệu mẫu**.
