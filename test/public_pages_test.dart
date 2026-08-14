import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:xs_go_server/ai.dart';
import 'package:xs_go_server/api.dart';
import 'package:xs_go_server/asr.dart';
import 'package:xs_go_server/db.dart';

void main() {
  late Db db;
  late Handler api;

  setUp(() {
    db = Db.open(':memory:');
    api = buildRouter(db, Ai(), Asr()).call;
  });

  Future<Response> get(String path) => Future.sync(
      () => api(Request('GET', Uri.parse('http://localhost$path'))));

  test('/support là trang hỗ trợ riêng, không dùng /terms thay thế', () async {
    final response = await get('/support');
    final body = await response.readAsString();
    expect(response.statusCode, 200);
    expect(body, contains('Hỗ trợ XS GO'));
    expect(body, contains('zone1hit@gmail.com'));
  });

  test('legal pages dùng nội dung trung lập, không nhúng store hoặc giá',
      () async {
    for (final path in ['/privacy', '/terms', '/delete-account']) {
      final response = await get(path);
      final body = await response.readAsString();
      expect(response.statusCode, 200, reason: path);
      expect(body, isNot(contains('Google Play')), reason: path);
      expect(body, isNot(matches(RegExp(r'¥\s*[0-9]'))), reason: path);
    }
  });

  test('/config giữ legacy keys và trả thêm namespace theo platform',
      () async {
    const entries = {
      'selling_enabled': '0',
      'bjtPrice': 'legacy',
      'announce': 'legacy announcement',
      'selling_enabled_android': '0',
      'selling_enabled_ios': '0',
      'bjtPrice_android': 'android price',
      'announce_android': 'android announcement',
      'announce_ios': 'ios announcement',
    };
    for (final entry in entries.entries) {
      db.setConfig(entry.key, entry.value);
    }
    final response = await get('/config');
    final json = jsonDecode(await response.readAsString())
        as Map<String, dynamic>;
    final config = json['config'] as Map<String, dynamic>;
    expect(config['selling_enabled'], '0');
    expect(config['bjtPrice'], 'legacy');
    expect(config['announce'], 'legacy announcement');
    expect(config['selling_enabled_android'], '0');
    expect(config['selling_enabled_ios'], '0');
    expect(config['bjtPrice_android'], 'android price');
    expect(config['announce_android'], 'android announcement');
    expect(config['announce_ios'], 'ios announcement');
  });
}
