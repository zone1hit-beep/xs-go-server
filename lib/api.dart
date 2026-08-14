import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'ai.dart';
import 'asr.dart';
import 'billing.dart';
import 'db.dart';
import 'security.dart';
import 'social_auth.dart';

/// oEmbed YouTube: vừa kiểm tra CHO PHÉP NHÚNG, vừa lấy TIÊU ĐỀ + KÊNH.
/// ok=true (nhúng được, kèm title/author) · ok=false (private/tắt nhúng) ·
/// ok=null (lỗi mạng — không kết luận được, để caller tự quyết).
class YtInfo {
  final bool? ok;
  final String? title;
  final String? author;
  const YtInfo(this.ok, [this.title, this.author]);
}

Future<YtInfo> _youtubeInfo(String id) async {
  HttpClient? client;
  try {
    client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    final uri = Uri.parse(
        'https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=$id&format=json');
    final req = await client.getUrl(uri);
    final resp = await req.close();
    if (resp.statusCode != 200) {
      await resp.drain<void>();
      return const YtInfo(false);
    }
    final body = await resp.transform(utf8.decoder).join();
    final j = jsonDecode(body) as Map<String, dynamic>;
    return YtInfo(true, (j['title'] as String?)?.trim(),
        (j['author_name'] as String?)?.trim());
  } catch (_) {
    return const YtInfo(null); // mạng lỗi — không chặn
  } finally {
    client?.close(force: true);
  }
}

/// Giữ API cũ: chỉ cần biết nhúng được hay không.
Future<bool?> _youtubeEmbeddable(String id) async => (await _youtubeInfo(id)).ok;

/// Liệt kê videoId trong 1 playlist YouTube qua Data API v3 (cần biến môi
/// trường YOUTUBE_API_KEY). Trả null nếu thiếu key; ném String nếu API lỗi
/// (key sai, playlist private...).
Future<List<String>?> _playlistVideoIds(String playlistId) async {
  final key = Platform.environment['YOUTUBE_API_KEY'];
  if (key == null || key.isEmpty) return null;
  final out = <String>[];
  String? pageToken;
  HttpClient? client;
  try {
    client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    for (var page = 0; page < 8; page++) {
      // tối đa ~400 video/playlist
      final uri = Uri.parse('https://www.googleapis.com/youtube/v3/playlistItems'
          '?part=contentDetails&maxResults=50&playlistId=$playlistId&key=$key'
          '${pageToken != null ? '&pageToken=$pageToken' : ''}');
      final req = await client.getUrl(uri);
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        throw 'YouTube API lỗi ${resp.statusCode} (kiểm tra YOUTUBE_API_KEY và playlist có công khai không)';
      }
      final j = jsonDecode(body) as Map<String, dynamic>;
      for (final it in (j['items'] as List? ?? const [])) {
        final vid = ((it as Map)['contentDetails'] as Map?)?['videoId'];
        if (vid is String && vid.length == 11) out.add(vid);
      }
      pageToken = j['nextPageToken'] as String?;
      if (pageToken == null) break;
    }
    return out;
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


/// Đuôi KẾT THÚC VẾ CÂU — cắt NGAY SAU chúng nghe rất tự nhiên.
final _endTail = RegExp(
    r'(ます|ました|ません|ませんでした|でした|です|だった|ください|'
    r'ましょう|でしょう|ですね|ますね|ますが|た|る|よ|ね|な)$');

/// Đuôi NỐI VẾ — cắt sau chúng chấp nhận được (nghỉ ngắn giữa câu).
final _joinTail = RegExp(r'(て|で|が|けど|けれど|から|ので|のに|し|たら|ば|と)$');

/// Mảnh MỞ ĐẦU bằng đuôi động từ / TRỢ TỪ / danh từ phụ thuộc — TUYỆT ĐỐI
/// không cắt ngay trước nó. Tiếng Nhật gắn đuôi và trợ từ vào từ ĐỨNG TRƯỚC,
/// nên cắt ở đây là cắt vào giữa một cụm đang đọc liền:
///   「始め | ます」「ジャパニーズ | のレーラ」「行った | 時の話」
/// — đây chính là lỗi làm phụ đề lệch nhịp đọc.
final _startTail = RegExp(
    r'^(ます|ました|ません|ませんでした|でした|です|ている|ています|'
    r'ていました|た|て|られ|させ|そう|ながら|' // đuôi động từ
    r'の|を|が|は|に|へ|と|で|も|か|ね|よ|な|ら|ば|し|や|から|まで|より|'
    r'ので|のに|けど|けれど|' // trợ từ (luôn dính từ trước)
    r'時|こと|もの|ため|よう|はず|わけ|つもり|ところ)'); // danh từ phụ thuộc

/// Chia một cụm từ liền mạch (không có chỗ nghỉ) thành các dòng phụ đề, cắt ở
/// điểm TỰ NHIÊN nhất: ưu tiên khoảng nghỉ dài nhất + ranh giới vế câu, và
/// tránh cắt vào giữa một từ đang chia đuôi.
List<List<Map<String, dynamic>>> _splitRunNaturally(
    List<Map<String, dynamic>> run, int maxChars, int maxSpanMs) {
  final chars = run.fold<int>(0, (a, w) => a + (w['text'] as String).length);
  final span = (run.last['tMs'] as int) - (run.first['tMs'] as int);
  if (run.length < 2 || (chars <= maxChars && span <= maxSpanMs)) {
    return [run];
  }

  var bestAt = -1;
  var bestScore = -1 << 30;
  var before = (run.first['text'] as String).length;
  for (var i = 1; i < run.length; i++) {
    final prev = run[i - 1]['text'] as String;
    final next = run[i]['text'] as String;
    final gap = (run[i]['tMs'] as int) - (run[i - 1]['tMs'] as int);
    final after = chars - before;

    var score = gap; // nghỉ càng dài, cắt càng hợp tai
    if (_endTail.hasMatch(prev)) score += 1500; // hết một vế câu
    if (_joinTail.hasMatch(prev)) score += 600; // nối vế, nghỉ nhẹ
    if (_startTail.hasMatch(next)) score -= 3000; // ĐỪNG tách đuôi khỏi thân
    // Ưu tiên chia cân đối để không ra dòng 2 chữ.
    score -= ((before - after).abs() * 8);
    // Tránh cắt sát đầu/cuối cụm.
    if (before < 4 || after < 4) score -= 2000;

    if (score > bestScore) {
      bestScore = score;
      bestAt = i;
    }
    before += next.length;
  }

  if (bestAt <= 0) return [run];
  return [
    ..._splitRunNaturally(run.sublist(0, bestAt), maxChars, maxSpanMs),
    ..._splitRunNaturally(run.sublist(bestAt), maxChars, maxSpanMs),
  ];
}

/// Tách một chuỗi caption thành các mảnh KẾT THÚC bằng dấu câu tiếng Nhật.
/// "です。それで" → ["です。", "それで"]. Không có dấu câu ở giữa → trả nguyên.
List<String> _splitAfterPunct(String t) {
  final out = <String>[];
  final buf = StringBuffer();
  for (var i = 0; i < t.length; i++) {
    final ch = t[i];
    buf.write(ch);
    if ('。．！？!?'.contains(ch) && i < t.length - 1) {
      out.add(buf.toString());
      buf.clear();
    }
  }
  if (buf.isNotEmpty) out.add(buf.toString());
  return out.isEmpty ? [t] : out;
}

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
      // TÁCH TỪ CHỨA DẤU KẾT CÂU Ở GIỮA. Caption hay gộp kiểu "です。それで"
      // — nếu để nguyên thì bước gom câu (chỉ ngắt khi dấu câu ở CUỐI từ)
      // sẽ dính 2 câu vào một dòng, đọc rất mệt. Chia mốc thời gian theo tỉ
      // lệ ký tự để mảnh sau vẫn khớp giọng đọc.
      final parts = _splitAfterPunct(t);
      if (parts.length == 1) {
        words.add({'tMs': base + off, 'text': t, 'seq': words.length});
      } else {
        // Ước lượng độ dài từ này: tới từ kế trong cùng event, hoặc 400ms.
        var acc = 0;
        for (final part in parts) {
          final shift = (400 * acc / t.length).round();
          words.add({
            'tMs': base + off + shift,
            'text': part,
            'seq': words.length
          });
          acc += part.length;
        }
      }
    }
  }
  if (words.isEmpty) return const [];
  words.sort((a, b) {
    final c = (a['tMs'] as int).compareTo(b['tMs'] as int);
    return c != 0 ? c : (a['seq'] as int).compareTo(b['seq'] as int);
  });

  // 2) Gộp từ thành CÂU/DÒNG phụ đề — NGẮT THEO NHỊP NGHỈ CỦA GIỌNG ĐỌC.
  //
  //    Nguyên tắc: dòng phụ đề phải trùng với chỗ người nói NGHỈ, không được
  //    cắt cứng theo số chữ. Cắt giữa chừng (vd tách đuôi「ます」khỏi động từ)
  //    làm người học đọc theo bị hụt và chữ nhảy sai nhịp.
  //    Ngưỡng đo từ dữ liệu thật (1531 từ): 2 từ liền mạch cách nhau p50=360ms,
  //    p80=600ms → nghỉ ≥800ms là ngắt ý thật.
  const gapMs = 800; // nghỉ ≥0,8s = ngắt ý → sang dòng mới
  // Trần MỀM: vượt thì đi tìm chỗ ngắt tự nhiên nhất bên trong, KHÔNG chặt ngay.
  const softMaxChars = 26;
  const softMaxSpanMs = 6500;

  final sentences = <Map<String, dynamic>>[];

  // Gom thô: chỉ ngắt ở chỗ NGHỈ THẬT hoặc sau dấu kết câu.
  final runs = <List<Map<String, dynamic>>>[];
  var cur = <Map<String, dynamic>>[];
  for (final w in words) {
    if (cur.isNotEmpty &&
        (w['tMs'] as int) - (cur.last['tMs'] as int) >= gapMs) {
      runs.add(cur);
      cur = [];
    }
    cur.add(w);
    if (RegExp(r'[。．！？!?]$').hasMatch(w['text'] as String)) {
      runs.add(cur);
      cur = [];
    }
  }
  if (cur.isNotEmpty) runs.add(cur);

  // Cụm quá dài (người nói liền một mạch) → chia tại điểm TỰ NHIÊN nhất.
  for (final run in runs) {
    for (final piece in _splitRunNaturally(run, softMaxChars, softMaxSpanMs)) {
      final text = piece.map((w) => w['text'] as String).join();
      if (text.trim().isEmpty) continue;
      sentences.add({
        'startMs': piece.first['tMs'],
        // endMs tạm = mốc từ cuối; sẽ chỉnh lại bằng mốc câu kế ở bước 3.
        'endMs': piece.last['tMs'],
        'text': text,
        'words': List<Map<String, dynamic>>.from(piece),
      });
    }
  }

  const maxChars = softMaxChars; // dùng lại cho bước gộp dòng vụn bên dưới
  const maxSpanMs = softMaxSpanMs;

  // 2b) GỘP DÒNG VỤN: auto-caption hay cắt lệch (vd "ましょう" đứng một mình).
  //     Dòng quá ngắn thì nhập vào dòng liền kề — NHƯNG chỉ khi hai dòng thực
  //     sự liền mạch: nghỉ giữa chúng < [mergeGapMs]. Nghỉ dài = ngắt ý thật,
  //     gộp vào sẽ làm phụ đề lệch tiếng nói.
  const minChars = 6; // dòng ngắn hơn 6 chữ mới coi là vụn (trần 22 chữ)
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

