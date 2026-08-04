import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'ai.dart';
import 'asr.dart';
import 'db.dart';
import 'security.dart';

/// Kiểm tra video YouTube có CHO PHÉP NHÚNG không (qua oembed).
/// 200 = nhúng được; 401/403/404 = chặn/private/không tồn tại.
/// Lỗi mạng → trả `null` (không kết luận được, để caller tự quyết).
Future<bool?> _youtubeEmbeddable(String id) async {
  HttpClient? client;
  try {
    client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    final uri = Uri.parse(
        'https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=$id&format=json');
    final req = await client.getUrl(uri);
    final resp = await req.close();
    await resp.drain<void>();
    return resp.statusCode == 200;
  } catch (_) {
    return null; // mạng lỗi — không chặn
  } finally {
    client?.close(force: true);
  }
}

/// Đổi mốc thời gian phụ đề ("mm:ss", "h:mm:ss", "mm:ss.d" hoặc số giây) → ms.
int? _parseSubTime(String s) {
  final parts = s.trim().split(':');
  try {
    double total;
    if (parts.length == 3) {
      total = int.parse(parts[0]) * 3600 +
          int.parse(parts[1]) * 60 +
          double.parse(parts[2]);
    } else if (parts.length == 2) {
      total = int.parse(parts[0]) * 60 + double.parse(parts[1]);
    } else {
      total = double.parse(parts[0]);
    }
    return (total * 1000).round();
  } catch (_) {
    return null;
  }
}

/// Phân tích chữ Nhật có ký hiệu furigana `[漢字|かな]` thành (tokens, words, plain).
/// - tokens: để hiển thị (phần trong ngoặc → tappable kèm reading).
/// - words: từ tra được (mỗi cặp [từ|đọc]).
/// - plain: câu trơn (bỏ ngoặc) để lưu text_jp.
(List<Map<String, dynamic>>, List<Map<String, dynamic>>, String) _parseJp(
    String text) {
  final tokens = <Map<String, dynamic>>[];
  final words = <Map<String, dynamic>>[];
  final re = RegExp(r'\[([^\|\]]+)\|([^\]]+)\]');
  var last = 0;
  for (final m in re.allMatches(text)) {
    if (m.start > last) {
      tokens.add({'surface': text.substring(last, m.start), 'tappable': false});
    }
    final surface = m.group(1)!;
    final reading = m.group(2)!;
    tokens.add({'surface': surface, 'reading': reading, 'tappable': true});
    words.add(
        {'term': surface, 'reading': reading, 'meaning': '', 'jlpt': ''});
    last = m.end;
  }
  if (last < text.length) {
    tokens.add({'surface': text.substring(last), 'tappable': false});
  }
  final plain = text.replaceAllMapped(re, (m) => m.group(1)!);
  return (tokens, words, plain);
}

/// Phân tích khối phụ đề admin dán vào. Mỗi dòng:
///   `mm:ss  <câu tiếng Nhật, có thể [漢字|かな]>  [ | bản dịch tiếng Việt]`
/// endMs = mốc dòng kế tiếp (dòng cuối +4s).
List<Map<String, dynamic>> parseSubtitles(String raw) {
  final out = <Map<String, dynamic>>[];
  for (final ln in const LineSplitter().convert(raw)) {
    final line = ln.trim();
    if (line.isEmpty) continue;
    final sp = line.indexOf(RegExp(r'\s'));
    if (sp < 0) continue;
    final startMs = _parseSubTime(line.substring(0, sp));
    if (startMs == null) continue;
    var rest = line.substring(sp + 1).trim();
    var vi = '';
    final bar = rest.indexOf(' | '); // dấu tách bản dịch (furigana dùng | KHÔNG có khoảng trắng)
    if (bar >= 0) {
      vi = rest.substring(bar + 3).trim();
      rest = rest.substring(0, bar).trim();
    }
    final (tokens, words, plain) = _parseJp(rest);
    out.add({
      'startMs': startMs,
      'textJp': plain,
      'tokens': tokens,
      'words': words,
      'vi': vi,
    });
  }
  for (var i = 0; i < out.length; i++) {
    out[i]['endMs'] =
        i + 1 < out.length ? out[i + 1]['startMs'] : (out[i]['startMs'] as int) + 4000;
  }
  return out;
}

/// Ngôn ngữ đích được phép dịch (chống spam ngôn ngữ lạ → gọi AI vô tội vạ).
const _supportedLangs = {'vi', 'id', 'my', 'ne', 'en', 'ja'};

/// Giới hạn tần suất đơn giản (in-memory) cho các endpoint gọi AI —
/// chống lạm dụng/tốn tiền API. Tối đa [_aiMaxPerWindow] request / [_aiWindowMs] / IP.
final Map<String, List<int>> _aiHits = {};
const _aiMaxPerWindow = 40;
const _aiWindowMs = 60 * 1000;

bool _aiRateLimited(String ip) => _limited('ai:$ip', _aiMaxPerWindow, _aiWindowMs);

/// Bộ đếm cửa sổ trượt dùng chung (rate limit theo key bất kỳ: IP, email...).
bool _limited(String key, int max, int windowMs) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final list = _aiHits.putIfAbsent(key, () => <int>[]);
  list.removeWhere((t) => now - t > windowMs);
  if (list.length >= max) return true;
  list.add(now);
  // Dọn bớt key cũ để map không phình vô hạn.
  if (_aiHits.length > 5000) {
    _aiHits.removeWhere((_, v) => v.isEmpty || now - v.last > windowMs);
  }
  return false;
}

String _clientIp(Request req) {
  // Fly.io đặt Fly-Client-IP — client KHÔNG giả được. KHÔNG tin X-Forwarded-For
  // (client tự gửi phần tử đầu → vượt rate limit).
  final fly = req.headers['fly-client-ip'];
  if (fly != null && fly.isNotEmpty) return fly.trim();
  final ci = req.context['shelf.io.connection_info'];
  if (ci is HttpConnectionInfo) return ci.remoteAddress.address;
  return 'unknown';
}

/// Xây router API cho XS GO.
/// Tải audio của 1 video YouTube về file tạm bằng yt-dlp (+ ffmpeg). Trả file
/// mp3, hoặc null nếu thiếu công cụ / YouTube chặn / lỗi. Chỉ chạy trên server
/// đã cài yt-dlp & ffmpeg (xem Dockerfile).
Future<File?> _downloadYoutubeAudio(String ytId) async {
  Directory? dir;
  try {
    dir = await Directory.systemTemp.createTemp('xsgo_asr_');
    final outTpl = '${dir.path}/audio.%(ext)s';
    // Proxy dân cư (nếu có) để lách chặn 403 của YouTube với IP máy chủ.
    // Đặt secret XSGO_PROXY=http://user:pass@host:port trên Fly.
    final proxy = Platform.environment['XSGO_PROXY'] ?? '';
    final res = await Process.run('yt-dlp', [
      '-f', 'bestaudio/best',
      '-x', '--audio-format', 'mp3', '--audio-quality', '5',
      '--extractor-args', 'youtube:player_client=android,ios,tv,web',
      if (proxy.isNotEmpty) ...['--proxy', proxy],
      '--no-playlist', '--no-warnings', '--quiet',
      '-o', outTpl,
      'https://www.youtube.com/watch?v=$ytId',
    ]);
    if (res.exitCode != 0) {
      stderr.writeln('[ASR] yt-dlp exit ${res.exitCode}: ${res.stderr}');
      return null;
    }
    final mp3 = File('${dir.path}/audio.mp3');
    if (mp3.existsSync()) return mp3;
    // Phòng khi định dạng khác: lấy file đầu tiên trong thư mục.
    final files = dir.listSync().whereType<File>().toList();
    return files.isEmpty ? null : files.first;
  } catch (e) {
    stderr.writeln('[ASR] download error: $e');
    return null;
  }
}

