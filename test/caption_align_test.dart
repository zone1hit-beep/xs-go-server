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

  group('ngắt câu theo dấu câu ở GIỮA từ (lỗi phụ đề dính 2 câu)', () {
    test('"です。それで" bị tách thành 2 dòng riêng', () {
      final data = {
        'events': [
          {
            'tStartMs': 0,
            'segs': [
              {'utf8': 'おはよう', 'tOffsetMs': 0},
              {'utf8': 'ございます。それでは', 'tOffsetMs': 300},
              {'utf8': '始めます', 'tOffsetMs': 900},
            ],
          },
        ],
      };
      final out = parseJson3Captions(data);
      expect(out.length, greaterThanOrEqualTo(2),
          reason: 'dấu 。 ở giữa từ phải cắt sang dòng mới');
      expect(out.first['text'], contains('。'));
      // Câu sau KHÔNG được chứa phần trước dấu chấm.
      expect(out[1]['text'], isNot(contains('ございます')));
    });

    test('không có dấu câu ở giữa thì giữ nguyên từ', () {
      final data = {
        'events': [
          {
            'tStartMs': 0,
            'segs': [
              {'utf8': 'これは', 'tOffsetMs': 0},
              {'utf8': 'ペンです', 'tOffsetMs': 200},
            ],
          },
        ],
      };
      final out = parseJson3Captions(data);
      expect(out.length, 1);
      expect(out.first['text'], 'これはペンです');
    });

    test('dòng phụ đề không quá dài (trần mềm ~26 chữ)', () {
      final segs = <Map<String, dynamic>>[];
      for (var i = 0; i < 30; i++) {
        segs.add({'utf8': 'あい', 'tOffsetMs': i * 200});
      }
      final out = parseJson3Captions({
        'events': [
          {'tStartMs': 0, 'segs': segs}
        ]
      });
      for (final s in out) {
        expect((s['text'] as String).length, lessThanOrEqualTo(30),
            reason: 'dòng "${s['text']}" quá dài');
      }
    });
  });

  group('NGẮT THEO NHỊP ĐỌC (lỗi: cắt cứng giữa chừng, tách đuôi ます)', () {
    /// Dựng caption liền mạch: các từ cách nhau [gapMs] (không có chỗ nghỉ).
    Map<String, dynamic> run(List<String> texts, {int gapMs = 220}) => {
          'events': [
            {
              'tStartMs': 0,
              'segs': [
                for (var i = 0; i < texts.length; i++)
                  {'utf8': texts[i], 'tOffsetMs': i * gapMs},
              ],
            },
          ],
        };

    test('KHÔNG tách đuôi「ます」khỏi thân động từ', () {
      // Câu dài liền mạch, phải chia — nhưng không được chia ngay trước ます.
      final out = parseJson3Captions(run([
        'それでは', '今日', 'の', 'ニュース', 'を',
        '始め', 'ます', 'ので', 'よろしく', 'お願い', 'し', 'ます',
      ]));
      expect(out.length, greaterThan(1), reason: 'câu dài phải được chia');
      for (final s in out) {
        final t = s['text'] as String;
        expect(t.startsWith('ます'), isFalse,
            reason: 'dòng "$t" bắt đầu bằng đuôi ます → đã tách khỏi thân từ');
        expect(t.startsWith('ました'), isFalse, reason: 'dòng "$t"');
        expect(t.startsWith('です'), isFalse, reason: 'dòng "$t"');
      }
    });

    test('ngắt ĐÚNG chỗ người nói nghỉ (nghỉ dài giữa câu)', () {
      final out = parseJson3Captions({
        'events': [
          {
            'tStartMs': 0,
            'segs': [
              {'utf8': 'これは', 'tOffsetMs': 0},
              {'utf8': 'ペンです', 'tOffsetMs': 250},
              // nghỉ 1,2 giây = ngắt ý rõ ràng
              {'utf8': 'それから', 'tOffsetMs': 1450},
              {'utf8': 'ノートも', 'tOffsetMs': 1700},
            ],
          },
        ],
      });
      expect(out.length, 2, reason: 'phải ngắt đúng tại chỗ nghỉ 1,2s');
      expect(out[0]['text'], 'これはペンです');
      expect(out[1]['text'], 'それからノートも');
    });

    test('câu ngắn liền mạch KHÔNG bị chia vụn', () {
      final out = parseJson3Captions(run(['今日', 'は', 'いい', '天気']));
      expect(out.length, 1, reason: 'câu ngắn không có lý do gì để cắt');
      expect(out.first['text'], '今日はいい天気');
    });


    test('KHÔNG cắt ngay trước TRỢ TỪ (の を が は に…)', () {
      final out = parseJson3Captions(run([
        'バイト', 'サイズ', 'ジャパニーズ', 'の', 'レーラ', 'です',
        'よろしく', 'お願い', 'いたし', 'ます', 'ね',
      ]));
      for (final s in out) {
        final t = s['text'] as String;
        for (final joshi in ['の', 'を', 'が', 'は', 'に', 'で', 'と']) {
          expect(t.startsWith(joshi), isFalse,
              reason: 'dòng "$t" mở đầu bằng trợ từ "$joshi" → cắt sai chỗ');
        }
      }
    });

    test('KHÔNG tách danh từ phụ thuộc (時 / こと) khỏi mệnh đề trước', () {
      final out = parseJson3Captions(run([
        '私', 'が', 'バリ', 'に', '行った', '時', 'の', '話', 'を',
        'し', 'たい', 'と', '思い', 'ます', 'けど', 'いい', 'ですか',
      ]));
      for (final s in out) {
        final t = s['text'] as String;
        expect(t.startsWith('時'), isFalse,
            reason: 'dòng "$t" tách 時 khỏi mệnh đề đứng trước');
        expect(t.startsWith('こと'), isFalse, reason: 'dòng "$t"');
      }
    });

    test('ưu tiên cắt SAU hết vế câu thay vì giữa vế', () {
      // Đủ dài để BUỘC phải chia (>26 chữ), có ranh giới vế rõ ở ました.
      final out = parseJson3Captions(run([
        '昨日', 'は', '会社', 'に', '行き', 'ました',
        'それから', '友達', 'と', '晩ご飯', 'を', '食べ', 'ました',
      ]));
      expect(out.length, greaterThan(1),
          reason: 'câu ${out.map((e) => e['text']).toList()} phải được chia');
      // Dòng đầu nên kết thúc trọn vẹn ở ました (hết vế), không đứt giữa chừng.
      expect((out.first['text'] as String).endsWith('ました'), isTrue,
          reason: 'dòng đầu "${out.first['text']}" phải hết ở ranh giới vế câu');
    });
  });
}
