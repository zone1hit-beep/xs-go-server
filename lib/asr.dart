import 'dart:convert';
import 'dart:io';

/// Bóc tiếng (speech-to-text) từ file audio bằng Whisper qua Groq API.
/// Groq nhanh + rẻ + có gói free. Trả về danh sách câu kèm mốc thời gian.
///
/// Chưa có GROQ_API_KEY → `enabled == false`, mọi lời gọi trả rỗng (app vẫn chạy).
class Asr {
  final String? apiKey;
  final String model;
  Asr({this.apiKey, this.model = 'whisper-large-v3-turbo'});

  bool get enabled => apiKey != null && apiKey!.isNotEmpty;

  /// Phiên âm [audio] (mp3/m4a/wav...) sang [lang]. Trả list
  /// {startMs, endMs, text}. Rỗng nếu chưa bật hoặc lỗi.
  Future<List<Map<String, dynamic>>> transcribe(File audio,
      {String lang = 'ja'}) async {
    if (!enabled) return const [];
    if (!audio.existsSync()) return const [];
    try {
      final bytes = await audio.readAsBytes();
      final boundary =
          '----xsgo${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
      final body = <int>[];
      void field(String name, String value) {
        body.addAll(utf8.encode('--$boundary\r\n'
            'Content-Disposition: form-data; name="$name"\r\n\r\n$value\r\n'));
      }

      field('model', model);
      field('response_format', 'verbose_json'); // để có segments + timestamp
      field('language', lang);
      field('temperature', '0');
      body.addAll(utf8.encode('--$boundary\r\n'
          'Content-Disposition: form-data; name="file"; filename="audio"\r\n'
          'Content-Type: application/octet-stream\r\n\r\n'));
      body.addAll(bytes);
      body.addAll(utf8.encode('\r\n--$boundary--\r\n'));

      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 30);
      final req = await client.postUrl(Uri.parse(
          'https://api.groq.com/openai/v1/audio/transcriptions'));
      req.headers.set('authorization', 'Bearer $apiKey');
      req.headers
          .set('content-type', 'multipart/form-data; boundary=$boundary');
      req.headers.set('content-length', body.length.toString());
      req.add(body);
      final resp = await req.close();
      final respBody = await resp.transform(utf8.decoder).join();
      client.close();
      if (resp.statusCode != 200) {
        stderr.writeln('[ASR] ${resp.statusCode}: $respBody');
        return const [];
      }
      final data = jsonDecode(respBody) as Map<String, dynamic>;
      final segs = (data['segments'] as List?) ?? const [];
      final out = <Map<String, dynamic>>[];
      for (final s in segs) {
        final text = ((s['text'] as String?) ?? '').trim();
        if (text.isEmpty) continue;
        out.add({
          'startMs': (((s['start'] as num?) ?? 0) * 1000).round(),
          'endMs': (((s['end'] as num?) ?? 0) * 1000).round(),
          'text': text,
        });
      }
      return out;
    } catch (e) {
      stderr.writeln('[ASR] error: $e');
      return const [];
    }
  }
}
