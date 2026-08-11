/// Đăng nhập Apple/Google bằng EMAIL ADMIN — nới đúng một khe cho chính chủ
/// (11/8/2026, sếp duyệt). Kiểm 2 tầng:
///  1. `blockAdminSocial` — bảng chân trị đầy đủ của điều kiện chặn.
///  2. `Db.upsertSocial` — khi được cho qua, phải GỘP vào tài khoản admin sẵn
///     có (không tạo tài khoản mới, không đổi role trong DB).
import 'dart:io';

import 'package:test/test.dart';
import 'package:xs_go_server/api.dart' show blockAdminSocial;
import 'package:xs_go_server/db.dart';

void main() {
  group('blockAdminSocial — bảng chân trị', () {
    const admin = 'boss@xsgo.app';

    test('email khác admin: KHÔNG chặn, kể cả chưa xác minh', () {
      expect(
          blockAdminSocial(
              email: 'hocvien@example.com',
              emailVerified: false,
              adminEmail: admin,
              adminAccountExists: true),
          isFalse);
    });

    test('không có email (Apple ẩn email): KHÔNG chặn', () {
      expect(
          blockAdminSocial(
              email: null,
              emailVerified: true,
              adminEmail: admin,
              adminAccountExists: true),
          isFalse);
    });

    test('email admin + đã xác minh + tài khoản sẵn có: CHO QUA (chính chủ)',
        () {
      expect(
          blockAdminSocial(
              email: admin,
              emailVerified: true,
              adminEmail: admin,
              adminAccountExists: true),
          isFalse);
    });

    test('email admin nhưng CHƯA xác minh: chặn (mạo danh)', () {
      expect(
          blockAdminSocial(
              email: admin,
              emailVerified: false,
              adminEmail: admin,
              adminAccountExists: true),
          isTrue);
    });

    test('email admin nhưng tài khoản CHƯA tồn tại: chặn (không cho tạo mới)',
        () {
      expect(
          blockAdminSocial(
              email: admin,
              emailVerified: true,
              adminEmail: admin,
              adminAccountExists: false),
          isTrue);
    });
  });

  group('upsertSocial với email admin đã xác minh', () {
    late Directory tmp;
    late Db db;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('xsgo_admin_social');
      db = Db.open('${tmp.path}/t.db');
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('GỘP vào tài khoản admin sẵn có, giữ nguyên id + role', () {
      final adminId = db.createUser('boss@xsgo.app', 'x', 'vi', 'N5');
      db.setRole(adminId, 'admin');

      final merged = db.upsertSocial(
          provider: 'apple',
          providerId: 'apple-uid-1',
          email: 'boss@xsgo.app',
          emailVerified: true);

      expect(merged['id'], adminId, reason: 'phải là CÙNG tài khoản');
      expect(db.userById(adminId)!['role'], 'admin',
          reason: 'role đọc từ DB, không bị ghi đè');
      // Lần sau đăng nhập bằng provider id → vẫn ra đúng tài khoản đó.
      final again = db.upsertSocial(
          provider: 'apple', providerId: 'apple-uid-1', emailVerified: false);
      expect(again['id'], adminId);
    });

    test('email admin CHƯA xác minh: không gộp, tạo hồ sơ placeholder riêng',
        () {
      final adminId = db.createUser('boss@xsgo.app', 'x', 'vi', 'N5');
      final u = db.upsertSocial(
          provider: 'apple',
          providerId: 'apple-uid-2',
          email: 'boss@xsgo.app',
          emailVerified: false);
      expect(u['id'], isNot(adminId));
      expect(u['email'], 'apple_apple-uid-2@xsgo.social',
          reason: 'email chưa xác minh KHÔNG được ghi vào hồ sơ');
    });
  });
}
