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
