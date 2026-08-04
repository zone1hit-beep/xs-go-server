// Kiểm chứng logic phụ đề: gộp câu từ caption json3 + căn mốc thời gian
// từng TOKEN sau khi thêm furigana.
import 'package:test/test.dart';
import 'package:xs_go_server/api.dart';

Map<String, dynamic> _ev(int tStart, List<List<Object?>> segs) => {
      'tStartMs': tStart,
      'segs': [
        for (final s in segs) {'utf8': s[0], if (s[1] != null) 'tOffsetMs': s[1]}
      ],
    };

void main() {
  group('parseJson3Captions', () {
    test('bỏ event xoá dòng, giữ mốc từng từ, end = mốc câu kế', () {
      final data = {
        'events': [
          _ev(1000, [
            ['\n', null]
          ]), // event xoá dòng -> phải bỏ
          _ev(1000, [
            ['こんにちは', null],
            ['田中', 400],
            ['です', 700],
          ]),
          _ev(5000, [
            ['よろしく', null],
            ['お願い', 500],
          ]),
        ]
      };
      final s = parseJson3Captions(data);
      expect(s.length, 2);
      expect(s[0]['text'], 'こんにちは田中です');
      expect(s[0]['startMs'], 1000);
      // end = mốc bắt đầu câu kế
      expect(s[0]['endMs'], 5000);
      final w = (s[0]['words'] as List).cast<Map>();
      expect(w.map((e) => e['tMs']).toList(), [1000, 1400, 1700]);
      expect(s[1]['text'], 'よろしくお願い');
    });

    test('ngắt dòng khi nghỉ >= 800ms', () {
      // Hai dòng đều đủ dài (>= 8 chữ) để không bị bước "gộp dòng vụn" nhập lại
      // -> kiểm đúng riêng logic ngắt theo khoảng nghỉ.
      final data = {
        'events': [
          _ev(0, [
            ['あああああああああ', null],
            ['いいいいいいいいい', 1000], // nghỉ 1s -> dòng mới
          ]),
        ]
      };
      final s = parseJson3Captions(data);
      expect(s.length, 2);
      expect(s[0]['text'], 'あああああああああ');
      expect(s[1]['text'], 'いいいいいいいいい');
    });

    test('gộp dòng vụn (< 8 chữ) vào dòng kề khi liền mạch', () {
      final data = {
        'events': [
          _ev(0, [
            ['見ていき', null],
          ]),
          _ev(900, [
            ['ましょう', null], // nghỉ 0,9s < 1,2s -> gộp
          ]),
        ]
      };
      final s = parseJson3Captions(data);
      expect(s.length, 1);
      expect(s.first['text'], '見ていきましょう');
      expect(s.first['startMs'], 0);
    });

    test('KHÔNG gộp dòng vụn khi nghỉ dài (>= 1,2s)', () {
      final data = {
        'events': [
          _ev(0, [
            ['はい', null],
          ]),
          _ev(3000, [
            ['どうも', null], // nghỉ 3s = ngắt ý thật -> giữ 2 dòng
          ]),
        ]
      };
      final s = parseJson3Captions(data);
      expect(s.length, 2);
      expect(s[0]['text'], 'はい');
      expect(s[1]['text'], 'どうも');
    });

    test('GIỮ THỨ TỰ CHỮ khi nhiều từ trùng mốc thời gian (sort ổn định)', () {
      // Kịch bản review đối kháng đã repro: >32 từ (Dart chuyển sang quicksort
      // KHÔNG ổn định) + seg cuối event N trùng mốc tuyệt đối seg đầu event
      // N+1 → bản cũ đảo chữ ('a7i6' thay vì 'i6a7'). Sort có khóa phụ 'seq'
      // phải giữ nguyên thứ tự xuất hiện.
      final events = <Map<String, dynamic>>[
        for (var i = 0; i < 60; i++)
          _ev(i * 500, [
            ['あ$i', null],
            ['い$i', 500], // trùng mốc với 'あ' của event kế tiếp
          ]),
      ];
      final s = parseJson3Captions({'events': events});
      final text = s.map((e) => e['text']).join();
      final expected =
          [for (var i = 0; i < 60; i++) 'あ$iい$i'].join();
      expect(text, expected);
    });

    test('không có từ nào -> danh sách rỗng', () {
      expect(parseJson3Captions({'events': []}), isEmpty);
      expect(
          parseJson3Captions({
            'events': [
              _ev(0, [
                ['\n', null]
              ])
            ]
          }),
          isEmpty);
    });
  });

  group('alignTokenTimings', () {
    test('gán đúng mốc cho token có furigana', () {
      // Câu: 私は田中です  (từ: 私@0 は@300 田中@600 です@900)
      final tokens = <Map<String, dynamic>>[
        {'surface': '私', 'reading': 'わたし', 'tappable': true},
        {'surface': 'は', 'tappable': false},
        {'surface': '田中', 'reading': 'たなか', 'tappable': true},
        {'surface': 'です', 'tappable': false},
      ];
      final words = <Map<String, dynamic>>[
        {'tMs': 0, 'text': '私'},
        {'tMs': 300, 'text': 'は'},
        {'tMs': 600, 'text': '田中'},
        {'tMs': 900, 'text': 'です'},
      ];
      alignTokenTimings(tokens, '私は田中です', words);
      expect(tokens.map((t) => t['tMs']).toList(), [0, 300, 600, 900]);
    });

    test('token nhỏ hơn từ caption vẫn lấy mốc của từ chứa nó', () {
      // caption gộp '田中です' thành 1 từ; token tách nhỏ hơn.
      final tokens = <Map<String, dynamic>>[
        {'surface': '田中', 'tappable': true},
        {'surface': 'です', 'tappable': false},
      ];
      final words = <Map<String, dynamic>>[
        {'tMs': 500, 'text': '田中です'},
      ];
      alignTokenTimings(tokens, '田中です', words);
      expect(tokens[0]['tMs'], 500);
      expect(tokens[1]['tMs'], 500);
    });

    test('câu KHÔNG khớp chuỗi từ -> không gán mốc (tránh sai lệch)', () {
      final tokens = <Map<String, dynamic>>[
        {'surface': 'まったく', 'tappable': false},
      ];
      final words = <Map<String, dynamic>>[
        {'tMs': 0, 'text': 'ぜんぜん'},
      ];
      alignTokenTimings(tokens, 'まったく', words);
      expect(tokens[0].containsKey('tMs'), isFalse);
    });

    test('bỏ qua an toàn khi thiếu dữ liệu', () {
      final tokens = <Map<String, dynamic>>[
        {'surface': 'あ', 'tappable': false}
      ];
      alignTokenTimings(tokens, 'あ', const []);
      expect(tokens[0].containsKey('tMs'), isFalse);
      alignTokenTimings(<Map<String, dynamic>>[], '', const []); // không ném lỗi
    });
  });
}
