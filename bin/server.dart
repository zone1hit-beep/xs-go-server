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
  );

  final asr = Asr(
    apiKey: env['GROQ_API_KEY'],
    model: env['XSGO_ASR_MODEL'] ?? 'whisper-large-v3-turbo',
  );

  final handler = const Pipeline()
      .addMiddleware(_cors())
      .addMiddleware(_jsonErrors())
      .addMiddleware(logRequests())
      .addHandler(buildRouter(db, ai, asr).call);

  final port = int.parse(env['PORT'] ?? '8091');
  final server = await io.serve(handler, '0.0.0.0', port);
  stdout.writeln('XS GO backend chạy ở http://${server.address.host}:${server.port}'
      ' (AI: ${ai.enabled ? "bật (${ai.model})" : "OFF - dùng fallback"}'
      ', ASR: ${asr.enabled ? "bật (${asr.model})" : "OFF"}, DB: $dbPath)');
}
