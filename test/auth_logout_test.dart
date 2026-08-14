import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:xs_go_server/ai.dart';
import 'package:xs_go_server/api.dart';
import 'package:xs_go_server/asr.dart';
import 'package:xs_go_server/db.dart';
import 'package:xs_go_server/security.dart';

void main() {
  late Directory tmp;
  late Db db;
  late Handler api;
  late int userId;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xsgo_auth_logout');
    db = Db.open('${tmp.path}/test.db');
    userId = db.createUser(
        'a@example.com', hashPassword('password-123'), 'vi', 'N5');
    api = buildRouter(db, Ai(), Asr()).call;
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Future<Response> request(String method, String path,
      {String? token, Map<String, Object?>? body}) async {
    return await Future<Response>.value(api(Request(
      method,
      Uri.parse('http://localhost$path'),
      headers: {
        if (token != null) 'authorization': 'Bearer $token',
        if (body != null) 'content-type': 'application/json',
      },
      body: body == null ? null : jsonEncode(body),
    )));
  }

  test('logout revokes old JWTs and a later login receives a usable token',
      () async {
    final oldToken = signJwt({'sub': userId, 'email': 'a@example.com'});
    expect((await request('GET', '/progress', token: oldToken)).statusCode, 200);

    final logout = await request('POST', '/auth/logout', token: oldToken);
    expect(logout.statusCode, 200);
    expect((await request('GET', '/progress', token: oldToken)).statusCode, 401,
        reason: 'a copied token must stop working after logout');

    final login = await request('POST', '/auth/login', body: {
      'email': 'a@example.com',
      'password': 'password-123',
    });
    expect(login.statusCode, 200);
    final payload = jsonDecode(await login.readAsString()) as Map<String, dynamic>;
    final newToken = payload['token'] as String;
    expect((await request('GET', '/progress', token: newToken)).statusCode, 200);
  });
}
