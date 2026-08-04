// Kiểm chứng parser caption json3 bằng DỮ LIỆU THẬT (không đoán).
// Chạy: dart run tool/check_captions.dart <file.json3>
//
// In ra: số câu, phân bố thời lượng, tỉ lệ câu có mốc TỪNG TỪ, và kiểm tra
// các bất biến (thứ tự tăng dần, end > start, mốc từ nằm trong câu).
import 'dart:convert';
import 'dart:io';

import 'package:xs_go_server/api.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('Cần đường dẫn tới file .json3');
    exit(2);
  }
  final data =
      jsonDecode(File(args.first).readAsStringSync()) as Map<String, dynamic>;
  final sents = parseJson3Captions(data);
  if (sents.isEmpty) {
    stderr.writeln('❌ Không phân tích được câu nào');
    exit(1);
  }

  final durs = <int>[];
  var withWords = 0, totalWords = 0;
  var badOrder = 0, badRange = 0, wordOutside = 0;
  int? prevStart;

  for (final s in sents) {
    final st = s['startMs'] as int, en = s['endMs'] as int;
    durs.add(en - st);
    if (en <= st) badRange++;
    if (prevStart != null && st < prevStart) badOrder++;
    prevStart = st;
    final ws = (s['words'] as List?) ?? const [];
    if (ws.isNotEmpty) withWords++;
    totalWords += ws.length;
    for (final w in ws) {
      final t = (w as Map)['tMs'] as int;
      // Mốc từ phải nằm trong [start, end] (cho phép lệch nhỏ ở biên cuối).
      if (t < st - 1 || t > en + 1) wordOutside++;
    }
  }
  durs.sort();
  int pct(int p) => durs[(durs.length * p ~/ 100).clamp(0, durs.length - 1)];

  stdout.writeln('=== KẾT QUẢ PHÂN TÍCH CAPTION (dữ liệu thật) ===');
  stdout.writeln('Số câu:            ${sents.length}');
  stdout.writeln('Tổng số từ có mốc: $totalWords');
  stdout.writeln('Câu có mốc từng từ: $withWords/${sents.length} '
      '(${(withWords * 100 / sents.length).toStringAsFixed(1)}%)');
  stdout.writeln('Thời lượng câu (ms): min=${durs.first} '
      'p50=${pct(50)} p90=${pct(90)} max=${durs.last}');
  stdout.writeln('');
  stdout.writeln('--- KIỂM TRA BẤT BIẾN ---');
  stdout.writeln('Câu sai thứ tự thời gian: $badOrder  (phải = 0)');
  stdout.writeln('Câu có end <= start:      $badRange  (phải = 0)');
  stdout.writeln('Mốc từ nằm ngoài câu:     $wordOutside (phải = 0)');
  stdout.writeln('');
  stdout.writeln('--- 5 CÂU ĐẦU ---');
  for (final s in sents.take(5)) {
    final ws = (s['words'] as List).cast<Map>();
    final head = ws
        .take(4)
        .map((w) => '${w['text']}@${w['tMs']}')
        .join(' ');
    stdout.writeln('  ${s['startMs']}→${s['endMs']}  ${s['text']}');
    stdout.writeln('      mốc từ: $head');
  }

  final okAll = badOrder == 0 && badRange == 0 && wordOutside == 0;
  stdout.writeln('');
  stdout.writeln(okAll ? '✅ TẤT CẢ BẤT BIẾN ĐẠT' : '❌ CÓ BẤT BIẾN SAI');
  exit(okAll ? 0 : 1);
}