/// Đang chạy tạo phụ đề HÀNG LOẠT (admin) — chỉ cho 1 lượt tại một thời điểm.
bool _bulkSubsRunning = false;

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

/// Ký tự ngăn cách `meaning` và `reading` trong một ô cache tra từ.
const String _dictSep = '\u0001';

/// Có PHẢI CHẶN lượt đăng nhập social này vì đụng email admin không.
///
/// Cho phép đúng MỘT khe cho chính chủ: (1) nhà cung cấp khẳng định email đã
/// xác minh — Apple/Google đều bắt nhập mã gửi về hộp thư khi gắn email vào
/// tài khoản, nên "đã xác minh" = người đó sở hữu hộp thư admin; và (2) tài
/// khoản admin đã tồn tại sẵn trong DB — đường social chỉ GẮN THÊM cách đăng
/// nhập, không bao giờ TẠO MỚI tài khoản mang email admin (tạo mới chỉ qua
/// /auth/register có XSGO_ADMIN_BOOTSTRAP). Email khác admin: không chặn.
bool blockAdminSocial({
  required String? email,
  required bool emailVerified,
  required String adminEmail,
  required bool adminAccountExists,
}) {
  if (email == null || email != adminEmail) return false;
  return !emailVerified || !adminAccountExists;
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

  String tokenFor(Map<String, dynamic> user) => signJwt({
        'sub': user['id'],
        'email': user['email'],
        'ver': user['token_version'] as int? ?? 0,
      });

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
    final tokenVersion = claims?['ver'] as int? ?? 0;
    if (tokenVersion != (u['token_version'] as int? ?? 0)) return null;
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
    };
  }

  // ============================================================
  //  GOOGLE PLAY BILLING — helpers (routes ở dưới, sau /me/*)
  // ============================================================
  final gplay = GooglePlayVerifier(Platform.environment);
  final catalog = BillingCatalog(Platform.environment);
  // Công tắc BÁN HÀNG phía server (đồng bộ với kSellingEnabled trong app):
  // bật = enforce quota xem/nhập video. Đặt: POST /admin/config {selling_enabled:'1'}
  bool sellingEnabled() => (db.allConfig()['selling_enabled'] ?? '0') == '1';
  String pad2(int n) => n.toString().padLeft(2, '0');
  String videoPeriodKey() {
    final n = DateTime.now();
    return 'V:${n.year}-${pad2(n.month)}';
  }

  String dayKey() {
    final n = DateTime.now();
    return '${n.year}-${pad2(n.month)}-${pad2(n.day)}';
  }

  /// Xác minh 1 giao dịch với Google rồi ghi kết quả vào DB (purchases +
  /// entitlements). Trả về state cuối cùng ('active'/'pending'/...).
  Future<String> applyVerified(int uid, String productId, String token) async {
    final isSub = catalog.isSubscription(productId);
    final entKey = catalog.entitlementOf(productId)!;
    final v = isSub
        ? await gplay.verifySubscription(token)
        : await gplay.verifyProduct(productId, token);
    db.upsertPurchase(
      token: token,
      userId: uid,
      productId: productId,
      kind: isSub ? 'subs' : 'inapp',
      state: v.state,
      orderId: v.orderId,
      expiryMs: v.expiryMs,
    );
    if (v.state == 'active') {
      // Mua đứt: trọn đời (expires 0). Subscription: hết hạn theo Google —
      // gia hạn thành công thì lần verify sau đẩy mốc mới.
      db.grantEntitlement(uid, entKey,
          expiresAt: isSub ? v.expiryMs : 0, source: 'google_play');
      if (v.needsAck) {
        // Lưới an toàn: Google TỰ HOÀN TIỀN sau 3 ngày nếu không acknowledge.
        try {
          if (isSub) {
            await gplay.acknowledgeSubscription(productId, token);
          } else {
            await gplay.acknowledgeProduct(productId, token);
          }
        } catch (e) {
          stderr.writeln('[billing] ack lỗi (client sẽ tự ack): $e');
        }
      }
    } else if (isSub) {
      // Sub hết hạn/hold → hạ mốc hết hạn (quyền tự rơi khỏi userEntitlements).
      db.grantEntitlement(uid, entKey,
          expiresAt: v.expiryMs > 0 ? v.expiryMs : 1, source: 'google_play');
    }
    return v.state;
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
  // Email hỗ trợ hiển thị công khai. Đổi KHÔNG cần sửa code:
  //   fly secrets set XSGO_SUPPORT_EMAIL=... -a xs-go-server
  final supportEmail =
      (Platform.environment['XSGO_SUPPORT_EMAIL'] ?? 'zone1hit@gmail.com')
          .trim();

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
        'Nhà phát triển: XS GO. Liên hệ: '
        '<a href="mailto:$supportEmail">$supportEmail</a></p></body></html>',
        headers: {'content-type': 'text/html; charset=utf-8'},
      );

  r.get('/privacy', (Request req) => htmlPage('Chính sách bảo mật', '''
    <h1>Chính sách bảo mật</h1><p>Cập nhật: 11/08/2026</p>
    <p><strong>Nhà phát triển:</strong> XS GO. <strong>Liên hệ:</strong>
    <a href="mailto:$supportEmail">$supportEmail</a></p>
    <h2>1. Thông tin thu thập</h2><p>Email (khi đăng ký), ngôn ngữ mẹ đẻ, trình độ,
    tiến độ học (streak, số từ, bài đã học), kho từ vựng bạn lưu,
    <strong>lịch sử xem video</strong> (để tiếp tục xem và đo hạn mức gói Free),
    <strong>video YouTube bạn tự thêm</strong>, <strong>nội dung bạn nhập khi luyện
    nói với AI</strong>, và <strong>lịch sử mua hàng</strong> (do Google Play xử lý).
    Đăng nhập bằng Google/Apple: nhận email và mã định danh do nhà cung cấp cấp.</p>
    <p>Chúng tôi <strong>KHÔNG</strong> thu thập vị trí, danh bạ, ảnh, và
    <strong>KHÔNG</strong> dùng Advertising ID — ứng dụng không có quảng cáo.</p>
    <h2>2. Mục đích</h2><p>Đồng bộ tiến độ giữa các thiết bị, cá nhân hoá nội dung,
    dịch nội dung sang ngôn ngữ của bạn, áp dụng hạn mức gói, cải thiện khóa học.
    Chúng tôi KHÔNG bán dữ liệu và KHÔNG dùng dữ liệu để quảng cáo.</p>
    <h2>3. Nội dung bạn tạo</h2><p>Video YouTube bạn tự thêm có thể hiển thị ở mục
    Khám phá cộng đồng cho học viên dùng cùng ngôn ngữ (hiển thị theo tiêu đề gốc
    YouTube); video vi phạm hoặc bị báo cáo sẽ bị ẩn/gỡ.
    Phản hồi bạn gửi được lưu để xử lý.</p>
    <h2>4. Chia sẻ với bên thứ ba</h2><p>Chúng tôi gửi phần <em>văn bản cần xử lý</em>
    tới các nhà cung cấp sau, không kèm danh tính của bạn:</p>
    <ul>
      <li><strong>Anthropic</strong> (dịch, giải thích, luyện nói bằng AI)</li>
      <li><strong>Groq</strong> (nhận dạng giọng nói để tạo phụ đề)</li>
      <li><strong>Google / YouTube</strong> (phát video nhúng, đăng nhập Google)</li>
      <li><strong>Apple</strong> (đăng nhập Apple, nếu bạn chọn)</li>
      <li><strong>Google Play</strong> (thanh toán trong ứng dụng — chúng tôi không
          nhận và không lưu thông tin thẻ của bạn)</li>
    </ul>
    <h2>5. Lưu trữ &amp; bảo mật</h2><p>Dữ liệu lưu trên máy chủ XS GO (Fly.io,
    khu vực Singapore); mật khẩu được băm; toàn bộ kết nối dùng HTTPS.
    Áp dụng biện pháp bảo vệ hợp lý nhưng không hệ thống nào an toàn tuyệt đối.</p>
    <h2>6. Quyền của bạn — xoá dữ liệu</h2><p>Bạn có thể XOÁ tài khoản và toàn bộ dữ liệu
    ngay trong app (Hồ sơ → Xoá tài khoản), hoặc gửi yêu cầu theo hướng dẫn ở trang
    <a href="/delete-account">Xoá tài khoản &amp; dữ liệu</a>. Chúng tôi xử lý trong
    vòng 30 ngày.</p>
    <h2>7. Trẻ em</h2><p>Ứng dụng dành cho người từ 16 tuổi trở lên và không hướng tới trẻ em.</p>'''));

  r.get('/terms', (Request req) => htmlPage('Điều khoản sử dụng', '''
    <h1>Điều khoản sử dụng</h1><p>Cập nhật: 11/08/2026</p>
    <h2>1. Chấp nhận</h2><p>Sử dụng XS GO nghĩa là bạn đồng ý các điều khoản này.</p>
    <h2>2. Tài khoản</h2><p>Bạn tự bảo mật tài khoản/mật khẩu và cung cấp thông tin chính xác.
    Bạn có thể xoá tài khoản bất cứ lúc nào — xem
    <a href="/delete-account">Xoá tài khoản &amp; dữ liệu</a>.</p>
    <h2>3. Bản quyền nội dung</h2><p>Nội dung khóa học thuộc XS GO, dùng cho học cá nhân,
    không sao chép/bán lại khi chưa được phép. Video thuộc bản quyền của chủ kênh YouTube.</p>
    <h2>4. Nội dung bạn thêm &amp; quy tắc cộng đồng</h2><p>Khi thêm video, bạn xác nhận có
    quyền xem/chia sẻ; video bạn thêm <strong>có thể hiển thị công khai</strong> ở mục Khám phá
    cho học viên khác. <strong>NGHIÊM CẤM</strong> thêm nội dung: khiêu dâm hoặc gợi dục;
    bạo lực, máu me, khủng bố; thù ghét, phân biệt đối xử, quấy rối, bắt nạt; ma tuý, vũ khí,
    cờ bạc; lừa đảo, spam; nội dung vi phạm bản quyền; nội dung gây hại cho trẻ em.
    Vi phạm sẽ bị gỡ nội dung và khoá tài khoản vĩnh viễn, không hoàn tiền.
    Mọi người dùng có thể báo cáo nội dung ngay trong ứng dụng (nút cờ 🚩 ở màn xem video);
    chúng tôi xem xét và xử lý trong vòng 24–48 giờ.</p>
    <h2>5. Gói trả phí &amp; thanh toán</h2>
    <p>Thanh toán thực hiện qua <strong>Google Play</strong>. Giá áp dụng là giá hiển thị tại
    thời điểm mua, đã bao gồm thuế theo quy định của Google Play.</p>
    <ul>
      <li><strong>Video Premium theo tháng</strong> — ¥1.500/tháng, <strong>tự động gia hạn</strong>
          mỗi tháng cho tới khi bạn huỷ.</li>
      <li><strong>Video Premium theo năm</strong> — ¥9.999/năm, <strong>tự động gia hạn</strong>
          mỗi năm cho tới khi bạn huỷ.</li>
      <li><strong>Khoá BJT</strong> — ¥7.999, mua một lần, dùng trọn đời.</li>
      <li><strong>Tokutei theo ngành</strong> — ¥9.999/ngành, mua một lần, dùng trọn đời.</li>
      <li><strong>All Access</strong> — ¥19.999, mua một lần, mở toàn bộ, dùng trọn đời.</li>
    </ul>
    <p><strong>Huỷ gia hạn:</strong> mở ứng dụng Google Play → ảnh đại diện →
    Thanh toán và gói đăng ký → Gói đăng ký → chọn XS GO → Huỷ. Việc huỷ có hiệu lực từ
    chu kỳ kế tiếp; bạn vẫn dùng được tới hết chu kỳ đã trả tiền.
    <strong>Hoàn tiền</strong> theo chính sách của Google Play; bạn cũng có thể liên hệ
    <a href="mailto:$supportEmail">$supportEmail</a> để được hỗ trợ.
    Gói Free được xem tối đa 3 giờ video mỗi tháng, tự làm mới vào đầu tháng.</p>
    <h2>6. Giới hạn trách nhiệm</h2><p>XS GO là công cụ hỗ trợ học, không cam kết kết quả thi
    cụ thể; dịch vụ có thể thay đổi hoặc gián đoạn.</p>'''));

  // Trang XOÁ TÀI KHOẢN công khai — Google Play BẮT BUỘC với app cho tạo tài
  // khoản: người dùng phải yêu cầu xoá được mà KHÔNG cần cài app.
  r.get('/delete-account', (Request req) => htmlPage('Xoá tài khoản & dữ liệu', '''
    <h1>Xoá tài khoản &amp; dữ liệu — XS GO</h1>
    <p>Ứng dụng: <strong>XS GO</strong> (com.xsgo.xs_go). Nhà phát triển: XS GO.</p>
    <h2>Cách 1 — xoá ngay trong ứng dụng (nhanh nhất)</h2>
    <ol>
      <li>Mở XS GO → thẻ <strong>Hồ sơ</strong>.</li>
      <li>Kéo xuống mục <strong>Tài khoản</strong> → bấm <strong>Xoá tài khoản</strong>.</li>
      <li>Xác nhận. Tài khoản và dữ liệu bị xoá <strong>ngay lập tức</strong>.</li>
    </ol>
    <h2>Cách 2 — gửi yêu cầu qua email (không cần cài app)</h2>
    <p>Gửi email tới <a href="mailto:$supportEmail">$supportEmail</a> với tiêu đề
    <strong>"Xoá tài khoản XS GO"</strong>, kèm địa chỉ email bạn đã dùng để đăng ký.
    Chúng tôi xác minh và xoá trong vòng <strong>30 ngày</strong>, và báo lại khi xong.</p>
    <h2>Dữ liệu bị XOÁ VĨNH VIỄN</h2>
    <ul>
      <li>Tài khoản và email đăng nhập</li>
      <li>Tiến độ học, streak, mục tiêu</li>
      <li>Kho từ vựng đã lưu</li>
      <li>Lịch sử xem video và hạn mức đã dùng</li>
      <li>Video bạn tự thêm</li>
      <li>Phản hồi/báo cáo bạn đã gửi (email trong phản hồi được xoá)</li>
      <li>Quyền sở hữu khoá học đã mua</li>
    </ul>
    <h2>Dữ liệu được GIỮ LẠI và lý do</h2>
    <ul>
      <li><strong>Hoá đơn/giao dịch do Google Play lưu giữ</strong> — chúng tôi không
          kiểm soát; giữ theo yêu cầu kế toán và chống gian lận của Google.
          Xem <a href="https://policies.google.com/privacy">chính sách của Google</a>.</li>
      <li><strong>Nhật ký máy chủ ẩn danh</strong> (không chứa danh tính) — tối đa 30 ngày.</li>
    </ul>
    <p style="background:#FEF3C7;padding:12px;border-radius:8px">
    ⚠️ <strong>Lưu ý:</strong> xoá tài khoản sẽ mất quyền truy cập các khoá học đã mua và
    <strong>không thể khôi phục</strong>. Nếu bạn chỉ muốn ngừng gói đăng ký, hãy huỷ trong
    Google Play thay vì xoá tài khoản.</p>'''));

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
    final token = tokenFor(u);
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
    final token = tokenFor(u);
    return ok({'token': token, 'user': publicUser(u)});
  });

  // Đăng nhập Google / Apple / Facebook.
  // App gửi TOKEN gốc do SDK của nhà cung cấp phát; server XÁC THỰC ngược với
  // nhà cung cấp rồi mới lấy providerId đáng tin → không thể mạo danh bằng
  // cách bịa providerId. Nền tảng nào chưa cấu hình khoá (env) thì tự tắt.
  r.post('/auth/social', (Request req) async {
    // Chống dò/spam: 20 lượt/phút mỗi IP.
    if (_limited('social:${_clientIp(req)}', 20, 60 * 1000)) {
      return bad('Thử lại sau ít phút', code: 429);
    }
    final b = await readJson(req);
    final provider = (b['provider'] as String?)?.trim().toLowerCase();
    final token = (b['token'] as String?)?.trim();
    if (provider == null || provider.isEmpty || token == null || token.isEmpty) {
      return bad('Thiếu provider hoặc token');
    }
    final env = Platform.environment;
    List<String> ids(String key) => (env[key] ?? '')
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    VerifiedIdentity? id;
    switch (provider) {
      case 'google':
        id = await verifyGoogleIdToken(token, ids('XSGO_GOOGLE_CLIENT_IDS'));
      case 'apple':
        id = await verifyAppleIdentityToken(token, ids('XSGO_APPLE_AUDIENCES'));
      case 'facebook':
        id = await verifyFacebookToken(token, env['XSGO_FB_APP_ID'] ?? '',
            env['XSGO_FB_APP_SECRET'] ?? '');
      default:
        return bad('Nhà cung cấp không hỗ trợ: $provider');
    }
    if (id == null) {
      return bad(
          'Không xác thực được với $provider (token sai/hết hạn, hoặc máy chủ '
          'chưa cấu hình khoá cho nhà cung cấp này).',
          code: 401);
    }
    // ⛔ EMAIL ADMIN: trước 11/8 chặn thẳng mọi lượt social mang email này
    // (chống chiếm quyền) — nhưng chặn luôn cả CHÍNH CHỦ đăng nhập Apple/Google
    // bằng gmail admin. Nay nới đúng một khe (sếp duyệt 11/8, xem
    // blockAdminSocial): nhà cung cấp đã XÁC MINH quyền sở hữu hộp thư + tài
    // khoản admin ĐÃ TỒN TẠI (chỉ gắn thêm cách đăng nhập vào tài khoản sẵn có;
    // tạo mới tài khoản admin vẫn CHỈ qua /auth/register + bootstrap secret).
    // Không có nâng quyền ở đây: role đọc từ DB như mọi lần đăng nhập khác.
    final socialEmail = id.email?.trim().toLowerCase();
    if (blockAdminSocial(
        email: socialEmail,
        emailVerified: id.emailVerified,
        adminEmail: adminEmail,
        adminAccountExists: db.userByEmail(adminEmail) != null)) {
      return bad('Không được phép', code: 403);
    }
    // Email lấy TỪ NHÀ CUNG CẤP (đã xác thực); nếu họ không trả (Facebook,
    // hoặc Apple ẩn email) thì để trống — KHÔNG tin email client tự gửi.
    final u = db.upsertSocial(
      provider: provider,
      providerId: id.providerId,
      email: socialEmail,
      emailVerified: id.emailVerified,
    );
    if ((u['disabled'] as int? ?? 0) == 1) {
      return bad('Tài khoản đã bị khoá', code: 403);
    }
    // KHÔNG gọi ensureRole ở đây — quyền admin chỉ cấp qua /auth/register có
    // bootstrap secret hoặc do admin sẵn có nâng quyền trong tab Quản trị.
    final jwt = tokenFor(u);
    return ok({'token': jwt, 'user': publicUser(u)});
  });

  // Logout is intentionally account-wide: a copied token on a lost device
  // must stop working too. The app still clears its local session if offline.
  r.post('/auth/logout', (Request req) {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    db.revokeUserTokens(uid);
    return ok({'ok': true});
  });

  // -------- TRA NGHĨA TỪ (bấm vào từ trong phụ đề) --------
  // Không cần đăng nhập (tra từ là chức năng học cơ bản), nhưng có giới hạn
  // theo IP để không ai dùng nó như cổng dịch miễn phí. Có CACHE nên từ đã
  // tra rồi trả về tức thì, không tốn thêm tiền AI.
  r.post('/dict/lookup', (Request req) async {
    if (_limited('dict:${_clientIp(req)}', 120, 60 * 1000)) {
      return bad('Bạn tra hơi nhanh, thử lại sau chút', code: 429);
    }
    final b = await readJson(req);
    final term = ((b['term'] as String?) ?? '').trim();
    final lang = ((b['lang'] as String?) ?? 'vi').trim();
    final context = ((b['context'] as String?) ?? '').trim();
    if (term.isEmpty) return bad('Thiếu từ cần tra');
    if (term.length > 40) return bad('Từ quá dài');

    final key = 'dict:$term';
    final cached = db.cachedTranslation(key, lang);
    if (cached != null) {
      final parts = cached.split(_dictSep);
      return ok({
        'term': term,
        'reading': parts.length > 1 ? parts[1] : '',
        'meaning': parts[0],
        'cached': true,
      });
    }

    final res = await ai.lookupWord(term, lang, context: context);
    if (res == null) {
      return bad('Chưa tra được nghĩa của từ này', code: 503);
    }
    db.putTranslation(key, lang,
        '${res['meaning']}' + _dictSep + '${res['reading'] ?? ''}');
    return ok({
      'term': term,
      'reading': res['reading'] ?? '',
      'meaning': res['meaning'],
      'cached': false,
    });
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
          // 'home' = mục Danh sách phát trên Home · 'explore' = mục Khám phá.
          'section': p['section'] ?? 'home',
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
    // Ngôn ngữ người xem: tài khoản đăng nhập → native_lang trong DB;
    // khách → ?lang= (app gửi theo ngôn ngữ đang chọn). Mặc định vi.
    var lang = req.url.queryParameters['lang'] ?? 'vi';
    if (uid != null) {
      lang = (db.userById(uid)?['native_lang'] as String?) ?? lang;
    }
    if (!_supportedLangs.contains(lang)) lang = 'vi';
    final list = db.communityVideos(uid, lang: lang).map((v) {
      final mine = v['owner_user_id'] != null && v['owner_user_id'] == uid;
      // Người xem KHÁC chủ video → tiêu đề/kênh GỐC YouTube (nếu đã lấy được);
      // chủ video vẫn thấy tên mình tự đặt.
      final title = mine ? v['title'] : ((v['yt_title'] as String?) ?? v['title']);
      final channel =
          mine ? v['channel'] : ((v['yt_channel'] as String?) ?? v['channel']);
      return {
        'id': v['id'],
        'title': title,
        'channel': channel,
        'level': v['level'],
        'color': v['color'],
        'youtubeId': v['youtube_id'],
        'durationMs': v['duration_ms'],
        'isOfficial': false,
        'ownerId': v['owner_user_id'],
        'mine': mine,
      };
    });
    return ok({'videos': list.toList()});
  });

  // Báo cáo 1 video cộng đồng (cần đăng nhập). Đủ số báo cáo → tự ẩn.
  // Báo cáo video — KHÔNG bắt đăng nhập: khách chưa đăng nhập vẫn xem được
  // video cộng đồng ở Khám phá nên phải báo cáo được (chính sách UGC của
  // Google Play). Người đã đăng nhập: gắn reporter_id để mỗi người báo 1 lần.
  // Khách: chống spam theo IP (10 báo cáo/giờ/IP), không đếm vào ngưỡng tự ẩn.
  r.post('/videos/<id|[0-9]+>/report', (Request req, String id) async {
    final vid = int.parse(id);
    if (db.video(vid) == null) return bad('Không tìm thấy video', code: 404);
    final uid = authUserId(req);
    if (uid == null && _limited('report:${_clientIp(req)}', 10, 3600 * 1000)) {
      return bad('Quá nhiều báo cáo, thử lại sau', code: 429);
    }
    final body = await readJson(req);
    final reason = (body['reason'] as String?)?.trim() ?? '';
    // Khách gửi reporterId null → reportVideo dùng id bản ghi làm khoá đếm,
    // nhưng chỉ báo cáo của TÀI KHOẢN mới đủ tin cậy để tự ẩn (threshold).
    final hidden = db.reportVideo(vid, uid, reason, countsToward: uid != null);
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
    // Khi BÁN HÀNG bật: Free đã xem hết 3h/tháng → chặn tải nội dung học
    // (phụ đề/từ vựng) ở server — sửa state local trong app không lách được.
    if (sellingEnabled()) {
      final quid = authUserId(req);
      if (quid != null &&
          db.userById(quid)?['role'] != 'admin' &&
          !hasVideoPremium(db.userEntitlements(quid))) {
        final used = db.videoUsedSec(quid, videoPeriodKey());
        if (used >= cfgInt('video_free_month_sec', 10800)) {
          return bad(
              'Bạn đã dùng hết 3 giờ video miễn phí tháng này. '
              'Nâng cấp Video Premium để xem không giới hạn.',
              code: 429);
        }
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
    // Video cộng đồng xem bởi người KHÁC chủ → tiêu đề/kênh gốc YouTube.
    final vuid = authUserId(req);
    final vMine = v['owner_user_id'] != null && v['owner_user_id'] == vuid;
    final community = (v['is_official'] as int? ?? 0) == 0 &&
        v['owner_user_id'] != null;
    final showTitle = (community && !vMine)
        ? ((v['yt_title'] as String?) ?? v['title'])
        : v['title'];
    final showChannel = (community && !vMine)
        ? ((v['yt_channel'] as String?) ?? v['channel'])
        : v['channel'];
    return ok({
      'id': v['id'],
      'title': showTitle,
      'channel': showChannel,
      'level': v['level'],
      'durationMs': v['duration_ms'],
      'youtubeId': v['youtube_id'],
      'sentences': sentences,
      // Video đã có phụ đề THẬT chưa. App dựa vào CỜ NÀY (không đoán bằng cách
      // so chuỗi tiếng Nhật) để hiện trạng thái "phụ đề đang được chuẩn bị"
      // thay vì màn học rỗng, và để KHÔNG tính "đã học xong bài".
      'hasSubtitles': db.videoHasRealSubs(int.parse(id)),
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
    // Khi BÁN HÀNG bật: nhập video riêng là quyền của Video Premium
    // (Monthly/Yearly/All Access), tối đa 3 video/ngày. Enforce ở SERVER —
    // restart app hay sửa state local không lách được. Admin không giới hạn.
    if (sellingEnabled() && db.userById(uid)?['role'] != 'admin') {
      if (!hasVideoPremium(db.userEntitlements(uid))) {
        return bad(
            'Nhập video riêng là quyền của gói Video Premium. '
            'Nâng cấp để tự thêm video YouTube bạn thích.',
            code: 403);
      }
      if (db.importCount(uid, dayKey()) >=
          cfgInt('import_day_limit', 3)) {
        return bad(
            'Bạn đã nhập đủ ${cfgInt('import_day_limit', 3)} video hôm nay. '
            'Mai quay lại nhé!',
            code: 429);
      }
    }
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
    // "This video is private" và không phát được trong app. Đồng thời lấy luôn
    // TIÊU ĐỀ + KÊNH GỐC từ YouTube: người xem KHÁC chủ video sẽ thấy tên gốc
    // này (không thấy tên tự đặt — chống tiêu đề misleading).
    final info = await _youtubeInfo(ytId);
    if (info.ok == false) {
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
      ytTitle: info.title,
      ytChannel: info.author,
    );
    // Ghi sổ nhập video (đếm cả khi chưa bật bán — có sẵn dữ liệu khi bật).
    db.addImport(uid, dayKey());
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

  // -------- luyện nói: ĐÃ GỠ (11/8/2026) --------
  // Tính năng hội thoại AI dùng model chính (Opus) và tốn tới ~12 USD/tháng cho
  // một học viên premium dùng hết hạn mức 1 giờ/ngày — cao hơn cả tiền gói
  // ¥1.500/tháng. Sếp chốt bỏ hẳn. Giữ 2 route trả 410 để BẢN APP CŨ đã cài trên
  // máy học viên không gọi vào khoảng trống (và không đốt tiền nữa).
  Response _speakingGone() => Response(
        410,
        body: jsonEncode({
          'error': 'Tính năng luyện nói AI đã được gỡ khỏi XS GO. '
              'Hãy cập nhật app lên bản mới nhất.'
        }),
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
  r.get('/speaking/scenarios', (Request req) => _speakingGone());
  r.post('/speaking', (Request req) => _speakingGone());

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

  // Cập nhật ngôn ngữ mẹ đẻ của tài khoản (app gọi khi user đổi ngôn ngữ) —
  // dùng để lọc video cộng đồng theo ngôn ngữ ở /discover.
  r.post('/me/lang', (Request req) async {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    final b = await readJson(req);
    final lang = ((b['lang'] as String?) ?? '').trim();
    if (!{'vi', 'my', 'id', 'ne'}.contains(lang)) {
      return bad('Ngôn ngữ không hỗ trợ');
    }
    db.setNativeLang(uid, lang);
    return ok({'ok': true, 'lang': lang});
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

  // ============================================================
  //  GOOGLE PLAY BILLING — routes
  // ============================================================
  // Client gửi purchaseToken sau khi mua/restore → server xác minh với Google
  // rồi mới cấp quyền. KHÔNG BAO GIỜ cấp quyền chỉ vì client nói đã mua.
  r.post('/billing/google/verify', (Request req) async {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    if (!gplay.enabled) {
      return bad(
          'Máy chủ chưa cấu hình xác minh Google Play (XSGO_GPLAY_SA_JSON). '
          'Liên hệ hỗ trợ.',
          code: 503);
    }
    // Chống dò token bừa bãi.
    if (_limited('bill:u$uid', 30, 3600 * 1000)) {
      return bad('Quá nhiều yêu cầu, thử lại sau', code: 429);
    }
    final b = await readJson(req);
    final productId = ((b['productId'] as String?) ?? '').trim();
    final token = ((b['purchaseToken'] as String?) ?? '').trim();
    if (productId.isEmpty || token.isEmpty || token.length > 4096) {
      return bad('Thiếu productId/purchaseToken');
    }
    if (catalog.entitlementOf(productId) == null) {
      return bad('Sản phẩm không hợp lệ: $productId');
    }
    // Token đã gắn tài khoản app KHÁC → từ chối (chống mua 1 lần dùng nhiều
    // tài khoản). Người thật đổi tài khoản → liên hệ hỗ trợ chuyển tay.
    final existing = db.purchaseByToken(token);
    if (existing != null && existing['user_id'] != uid) {
      return bad(
          'Giao dịch này đã gắn với tài khoản XS GO khác. '
          'Hãy đăng nhập đúng tài khoản đã mua, hoặc liên hệ hỗ trợ.',
          code: 409);
    }
    try {
      final state = await applyVerified(uid, productId, token);
      return ok({'status': state, 'owned': db.userEntitlements(uid)});
    } on PurchaseNotFound {
      return bad('Giao dịch không tồn tại trên Google Play', code: 400);
    } catch (e) {
      stderr.writeln('[billing] verify lỗi: $e');
      return bad('Không xác minh được với Google Play, thử lại sau',
          code: 502);
    }
  });

  // Real-time developer notifications (Pub/Sub push) — gia hạn/hết hạn/hoàn
  // tiền cập nhật NGAY không đợi user mở app. Bật bằng env XSGO_RTDN_TOKEN +
  // trỏ Pub/Sub push về .../billing/google/rtdn?token=<XSGO_RTDN_TOKEN>.
  r.post('/billing/google/rtdn', (Request req) async {
    final secret = Platform.environment['XSGO_RTDN_TOKEN'];
    if (secret == null || secret.isEmpty) return bad('RTDN tắt', code: 404);
    if (req.url.queryParameters['token'] != secret) {
      return bad('Sai token', code: 403);
    }
    try {
      final b = await readJson(req);
      final data = (b['message'] as Map<String, dynamic>?)?['data'] as String?;
      if (data != null) {
        final n = jsonDecode(utf8.decode(base64.decode(data)))
            as Map<String, dynamic>;
        final voided =
            n['voidedPurchaseNotification'] as Map<String, dynamic>?;
        final token = ((n['subscriptionNotification']
                    as Map<String, dynamic>?)?['purchaseToken'] ??
                (n['oneTimeProductNotification']
                    as Map<String, dynamic>?)?['purchaseToken'] ??
                voided?['purchaseToken']) as String?;
        final p = token == null ? null : db.purchaseByToken(token);
        if (p != null) {
          final uid = p['user_id'] as int;
          final productId = p['product_id'] as String;
          final entKey = catalog.entitlementOf(productId);
          if (voided != null) {
            // Hoàn tiền/void → thu hồi quyền ngay.
            db.upsertPurchase(
                token: token!,
                userId: uid,
                productId: productId,
                kind: p['kind'] as String,
                state: 'revoked',
                expiryMs: 0);
            if (entKey != null) db.revokeEntitlement(uid, entKey);
          } else if (gplay.enabled) {
            await applyVerified(uid, productId, token!);
          }
        }
      }
    } catch (e) {
      stderr.writeln('[billing] RTDN lỗi: $e');
    }
    // LUÔN 200 — trả lỗi là Pub/Sub retry dồn dập.
    return ok({'ok': true});
  });

  // -------- entitlements của chính mình (app kéo về sau login) --------
  r.get('/me/entitlements', (Request req) async {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    // Subscription đã quá mốc hết hạn ghi nhận → hỏi lại Google (thường là đã
    // GIA HẠN thành công → đẩy mốc mới; không thì quyền tự rơi). Không có RTDN
    // vẫn tự lành theo cách này mỗi lần user mở app.
    if (gplay.enabled) {
      for (final p
          in db.stalePurchasesOf(uid, DateTime.now().millisecondsSinceEpoch)) {
        try {
          await applyVerified(
              uid, p['product_id'] as String, p['purchase_token'] as String);
        } catch (e) {
          stderr.writeln('[billing] re-verify lỗi: $e');
        }
      }
    }
    return ok({'owned': db.userEntitlements(uid)});
  });

  // -------- quota XEM video Free (3h/tháng) --------
  Map<String, dynamic> videoQuotaFor(int uid) {
    final owned = db.userEntitlements(uid);
    final unlimited = hasVideoPremium(owned);
    final limit = cfgInt('video_free_month_sec', 10800); // 3 giờ
    final used = db.videoUsedSec(uid, videoPeriodKey());
    return {
      'unlimited': unlimited,
      'limitSec': limit,
      'usedSec': used,
      'remainingSec': unlimited ? -1 : (limit - used).clamp(0, limit),
      'enforced': sellingEnabled(),
    };
  }

  r.get('/me/video-quota', (Request req) {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    return ok(videoQuotaFor(uid));
  });

  // App báo số giây VỪA XEM THÊM (chỉ đếm lúc đang phát, không đếm pause).
  // Server là sổ cái: restart app/đổi máy không reset được quota.
  r.post('/me/video-usage', (Request req) async {
    final uid = authUserId(req);
    if (uid == null) return bad('Cần đăng nhập', code: 401);
    // Flush mỗi ≥30s → 120 lần/giờ là quá đủ; chặn spam làm phình DB.
    if (_limited('vu:u$uid', 240, 3600 * 1000)) {
      return bad('Quá nhiều yêu cầu', code: 429);
    }
    final b = await readJson(req);
    // Kẹp mỗi lần báo tối đa 10 phút — client flush 30s/lần, delta lớn hơn
    // nghĩa là bịa số liệu.
    final delta = ((b['deltaSec'] as num?)?.toInt() ?? 0).clamp(0, 600);
    if (delta > 0 && !hasVideoPremium(db.userEntitlements(uid))) {
      db.addVideoUsage(uid, videoPeriodKey(), delta);
    }
    return ok(videoQuotaFor(uid));
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
    'announce_my', // thông báo riêng cho từng ngôn ngữ (rỗng → dùng 'announce')
    'announce_id',
    'announce_ne',
    'bjtPrice',
    'tokuteiPrice', // giá khóa Tokutei hiển thị ở màn mua (rỗng → mặc định)
    'saleBadge', // nhãn khuyến mãi ở màn mua, vd "🔥 Sale 8/8 · giảm 50%"
    'premium_enabled',
    'selling_enabled', // công tắc bán hàng server (đồng bộ kSellingEnabled app)
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

  // THÊM NHANH hàng loạt: dán 1 đoạn text chứa nhiều link video YouTube
  // và/hoặc link playlist — server tự nhận diện, tự lấy TIÊU ĐỀ + KÊNH qua
  // oEmbed, kiểm tra nhúng được, bỏ trùng, rồi thêm tất cả (official).
  // body: {text, level?, playlistId?} → {added:[{id,youtubeId,title}...],
  //        skipped:[{youtubeId?,item?,reason}...]}
  r.post('/admin/videos/bulk', (Request req) async {
    final g = adminGuard(req);
    if (g != null) return g;
    final b = await readJson(req);
    final text = ((b['text'] as String?) ?? '').trim();
    if (text.isEmpty) return bad('Dán ít nhất 1 link YouTube');
    if (text.length > 20000) return bad('Nội dung dán quá dài');
    final level = ((b['level'] as String?) ?? 'N5').trim();
    final pid = b['playlistId'];

    final videoRe = RegExp(
        r'(?:youtu\.be/|watch\?v=|/embed/|/shorts/|/live/)([A-Za-z0-9_-]{11})');
    final bareIdRe = RegExp(r'^[A-Za-z0-9_-]{11}$');
    final playlistRe = RegExp(r'[?&]list=([A-Za-z0-9_-]{10,})');

    final ids = <String>[]; // giữ thứ tự dán
    final skipped = <Map<String, dynamic>>[];
    void addId(String id) {
      if (!ids.contains(id)) ids.add(id);
    }

    // Tách theo dòng/khoảng trắng/phẩy — mỗi token 1 link hoặc 1 ID.
    for (final tokRaw in text.split(RegExp(r'[\s,]+'))) {
      final tok = tokRaw.trim();
      if (tok.isEmpty) continue;
      final vm = videoRe.firstMatch(tok);
      if (vm != null) {
        addId(vm.group(1)!);
        continue; // link watch?v=..&list=.. → ưu tiên video, không kéo cả list
      }
      final pm = playlistRe.firstMatch(tok);
      if (pm != null) {
        // Link playlist thuần → kéo toàn bộ video trong đó (cần API key).
        try {
          final listIds = await _playlistVideoIds(pm.group(1)!);
          if (listIds == null) {
            skipped.add({
              'item': tok,
              'reason':
                  'Nhập playlist cần đặt YOUTUBE_API_KEY trên server (Google Cloud → YouTube Data API v3)'
            });
          } else if (listIds.isEmpty) {
            skipped.add({'item': tok, 'reason': 'Playlist rỗng hoặc không đọc được'});
          } else {
            listIds.forEach(addId);
          }
        } catch (e) {
          skipped.add({'item': tok, 'reason': '$e'});
        }
        continue;
      }
      if (bareIdRe.hasMatch(tok)) {
        addId(tok);
        continue;
      }
      skipped.add({'item': tok, 'reason': 'Không nhận diện được link/ID'});
    }
    if (ids.length > 200) {
      skipped.add({'item': '...', 'reason': 'Chỉ nhận tối đa 200 video/lần — phần dư bị bỏ'});
      ids.removeRange(200, ids.length);
    }

    // Lấy metadata + thêm — chạy song song từng nhóm 6 cho nhanh.
    final added = <Map<String, dynamic>>[];
    for (var i = 0; i < ids.length; i += 6) {
      final chunk = ids.sublist(i, i + 6 > ids.length ? ids.length : i + 6);
      await Future.wait(chunk.map((ytId) async {
        if (db.officialVideoExists(ytId)) {
          skipped.add({'youtubeId': ytId, 'reason': 'Đã có trong thư viện'});
          return;
        }
        final info = await _youtubeInfo(ytId);
        if (info.ok == false) {
          skipped.add({
            'youtubeId': ytId,
            'reason': 'Không nhúng được (private/tắt embed)'
          });
          return;
        }
        final title = (info.title?.isNotEmpty == true) ? info.title! : ytId;
        final id = db.createVideo(
          title: title,
          channel:
              (info.author?.isNotEmpty == true) ? info.author! : 'XS GO',
          level: level,
          youtubeId: ytId,
          ownerUserId: null,
          official: true,
        );
        if (pid is int && db.playlistExists(pid)) {
          db.addVideoToPlaylist(pid, id);
        }
        added.add({'id': id, 'youtubeId': ytId, 'title': title});
      }));
    }
    return ok({'added': added, 'skipped': skipped});
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

  // CHI PHÍ AI: tổng phút AI theo kỳ + top người dùng kỳ này (soát chi phí).
  r.get('/admin/ai-usage', (Request req) {
    final g = adminGuard(req);
    if (g != null) return g;
    String two(int n) => n.toString().padLeft(2, '0');
    final now = DateTime.now();
    return ok(db.aiUsageSummary('${now.year}-${two(now.month)}'));
  });

  // THỐNG KÊ HỌC TẬP: user hoạt động 7/30 ngày + video xem nhiều nhất.
  r.get('/admin/learn-stats', (Request req) {
    final g = adminGuard(req);
    if (g != null) return g;
    return ok(db.learnStats());
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
  /// Chặng 3 của pipeline phụ đề, tách riêng để dùng lại: câu + mốc thời gian
  /// (từ caption YouTube, Whisper, HOẶC caption json3 do máy khác đẩy lên) →
  /// furigana + dịch lô đầu → lưu → dịch trọn video ở nền.
  Future<Response> saveSubsFromSegs(
      int vid, List<Map<String, dynamic>> segs, String source,
      {bool aiFurigana = true}) async {
    // 3) Furigana + DỊCH tiếng Việt lô đầu (để mở xem ngay) + lưu.
    final jp = [for (final s in segs) s['text'] as String];
    // `aiFurigana: false` → bỏ hẳn lượt gọi model chính (Opus, đắt): máy ở nhà
    // gắn furigana bằng SudachiPy miễn phí rồi đẩy lên qua route
    // `/admin/videos/<id>/furigana` (scripts/furigana_offline.py).
    final withFuri = aiFurigana ? await ai.furigana(jp) : jp;
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
    return saveSubsFromSegs(vid, segs, source);
  }

  // PHỤ ĐỀ HÀNG LOẠT: quét video chưa có phụ đề thật → tạo TUẦN TỰ ở nền
  // (caption-first, không phụ thuộc admin còn mở app). Trả về số video xếp hàng.
  r.post('/admin/videos/generate-subtitles-missing', (Request req) async {
    final g = adminGuard(req);
    if (g != null) return g;
    if (_bulkSubsRunning) {
      return bad('Đang có một lượt tạo phụ đề hàng loạt chạy — chờ xong đã.');
    }
    final missing = db.videosMissingSubs(limit: 30);
    if (missing.isEmpty) return ok({'queued': 0});
    _bulkSubsRunning = true;
    unawaited(() async {
      try {
        for (final v in missing) {
          final vid = v['id'] as int;
          // Ghi mốc ĐÃ THỬ (kể cả thất bại) — video hỏng vĩnh viễn không
          // chiếm đầu hàng của lượt quét sau (nghỉ 24h mới thử lại).
          db.markSubsAttempt(vid);
          try {
            final res = await genSubtitles(vid);
            if (res.statusCode != 200) {
              stderr.writeln(
                  '[BULK-SUBS] video $vid bỏ qua (${res.statusCode}): '
                  '${await res.readAsString()}');
            }
          } catch (e) {
            stderr.writeln('[BULK-SUBS] video $vid: $e');
          }
          // Nghỉ giữa các video: tránh YouTube rate-limit + nhường event loop.
          await Future.delayed(const Duration(seconds: 8));
        }
      } finally {
        _bulkSubsRunning = false;
      }
    }());
    return ok({'queued': missing.length});
  });

  // NHẬN CAPTION TỪ MÁY KHÁC: YouTube chặn IP trung tâm dữ liệu nên
  // `yt-dlp` chạy TRÊN SERVER thường về tay không (403). Máy ở nhà/máy dev thì
  // tải được → chạy `scripts/push_captions_local.py` để đẩy nguyên file
  // caption **json3** lên đây; server vẫn dùng CHUNG pipeline (ngắt câu theo
  // nhịp đọc → furigana → dịch nền) nên phụ đề giống hệt đường tự động.
  r.post('/admin/videos/<id|[0-9]+>/captions-json3',
      (Request req, String id) async {
    final g = adminGuard(req);
    if (g != null) return g;
    final vid = int.parse(id);
    if (db.video(vid) == null) return bad('Không tìm thấy video', code: 404);
    final b = await readJson(req);
    final raw = b['json3'];
    final data = raw is Map<String, dynamic>
        ? raw
        : (raw is String
            ? (jsonDecode(raw) as Map<String, dynamic>)
            : <String, dynamic>{});
    if (data.isEmpty) {
      return bad('Thiếu nội dung caption json3 (field "json3").');
    }
    final segs = parseJson3Captions(data);
    if (segs.isEmpty) {
      return bad('Caption json3 không có câu tiếng Nhật nào đọc được.',
          code: 422);
    }
    // furigana: 'ai' (mặc định, gọi model chính) | 'local' (bỏ qua — máy gửi sẽ
    // gắn offline rồi POST /admin/videos/<id>/furigana).
    final wantAi = ((b['furigana'] as String?) ?? 'ai') != 'local';
    final res = await saveSubsFromSegs(vid, segs, 'caption-push',
        aiFurigana: wantAi);
    if (wantAi || res.statusCode != 200) return res;
    // Trả lại câu ĐÃ NGẮT (server ngắt theo nhịp đọc) để máy local gắn ruby vào
    // đúng những câu này — không tự ngắt lại ở phía client.
    return ok({
      'count': db.sentences(vid).length,
      'source': 'caption-push',
      'furigana': 'pending-local',
      'sentences': [
        for (var i = 0; i < segs.length; i++)
          {
            'ord': i,
            'jp': segs[i]['text'],
            // Mốc từng từ của caption: gửi kèm để vòng 2 căn karaoke cho token
            // MỚI (chưa có furigana thì cả câu là 1 token, không suy lại được).
            'words': segs[i]['words'] ?? const [],
          }
      ],
    });
  });

  // NHẬN FURIGANA LÀM SẴN Ở MÁY KHÁC: `scripts/furigana_offline.py` (SudachiPy)
  // gắn `[漢字|かな]` miễn phí, ở đây chỉ tách token lại và GIỮ mốc karaoke
  // (mốc từng từ được chuyển sang token mới theo vị trí ký tự).
  r.post('/admin/videos/<id|[0-9]+>/furigana',
      (Request req, String id) async {
    final g = adminGuard(req);
    if (g != null) return g;
    final vid = int.parse(id);
    if (db.video(vid) == null) return bad('Không tìm thấy video', code: 404);
    final b = await readJson(req);
    final lines = (b['lines'] as List?) ?? const [];
    if (lines.isEmpty) return bad('Thiếu danh sách câu (field "lines").');
    final byOrd = <int, String>{};
    final wordsByOrd = <int, List<Map<String, dynamic>>>{};
    for (final l in lines) {
      final m = Map<String, dynamic>.from(l as Map);
      final ord = (m['ord'] as num?)?.toInt();
      final jp = (m['jp'] as String?) ?? '';
      if (ord == null || jp.trim().isEmpty) continue;
      byOrd[ord] = jp;
      final w = (m['words'] as List?) ?? const [];
      if (w.isNotEmpty) {
        wordsByOrd[ord] = [
          for (final e in w)
            {
              'text': '${(e as Map)['text'] ?? ''}',
              'tMs': ((e)['tMs'] as num?)?.toInt() ?? 0,
            }
        ];
      }
    }
    final rows = db.sentences(vid);
    if (rows.isEmpty) return bad('Video chưa có phụ đề để gắn furigana', code: 422);
    var changed = 0;
    final sents = <Map<String, dynamic>>[];
    for (final row in rows) {
      final ord = (row['ord'] as num).toInt();
      final oldTokens = (jsonDecode(row['tokens_json'] as String? ?? '[]') as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final ruby = byOrd[ord];
      var tokens = oldTokens;
      var words = (jsonDecode(row['words_json'] as String? ?? '[]') as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      var plain = row['text_jp'] as String;
      if (ruby != null) {
        final parsed = _parseJp(ruby);
        // Chỉ nhận khi bóc markup ra ĐÚNG câu gốc — chặn lệch câu/lệch thứ tự.
        if (parsed.$3 == plain) {
          tokens = parsed.$1;
          words = parsed.$2;
          // Karaoke: ưu tiên mốc TỪNG TỪ gốc của caption (client gửi lại từ
          // vòng 1). Không có thì suy từ token cũ — chỉ giữ được mốc theo câu.
          final timed = wordsByOrd[ord] ??
              () {
                final out = <Map<String, dynamic>>[];
                var last = (row['start_ms'] as num).toInt();
                for (final t in oldTokens) {
                  final ms = (t['tMs'] as num?)?.toInt();
                  if (ms != null) last = ms;
                  out.add(
                      {'text': (t['surface'] as String?) ?? '', 'tMs': last});
                }
                return out;
              }();
          if (timed.isNotEmpty) alignTokenTimings(tokens, plain, timed);
          changed++;
        }
      }
      sents.add({
        'startMs': (row['start_ms'] as num).toInt(),
        'endMs': (row['end_ms'] as num).toInt(),
        'textJp': plain,
        'tokens': tokens,
        'words': words,
        'vi': (jsonDecode(row['translations_json'] as String? ?? '{}')
            as Map)['vi'] ?? '',
      });
    }
    db.replaceVideoSentences(vid, sents);
    return ok({'updated': changed, 'total': rows.length});
  });

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
          position: b['position'] as int?,
          section: b['section'] as String?);
      return ok({'id': idRaw});
    }
    if (title.isEmpty) return bad('Thiếu tên danh sách phát');
    final newId = db.createPlaylist(
      title: title,
      description: (b['description'] as String?) ?? '',
      level: (b['level'] as String?) ?? '',
      position: (b['position'] as int?) ?? 0,
      section: (b['section'] as String?) ?? 'home',
    );
    return ok({'id': newId});
  });

  // Xoá NHANH nhiều video một lần (admin dọn kho — kể cả video seed/demo).
  r.post('/admin/videos/delete-bulk', (Request req) async {
    final g = adminGuard(req);
    if (g != null) return g;
    final b = await readJson(req);
    final ids = ((b['ids'] as List?) ?? const [])
        .whereType<num>()
        .map((e) => e.toInt())
        .toList();
    if (ids.isEmpty) return bad('Thiếu danh sách id video');
    // Trần số lượng: server đơn luồng (sqlite đồng bộ) — payload khổng lồ sẽ
    // block mọi request khác. 1000/lượt là quá đủ cho thao tác dọn kho thật.
    if (ids.length > 1000) {
      return bad('Tối đa 1000 video mỗi lượt (đang gửi ${ids.length})');
    }
    final n = db.adminDeleteVideos(ids);
    return ok({'deleted': n});
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
