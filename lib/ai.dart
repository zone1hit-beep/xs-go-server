import 'dart:convert';
import 'dart:io';

/// Cầu nối AI qua Claude API (Anthropic). Nếu chưa có ANTHROPIC_API_KEY thì
/// trả về fallback tất định để app vẫn chạy được khi dev (không tốn tiền).
class Ai {
  final String? apiKey;
  final String model;
  Ai({this.apiKey, this.model = 'claude-opus-4-8'});

  bool get enabled => apiKey != null && apiKey!.isNotEmpty;

  static const _langNames = {
    'vi': 'Vietnamese',
    'my': 'Burmese (Myanmar)',
    'id': 'Indonesian',
    'ne': 'Nepali',
  };

  /// Dịch danh sách câu tiếng Nhật sang [lang]. Trả về list cùng độ dài.
  Future<List<String>> translate(List<String> jp, String lang) async {
    if (jp.isEmpty) return [];
    if (!enabled) {
      // Fallback: đánh dấu ngôn ngữ để dev thấy đường đi (vi đã có sẵn cache ở DB).
      return jp.map((s) => '[${lang.toUpperCase()}] $s').toList();
    }
    final target = _langNames[lang] ?? lang;
    final numbered = [
      for (var i = 0; i < jp.length; i++) '${i + 1}. ${jp[i]}'
    ].join('\n');
    final prompt =
        'Translate each numbered Japanese sentence into natural $target for a '
        'language-learning app. Keep the same numbering, one translation per line, '
        'no romaji, no extra commentary.\n\n$numbered';
    // max_tokens theo cỡ lô — lô lớn mà để 1024 sẽ bị cắt giữa chừng, các câu
    // cuối rơi về placeholder "[LANG] …".
    final budget = (200 + jp.length * 90).clamp(1024, 8000);
    final text = await _message(prompt, maxTokens: budget);
    if (text == null) {
      return jp.map((s) => '[${lang.toUpperCase()}] $s').toList();
    }
    // Bóc theo số thứ tự "N. ..."
    final out = List<String>.filled(jp.length, '');
    for (final line in const LineSplitter().convert(text)) {
      final m = RegExp(r'^\s*(\d+)\.\s*(.+)$').firstMatch(line);
      if (m != null) {
        final idx = int.parse(m.group(1)!) - 1;
        if (idx >= 0 && idx < out.length) out[idx] = m.group(2)!.trim();
      }
    }
    for (var i = 0; i < out.length; i++) {
      if (out[i].isEmpty) out[i] = '[${lang.toUpperCase()}] ${jp[i]}';
    }
    return out;
  }

  /// Dịch một loạt chuỗi giao diện/giáo trình (nguồn thường là tiếng Việt, có
  /// thể lẫn tiếng Nhật) sang [lang]. Giữ nguyên chữ Nhật. Trả về cùng độ dài.
  Future<List<String>> translateTexts(List<String> texts, String lang) async {
    if (texts.isEmpty) return [];
    if (!enabled) return List<String>.from(texts); // fallback: giữ nguyên nguồn
    final target = _langNames[lang] ?? lang;
    final numbered = [
      for (var i = 0; i < texts.length; i++) '${i + 1}. ${texts[i]}'
    ].join('\n');
    final prompt =
        'You are localizing a Japanese-learning app. Translate each numbered line '
        'into natural $target. The source is Vietnamese and may contain Japanese '
        'words/phrases — KEEP any Japanese (kanji/kana) exactly as-is, translate '
        'only the surrounding explanation. Preserve meaning and tone for learners. '
        'Keep the same numbering, one line each, no extra commentary.\n\n$numbered';
    final text = await _message(prompt, maxTokens: 2048);
    if (text == null) return List<String>.from(texts);
    final out = List<String>.from(texts); // mặc định nguồn nếu bóc thiếu
    for (final line in const LineSplitter().convert(text)) {
      final m = RegExp(r'^\s*(\d+)\.\s*(.+)$').firstMatch(line);
      if (m != null) {
        final idx = int.parse(m.group(1)!) - 1;
        if (idx >= 0 && idx < out.length) out[idx] = m.group(2)!.trim();
      }
    }
    return out;
  }

