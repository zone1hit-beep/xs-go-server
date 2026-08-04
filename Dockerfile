# XS GO backend — Dart AOT build, image chạy ~15MB.
FROM dart:stable AS build
WORKDIR /app
COPY pubspec.* ./
RUN dart pub get
COPY . .
RUN dart pub get --offline && dart compile exe bin/server.dart -o /app/server

FROM debian:bookworm-slim
# libsqlite3 (DB), ca-certificates (HTTPS gọi AI), ffmpeg + yt-dlp (bóc audio
# YouTube cho tính năng AI tạo phụ đề).
RUN apt-get update && apt-get install -y --no-install-recommends \
    libsqlite3-dev ca-certificates ffmpeg python3 curl && \
    curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp \
      -o /usr/local/bin/yt-dlp && chmod a+rx /usr/local/bin/yt-dlp && \
    apt-get purge -y curl && apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/server /app/server
# DB SQLite ghi ở /data (mount volume để không mất dữ liệu khi deploy lại)
ENV XSGO_DB=/data/xs_go.db PORT=8091
VOLUME /data
EXPOSE 8091
CMD ["/app/server"]
