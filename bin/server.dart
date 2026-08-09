import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;

import 'package:xs_go_server/ai.dart';
import 'package:xs_go_server/asr.dart';
import 'package:xs_go_server/api.dart';
import 'package:xs_go_server/db.dart';
import 'package:xs_go_server/security.dart';

/// CORS cho phép app Flutter web/mobile gọi vào.
Middleware _cors() => (Handler inner) => (Request req) async {
      const headers = {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
        'Access-Control-Allow-Headers': 'Origin, Content-Type, Authorization',
      };
      if (req.method == 'OPTIONS') {
        return Response.ok('', headers: headers);
      }
      final res = await inner(req);
      return res.change(headers: headers);
    };

/// CACHE 20s cho các GET công khai nóng — 100k user mở Home cùng lúc thì
/// /playlists + /config chỉ chạm DB vài lần/phút thay vì mỗi request.
/// ⚠️ CHỈ cache route KHÔNG phụ thuộc người dùng: /playlists, /config luôn
/// public; /discover chỉ cache khi KHÔNG gửi token (có token thì kết quả lọc
/// theo danh sách chặn của từng người).
final Map<String, (int, String)> _hotCache = {};
Middleware _publicCache() => (Handler inner) => (Request req) async {
      final path = '/${req.url.path}';
      final cacheable = req.method == 'GET' &&
          (path == '/playlists' ||
              path == '/config' ||
              (path == '/discover' &&
                  req.headers['authorization'] == null));
      if (!cacheable) return inner(req);
      // Key gồm CẢ query (?lang=...) — /discover trả kết quả KHÁC NHAU theo
      // ngôn ngữ, cache theo path trần sẽ trộn lẫn ngôn ngữ giữa các khách.
      final key = req.url.query.isEmpty ? path : '$path?${req.url.query}';
      final now = DateTime.now().millisecondsSinceEpoch;
      final hit = _hotCache[key];
      if (hit != null && now - hit.$1 < 20000) {
        return Response.ok(hit.$2, headers: const {
          'content-type': 'application/json; charset=utf-8',
          'x-cache': 'hit',
        });
      }
      final res = await inner(req);
      if (res.statusCode == 200) {
        final body = await res.readAsString();
        // Chặn map phình vô hạn (query rác do khách gửi tuỳ ý).
        if (_hotCache.length > 64) {
          _hotCache.removeWhere((_, v) => now - v.$1 >= 20000);
          if (_hotCache.length > 64) _hotCache.clear();
        }
        _hotCache[key] = (now, body);
        return Response.ok(body, headers: const {
          'content-type': 'application/json; charset=utf-8',
        });
      }
      return res;
    };

/// NÉN GZIP các phản hồi JSON lớn (phụ đề video vài trăm KB → còn ~15-20%):
/// tiết kiệm băng thông máy chủ + tải nhanh hẳn trên mạng di động.
Middleware _gzip() => (Handler inner) => (Request req) async {
      final res = await inner(req);
      final accept = req.headers['accept-encoding'] ?? '';
      if (!accept.contains('gzip')) return res;
      final type = res.headers['content-type'] ?? '';
      if (!type.contains('json')) return res;
      final body = await res.readAsString();
      if (body.length < 1024) {
        return res.change(body: body);
      }
      final packed = gzip.encode(utf8.encode(body));
      return Response(res.statusCode,
          body: packed,
          headers: {
            ...res.headers,
            'content-encoding': 'gzip',
            'content-length': '${packed.length}',
          });
    };

/// Bắt lỗi để không lộ stack trace và trả JSON gọn: JSON hỏng → 400, còn lại 500.
Middleware _jsonErrors() => (Handler inner) => (Request req) async {
      const h = {'content-type': 'application/json; charset=utf-8'};
      try {
        return await inner(req);
      } on FormatException catch (e) {
        return Response(400,
            body: jsonEncode({'error': 'Dữ liệu không hợp lệ: ${e.message}'}),
            headers: h);
      } catch (e, st) {
        stderr.writeln('Lỗi máy chủ: $e\n$st');
        return Response(500, body: jsonEncode({'error': 'Lỗi máy chủ'}), headers: h);
      }
    };

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  configureSecurity(env);

  // BẢO MẬT: không cho chạy production với JWT secret mặc định (ai cũng biết →
  // tự làm giả token, mạo danh mọi tài khoản). Muốn chạy dev với secret mặc định
  // thì đặt XSGO_ALLOW_INSECURE=1 để xác nhận là cố ý.
  if (usingDefaultJwtSecret && env['XSGO_ALLOW_INSECURE'] != '1') {
    stderr.writeln('❌ TỪ CHỐI KHỞI ĐỘNG: chưa đặt XSGO_JWT_SECRET.\n'
        '   Đang dùng secret MẶC ĐỊNH (public) → bất kỳ ai cũng có thể làm giả JWT.\n'
        '   • Production: đặt biến môi trường XSGO_JWT_SECRET = một chuỗi ngẫu nhiên dài.\n'
        '   • Dev (chấp nhận rủi ro): đặt XSGO_ALLOW_INSECURE=1.');
    exitCode = 78; // EX_CONFIG
    return;
  }
  if (usingDefaultJwtSecret) {
    stderr.writeln('⚠️  CẢNH BÁO: đang dùng JWT secret mặc định (chế độ dev). '
        'KHÔNG dùng cấu hình này cho production.');
  }

  final dbPath = env['XSGO_DB'] ?? 'xs_go.db';
  final db = Db.open(dbPath);

  final ai = Ai(
    apiKey: env['ANTHROPIC_API_KEY'],
    model: env['XSGO_AI_MODEL'] ?? 'claude-opus-4-8',
    // Model RẺ cho dịch phụ đề (Haiku rẻ ~5x Opus); furigana giữ model chính.
    translateModel: env['XSGO_AI_MODEL_TRANSLATE'] ?? 'claude-opus-4-8',
  );

  final asr = Asr(
    apiKey: env['GROQ_API_KEY'],
    model: env['XSGO_ASR_MODEL'] ?? 'whisper-large-v3-turbo',
  );

  final handler = const Pipeline()
      .addMiddleware(_cors())
      .addMiddleware(_gzip()) // nén NGOÀI cùng (sau cache) — cache giữ bản thô
      .addMiddleware(_jsonErrors())
      .addMiddleware(logRequests())
      .addMiddleware(_publicCache())
      .addHandler(buildRouter(db, ai, asr).call);

  final port = int.parse(env['PORT'] ?? '8091');
  final server = await io.serve(handler, '0.0.0.0', port);
  stdout.writeln('XS GO backend chạy ở http://${server.address.host}:${server.port}'
      ' (AI: ${ai.enabled ? "bật (${ai.model} · dịch: ${ai.translateModel})" : "OFF - dùng fallback"}'
      ', ASR: ${asr.enabled ? "bật (${asr.model})" : "OFF"}, DB: $dbPath)');
}