  /// Trả lời hội thoại luyện nói (AI đóng vai bạn nói chuyện theo tình huống).
  Future<String> speakingReply(
      String scenario, String userMessage, String lang) async {
    if (!enabled) {
      return 'そうですね！「$userMessage」いいですね。もっと話しましょう。'
          '\n(AI luyện nói bản demo — bật ANTHROPIC_API_KEY để trả lời thật)';
    }
    final target = _langNames[lang] ?? lang;
    final prompt =
        'You are a friendly Japanese conversation partner in a JLPT practice app. '
        'Scenario: "$scenario". The learner is a beginner whose native language is '
        '$target. Reply in short, natural Japanese (1-2 sentences), then on a new '
        'line give a brief $target translation in parentheses. Keep it encouraging.\n\n'
        'Learner said: $userMessage';
    return await _message(prompt, maxTokens: 512) ??
        'すみません、もう一度お願いします。';
  }

  /// Thêm furigana cho câu tiếng Nhật: chỉ gắn cách đọc cho phần Hán tự theo
  /// ký hiệu `[漢字|かな]` để app tách token bấm-tra-được. Trả về cùng độ dài;
  /// fallback (chưa có key) → giữ nguyên câu (không có furigana).
  Future<List<String>> furigana(List<String> jp) async {
    if (jp.isEmpty) return [];
    if (!enabled) return List<String>.from(jp);
    final numbered = [
      for (var i = 0; i < jp.length; i++) '${i + 1}. ${jp[i]}'
    ].join('\n');
    final prompt =
        'For each numbered Japanese sentence, add furigana ONLY to kanji words '
        'using the notation [KANJI|kana] — the kanji inside brackets, its hiragana '
        'reading after the vertical bar. Do NOT annotate kana-only words or '
        'punctuation. Keep the exact wording and order. Return the same numbering, '
        'one sentence per line, no romaji, no commentary.\n\n'
        'Example input:  1. 日本語を勉強します。\n'
        'Example output: 1. [日本語|にほんご]を[勉強|べんきょう]します。\n\n$numbered';
    final text = await _message(prompt, maxTokens: 2048);
    if (text == null) return List<String>.from(jp);
    final out = List<String>.from(jp);
    for (final line in const LineSplitter().convert(text)) {
      final m = RegExp(r'^\s*(\d+)\.\s*(.+)$').firstMatch(line);
      if (m != null) {
        final idx = int.parse(m.group(1)!) - 1;
        if (idx >= 0 && idx < out.length) out[idx] = m.group(2)!.trim();
      }
    }
    return out;
  }

  /// Gọi Anthropic Messages API. Trả về text hoặc null nếu lỗi.
  Future<String?> _message(String prompt, {int maxTokens = 1024}) async {
    try {
      final client = HttpClient();
      final req = await client
          .postUrl(Uri.parse('https://api.anthropic.com/v1/messages'));
      req.headers.set('content-type', 'application/json');
      req.headers.set('x-api-key', apiKey!);
      req.headers.set('anthropic-version', '2023-06-01');
      req.add(utf8.encode(jsonEncode({
        'model': model,
        'max_tokens': maxTokens,
        'messages': [
          {'role': 'user', 'content': prompt}
        ],
      })));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      client.close();
      if (resp.statusCode != 200) {
        stderr.writeln('[AI] ${resp.statusCode}: $body');
        return null;
      }
      final data = jsonDecode(body) as Map<String, dynamic>;
      final content = data['content'] as List?;
      if (content == null) return null;
      final buf = StringBuffer();
      for (final block in content) {
        if (block is Map && block['type'] == 'text') {
          buf.write(block['text']);
        }
      }
      return buf.toString().trim();
    } catch (e) {
      stderr.writeln('[AI] error: $e');
      return null;
    }
  }
}
