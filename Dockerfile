# XS GO backend — Dart public API + private Node Apple verifier sidecar.
FROM dart:stable AS dart-build
WORKDIR /app
COPY pubspec.* ./
RUN dart pub get
COPY . .
RUN dart pub get --offline && dart compile exe bin/server.dart -o /app/server

FROM node:22-bookworm-slim AS node-deps
WORKDIR /app/apple_verifier
COPY apple_verifier/package.json apple_verifier/package-lock.json ./
RUN npm ci --omit=dev

FROM node:22-bookworm-slim
# libsqlite3 (DB), ca-certificates (HTTPS gọi AI), ffmpeg + yt-dlp (bóc audio
# YouTube cho tính năng AI tạo phụ đề).
RUN apt-get update && apt-get install -y --no-install-recommends \
    libsqlite3-dev ca-certificates ffmpeg python3 curl && \
    curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp \
      -o /usr/local/bin/yt-dlp && chmod a+rx /usr/local/bin/yt-dlp && \
    apt-get purge -y curl && apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=dart-build /app/server /app/server
COPY --from=node-deps /app/apple_verifier/node_modules /app/apple_verifier/node_modules
COPY apple_verifier/package.json /app/apple_verifier/package.json
COPY apple_verifier/src /app/apple_verifier/src
COPY apple_verifier/certs /app/apple_verifier/certs
# DB SQLite ghi ở /data (mount volume để không mất dữ liệu khi deploy lại)
ENV XSGO_DB=/data/xs_go.db PORT=8091
VOLUME /data
EXPOSE 8091
CMD ["node", "/app/apple_verifier/src/supervisor.js"]