/// Lấy phụ đề tiếng Nhật CÓ SẴN của video YouTube (KHÔNG tải media → nhẹ, né
/// chặn 403). Trả list {startMs, endMs, text}; rỗng nếu video không có caption
/// hoặc bị chặn. Ưu tiên dùng cái này trước Whisper (nhẹ + miễn phí).
Future<List<Map<String, dynamic>>> _fetchYoutubeCaptions(String ytId) async {
  Directory? dir;
  try {
    dir = await Directory.systemTemp.createTemp('xsgo_sub_');
    final proxy = Platform.environment['XSGO_PROXY'] ?? '';
    final res = await Process.run('yt-dlp', [
      '--skip-download',
      '--write-subs', '--write-auto-subs',
      '--sub-langs', 'ja',
      '--sub-format', 'json3',
      '--extractor-args', 'youtube:player_client=android,ios,tv,web',
      if (proxy.isNotEmpty) ...['--proxy', proxy],
      '--no-playlist', '--no-warnings', '--quiet',
      '-o', '${dir.path}/sub',
      'https://www.youtube.com/watch?v=$ytId',
    ]);
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json3'))
        .toList();
    if (files.isEmpty) {
      stderr.writeln('[SUB] không có caption ja (exit ${res.exitCode}): '
          '${res.stderr.toString().trim()}');
      return const [];
    }
    final data =
        jsonDecode(await files.first.readAsString()) as Map<String, dynamic>;
    return parseJson3Captions(data);
  } catch (e) {
    stderr.writeln('[SUB] caption error: $e');
    return const [];
  } finally {
    try {
      dir?.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// Phân tích caption YouTube định dạng **json3** thành danh sách CÂU, giữ
/// **mốc thời gian TỪNG TỪ** (để tô sáng chữ đang đọc chính xác).
///
/// Định dạng json3 (đã kiểm chứng bằng dữ liệu thật):
/// - `events` xen kẽ: event `aAppend=1` chỉ chứa `"\n"` (xoá dòng) → BỎ QUA;
///   event nội dung có `segs`, mỗi seg là MỘT TỪ kèm `tOffsetMs` (lệch so với
///   `tStartMs` của event).
/// - `dDurationMs` của các event CHỒNG LẤN nhau → KHÔNG dùng để tính kết thúc.
/// - Các event là mảnh vụn cắt giữa câu (`てい` + `ます…`) → gộp lại thành câu
///   trọn vẹn theo dấu câu 。！？ (hoặc khi quá dài) cho dễ học.
///
/// Trả list: `{startMs, endMs, text, words: [{tMs, text}]}`.
List<Map<String, dynamic>> parseJson3Captions(Map<String, dynamic> data) {
  final events = (data['events'] as List?) ?? const [];
  // 1) Gom TỪNG TỪ kèm mốc tuyệt đối.
  final words = <Map<String, dynamic>>[]; // {tMs, text}
  for (final e in events) {
    if (e is! Map) continue;
    final segs = (e['segs'] as List?) ?? const [];
    if (segs.isEmpty) continue;
    final base = (e['tStartMs'] as num?)?.round() ?? 0;
    for (final s in segs) {
      if (s is! Map) continue;
      final raw = (s['utf8'] as String?) ?? '';
      // Bỏ marker xuống dòng / khoảng trắng thuần (event aAppend).
      final t = raw.replaceAll('\n', '').trim();
      if (t.isEmpty) continue;
      final off = (s['tOffsetMs'] as num?)?.round() ?? 0;
      // 'seq' = thứ tự xuất hiện — khóa phụ khi sort để KHÔNG đảo chữ lúc
      // 2 từ trùng mốc thời gian (List.sort của Dart không ổn định với list
      // >32 phần tử; trùng mốc là có thật vì các event json3 chồng lấn nhau).
      words.add({'tMs': base + off, 'text': t, 'seq': words.length});
    }
  }
  if (words.isEmpty) return const [];
  words.sort((a, b) {
    final c = (a['tMs'] as int).compareTo(b['tMs'] as int);
    return c != 0 ? c : (a['seq'] as int).compareTo(b['seq'] as int);
  });

  // 2) Gộp từ thành CÂU/DÒNG phụ đề.
  //    ⚠️ Auto-caption tiếng Nhật KHÔNG có dấu câu → không thể chỉ dựa vào 。！？.
  //    Ngưỡng dưới đây ĐO TỪ DỮ LIỆU THẬT (1531 từ): khoảng cách giữa 2 từ liền
  //    mạch p50=360ms, p80=600ms; nghỉ thật (ngắt ý) ≥800ms → ~7 từ/dòng, đúng
  //    độ dài một dòng phụ đề dễ đọc.
  const maxChars = 32; // dòng phụ đề tiếng Nhật dễ đọc ~20-32 chữ
  const maxSpanMs = 7000; // không để 1 dòng dài quá 7s
  const gapMs = 800; // nghỉ ≥0,8s = ngắt ý → sang dòng mới
  final sentences = <Map<String, dynamic>>[];
  var cur = <Map<String, dynamic>>[];
  var curChars = 0;

  void flush() {
    if (cur.isEmpty) return;
    final text = cur.map((w) => w['text'] as String).join();
    if (text.trim().isNotEmpty) {
      sentences.add({
        'startMs': cur.first['tMs'],
        // endMs tạm = mốc từ cuối; sẽ chỉnh lại bằng mốc câu kế ở bước 3.
        'endMs': cur.last['tMs'],
        'text': text,
        'words': List<Map<String, dynamic>>.from(cur),
      });
    }
    cur = [];
    curChars = 0;
  }

  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    if (cur.isNotEmpty) {
      final gap = (w['tMs'] as int) - (cur.last['tMs'] as int);
      final span = (w['tMs'] as int) - (cur.first['tMs'] as int);
      if (gap >= gapMs || span >= maxSpanMs || curChars >= maxChars) flush();
    }
    cur.add(w);
    curChars += (w['text'] as String).length;
    // Ngắt câu ngay sau dấu kết câu tiếng Nhật.
    if (RegExp(r'[。．！？!?]$').hasMatch(w['text'] as String)) flush();
  }
  flush();

  // 2b) GỘP DÒNG VỤN: auto-caption hay cắt lệch (vd "ましょう" đứng một mình).
  //     Dòng quá ngắn thì nhập vào dòng liền kề — NHƯNG chỉ khi hai dòng thực
  //     sự liền mạch: nghỉ giữa chúng < [mergeGapMs]. Nghỉ dài = ngắt ý thật,
  //     gộp vào sẽ làm phụ đề lệch tiếng nói.
  const minChars = 8;
  const mergeGapMs = 1200;
  int gapBetween(Map<String, dynamic> a, Map<String, dynamic> b) {
    final aw = (a['words'] as List).cast<Map<String, dynamic>>();
    final bw = (b['words'] as List).cast<Map<String, dynamic>>();
    if (aw.isEmpty || bw.isEmpty) return 1 << 30;
    return (bw.first['tMs'] as int) - (aw.last['tMs'] as int);
  }

  for (var i = 0; i < sentences.length; i++) {
    final s = sentences[i];
    final text = s['text'] as String;
    if (text.length >= minChars) continue;
    final ws = (s['words'] as List).cast<Map<String, dynamic>>();
    // Ưu tiên gộp về SAU (câu vụn thường là đuôi/đầu của ý kế tiếp).
    Map<String, dynamic>? pick;
    var toNext = false;
    if (i + 1 < sentences.length) {
      final n = sentences[i + 1];
      final span = (n['endMs'] as int) - (s['startMs'] as int);
      if ((text.length + (n['text'] as String).length) <= maxChars &&
          span <= maxSpanMs &&
          gapBetween(s, n) < mergeGapMs) {
        pick = n;
        toNext = true;
      }
    }
    if (pick == null && i > 0) {
      final p = sentences[i - 1];
      final span = (s['endMs'] as int) - (p['startMs'] as int);
      if (((p['text'] as String).length + text.length) <= maxChars &&
          span <= maxSpanMs &&
          gapBetween(p, s) < mergeGapMs) {
        pick = p;
      }
    }
    if (pick == null) continue;
    final pw = (pick['words'] as List).cast<Map<String, dynamic>>();
    if (toNext) {
      pick['text'] = text + (pick['text'] as String);
      pick['startMs'] = s['startMs'];
      pick['words'] = [...ws, ...pw];
    } else {
      pick['text'] = (pick['text'] as String) + text;
      pick['endMs'] = s['endMs'];
      pick['words'] = [...pw, ...ws];
    }
    sentences.removeAt(i);
    i--; // xét lại vị trí hiện tại sau khi bỏ phần tử
  }

  // 3) endMs = mốc bắt đầu câu kế (phụ đề hiện tới khi câu sau bắt đầu).
  for (var i = 0; i < sentences.length; i++) {
    final s = sentences[i];
    final nextStart =
        i + 1 < sentences.length ? sentences[i + 1]['startMs'] as int : null;
    final lastWordMs = s['endMs'] as int;
    s['endMs'] = nextStart ?? (lastWordMs + 2500);
    // Phòng dữ liệu lỗi: đảm bảo end > start.
    if ((s['endMs'] as int) <= (s['startMs'] as int)) {
      s['endMs'] = (s['startMs'] as int) + 1200;
    }
  }
  return sentences;
}

/// Gán mốc thời gian cho từng TOKEN hiển thị (sau khi thêm furigana) dựa trên
/// mốc TỪNG TỪ của caption. Căn theo VỊ TRÍ KÝ TỰ trong câu trơn.
///
/// [tokens] là kết quả `_parseJp` (mỗi phần tử có `surface`), [plain] là câu
/// trơn tương ứng, [words] là `[{tMs, text}]` của câu. Ghi thêm `tMs` vào token.
/// Nếu dữ liệu không khớp (AI đổi chữ) → bỏ qua, app tự ước lượng theo tỉ lệ.
void alignTokenTimings(List<Map<String, dynamic>> tokens, String plain,
    List<Map<String, dynamic>> words) {
  if (words.isEmpty || tokens.isEmpty) return;
  final joined = words.map((w) => w['text'] as String).join();
  // Chỉ căn khi câu trơn khớp chuỗi từ (bỏ khoảng trắng để chịu sai lệch nhỏ).
  String norm(String s) => s.replaceAll(RegExp(r'\s+'), '');
  if (norm(joined) != norm(plain)) return;
  // Bảng: vị trí ký tự bắt đầu của mỗi từ → mốc thời gian.
  final startChar = <int>[];
  final startMs = <int>[];
  var pos = 0;
  for (final w in words) {
    startChar.add(pos);
    startMs.add(w['tMs'] as int);
    pos += norm(w['text'] as String).length;
  }
  var tokenPos = 0;
  for (final t in tokens) {
    final surface = norm((t['surface'] as String?) ?? '');
    if (surface.isEmpty) continue;
    // Từ cuối cùng có vị trí bắt đầu <= vị trí token.
    var idx = 0;
    for (var i = 0; i < startChar.length; i++) {
      if (startChar[i] <= tokenPos) {
        idx = i;
      } else {
        break;
      }
    }
    t['tMs'] = startMs[idx];
    tokenPos += surface.length;
  }
}

/// Đang dịch nền cho video nào (tránh chạy trùng nhiều lượt cùng lúc).
final Set<String> _bgTranslating = <String>{};

/// Bản dịch THẬT hay placeholder lỗi? `ai.translate` khi fail/mock trả
/// "[VI] <câu gốc>" (không rỗng) — tuyệt đối KHÔNG được cache thứ này, nếu
/// không câu đó hỏng vĩnh viễn (cache non-empty sẽ không bao giờ dịch lại).
bool _realTranslation(String s) {
  final t = s.trim();
  return t.isNotEmpty && !RegExp(r'^\[[A-Z]{2,3}\]\s').hasMatch(t);
}

/// DỊCH TRỌN VIDEO ở nền, ngay trên máy chủ — chạy tới khi HẾT video, không
/// phụ thuộc app còn mở hay không. Dịch theo lô (SQL chỉ lấy câu còn thiếu),
/// có backoff khi AI lỗi, phần đã dịch cache từng câu nên dừng giữa chừng
/// không mất gì.
Future<void> _translateWholeVideo(Db db, Ai ai, int vid, String lang) async {
  final key = '$vid|$lang';
  if (_bgTranslating.contains(key)) return; // đã có lượt đang chạy
  if (!ai.enabled) return;
  if (_bgTranslating.length >= 3) return; // trần đồng thời toàn máy chủ
  _bgTranslating.add(key);
  try {
    var failStreak = 0;
    // Vòng lặp có trần để không chạy vô hạn nếu AI liên tục lỗi.
    for (var round = 0; round < 200; round++) {
      final pending = db.pendingSentences(vid, lang, 25);
      if (pending.isEmpty) return; // đã dịch hết video
      final texts = [for (final s in pending) s['text_jp'] as String];
      final out = await ai.translate(texts, lang);
      var wrote = 0;
      for (var i = 0; i < pending.length && i < out.length; i++) {
        if (!_realTranslation(out[i])) continue; // KHÔNG cache placeholder lỗi
        db.cacheTranslation(pending[i]['id'] as int, lang, out[i]);
        wrote++;
      }
      if (wrote == 0) {
        // AI đang lỗi → backoff lũy tiến, quá 3 lần thì dừng (lượt gọi
        // /translate sau sẽ kích lại job, không mất gì).
        failStreak++;
        if (failStreak >= 3) return;
        await Future.delayed(Duration(seconds: 5 * failStreak));
      } else {
        failStreak = 0;
        // Nhường event loop giữa các lô (sqlite đồng bộ, server 1 isolate).
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  } catch (e) {
    stderr.writeln('[BG-TRANSLATE] video $vid ($lang): $e');
  } finally {
    _bgTranslating.remove(key);
  }
}

Router buildRouter(Db db, Ai ai, Asr asr) {
  final r = Router();

  Response ok(Object body) => Response.ok(jsonEncode(body),
      headers: {'content-type': 'application/json; charset=utf-8'});
  Response bad(String msg, {int code = 400}) => Response(code,
      body: jsonEncode({'error': msg}),
      headers: {'content-type': 'application/json; charset=utf-8'});

  Future<Map<String, dynamic>> readJson(Request req) async {
    // Chặn body quá lớn TRƯỚC khi đọc vào RAM (chống nhồi payload khổng lồ).
    final cl = int.tryParse(req.headers['content-length'] ?? '');
    if (cl != null && cl > 1 << 20) throw const FormatException('Body quá lớn');
    final s = await req.readAsString();
    if (s.isEmpty) return {};
    if (s.length > 1 << 20) throw const FormatException('Body quá lớn');
    final decoded = jsonDecode(s);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('JSON phải là object');
    }
    return decoded;
  }

  // Email được tự cấp quyền admin (đặt qua env, mặc định admin@xsgo.app).
  final adminEmail = (Platform.environment['XSGO_ADMIN_EMAIL'] ?? 'admin@xsgo.app')
      .trim()
      .toLowerCase();

  Map<String, dynamic> publicUser(Map<String, dynamic> u) => {
        'id': u['id'],
        'email': u['email'],
        'nativeLang': u['native_lang'],
        'level': u['level'],
        'role': u['role'] ?? 'user',
        'entitlements': db.userEntitlements(u['id'] as int),
      };

  /// Tự nâng quyền admin nếu email khớp cấu hình. Trả về user (đã cập nhật).
  Map<String, dynamic> ensureRole(Map<String, dynamic> u) {
    if ((u['email'] as String).toLowerCase() == adminEmail &&
        u['role'] != 'admin') {
      db.setRole(u['id'] as int, 'admin');
      return db.userById(u['id'] as int)!;
    }
    return u;
  }

  Map<String, dynamic> publicProgress(Map<String, dynamic> p) => {
        'goalWords': p['goal_words'],
        'todayWords': p['today_words'],
        'totalWords': p['total_words'],
        'streak': p['streak'],
        'lastStudyDay': p['last_study_day'],
      };

  int? authUserId(Request req) {
    final h = req.headers['authorization'];
    if (h == null || !h.startsWith('Bearer ')) return null;
    final claims = verifyJwt(h.substring(7));
    final uid = claims?['sub'] as int?;
    if (uid == null) return null;
    // Token còn hạn nhưng tài khoản đã bị khoá/xoá → coi như chưa đăng nhập
    // (admin khoá là chặn NGAY, không đợi token hết hạn 30 ngày).
    final u = db.userById(uid);
    if (u == null || (u['disabled'] as int? ?? 0) == 1) return null;
    return uid;
  }

  /// Trả về Response 429 nếu IP vượt giới hạn gọi AI, ngược lại null.
  /// Gồm 2 tầng: theo PHÚT (chống dồn dập) + theo NGÀY (trần cứng chống đốt
  /// tiền Claude API — kể cả khi premium_enabled tắt; khách chặt hơn user).
  Response? aiGuard(Request req) {
    if (_aiRateLimited(_clientIp(req))) {
      return bad('Quá nhiều yêu cầu, thử lại sau', code: 429);
    }
    final uid = authUserId(req);
    final who = uid != null ? 'u$uid' : 'ip:${_clientIp(req)}';
    final maxPerDay = uid != null ? 400 : 60;
    if (_limited('aiday:$who', maxPerDay, 24 * 3600 * 1000)) {
      return bad('Đã hết lượt dùng AI hôm nay, mai quay lại nhé', code: 429);
    }
    return null;
  }

  /// Trả về user admin nếu token hợp lệ & là admin, ngược lại null.
  Map<String, dynamic>? adminUser(Request req) {
    final uid = authUserId(req);
    if (uid == null) return null;
    final u = db.userById(uid);
    if (u == null || u['role'] != 'admin') return null;
    return u;
  }

  // -------- Premium / hạn mức AI (hạn mức + cờ đều CHỈNH TỪ SERVER) --------
  const premiumLifetime = 4102444800000; // 2100-01-01 = "vĩnh viễn"
  int cfgInt(String key, int dflt) {
    final v = db.allConfig()[key];
    return v == null ? dflt : (int.tryParse(v) ?? dflt);
  }

  bool premiumEnabled() => (db.allConfig()['premium_enabled'] ?? '0') == '1';

  /// Nguồn CHÂN LÝ DUY NHẤT về gói của 1 user: cờ bật, premium hay không, hạn
  /// mức AI còn lại (free đo theo THÁNG, premium theo NGÀY).
  Map<String, dynamic> planFor(int uid) {
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final u = db.userById(uid);
    final until = (u?['premium_until'] as int?) ?? 0;
    final isPremium = until > nowMs;
    final plan = !isPremium
        ? 'free'
        : (until >= premiumLifetime ? 'lifetime' : 'premium');
    String two(int n) => n.toString().padLeft(2, '0');
    final periodKey = isPremium
        ? 'D:${now.year}-${two(now.month)}-${two(now.day)}'
        : 'M:${now.year}-${two(now.month)}';
    final limitSec = isPremium
        ? cfgInt('premium_ai_day_sec', 3600)
        : cfgInt('free_ai_month_sec', 3600);
    final usedSec = db.aiUsedSec(uid, periodKey);
    final remaining = (limitSec - usedSec).clamp(0, limitSec);
    return {
      'premiumEnabled': premiumEnabled(),
      'isPremium': isPremium,
      'premiumUntil': until,
      'plan': plan,
      'trialUsed': ((u?['trial_used'] as int?) ?? 0) == 1,
      'limitSec': limitSec,
      'usedSec': usedSec,
      'remainingSec': remaining,
      'period': periodKey,
      'costTranslateSec': cfgInt('ai_cost_translate_sec', 20),
      'costSpeakingSec': cfgInt('ai_cost_speaking_sec', 45),
    };
  }

  /// Guard hạn mức route AI: cờ TẮT hoặc khách → không chặn (ra mắt free chạy
  /// như cũ). Cờ BẬT & hết hạn mức → 429 (code ai_limit); còn thì ghi usage.
  Response? aiLimitGuard(int? uid, int costSec) {
    if (uid == null || !premiumEnabled()) return null;
    final p = planFor(uid);
    if ((p['remainingSec'] as int) < costSec) {
      return Response(429,
          body: jsonEncode({
            'error': 'Đã hết hạn mức AI hôm nay. Nâng cấp Premium để dùng tiếp.',
            'code': 'ai_limit',
          }),
          headers: {'content-type': 'application/json'});
    }
    db.addAiUsage(uid, p['period'] as String, costSec);
    return null;
  }

  // -------- health --------
  r.get('/health', (Request req) => ok({'ok': true, 'ai': ai.enabled}));

  // -------- trang pháp lý CÔNG KHAI (URL cho hồ sơ App Store / Google Play) --------
  Response htmlPage(String title, String body) => Response.ok(
        '<!doctype html><html lang="vi"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>$title — XS GO</title>'
        '<style>body{font-family:-apple-system,Segoe UI,Roboto,sans-serif;'
        'max-width:720px;margin:40px auto;padding:0 20px;line-height:1.6;color:#1a2233}'
        'h1{color:#2563EB}h2{margin-top:28px;font-size:1.15rem}'
        'a{color:#2563EB}</style></head><body>$body'
        '<hr style="margin:32px 0;border:none;border-top:1px solid #ddd">'
        '<p style="color:#888;font-size:.85rem">XS GO — Học tiếng Nhật. '
        'Liên hệ: hotro@xsgo.app</p></body></html>',
        headers: {'content-type': 'text/html; charset=utf-8'},
      );

  r.get('/privacy', (Request req) => htmlPage('Chính sách bảo mật', '''
    <h1>Chính sách bảo mật</h1><p>Cập nhật: 07/2026</p>
    <h2>1. Thông tin thu thập</h2><p>Email (khi đăng ký), ngôn ngữ mẹ đẻ, trình độ,
    tiến độ học (streak, số từ, bài đã học) và kho từ vựng bạn lưu. Đăng nhập bằng
    Google/Apple/Facebook: nhận email và mã định danh do nhà cung cấp cấp.</p>
    <h2>2. Mục đích</h2><p>Đồng bộ tiến độ giữa các thiết bị, cá nhân hoá nội dung,
    dịch nội dung sang ngôn ngữ của bạn, cải thiện khóa học. Chúng tôi KHÔNG bán dữ liệu.</p>
    <h2>3. Nội dung bạn tạo</h2><p>Video YouTube bạn tự thêm là riêng tư — chỉ bạn thấy.
    Phản hồi bạn gửi được lưu để xử lý.</p>
    <h2>4. Lưu trữ &amp; bảo mật</h2><p>Dữ liệu lưu trên máy chủ XS GO; mật khẩu được băm.
    Áp dụng biện pháp bảo vệ hợp lý nhưng không hệ thống nào an toàn tuyệt đối.</p>
    <h2>5. Quyền của bạn</h2><p>Bạn có thể XOÁ tài khoản và toàn bộ dữ liệu ngay trong app
    (Hồ sơ → Xoá tài khoản), hoặc liên hệ hotro@xsgo.app.</p>
    <h2>6. Dịch vụ bên thứ ba</h2><p>Video nhúng từ YouTube (theo điều khoản YouTube).
    Bản dịch/AI xử lý qua nhà cung cấp AI; chỉ gửi phần văn bản cần xử lý.</p>'''));

  r.get('/terms', (Request req) => htmlPage('Điều khoản sử dụng', '''
    <h1>Điều khoản sử dụng</h1><p>Cập nhật: 07/2026</p>
    <h2>1. Chấp nhận</h2><p>Sử dụng XS GO nghĩa là bạn đồng ý các điều khoản này.</p>
    <h2>2. Tài khoản</h2><p>Bạn tự bảo mật tài khoản/mật khẩu và cung cấp thông tin chính xác.</p>
    <h2>3. Bản quyền nội dung</h2><p>Nội dung khóa học thuộc XS GO, dùng cho học cá nhân,
    không sao chép/bán lại khi chưa được phép. Video thuộc bản quyền của chủ kênh YouTube.</p>
    <h2>4. Nội dung bạn thêm</h2><p>Khi thêm video, bạn xác nhận có quyền xem/chia sẻ; video
    bạn thêm có thể hiển thị ở mục Khám phá cộng đồng cho học viên khác và sẽ bị ẩn/gỡ
    nếu bị báo cáo hoặc vi phạm.</p>
    <h2>5. Thanh toán</h2><p>Một số khóa có thể trả phí; giá áp dụng là giá tại thời điểm mua.</p>
    <h2>6. Giới hạn trách nhiệm</h2><p>XS GO là công cụ hỗ trợ học, không cam kết kết quả thi
    cụ thể; dịch vụ có thể thay đổi hoặc gián đoạn.</p>'''));

  // -------- auth --------
  r.post('/auth/register', (Request req) async {
    // Chống tạo tài khoản hàng loạt (nuôi report rác / dò email).
    if (_limited('reg:${_clientIp(req)}', 10, 3600 * 1000)) {
      return bad('Quá nhiều yêu cầu, thử lại sau', code: 429);
    }
    final b = await readJson(req);
    final email = (b['email'] as String?)?.trim().toLowerCase();
    final password = b['password'] as String?;
    if (email == null || email.isEmpty || password == null || password.length < 8) {
      return bad('Email và mật khẩu (>= 8 ký tự) là bắt buộc');
    }
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      return bad('Email không hợp lệ');
    }
    // ⛔ CHẶN CHIẾM QUYỀN ADMIN: email admin (được ensureRole tự nâng quyền)
    // chỉ đăng ký được khi kèm bootstrap secret (env XSGO_ADMIN_BOOTSTRAP).
    // Không đặt env → không ai đăng ký được email này (fail-closed).
    if (email == adminEmail) {
      final boot = Platform.environment['XSGO_ADMIN_BOOTSTRAP'];
      if (boot == null || boot.isEmpty || b['bootstrap'] != boot) {
        return bad('Không được phép', code: 403);
      }
    }
    if (db.userByEmail(email) != null) return bad('Email đã tồn tại', code: 409);
    final id = db.createUser(
      email,
      hashPassword(password),
      (b['nativeLang'] as String?) ?? 'vi',
      (b['level'] as String?) ?? 'N5',
    );
    final u = ensureRole(db.userById(id)!);
    final token = signJwt({'sub': id, 'email': email});
    return ok({'token': token, 'user': publicUser(u)});
  });

  r.post('/auth/login', (Request req) async {
    final b = await readJson(req);
    final email = (b['email'] as String?)?.trim().toLowerCase();
    final password = b['password'] as String?;
    if (email == null || password == null) return bad('Thiếu email/mật khẩu');
    // Chống brute-force: giới hạn theo IP VÀ theo email bị nhắm tới.
    if (_limited('login:${_clientIp(req)}', 10, 60 * 1000) ||
        _limited('loginmail:$email', 20, 3600 * 1000)) {
      return bad('Thử lại sau ít phút', code: 429);
    }
    final u0 = db.userByEmail(email);
    if (u0 == null || !verifyPassword(password, u0['password'] as String)) {
      return bad('Sai email hoặc mật khẩu', code: 401);
    }
    if ((u0['disabled'] as int? ?? 0) == 1) {
      return bad('Tài khoản đã bị khoá', code: 403);
    }
    final u = ensureRole(u0);
    final token = signJwt({'sub': u['id'], 'email': email});
    return ok({'token': token, 'user': publicUser(u)});
  });

  // Đăng nhập bằng nhà cung cấp (Google/Apple/Facebook). App gửi provider +
  // providerId (lấy từ SDK OAuth) + email; backend upsert & phát JWT.
  r.post('/auth/social', (Request req) async {
    // ⚠️ BẢO MẬT: hiện endpoint TIN providerId do client gửi mà CHƯA xác thực
    // OAuth token phía server → nếu bật thật, kẻ xấu có thể mạo danh bằng cách
    // gửi providerId bất kỳ. Vì vậy MẶC ĐỊNH TẮT; chỉ bật ở dev qua env.
    // TODO(prod): xác thực id_token/access_token với Google/Apple/Facebook rồi
    // mới lấy providerId đáng tin, sau đó bỏ cổng chặn này.
    if (Platform.environment['XSGO_ALLOW_DEMO_SOCIAL'] != '1') {
      return bad(
          'Đăng nhập mạng xã hội chưa được bật (cần xác thực OAuth phía server).',
          code: 501);
    }
    final b = await readJson(req);
    final provider = (b['provider'] as String?)?.trim();
    final providerId = (b['providerId'] as String?)?.trim();
    if (provider == null || provider.isEmpty || providerId == null || providerId.isEmpty) {
      return bad('Thiếu provider hoặc providerId');
    }
    final u = db.upsertSocial(
      provider: provider,
      providerId: providerId,
      email: (b['email'] as String?)?.trim().toLowerCase(),
    );
    final token = signJwt({'sub': u['id'], 'email': u['email']});
    return ok({'token': token, 'user': publicUser(u)});
  });

  // -------- videos --------
  r.get('/videos', (Request req) {
    // Đăng nhập (tuỳ chọn): có token → thấy thêm video RIÊNG của mình; không có
    // → chỉ video chính thức. Video user khác thêm luôn ẩn với mình.
    final uid = authUserId(req);
    final list = db.videosFor(uid).map((v) => {
          'id': v['id'],
          'title': v['title'],
          'channel': v['channel'],
          'level': v['level'],
          'color': v['color'],
          'youtubeId': v['youtube_id'],
          'durationMs': v['duration_ms'],
          'isOfficial': (v['is_official'] as int? ?? 0) == 1,
          'mine': v['owner_user_id'] != null && v['owner_user_id'] == uid,
        });
    return ok({'videos': list.toList()});
  });

  // Danh sách phát CÔNG KHAI (video chính thức) — cho mục Khám phá.
  r.get('/playlists', (Request req) {
    final pls = db.playlists().map((p) => {
          'id': p['id'],
          'title': p['title'],
          'description': p['description'],
          'level': p['level'],
          'color': p['color'],
          'videos': (p['videos'] as List)
              .map((v) => {
                    'id': v['id'],
                    'title': v['title'],
                    'channel': v['channel'],
                    'level': v['level'],
                    'color': v['color'],
                    'youtubeId': v['youtube_id'],
                    'durationMs': v['duration_ms'],
                    'isOfficial': true,
                  })
              .toList(),
        });
    return ok({'playlists': pls.toList()});
  });

  // Khám phá CỘNG ĐỒNG: video do học viên đóng góp (đăng nhập tuỳ chọn — có
  // token thì loại video của người mình đã chặn). Video bị báo cáo nhiều tự ẩn.
  r.get('/discover', (Request req) {
    final uid = authUserId(req);
    final list = db.communityVideos(uid).map((v) => {
          'id': v['id'],
          'title': v['title'],
          'channel': v['channel'],
          'level': v['level'],
          'color': v['color'],
          'youtubeId': v['youtube_id'],
          'durationMs': v['duration_ms'],
          'isOfficial': false,
          'ownerId': v['owner_user_id'],
          'mine': v['owner_user_id'] != null && v['owner_user_id'] == uid,
        });
    return ok({'videos': list.toList()});
  });

  // Báo cáo 1 video cộng đồng (cần đăng nhập). Đủ số báo cáo → tự ẩn.
  r.post('/videos/<id|[0-9]+>/report', (Request req, String id) async {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    final body = await readJson(req);
    final reason = (body['reason'] as String?)?.trim() ?? '';
    final hidden = db.reportVideo(int.parse(id), uid, reason);
    return ok({'ok': true, 'hidden': hidden});
  });

  // Chặn / bỏ chặn người đăng video (cần đăng nhập).
  r.post('/users/<id|[0-9]+>/block', (Request req, String id) {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    db.blockUser(uid, int.parse(id));
    return ok({'ok': true});
  });
  r.delete('/users/<id|[0-9]+>/block', (Request req, String id) {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    db.unblockUser(uid, int.parse(id));
    return ok({'ok': true});
  });

  r.get('/videos/<id|[0-9]+>', (Request req, String id) {
    final v = db.video(int.parse(id));
    if (v == null) return bad('Không tìm thấy video', code: 404);
    // Video đã ẨN (bị báo cáo/admin gỡ) chỉ chủ video hoặc admin xem được.
    if ((v['hidden'] as int? ?? 0) == 1) {
      final uid = authUserId(req);
      final isOwner = v['owner_user_id'] != null && v['owner_user_id'] == uid;
      if (!isOwner && adminUser(req) == null) {
        return bad('Không tìm thấy video', code: 404);
      }
    }
    final lang = req.url.queryParameters['lang'] ?? 'vi';
    final sentences = db.sentences(int.parse(id)).map((s) {
      final tr = jsonDecode(s['translations_json'] as String) as Map;
      return {
        'id': s['id'],
        'ord': s['ord'],
        'startMs': s['start_ms'],
        'endMs': s['end_ms'],
        'textJp': s['text_jp'],
        'tokens': jsonDecode(s['tokens_json'] as String),
        'words': jsonDecode(s['words_json'] as String),
        'translation': tr[lang] ?? tr['vi'] ?? '',
      };
    }).toList();
    return ok({
      'id': v['id'],
      'title': v['title'],
      'channel': v['channel'],
      'level': v['level'],
      'durationMs': v['duration_ms'],
      'youtubeId': v['youtube_id'],
      'sentences': sentences,
      // Số câu CHƯA có bản dịch [lang] — app dựa vào đây để tự tải lại bản
      // dịch trong lúc xem (job nền trên máy chủ đang dịch dần).
      'pending': db.pendingTranslationCount(int.parse(id), lang),
    });
  });

  // Thêm video từ YouTube (cần đăng nhập). Nhận URL hoặc ID 11 ký tự.
  // Phụ đề: tạo 1 câu placeholder — ASR tự tạo phụ đề là tính năng sau (mục 5/6 PROJECT.md).
  r.post('/videos', (Request req) async {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    final b = await readJson(req);
    final raw = ((b['youtube'] as String?) ?? '').trim();
    final m = RegExp(
            r'(?:youtu\.be/|watch\?v=|/embed/|/shorts/|^)([A-Za-z0-9_-]{11})(?:[?&#]|$)')
        .firstMatch(raw);
    if (m == null) return bad('Link/ID YouTube không hợp lệ');
    final ytId = m.group(1)!;
    final title = ((b['title'] as String?) ?? '').trim();
    if (title.isEmpty) return bad('Thiếu tiêu đề');
    final level = ((b['level'] as String?) ?? 'N5').trim();
    // Chặn video không cho phép nhúng (private / tắt embed) — nếu thêm sẽ hiện
    // "This video is private" và không phát được trong app.
    final embeddable = await _youtubeEmbeddable(ytId);
    if (embeddable == false) {
      return bad(
          'Video này không cho phép nhúng (private hoặc chủ kênh tắt nhúng). '
          'Hãy chọn video khác cho phép phát ngoài YouTube.',
          code: 422);
    }
    final id = db.createVideo(
      title: title,
      channel: (b['channel'] as String?) ?? 'Video của tôi',
      level: level,
      youtubeId: ytId,
      ownerUserId: uid,
    );
    final v = db.video(id)!;
    return ok({
      'id': v['id'],
      'title': v['title'],
      'channel': v['channel'],
      'level': v['level'],
      'color': v['color'],
      'youtubeId': v['youtube_id'],
      'durationMs': v['duration_ms'],
    });
  });

  // Xoá video (cần đăng nhập). Sentences tự xoá theo (ON DELETE CASCADE).
  r.delete('/videos/<id|[0-9]+>', (Request req, String id) {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    final removed = db.deleteVideo(int.parse(id), uid);
    if (removed == 0) {
      return bad('Không thể xoá video này (chỉ xoá được video bạn tự thêm)',
          code: 403);
    }
    return ok({'ok': true});
  });

  // Dịch các câu của video sang ngôn ngữ người dùng (AI, cache lại DB).
  // Lô đầu dịch NGAY (mở xem liền); phần còn lại máy chủ tự dịch TRỌN VIDEO
  // ở nền. Cần đăng nhập (job nền tiêu tiền AI — không mở cho khách vãng lai).
  r.post('/videos/<id|[0-9]+>/translate', (Request req, String id) async {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    final b = await readJson(req);
    final lang = (b['lang'] as String?) ?? 'vi';
    if (lang != 'vi' && !_supportedLangs.contains(lang)) {
      return bad('Ngôn ngữ không hỗ trợ');
    }
    final vid = int.parse(id);
    if (db.video(vid) == null) return bad('Không tìm thấy video', code: 404);
    // Trần lô ép Ở MÁY CHỦ: client không gửi limit (bản cũ) cũng không thể
    // kéo cả video vào một prompt (sẽ bị cắt max_tokens → cache rác).
    final limit = ((b['limit'] as num?)?.toInt() ?? 25).clamp(1, 50);
    final key = '$vid|$lang';
    final result = <Map<String, dynamic>>[];
    var pendingCount = db.pendingTranslationCount(vid, lang);
    // Job nền đang dịch video này → không gọi AI trùng (đỡ tốn đôi tiền),
    // chỉ trả về tiến độ để app poll.
    if (pendingCount > 0 && !_bgTranslating.contains(key)) {
      final g = aiGuard(req);
      if (g != null) return g;
      final gl =
          aiLimitGuard(uid, cfgInt('ai_cost_translate_sec', 20));
      if (gl != null) return gl;
      final need = db.pendingSentences(vid, lang, limit);
      final translated = await ai.translate(
          [for (final s in need) s['text_jp'] as String], lang);
      for (var i = 0; i < need.length && i < translated.length; i++) {
        if (!_realTranslation(translated[i])) continue; // không cache lỗi
        db.cacheTranslation(need[i]['id'] as int, lang, translated[i]);
        result.add({'id': need[i]['id'], 'translation': translated[i]});
      }
      pendingCount = db.pendingTranslationCount(vid, lang);
    }
    // Còn câu chưa dịch → máy chủ tự dịch nốt ở nền (không phụ thuộc app).
    if (pendingCount > 0) {
      unawaited(_translateWholeVideo(db, ai, vid, lang));
    }
    return ok(
        {'lang': lang, 'translations': result, 'remaining': pendingCount});
  });

  // -------- speaking --------
  r.get('/speaking/scenarios', (Request req) {
    return ok({
      'scenarios': [
        {'id': 'self_intro', 'title': '自己紹介', 'sub': 'Giới thiệu bản thân', 'level': 'N5'},
        {'id': 'restaurant', 'title': 'レストランで', 'sub': 'Ở nhà hàng', 'level': 'N4'},
        {'id': 'shopping', 'title': '買い物', 'sub': 'Đi mua sắm', 'level': 'N4'},
        {'id': 'interview', 'title': '面接', 'sub': 'Phỏng vấn xin việc', 'level': 'N3'},
      ]
    });
  });

  r.post('/speaking', (Request req) async {
    final b = await readJson(req);
    final scenario = (b['scenario'] as String?) ?? 'hội thoại chung';
    final message = (b['message'] as String?) ?? '';
    final lang = (b['lang'] as String?) ?? 'vi';
    if (message.isEmpty) return bad('Thiếu nội dung');
    if (message.length > 2000) return bad('Nội dung quá dài (tối đa 2000 ký tự)', code: 413);
    final g = aiGuard(req);
    if (g != null) return g;
    final gl = aiLimitGuard(authUserId(req), cfgInt('ai_cost_speaking_sec', 45));
    if (gl != null) return gl;
    final reply = await ai.speakingReply(scenario, message, lang);
    return ok({'reply': reply});
  });

  // -------- localization: dịch chuỗi giao diện/giáo trình sang ngôn ngữ user --------
  // Dùng chung cho giáo trình BJT & nội dung tĩnh khác. Cache theo hash để mỗi
  // chuỗi chỉ gọi AI 1 lần cho mỗi ngôn ngữ.
  r.post('/translate', (Request req) async {
    final b = await readJson(req);
    final lang = (b['lang'] as String?) ?? 'vi';
    final texts =
        (b['texts'] as List?)?.map((e) => e.toString()).toList() ?? [];
    if (lang == 'vi' || texts.isEmpty) {
      return ok({'translations': texts});
    }
    if (!_supportedLangs.contains(lang)) return bad('Ngôn ngữ không hỗ trợ');
    if (texts.length > 500) return bad('Quá nhiều chuỗi (tối đa 500)', code: 413);
    final result = List<String?>.filled(texts.length, null);
    final needIdx = <int>[];
    for (var i = 0; i < texts.length; i++) {
      final hash = sha256.convert(utf8.encode(texts[i])).toString();
      final cached = db.cachedTranslation(hash, lang);
      if (cached != null) {
        result[i] = cached;
      } else {
        needIdx.add(i);
      }
    }
    if (needIdx.isNotEmpty) {
      final g = aiGuard(req);
      if (g != null) return g;
      final gl = aiLimitGuard(authUserId(req), cfgInt('ai_cost_translate_sec', 20));
      if (gl != null) return gl;
      final translated =
          await ai.translateTexts([for (final i in needIdx) texts[i]], lang);
      for (var k = 0; k < needIdx.length; k++) {
        final i = needIdx[k];
        result[i] = translated[k];
        final hash = sha256.convert(utf8.encode(texts[i])).toString();
        db.putTranslation(hash, lang, translated[k]);
      }
    }
    return ok({'translations': result});
  });

  // -------- vocabulary (cần đăng nhập) --------
  r.get('/vocab', (Request req) {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    return ok({'vocab': db.vocabList(uid), 'count': db.vocabCount(uid)});
  });

  r.post('/vocab', (Request req) async {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    final b = await readJson(req);
    final term = (b['term'] as String?)?.trim();
    if (term == null || term.isEmpty) return bad('Thiếu từ');
    final item = db.addVocab(
      uid,
      term,
      (b['reading'] as String?) ?? '',
      (b['meaning'] as String?) ?? '',
      (b['jlpt'] as String?) ?? '',
    );
    return ok(item);
  });

  r.delete('/vocab/<id|[0-9]+>', (Request req, String id) {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    db.deleteVocab(uid, int.parse(id));
    return ok({'ok': true});
  });

  // -------- progress (cần đăng nhập) --------
  r.get('/progress', (Request req) {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    return ok(publicProgress(db.progress(uid)));
  });

  r.post('/progress', (Request req) async {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    final b = await readJson(req);
    final p = db.progress(uid);

    // Ép kiểu + kẹp giá trị: dữ liệu bẩn (string/âm/khổng lồ) sẽ làm hỏng
    // progress của chính user đó vĩnh viễn (GET sau cast int nổ 500).
    if (b['goalWords'] != null) {
      final g = (b['goalWords'] as num?)?.toInt();
      if (g == null || g < 1 || g > 500) return bad('goalWords không hợp lệ');
      p['goal_words'] = g;
    }

    // Ghi nhận phiên học: cộng từ + cập nhật streak theo ngày.
    if (b['wordsLearned'] != null) {
      final now = DateTime.now();
      String dayKey(DateTime d) =>
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final today = dayKey(now);
      final yesterday = dayKey(now.subtract(const Duration(days: 1)));
      final last = p['last_study_day'] as String;
      final learned =
          ((b['wordsLearned'] as num?)?.toInt() ?? 0).clamp(0, 1000);
      if (last != today) {
        p['streak'] = (last == yesterday) ? (p['streak'] as int) + 1 : 1;
        p['today_words'] = 0;
      }
      p['today_words'] = (p['today_words'] as int) + learned;
      p['total_words'] = (p['total_words'] as int) + learned;
      p['last_study_day'] = today;
    }
    db.saveProgress(uid, p);
    return ok(publicProgress(db.progress(uid)));
  });

  // -------- Lịch sử xem ("Tiếp tục xem") đồng bộ theo tài khoản --------
  Map<String, dynamic> watchJson(Map<String, dynamic> v) => {
        'key': v['vkey'],
        'videoId': v['video_id'],
        'youtubeId': v['youtube_id'],
        'title': v['title'],
        'channel': v['channel'],
        'level': v['level'],
        'posMs': v['pos_ms'],
        'durMs': v['dur_ms'],
        'done': (v['done'] as int? ?? 0) == 1,
        'lastSeen': v['last_seen'],
      };

  r.get('/watch', (Request req) {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    return ok({'items': db.watchHistory(uid).map(watchJson).toList()});
  });

  // Đẩy 1 hoặc nhiều mục lên (hợp nhất), trả về danh sách sau khi hợp nhất.
  r.post('/watch', (Request req) async {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    final b = await readJson(req);
    final items = (b['items'] as List?) ?? const [];
    for (final it in items) {
      db.watchUpsert(uid, Map<String, dynamic>.from(it as Map));
    }
    return ok({'items': db.watchHistory(uid).map(watchJson).toList()});
  });

  // -------- Gói Premium của chính mình (nguồn chân lý cho app) --------
  r.get('/me/plan', (Request req) {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    return ok(planFor(uid));
  });

  // Dùng thử 3 ngày — mỗi tài khoản 1 lần. Client gọi sau khi user chia sẻ MXH.
  r.post('/me/trial', (Request req) {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    final until =
        DateTime.now().add(const Duration(days: 3)).millisecondsSinceEpoch;
    if (!db.grantTrial(uid, until)) {
      return bad('Bạn đã dùng bản dùng thử rồi', code: 409);
    }
    return ok(planFor(uid));
  });

  // -------- entitlements của chính mình (app kéo về sau login) --------
  r.get('/me/entitlements', (Request req) {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    return ok({'owned': db.userEntitlements(uid)});
  });

  // Người dùng TỰ XOÁ tài khoản của mình + toàn bộ dữ liệu (App Store 5.1.1v
  // bắt buộc app có đăng ký phải cho xoá tài khoản ngay trong app).
  r.delete('/me', (Request req) {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    db.deleteUser(uid); // ON DELETE CASCADE xoá luôn progress/vocab/entitlements
    return ok({'ok': true});
  });

  // -------- config CÔNG KHAI (app đọc, không cần đăng nhập) --------
  // Chỉ trả các key an toàn để hiển thị/áp dụng trong app; admin đặt ở /admin/config.
  const publicConfigKeys = {
    'freePreview',
    'announce',
    'bjtPrice',
    'premium_enabled'
  };
  r.get('/config', (Request req) {
    final all = db.allConfig();
    final pub = <String, String>{
      for (final e in all.entries)
        if (publicConfigKeys.contains(e.key)) e.key: e.value,
    };
    return ok({'config': pub});
  });

  // -------- phản hồi người dùng (gửi được kể cả chưa đăng nhập) --------
  r.post('/feedback', (Request req) async {
    // Chống spam đầy DB (route mở cho cả khách).
    if (_limited('fb:${_clientIp(req)}', 5, 3600 * 1000)) {
      return bad('Gửi nhiều quá, thử lại sau', code: 429);
    }
    final b = await readJson(req);
    final message = ((b['message'] as String?) ?? '').trim();
    if (message.isEmpty) return bad('Nội dung phản hồi trống');
    if (message.length > 4000) return bad('Nội dung quá dài');
    final uid = authUserId(req); // null nếu khách
    db.addFeedback(
      userId: uid,
      email: ((b['email'] as String?) ?? '').trim(),
      category: ((b['category'] as String?) ?? '').trim(),
      message: message,
    );
    return ok({'ok': true});
  });

  // ======== ADMIN (chỉ tài khoản role=admin) ========
  Response? adminGuard(Request req) =>
      adminUser(req) == null ? bad('Chỉ dành cho admin', code: 403) : null;

  r.get('/admin/stats', (Request req) {
    final g = adminGuard(req);
    if (g != null) return g;
    return ok(db.adminStats());
  });

  r.get('/admin/users', (Request req) {
    final g = adminGuard(req);
    if (g != null) return g;
    final q = req.url.queryParameters['q'];
    final users = db.adminUsers(q: q).map((u) => {
          'id': u['id'],
          'email': u['email'],
          'nativeLang': u['native_lang'],
          'level': u['level'],
          'provider': u['provider'],
          'role': u['role'],
          'disabled': (u['disabled'] as int? ?? 0) == 1,
          'createdAt': u['created_at'],
          'totalWords': u['total_words'],
          'streak': u['streak'],
          'vocabCount': u['vocab_count'],
          'courses': ((u['courses'] as String?) ?? '')
              .split(',')
              .where((s) => s.isNotEmpty)
              .toList(),
        });
    return ok({'users': users.toList()});
  });

  r.post('/admin/users/<id|[0-9]+>', (Request req, String id) async {
    final me = adminUser(req);
    if (me == null) return bad('Chỉ dành cho admin', code: 403);
    final uid = int.parse(id);
    if (db.userById(uid) == null) return bad('Không tìm thấy user', code: 404);
    final b = await readJson(req);
    if (b['level'] != null) db.setUserLevel(uid, b['level'] as String);
    if (b['role'] != null) {
      // Không cho tự hạ quyền chính mình (tránh khoá cửa admin cuối).
      if (uid == me['id'] && b['role'] != 'admin') {
        return bad('Không thể tự bỏ quyền admin của chính mình');
      }
      db.setRole(uid, b['role'] as String);
    }
    if (b['disabled'] != null) {
      if (uid == me['id'] && b['disabled'] == true) {
        return bad('Không thể tự khoá tài khoản của mình');
      }
      db.setUserDisabled(uid, b['disabled'] as bool);
    }
    return ok({'ok': true});
  });

  r.post('/admin/users/<id|[0-9]+>/entitlement', (Request req, String id) async {
    final g = adminGuard(req);
    if (g != null) return g;
    final uid = int.parse(id);
    if (db.userById(uid) == null) return bad('Không tìm thấy user', code: 404);
    final b = await readJson(req);
    final course = (b['course'] as String?)?.trim();
    if (course == null || course.isEmpty) return bad('Thiếu course');
    if (b['grant'] == false) {
      db.revokeEntitlement(uid, course);
    } else {
      db.grantEntitlement(uid, course);
    }
    return ok({'owned': db.userEntitlements(uid)});
  });

  // Cấp/gỡ Premium cho user (comp tay, hoặc sau này IAP verify gọi vào đây).
  // body: {plan: 'month'|'year'|'lifetime'|'revoke'}
  r.post('/admin/users/<id|[0-9]+>/premium', (Request req, String id) async {
    final g = adminGuard(req);
    if (g != null) return g;
    final uid = int.parse(id);
    if (db.userById(uid) == null) return bad('Không tìm thấy user', code: 404);
    final b = await readJson(req);
    final plan = (b['plan'] as String?) ?? 'month';
    final now = DateTime.now();
    int until;
    switch (plan) {
      case 'revoke':
        until = 0;
        break;
      case 'lifetime':
        until = premiumLifetime;
        break;
      case 'year':
        until = now.add(const Duration(days: 365)).millisecondsSinceEpoch;
        break;
      default: // month
        until = now.add(const Duration(days: 30)).millisecondsSinceEpoch;
    }
    db.setPremiumUntil(uid, until);
    return ok(planFor(uid));
  });

  r.delete('/admin/users/<id|[0-9]+>', (Request req, String id) {
    final me = adminUser(req);
    if (me == null) return bad('Chỉ dành cho admin', code: 403);
    final uid = int.parse(id);
    if (uid == me['id']) return bad('Không thể tự xoá tài khoản của mình');
    db.deleteUser(uid);
    return ok({'ok': true});
  });

  r.get('/admin/config', (Request req) {
    final g = adminGuard(req);
    if (g != null) return g;
    return ok({'config': db.allConfig()});
  });

  r.post('/admin/config', (Request req) async {
    final g = adminGuard(req);
    if (g != null) return g;
    final b = await readJson(req);
    final cfg = b['config'];
    if (cfg is Map) {
      cfg.forEach((k, v) => db.setConfig(k.toString(), v.toString()));
    } else if (b['key'] != null) {
      db.setConfig(b['key'].toString(), (b['value'] ?? '').toString());
    }
    return ok({'config': db.allConfig()});
  });

  // -------- ADMIN: video & danh sách phát --------
  Map<String, dynamic> videoJson(Map<String, dynamic> v) => {
        'id': v['id'],
        'title': v['title'],
        'channel': v['channel'],
        'level': v['level'],
        'color': v['color'],
        'youtubeId': v['youtube_id'],
        'durationMs': v['duration_ms'],
        'isOfficial': (v['is_official'] as int? ?? 0) == 1,
        'hidden': (v['hidden'] as int? ?? 0) == 1,
      };

  // Liệt kê video CHÍNH THỨC (video user là riêng tư, không cần kiểm duyệt).
  r.get('/admin/videos', (Request req) {
    final g = adminGuard(req);
    if (g != null) return g;
    final q = req.url.queryParameters['q'];
    return ok({'videos': db.adminVideos(q: q).map(videoJson).toList()});
  });

  // Admin đăng video CHÍNH THỨC (owner null, is_official=1) → cả app thấy.
  r.post('/admin/videos', (Request req) async {
    final g = adminGuard(req);
    if (g != null) return g;
    final b = await readJson(req);
    final raw = ((b['youtube'] as String?) ?? '').trim();
    final m = RegExp(
            r'(?:youtu\.be/|watch\?v=|/embed/|/shorts/|^)([A-Za-z0-9_-]{11})(?:[?&#]|$)')
        .firstMatch(raw);
    if (m == null) return bad('Link/ID YouTube không hợp lệ');
    final ytId = m.group(1)!;
    final title = ((b['title'] as String?) ?? '').trim();
    if (title.isEmpty) return bad('Thiếu tiêu đề');
    final level = ((b['level'] as String?) ?? 'N5').trim();
    final embeddable = await _youtubeEmbeddable(ytId);
    if (embeddable == false) {
      return bad(
          'Video này không cho phép nhúng (private hoặc chủ kênh tắt nhúng). '
          'Hãy chọn video khác cho phép phát ngoài YouTube.',
          code: 422);
    }
    final id = db.createVideo(
      title: title,
      channel: (b['channel'] as String?)?.trim().isNotEmpty == true
          ? (b['channel'] as String).trim()
          : 'XS GO',
      level: level,
      youtubeId: ytId,
      ownerUserId: null,
      official: true,
    );
    // Gắn vào playlist nếu có chỉ định.
    final pid = b['playlistId'];
    if (pid is int && db.playlistExists(pid)) {
      db.addVideoToPlaylist(pid, id);
    }
    return ok(videoJson(db.video(id)!));
  });

  // Sửa video (tiêu đề/level/official/ẩn) — áp cho MỌI video.
  r.post('/admin/videos/<id|[0-9]+>', (Request req, String id) async {
    final g = adminGuard(req);
    if (g != null) return g;
    final vid = int.parse(id);
    if (db.video(vid) == null) return bad('Không tìm thấy video', code: 404);
    final b = await readJson(req);
    db.adminUpdateVideo(vid,
        title: b['title'] as String?,
        channel: b['channel'] as String?,
        level: b['level'] as String?,
        official: b['official'] as bool?,
        hidden: b['hidden'] as bool?);
    return ok(videoJson(db.video(vid)!));
  });

  // Xoá BẤT KỲ video nào.
  r.delete('/admin/videos/<id|[0-9]+>', (Request req, String id) {
    final g = adminGuard(req);
    if (g != null) return g;
    db.adminDeleteVideo(int.parse(id));
    return ok({'ok': true});
  });

  // Video cộng đồng bị BÁO CÁO — admin duyệt rồi ẩn/gỡ qua route ở trên.
  r.get('/admin/reports', (Request req) {
    final g = adminGuard(req);
    if (g != null) return g;
    final list = db.reportedVideos().map((v) => {
          'id': v['id'],
          'title': v['title'],
          'channel': v['channel'],
          'level': v['level'],
          'hidden': (v['hidden'] as int? ?? 0) == 1,
          'ownerId': v['owner_user_id'],
          'reports': v['reports'],
          'lastReport': v['last_report'],
        });
    return ok({'reports': list.toList()});
  });

  // Đặt/ghi đè phụ đề cho 1 video (admin dán, hoặc lớp AI sinh ra ghi vào đây).
  // Nhận {lines: "mm:ss <câu JP [漢字|かな]> [ | dịch VI]"} — mỗi dòng 1 câu.
  r.post('/admin/videos/<id|[0-9]+>/subtitles', (Request req, String id) async {
    final g = adminGuard(req);
    if (g != null) return g;
    final vid = int.parse(id);
    if (db.video(vid) == null) return bad('Không tìm thấy video', code: 404);
    final b = await readJson(req);
    final raw = (b['lines'] as String?) ?? '';
    final sents = parseSubtitles(raw);
    if (sents.isEmpty) {
      return bad('Không đọc được dòng phụ đề nào. Định dạng mỗi dòng: '
          '"mm:ss câu tiếng Nhật". Ví dụ: 00:03 [初|はじ]めまして。');
    }
    db.replaceVideoSentences(vid, sents);
    return ok({'count': sents.length});
  });

  // HELPER: chạy pipeline tạo phụ đề cho 1 video: yt-dlp lấy audio → Groq
  // Whisper bóc tiếng + mốc thời gian → Claude thêm furigana → lưu. Nghĩa dịch
  // để luồng /translate lo (lazy) khi học viên mở. Cần GROQ + ANTHROPIC + yt-dlp/ffmpeg.
  Future<Response> genSubtitles(int vid) async {
    final v = db.video(vid);
    if (v == null) return bad('Không tìm thấy video', code: 404);
    final ytId = (v['youtube_id'] as String?) ?? '';
    if (ytId.isEmpty) {
      return bad('Video này không có link YouTube để tạo phụ đề', code: 422);
    }

    // 1) ƯU TIÊN: phụ đề tiếng Nhật CÓ SẴN của YouTube (nhẹ, né 403, khỏi Whisper).
    var segs = await _fetchYoutubeCaptions(ytId);
    var source = 'caption';

    // 2) Không có caption → fallback Whisper (tải audio + bóc tiếng).
    if (segs.isEmpty) {
      if (!asr.enabled) {
        return bad(
            'Video này không có phụ đề tiếng Nhật sẵn, và chưa bật bóc tiếng '
            '(cần GROQ_API_KEY). Thử video có phụ đề CC.',
            code: 422);
      }
      final audio = await _downloadYoutubeAudio(ytId);
      if (audio == null) {
        return bad(
            'Video không có phụ đề sẵn và không tải được audio để bóc tiếng '
            '(YouTube chặn IP máy chủ). Thử video có phụ đề CC, hoặc cắm proxy/cookies.',
            code: 502);
      }
      try {
        segs = await asr.transcribe(audio, lang: 'ja');
        source = 'whisper';
      } finally {
        try {
          audio.parent.deleteSync(recursive: true);
        } catch (_) {}
      }
    }

    if (segs.isEmpty) {
      return bad('Không lấy được câu phụ đề nào cho video này.', code: 422);
    }

    // 3) Furigana + DỊCH tiếng Việt lô đầu (để mở xem ngay) + lưu.
    final jp = [for (final s in segs) s['text'] as String];
    final withFuri = await ai.furigana(jp);
    // Dịch NHANH phần ĐẦU (mở xem ngay); phần còn lại dịch TRỌN VIDEO ở nền
    // ngay trên máy chủ (không phụ thuộc app còn mở hay không).
    const kFirstChunk = 20;
    List<String> vi = const [];
    try {
      vi = await ai.translate(jp.take(kFirstChunk).toList(), 'vi');
    } catch (_) {/* lỗi dịch → để trống, nền sẽ dịch lại */}
    final sents = <Map<String, dynamic>>[];
    var alignedCount = 0; // số câu token được gán mốc từng từ THẬT SỰ
    for (var i = 0; i < segs.length; i++) {
      final (tokens, words, plain) = _parseJp(withFuri[i]);
      // Gán mốc TỪNG TỪ cho token (karaoke chính xác) nếu caption có mốc từ.
      final wordTimings = (segs[i]['words'] as List?)
          ?.map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (wordTimings != null && wordTimings.isNotEmpty) {
        alignTokenTimings(tokens, plain, wordTimings);
        if (tokens.any((t) => t['tMs'] != null)) alignedCount++;
      }
      sents.add({
        'startMs': segs[i]['startMs'],
        'endMs': segs[i]['endMs'],
        'textJp': plain,
        'tokens': tokens,
        'words': words,
        // Không lưu placeholder lỗi "[VI] …" — để trống cho job nền dịch lại.
        'vi': i < vi.length && _realTranslation(vi[i]) ? vi[i] : '',
      });
    }
    db.replaceVideoSentences(vid, sents);
    // DỊCH TRỌN VIDEO ở nền (server) — chạy tiếp sau khi đã trả lời client.
    unawaited(_translateWholeVideo(db, ai, vid, 'vi'));
    return ok({
      'count': sents.length,
      'furigana': ai.enabled,
      'source': source, // 'caption' (rẻ) hoặc 'whisper'
      // true = có câu được căn mốc từng từ thật (không phải chỉ "caption có mốc").
      'wordTiming': alignedCount > 0,
      'sample': sents.isEmpty ? '' : sents.first['textJp'],
    });
  }

  // Admin tạo phụ đề cho bất kỳ video nào.
  r.post('/admin/videos/<id|[0-9]+>/generate-subtitles',
      (Request req, String id) async {
    final g = adminGuard(req);
    if (g != null) return g;
    return genSubtitles(int.parse(id));
  });

  // CHỦ VIDEO tự tạo phụ đề AI cho video mình thêm (hoặc admin). Cần đăng nhập.
  r.post('/videos/<id|[0-9]+>/generate-subtitles',
      (Request req, String id) async {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    final vid = int.parse(id);
    final v = db.video(vid);
    if (v == null) return bad('Không tìm thấy video', code: 404);
    final isOwner =
        v['owner_user_id'] != null && v['owner_user_id'] == uid;
    if (!isOwner && adminGuard(req) != null) {
      return bad('Chỉ chủ video mới tạo được phụ đề cho video này', code: 403);
    }
    return genSubtitles(vid);
  });

  // Danh sách phát — quản trị (dùng chung dữ liệu với /playlists công khai).
  r.get('/admin/playlists', (Request req) {
    final g = adminGuard(req);
    if (g != null) return g;
    return ok({'playlists': db.playlists()});
  });

  // Tạo / sửa playlist. Có 'id' → sửa; không có → tạo mới.
  r.post('/admin/playlists', (Request req) async {
    final g = adminGuard(req);
    if (g != null) return g;
    final b = await readJson(req);
    final title = ((b['title'] as String?) ?? '').trim();
    final idRaw = b['id'];
    if (idRaw is int) {
      if (!db.playlistExists(idRaw)) return bad('Không tìm thấy playlist', code: 404);
      db.updatePlaylist(idRaw,
          title: title.isEmpty ? null : title,
          description: b['description'] as String?,
          level: b['level'] as String?,
          position: b['position'] as int?);
      return ok({'id': idRaw});
    }
    if (title.isEmpty) return bad('Thiếu tên danh sách phát');
    final newId = db.createPlaylist(
      title: title,
      description: (b['description'] as String?) ?? '',
      level: (b['level'] as String?) ?? '',
      position: (b['position'] as int?) ?? 0,
    );
    return ok({'id': newId});
  });

  r.delete('/admin/playlists/<id|[0-9]+>', (Request req, String id) {
    final g = adminGuard(req);
    if (g != null) return g;
    db.deletePlaylist(int.parse(id));
    return ok({'ok': true});
  });

  // Phản hồi người dùng — cho admin xem & xoá.
  r.get('/admin/feedback', (Request req) {
    final g = adminGuard(req);
    if (g != null) return g;
    return ok({'feedback': db.feedbackList()});
  });

  r.delete('/admin/feedback/<id|[0-9]+>', (Request req, String id) {
    final g = adminGuard(req);
    if (g != null) return g;
    db.deleteFeedback(int.parse(id));
    return ok({'ok': true});
  });

  // Thêm/bỏ 1 video khỏi playlist. {videoId, add:true|false, position}.
  r.post('/admin/playlists/<id|[0-9]+>/videos', (Request req, String id) async {
    final g = adminGuard(req);
    if (g != null) return g;
    final pid = int.parse(id);
    if (!db.playlistExists(pid)) return bad('Không tìm thấy playlist', code: 404);
    final b = await readJson(req);
    final vid = b['videoId'];
    if (vid is! int || db.video(vid) == null) return bad('videoId không hợp lệ');
    if (b['add'] == false) {
      db.removeVideoFromPlaylist(pid, vid);
    } else {
      db.addVideoToPlaylist(pid, vid, position: (b['position'] as int?) ?? 0);
    }
    return ok({'ok': true});
  });

  return r;
}
