# XS GO Backend (Dart)

Backend mới cho app XS GO — **thay thế backend Replit cũ**. Viết bằng Dart (cùng
ngôn ngữ với app Flutter) nên chạy được ngay trên máy Mac chỉ cần Dart SDK, không
cần Node/Docker/Postgres.

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
