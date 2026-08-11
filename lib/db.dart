import 'dart:convert';
import 'package:sqlite3/sqlite3.dart';

/// Lớp truy cập SQLite. File DB mặc định `xs_go.db` cạnh binary.
class Db {
  final Database _db;
  Db(this._db);

  factory Db.open(String path) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA foreign_keys = ON;');
    final self = Db(db);
    self._migrate();
    self._seedIfEmpty();
    return self;
  }

  void _migrate() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        email TEXT UNIQUE NOT NULL,
        password TEXT NOT NULL,
        native_lang TEXT NOT NULL DEFAULT 'vi',
        level TEXT NOT NULL DEFAULT 'N5',
        provider TEXT NOT NULL DEFAULT 'email',
        provider_id TEXT,
        created_at INTEGER NOT NULL
      );
    ''');
    // Bổ sung cột cho DB cũ (bỏ qua nếu đã có).
    _safeAddColumn('users', 'provider', "TEXT NOT NULL DEFAULT 'email'");
    _safeAddColumn('users', 'provider_id', 'TEXT');
    // role: 'user' | 'admin'. disabled: 1 = khoá đăng nhập.
    _safeAddColumn('users', 'role', "TEXT NOT NULL DEFAULT 'user'");
    _safeAddColumn('users', 'disabled', 'INTEGER NOT NULL DEFAULT 0');
    // Premium: premium_until = mốc hết hạn (ms epoch; 0 = không; sentinel lớn =
    // vĩnh viễn). trial_used = 1 khi đã dùng bản dùng thử 3 ngày (mỗi user 1 lần).
    _safeAddColumn('users', 'premium_until', 'INTEGER NOT NULL DEFAULT 0');
    _safeAddColumn('users', 'trial_used', 'INTEGER NOT NULL DEFAULT 0');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS videos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        channel TEXT NOT NULL,
        level TEXT NOT NULL,
        color INTEGER NOT NULL,
        youtube_id TEXT,
        duration_ms INTEGER NOT NULL
      );
    ''');
    // owner_user_id: null = video seed/dùng chung (không cho xoá qua API);
    // có giá trị = video do user thêm (chỉ chủ mới xoá được).
    _safeAddColumn('videos', 'owner_user_id', 'INTEGER');
    // is_official: 1 = video CHÍNH THỨC (seed + admin đăng) → hiện cho MỌI người
    // ở Khám phá. 0 = video user tự thêm → CHỈ chủ thấy (riêng tư).
    _safeAddColumn('videos', 'is_official', 'INTEGER NOT NULL DEFAULT 0');
    // hidden: admin ẩn video khỏi mọi feed (kiểm duyệt) mà không xoá hẳn.
    _safeAddColumn('videos', 'hidden', 'INTEGER NOT NULL DEFAULT 0');
    // Tiêu đề/kênh GỐC từ YouTube (oEmbed) — người xem KHÁC chủ video thấy
    // tên gốc này thay vì tên tự đặt của người thêm (chống tiêu đề misleading).
    _safeAddColumn('videos', 'yt_title', 'TEXT');
    _safeAddColumn('videos', 'yt_channel', 'TEXT');
    // subs_attempted_at: mốc lần cuối THỬ tạo phụ đề hàng loạt (ms epoch) —
    // để video fail vĩnh viễn không chiếm đầu hàng của lượt quét sau.
    _safeAddColumn('videos', 'subs_attempted_at', 'INTEGER');
    // Video seed (owner null) mặc nhiên là chính thức.
    _db.execute(
        'UPDATE videos SET is_official = 1 WHERE owner_user_id IS NULL AND is_official = 0');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS sentences (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        ord INTEGER NOT NULL,
        start_ms INTEGER NOT NULL,
        end_ms INTEGER NOT NULL,
        text_jp TEXT NOT NULL,
        tokens_json TEXT NOT NULL DEFAULT '[]',
        words_json TEXT NOT NULL DEFAULT '[]',
        translations_json TEXT NOT NULL DEFAULT '{}'
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS progress (
        user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
        goal_words INTEGER NOT NULL DEFAULT 10,
        today_words INTEGER NOT NULL DEFAULT 0,
        total_words INTEGER NOT NULL DEFAULT 0,
        streak INTEGER NOT NULL DEFAULT 0,
        last_study_day TEXT NOT NULL DEFAULT ''
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS translation_cache (
        hash TEXT NOT NULL,
        lang TEXT NOT NULL,
        translated TEXT NOT NULL,
        PRIMARY KEY (hash, lang)
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS vocab (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        term TEXT NOT NULL,
        reading TEXT NOT NULL DEFAULT '',
        meaning TEXT NOT NULL DEFAULT '',
        jlpt TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL
      );
    ''');
    // Quyền sở hữu khóa học/Premium theo user (admin cấp hoặc mua thật sau).
    _db.execute('''
      CREATE TABLE IF NOT EXISTS entitlements (
        user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        course_key TEXT NOT NULL,
        granted_at INTEGER NOT NULL,
        PRIMARY KEY (user_id, course_key)
      );
    ''');
    // Cấu hình app (feature flags, số bài thử, giá...) — admin sửa.
    _db.execute('''
      CREATE TABLE IF NOT EXISTS config (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');
    // Danh sách phát (bộ sưu tập video theo chủ đề) — admin tạo, hiện ở Khám phá.
    _db.execute('''
      CREATE TABLE IF NOT EXISTS playlists (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        level TEXT NOT NULL DEFAULT '',
        color INTEGER NOT NULL DEFAULT 4278226409,
        position INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      );
    ''');
    // section: 'home' = mục "Danh sách phát" trên Home; 'explore' = mục Khám phá.
    _safeAddColumn('playlists', 'section', "TEXT NOT NULL DEFAULT 'home'");
    _db.execute('''
      CREATE TABLE IF NOT EXISTS playlist_videos (
        playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        position INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (playlist_id, video_id)
      );
    ''');
    // Phản hồi / góp ý của người dùng (từ mục Hỗ trợ & phản hồi).
    _db.execute('''
      CREATE TABLE IF NOT EXISTS feedback (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER,
        email TEXT NOT NULL DEFAULT '',
        category TEXT NOT NULL DEFAULT '',
        message TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
    ''');
    // Báo cáo video cộng đồng (mục Khám phá) — kiểm duyệt UGC (Apple 1.2).
    // UNIQUE(video_id, reporter_id): mỗi người báo 1 video 1 lần.
    _db.execute('''
      CREATE TABLE IF NOT EXISTS video_reports (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        reporter_id INTEGER,
        reason TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        UNIQUE(video_id, reporter_id)
      );
    ''');
    // Chặn người đăng: video của người bị chặn không hiện ở Khám phá với mình.
    _db.execute('''
      CREATE TABLE IF NOT EXISTS user_blocks (
        user_id INTEGER NOT NULL,
        blocked_id INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (user_id, blocked_id)
      );
    ''');
    // Lịch sử xem ("Tiếp tục xem") đồng bộ theo tài khoản — đổi máy vẫn còn.
    // vkey = định danh ổn định phía client (yt:.. / v:.. / t:..).
    _db.execute('''
      CREATE TABLE IF NOT EXISTS watch_history (
        user_id INTEGER NOT NULL,
        vkey TEXT NOT NULL,
        video_id INTEGER,
        youtube_id TEXT,
        title TEXT NOT NULL DEFAULT '',
        channel TEXT NOT NULL DEFAULT '',
        level TEXT NOT NULL DEFAULT '',
        pos_ms INTEGER NOT NULL DEFAULT 0,
        dur_ms INTEGER NOT NULL DEFAULT 0,
        done INTEGER NOT NULL DEFAULT 0,
        last_seen INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (user_id, vkey)
      );
    ''');
    // Đo mức dùng AI theo kỳ (period_key = 'M:yyyy-mm' cho free / 'D:yyyy-mm-dd'
    // cho premium) — để áp hạn mức "1 tiếng AI/tháng" (free) · "1 tiếng/ngày" (premium).
    _db.execute('''
      CREATE TABLE IF NOT EXISTS ai_usage (
        user_id INTEGER NOT NULL,
        period_key TEXT NOT NULL,
        used_sec INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (user_id, period_key)
      );
    ''');
    // ---- Google Play Billing ----
    // entitlements granular: video_monthly / video_yearly / bjt_lifetime /
    // tokutei_<ngành> / all_access_lifetime (+ key cũ 'bjt','tokutei' admin cấp).
    // expires_at: 0 = trọn đời; >0 = mốc hết hạn ms (subscription).
    _safeAddColumn('entitlements', 'expires_at', 'INTEGER NOT NULL DEFAULT 0');
    // source: 'admin' | 'google_play' — để RTDN/re-verify chỉ đụng quyền do
    // Google Play cấp, không xoá nhầm quyền admin tặng tay.
    _safeAddColumn('entitlements', 'source', "TEXT NOT NULL DEFAULT 'admin'");
    // Mỗi giao dịch Google Play (purchaseToken là định danh duy nhất).
    // Gắn CHẶT với user đầu tiên xác minh — restore trên tài khoản app khác bị
    // từ chối (chống 1 người mua, cả nhóm dùng chung token).
    _db.execute('''
      CREATE TABLE IF NOT EXISTS purchases (
        purchase_token TEXT PRIMARY KEY,
        user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        product_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        state TEXT NOT NULL,
        order_id TEXT,
        expiry_ms INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    // Quota XEM video của Free (3h/tháng): period_key = 'V:yyyy-mm'.
    _db.execute('''
      CREATE TABLE IF NOT EXISTS video_usage (
        user_id INTEGER NOT NULL,
        period_key TEXT NOT NULL,
        used_sec INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (user_id, period_key)
      );
    ''');
    // Quota NHẬP video của Video Premium (3 video/ngày): day_key = 'yyyy-mm-dd'.
    _db.execute('''
      CREATE TABLE IF NOT EXISTS import_log (
        user_id INTEGER NOT NULL,
        day_key TEXT NOT NULL,
        count INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (user_id, day_key)
      );
    ''');
    // Câu placeholder CŨ hứa "AI tự tạo phụ đề sẽ có ở bản sau" — App Store
    // 2.1 không nhận nội dung hứa tính năng tương lai. Đổi sang hướng dẫn dùng
    // được ngay (CC của YouTube) cho các video đã nằm trong DB.
    _db.execute(
      "UPDATE sentences SET translations_json = ? "
      "WHERE text_jp = '字幕はまだありません' AND translations_json LIKE '%bản sau%'",
      [
        jsonEncode({
          'vi': 'Video này chưa có phụ đề trong XS GO. Bấm nút CC trên trình '
              'phát để dùng phụ đề của YouTube.'
        })
      ],
    );
    // ---- SỬA DỮ LIỆU CŨ: video chưa có phụ đề bị gán "dài 60 giây" ----
    fixPlaceholderDurations();
    // INDEX cho các truy vấn nóng — bắt buộc khi dữ liệu lớn (100k user):
    // không có thì mỗi lần mở video / xem thống kê là full-table-scan.
    _db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sentences_video ON sentences(video_id)');
    _db.execute(
        'CREATE INDEX IF NOT EXISTS idx_watch_last ON watch_history(last_seen)');
    _db.execute(
        'CREATE INDEX IF NOT EXISTS idx_reports_video ON video_reports(video_id)');
    _db.execute(
        'CREATE INDEX IF NOT EXISTS idx_videos_owner ON videos(owner_user_id)');
  }

  /// Tổng mức dùng AI theo THÁNG (6 tháng gần nhất) + top người dùng tháng này.
  ///
  /// ⚠️ Usage ghi dưới 2 dạng khóa: free 'M:yyyy-mm', premium 'D:yyyy-mm-dd'.
  /// Phải CHUẨN HÓA cả hai về tháng — nếu chỉ lọc 'M:' thì premium (nhóm được
  /// dùng nhiều nhất: 1h/ngày) biến mất khỏi báo cáo chi phí.
  Map<String, dynamic> aiUsageSummary(String currentMonth) {
    // currentMonth dạng 'yyyy-mm'.
    final byMonth = _db.select('''
      SELECT substr(period_key, 3, 7) month, SUM(used_sec) total,
             COUNT(DISTINCT user_id) users
      FROM ai_usage GROUP BY month ORDER BY month DESC LIMIT 6
    ''');
    final top = _db.select('''
      SELECT u.email, SUM(a.used_sec) used_sec
      FROM ai_usage a JOIN users u ON u.id = a.user_id
      WHERE substr(a.period_key, 3, 7) = ?
      GROUP BY a.user_id ORDER BY used_sec DESC LIMIT 10
    ''', [currentMonth]);
    return {
      'periods': byMonth.map((r) => Map<String, dynamic>.from(r)).toList(),
      'top': top.map((r) => Map<String, dynamic>.from(r)).toList(),
    };
  }

  /// Thống kê học tập: người dùng hoạt động + video được xem nhiều.
  Map<String, dynamic> learnStats() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final active7 = _db.select(
        'SELECT COUNT(DISTINCT user_id) c FROM watch_history WHERE last_seen > ?',
        [now - 7 * 86400000]).first['c'];
    final active30 = _db.select(
        'SELECT COUNT(DISTINCT user_id) c FROM watch_history WHERE last_seen > ?',
        [now - 30 * 86400000]).first['c'];
    final topVideos = _db.select(
        'SELECT title, channel, COUNT(*) views, SUM(done) dones '
        'FROM watch_history GROUP BY vkey ORDER BY views DESC LIMIT 10');
    return {
      'active7d': active7,
      'active30d': active30,
      'topVideos': topVideos.map((r) => Map<String, dynamic>.from(r)).toList(),
    };
  }

  /// Video CHÍNH THỨC chưa có phụ đề thật (0 câu, hoặc chỉ 1 câu placeholder).
  /// - CHỈ is_official=1: không đốt AI vào video riêng của học viên (chủ video
  ///   có route tự tạo phụ đề riêng).
  /// - Bỏ qua video ĐÃ THỬ trong 24h (subs_attempted_at): video hỏng vĩnh viễn
  ///   (không CC + YouTube chặn tải audio) không chiếm đầu hàng mãi.
  List<Map<String, dynamic>> videosMissingSubs({int limit = 50}) {
    final dayAgo =
        DateTime.now().millisecondsSinceEpoch - 24 * 3600 * 1000;
    final r = _db.select('''
      SELECT v.id, v.title, v.youtube_id,
             (SELECT COUNT(*) FROM sentences s WHERE s.video_id = v.id) sc
      FROM videos v
      WHERE v.hidden = 0 AND v.youtube_id IS NOT NULL
        AND v.is_official = 1
        AND COALESCE(v.subs_attempted_at, 0) < ?
        AND (SELECT COUNT(*) FROM sentences s WHERE s.video_id = v.id) <= 1
      ORDER BY v.id LIMIT ?
    ''', [dayAgo, limit]);
    return r.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  /// Ghi mốc đã thử tạo phụ đề cho video (thành công hay thất bại đều ghi).
  void markSubsAttempt(int videoId) {
    _db.execute('UPDATE videos SET subs_attempted_at = ? WHERE id = ?',
        [DateTime.now().millisecondsSinceEpoch, videoId]);
  }

  void _safeAddColumn(String table, String column, String type) {
    try {
      _db.execute('ALTER TABLE $table ADD COLUMN $column $type;');
    } catch (_) {
      // Cột đã tồn tại — bỏ qua.
    }
  }

  // ---------------- Seed ----------------

  void _seedIfEmpty() {
    // Chỉ seed ĐÚNG MỘT LẦN trong đời DB (gate bằng cờ config 'seeded').
    // Nếu chỉ dựa COUNT==0 thì sau khi admin "dọn sạch kho" bằng xoá hàng loạt,
    // lần restart kế tiếp video demo (có cả placeholder) sẽ tự mọc lại.
    final seeded = _db.select(
        "SELECT value FROM config WHERE key = 'seeded'");
    if (seeded.isNotEmpty && seeded.first['value'] == '1') return;
    final n = _db.select('SELECT COUNT(*) c FROM videos').first['c'] as int;
    if (n > 0) {
      // DB cũ đã có dữ liệu → coi như từng seed, chỉ ghi cờ.
      setConfig('seeded', '1');
      return;
    }
    for (final v in _seedVideos) {
      _db.execute(
        // is_official=1 NGAY khi seed: cột này chỉ được _migrate cập nhật ở
        // lần khởi động SAU, nên nếu không đặt ở đây thì lần chạy đầu tiên
        // video demo bị ẩn với mọi người (phải restart lần 2 mới hiện).
        'INSERT INTO videos (title, channel, level, color, youtube_id, duration_ms, is_official) VALUES (?,?,?,?,?,?,1)',
        [v.title, v.channel, v.level, v.color, v.youtubeId, v.durationMs],
      );
      final vid = _db.lastInsertRowId;
      var ord = 0;
      for (final s in v.sentences) {
        _db.execute(
          'INSERT INTO sentences (video_id, ord, start_ms, end_ms, text_jp, tokens_json, words_json, translations_json) VALUES (?,?,?,?,?,?,?,?)',
          [
            vid,
            ord++,
            s.startMs,
            s.endMs,
            s.textJp,
            jsonEncode(s.tokens),
            jsonEncode(s.words),
            jsonEncode({'vi': s.vi}),
          ],
        );
      }
    }
    setConfig('seeded', '1'); // không bao giờ tự seed lại nữa
  }

  // ---------------- Users / Auth ----------------

  Map<String, dynamic>? userByEmail(String email) {
    final r = _db.select('SELECT * FROM users WHERE email = ?', [email]);
    return r.isEmpty ? null : Map<String, dynamic>.from(r.first);
  }

  Map<String, dynamic>? userById(int id) {
    final r = _db.select('SELECT * FROM users WHERE id = ?', [id]);
    return r.isEmpty ? null : Map<String, dynamic>.from(r.first);
  }

  int createUser(String email, String passwordHash, String nativeLang,
      String level) {
    _db.execute(
      'INSERT INTO users (email, password, native_lang, level, created_at) VALUES (?,?,?,?,?)',
      [
        email,
        passwordHash,
        nativeLang,
        level,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    final id = _db.lastInsertRowId;
    _db.execute(
        'INSERT INTO progress (user_id, goal_words) VALUES (?, 10)', [id]);
    return id;
  }

  /// Cập nhật ngôn ngữ mẹ đẻ (app gọi khi user đổi ngôn ngữ trong Cài đặt).
  void setNativeLang(int userId, String lang) {
    _db.execute(
        'UPDATE users SET native_lang = ? WHERE id = ?', [lang, userId]);
  }

  // ---------------- Admin: users ----------------

  void setRole(int userId, String role) {
    _db.execute('UPDATE users SET role = ? WHERE id = ?', [role, userId]);
  }

  void setUserLevel(int userId, String level) {
    _db.execute('UPDATE users SET level = ? WHERE id = ?', [level, userId]);
  }

  void setUserDisabled(int userId, bool disabled) {
    _db.execute(
        'UPDATE users SET disabled = ? WHERE id = ?', [disabled ? 1 : 0, userId]);
  }

  /// Xoá tài khoản + TOÀN BỘ dữ liệu người dùng.
  ///
  /// FK ON DELETE CASCADE chỉ dọn được: progress, vocab, entitlements,
  /// purchases (và sentences/video_reports theo video). Các bảng KHÔNG có khoá
  /// ngoại tới users phải xoá TAY ở đây — thiếu là dữ liệu cá nhân (kể cả email
  /// trong feedback) ở lại vĩnh viễn, vi phạm cam kết "xoá toàn bộ dữ liệu".
  void deleteUser(int userId) {
    _db.execute('BEGIN');
    try {
      // Video user tự thêm → xoá (sentences/video_reports cascade theo video).
      _db.execute('DELETE FROM videos WHERE owner_user_id = ?', [userId]);
      // Các bảng không có FK tới users:
      for (final t in const [
        'watch_history',
        'ai_usage',
        'video_usage',
        'import_log',
      ]) {
        _db.execute('DELETE FROM $t WHERE user_id = ?', [userId]);
      }
      // Chặn/bị chặn 2 chiều.
      _db.execute(
          'DELETE FROM user_blocks WHERE user_id = ? OR blocked_id = ?',
          [userId, userId]);
      // Báo cáo do người này gửi (reporter_id không có FK).
      _db.execute('DELETE FROM video_reports WHERE reporter_id = ?', [userId]);
      // Feedback: xoá hẳn phản hồi + email đính kèm của người này.
      _db.execute('DELETE FROM feedback WHERE user_id = ?', [userId]);
      // Cuối cùng xoá user — CASCADE dọn progress/vocab/entitlements/purchases.
      _db.execute('DELETE FROM users WHERE id = ?', [userId]);
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Danh sách người dùng kèm tiến độ + số từ + khóa sở hữu (cho trang admin).
  List<Map<String, dynamic>> adminUsers({String? q, int limit = 200}) {
    final where = (q != null && q.isNotEmpty) ? "WHERE u.email LIKE ?" : '';
    final args = <Object?>[];
    if (q != null && q.isNotEmpty) args.add('%${q.toLowerCase()}%');
    args.add(limit);
    final rows = _db.select('''
      SELECT u.id, u.email, u.native_lang, u.level, u.provider, u.role,
             u.disabled, u.created_at,
             COALESCE(p.total_words, 0) AS total_words,
             COALESCE(p.streak, 0) AS streak,
             (SELECT COUNT(*) FROM vocab v WHERE v.user_id = u.id) AS vocab_count,
             (SELECT GROUP_CONCAT(course_key) FROM entitlements e WHERE e.user_id = u.id) AS courses
      FROM users u
      LEFT JOIN progress p ON p.user_id = u.id
      $where
      ORDER BY u.id DESC
      LIMIT ?
    ''', args);
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  // ---------------- Entitlements ----------------

  /// Quyền CÒN HIỆU LỰC (expires_at = 0 là trọn đời; >0 phải lớn hơn hiện tại).
  List<String> userEntitlements(int userId) {
    final r = _db.select(
        'SELECT course_key FROM entitlements '
        'WHERE user_id = ? AND (expires_at = 0 OR expires_at > ?)',
        [userId, DateTime.now().millisecondsSinceEpoch]);
    return r.map((e) => e['course_key'] as String).toList();
  }

  /// Cấp quyền. [expiresAt] 0 = trọn đời. Cấp lại thì CẬP NHẬT hạn (subscription
  /// gia hạn) + nguồn cấp — INSERT OR REPLACE giữ nguyên khóa chính (user, key).
  void grantEntitlement(int userId, String courseKey,
      {int expiresAt = 0, String source = 'admin'}) {
    _db.execute(
        'INSERT INTO entitlements (user_id, course_key, granted_at, expires_at, source) '
        'VALUES (?,?,?,?,?) '
        'ON CONFLICT(user_id, course_key) DO UPDATE SET '
        'expires_at = excluded.expires_at, source = excluded.source',
        [
          userId,
          courseKey,
          DateTime.now().millisecondsSinceEpoch,
          expiresAt,
          source
        ]);
  }

  void revokeEntitlement(int userId, String courseKey) {
    _db.execute(
        'DELETE FROM entitlements WHERE user_id = ? AND course_key = ?',
        [userId, courseKey]);
  }

  // ---------------- Google Play purchases ----------------

  Map<String, dynamic>? purchaseByToken(String token) {
    final r = _db.select(
        'SELECT * FROM purchases WHERE purchase_token = ?', [token]);
    return r.isEmpty ? null : Map<String, dynamic>.from(r.first);
  }

  void upsertPurchase({
    required String token,
    required int userId,
    required String productId,
    required String kind, // 'subs' | 'inapp'
    required String state, // 'active'|'pending'|'canceled'|'expired'|'revoked'
    String? orderId,
    int expiryMs = 0,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
        'INSERT INTO purchases (purchase_token, user_id, product_id, kind, state, order_id, expiry_ms, created_at, updated_at) '
        'VALUES (?,?,?,?,?,?,?,?,?) '
        'ON CONFLICT(purchase_token) DO UPDATE SET '
        'state = excluded.state, order_id = COALESCE(excluded.order_id, purchases.order_id), '
        'expiry_ms = excluded.expiry_ms, updated_at = excluded.updated_at',
        [token, userId, productId, kind, state, orderId, expiryMs, now, now]);
  }

  /// Các subscription ĐANG active nhưng đã quá hạn ghi nhận — cần re-verify
  /// với Google (gia hạn thành công thì cập nhật hạn mới, không thì hết quyền).
  List<Map<String, dynamic>> stalePurchasesOf(int userId, int nowMs) {
    final r = _db.select(
        "SELECT * FROM purchases WHERE user_id = ? AND kind = 'subs' "
        'AND state = ? AND expiry_ms > 0 AND expiry_ms < ?',
        [userId, 'active', nowMs]);
    return r.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  // ---------------- Quota video (xem + nhập) ----------------

  int videoUsedSec(int userId, String periodKey) {
    final r = _db.select(
        'SELECT used_sec FROM video_usage WHERE user_id = ? AND period_key = ?',
        [userId, periodKey]);
    return r.isEmpty ? 0 : (r.first['used_sec'] as int);
  }

  void addVideoUsage(int userId, String periodKey, int sec) {
    _db.execute(
        'INSERT INTO video_usage (user_id, period_key, used_sec) VALUES (?,?,?) '
        'ON CONFLICT(user_id, period_key) DO UPDATE SET '
        'used_sec = used_sec + excluded.used_sec',
        [userId, periodKey, sec]);
  }

  int importCount(int userId, String dayKey) {
    final r = _db.select(
        'SELECT count FROM import_log WHERE user_id = ? AND day_key = ?',
        [userId, dayKey]);
    return r.isEmpty ? 0 : (r.first['count'] as int);
  }

  void addImport(int userId, String dayKey) {
    _db.execute(
        'INSERT INTO import_log (user_id, day_key, count) VALUES (?,?,1) '
        'ON CONFLICT(user_id, day_key) DO UPDATE SET count = count + 1',
        [userId, dayKey]);
  }

  // ---------------- Premium / hạn mức AI ----------------

  bool isPremiumNow(int userId, int nowMs) {
    final u = userById(userId);
    if (u == null) return false;
    return ((u['premium_until'] as int?) ?? 0) > nowMs;
  }

  void setPremiumUntil(int userId, int untilMs) {
    _db.execute(
        'UPDATE users SET premium_until = ? WHERE id = ?', [untilMs, userId]);
  }

  /// Cấp trial (set hạn + đánh dấu đã dùng). Trả false nếu user đã dùng trial.
  bool grantTrial(int userId, int untilMs) {
    final u = userById(userId);
    if (u == null) return false;
    if (((u['trial_used'] as int?) ?? 0) == 1) return false;
    _db.execute('UPDATE users SET premium_until = ?, trial_used = 1 WHERE id = ?',
        [untilMs, userId]);
    return true;
  }

  int aiUsedSec(int userId, String periodKey) {
    final r = _db.select(
        'SELECT used_sec FROM ai_usage WHERE user_id = ? AND period_key = ?',
        [userId, periodKey]);
    return r.isEmpty ? 0 : (r.first['used_sec'] as int);
  }

  void addAiUsage(int userId, String periodKey, int sec) {
    _db.execute(
        'INSERT INTO ai_usage (user_id, period_key, used_sec) VALUES (?,?,?) '
        'ON CONFLICT(user_id, period_key) DO UPDATE SET '
        'used_sec = used_sec + excluded.used_sec',
        [userId, periodKey, sec]);
  }

  // ---------------- Admin: config ----------------

  Map<String, String> allConfig() {
    final r = _db.select('SELECT key, value FROM config');
    return {for (final row in r) row['key'] as String: row['value'] as String};
  }

  void setConfig(String key, String value) {
    _db.execute(
        'INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)', [key, value]);
  }

  // ---------------- Admin: stats ----------------

  Map<String, dynamic> adminStats() {
    int count(String sql, [List<Object?> a = const []]) =>
        _db.select(sql, a).first.values.first as int;
    return {
      'users': count('SELECT COUNT(*) FROM users'),
      'admins': count("SELECT COUNT(*) FROM users WHERE role = 'admin'"),
      'premiumUsers':
          count('SELECT COUNT(DISTINCT user_id) FROM entitlements'),
      'videos': count('SELECT COUNT(*) FROM videos'),
      'userVideos':
          count('SELECT COUNT(*) FROM videos WHERE owner_user_id IS NOT NULL'),
      'vocab': count('SELECT COUNT(*) FROM vocab'),
      'translationsCached': count('SELECT COUNT(*) FROM translation_cache'),
      'studyDaysActive':
          count("SELECT COUNT(*) FROM progress WHERE last_study_day != ''"),
      'feedback': count('SELECT COUNT(*) FROM feedback'),
    };
  }

  /// Đăng nhập bằng nhà cung cấp (Google/Apple/Facebook...). Tìm theo
  /// provider+providerId, rồi theo email, nếu chưa có thì tạo mới. Trả về user.
  /// [emailVerified] = nhà cung cấp đã xác minh email. CHỈ khi đó mới gộp
  /// vào tài khoản email/mật khẩu trùng email (chống chiếm tài khoản).
  Map<String, dynamic> upsertSocial({
    required String provider,
    required String providerId,
    String? email,
    bool emailVerified = false,
  }) {
    final byProvider = _db.select(
        'SELECT * FROM users WHERE provider = ? AND provider_id = ?',
        [provider, providerId]);
    if (byProvider.isNotEmpty) return Map<String, dynamic>.from(byProvider.first);

    // CHỈ tin email khi nhà cung cấp KHẲNG ĐỊNH đã xác minh. Không xác minh →
    // coi như không có email: vừa không gộp tài khoản, vừa KHÔNG ghi email đó
    // vào hồ sơ (nếu ghi, kẻ xấu chiếm được chỗ email của người khác).
    final trusted = emailVerified && email != null && email.isNotEmpty;

    if (trusted) {
      final existing = userByEmail(email);
      if (existing != null) {
        // Tài khoản đang bị khoá thì không cho gắn danh tính mới vào để mở lối.
        if ((existing['disabled'] as int? ?? 0) == 1) {
          return Map<String, dynamic>.from(existing);
        }
        _db.execute(
            'UPDATE users SET provider = ?, provider_id = ? WHERE id = ?',
            [provider, providerId, existing['id']]);
        return userById(existing['id'] as int)!;
      }
    }

    final finalEmail =
        trusted ? email : '${provider}_$providerId@xsgo.social';
    _db.execute(
      'INSERT INTO users (email, password, native_lang, level, provider, provider_id, created_at) VALUES (?,?,?,?,?,?,?)',
      [
        finalEmail,
        'social:$provider', // placeholder — không đăng nhập được bằng mật khẩu
        'vi',
        'N5',
        provider,
        providerId,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    final id = _db.lastInsertRowId;
    _db.execute(
        'INSERT INTO progress (user_id, goal_words) VALUES (?, 10)', [id]);
    return userById(id)!;
  }

  // ---------------- Videos ----------------

  /// Video hiển thị cho 1 người dùng ở Khám phá: video CHÍNH THỨC (mọi người
  /// thấy) + video RIÊNG của chính họ. Ẩn (hidden) bị loại. userId null (khách
  /// chưa đăng nhập) → chỉ video chính thức.
  List<Map<String, dynamic>> videosFor(int? userId) {
    final r = _db.select(
        'SELECT id,title,channel,level,color,youtube_id,duration_ms,'
        'is_official,owner_user_id FROM videos '
        'WHERE hidden = 0 AND (is_official = 1 OR owner_user_id = ?) '
        'ORDER BY is_official DESC, id',
        [userId ?? -1]);
    return r.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  /// Video CỘNG ĐỒNG cho mục Khám phá: video do học viên thêm (không chính thức),
  /// chưa bị ẩn, chủ video không nằm trong danh sách mình đã chặn.
  /// Video cộng đồng LỌC THEO NGÔN NGỮ: chỉ hiện video do học viên CÙNG
  /// ngôn ngữ mẹ đẻ [lang] đăng (video của chính mình luôn thấy).
  List<Map<String, dynamic>> communityVideos(int? userId, {String lang = 'vi'}) {
    final r = _db.select(
        'SELECT v.id,v.title,v.channel,v.level,v.color,v.youtube_id,'
        'v.duration_ms,v.is_official,v.owner_user_id,v.yt_title,v.yt_channel '
        'FROM videos v '
        'JOIN users u ON u.id = v.owner_user_id '
        'WHERE v.hidden = 0 AND v.is_official = 0 '
        'AND (u.native_lang = ? OR v.owner_user_id = ?) '
        'AND v.owner_user_id NOT IN '
        '(SELECT blocked_id FROM user_blocks WHERE user_id = ?) '
        'ORDER BY v.id DESC',
        [lang, userId ?? -1, userId ?? -1]);
    return r.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  /// Ghi báo cáo 1 video. Khi số người báo (khác nhau) >= [threshold] thì TỰ ẨN
  /// video khỏi Khám phá (kiểm duyệt tự động). Trả true nếu vừa bị ẩn.
  /// Ghi 1 báo cáo. [countsToward] = false (khách chưa đăng nhập) vẫn LƯU báo
  /// cáo cho admin xem nhưng KHÔNG kích hoạt tự ẩn (chống 3 khách nặc danh ẩn
  /// sạch nội dung). Chỉ báo cáo của tài khoản đã đăng nhập mới tính ngưỡng.
  bool reportVideo(int videoId, int? reporterId, String reason,
      {int threshold = 3, bool countsToward = true}) {
    _db.execute(
        'INSERT OR IGNORE INTO video_reports '
        '(video_id, reporter_id, reason, created_at) VALUES (?,?,?,?)',
        [videoId, reporterId, reason, DateTime.now().millisecondsSinceEpoch]);
    if (!countsToward) return false;
    final c = _db.select(
        'SELECT COUNT(DISTINCT reporter_id) n '
        'FROM video_reports WHERE video_id = ? AND reporter_id IS NOT NULL',
        [videoId]).first['n'] as int;
    if (c >= threshold) {
      // Chỉ TỰ ẨN video cộng đồng — video chính thức bị báo cáo thì chờ admin
      // duyệt (chống 3 tài khoản rác ẩn sạch nội dung của app).
      _db.execute(
          'UPDATE videos SET hidden = 1 WHERE id = ? AND is_official = 0',
          [videoId]);
      return _db.updatedRows > 0;
    }
    return false;
  }

  /// Video cộng đồng đang bị báo cáo (cho admin duyệt/gỡ).
  List<Map<String, dynamic>> reportedVideos() {
    final r = _db.select('''
      SELECT v.id, v.title, v.channel, v.level, v.hidden, v.owner_user_id,
             COUNT(rp.id) AS reports, MAX(rp.created_at) AS last_report
      FROM video_reports rp JOIN videos v ON v.id = rp.video_id
      GROUP BY rp.video_id
      ORDER BY reports DESC, last_report DESC
    ''', const []);
    return r.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  void blockUser(int userId, int blockedId) {
    _db.execute(
        'INSERT OR IGNORE INTO user_blocks (user_id, blocked_id, created_at) '
        'VALUES (?,?,?)',
        [userId, blockedId, DateTime.now().millisecondsSinceEpoch]);
  }

  void unblockUser(int userId, int blockedId) {
    _db.execute('DELETE FROM user_blocks WHERE user_id = ? AND blocked_id = ?',
        [userId, blockedId]);
  }

  // ---------------- Lịch sử xem ("Tiếp tục xem") ----------------

  /// Lịch sử xem của 1 user, mới nhất trước (tối đa 50).
  List<Map<String, dynamic>> watchHistory(int userId) {
    final r = _db.select(
        'SELECT vkey, video_id, youtube_id, title, channel, level, '
        'pos_ms, dur_ms, done, last_seen FROM watch_history '
        'WHERE user_id = ? ORDER BY last_seen DESC LIMIT 50',
        [userId]);
    return r.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  /// Ghi/hợp nhất 1 mục lịch sử. Chỉ ghi đè khi last_seen mới >= bản đang có
  /// (tránh máy cũ đẩy dữ liệu lỗi thời lên).
  void watchUpsert(int userId, Map<String, dynamic> it) {
    _db.execute(
      'INSERT INTO watch_history '
      '(user_id, vkey, video_id, youtube_id, title, channel, level, '
      'pos_ms, dur_ms, done, last_seen) VALUES (?,?,?,?,?,?,?,?,?,?,?) '
      'ON CONFLICT(user_id, vkey) DO UPDATE SET '
      'video_id=excluded.video_id, youtube_id=excluded.youtube_id, '
      'title=excluded.title, channel=excluded.channel, level=excluded.level, '
      'pos_ms=excluded.pos_ms, dur_ms=excluded.dur_ms, done=excluded.done, '
      'last_seen=excluded.last_seen '
      'WHERE excluded.last_seen >= watch_history.last_seen',
      [
        userId,
        it['key'],
        it['videoId'],
        it['youtubeId'],
        it['title'] ?? '',
        it['channel'] ?? '',
        it['level'] ?? '',
        it['posMs'] ?? 0,
        it['durMs'] ?? 0,
        (it['done'] == true) ? 1 : 0,
        it['lastSeen'] ?? 0,
      ],
    );
  }

  /// Video CHÍNH THỨC cho trang quản trị. Video user tự thêm là RIÊNG TƯ (chỉ
  /// chủ thấy) → không cần admin kiểm duyệt, nên không liệt kê ở đây.
  List<Map<String, dynamic>> adminVideos({String? q}) {
    final hasQ = q != null && q.isNotEmpty;
    final where = hasQ ? 'AND v.title LIKE ?' : '';
    final args = <Object?>[];
    if (hasQ) args.add('%$q%');
    final r = _db.select('''
      SELECT v.id, v.title, v.channel, v.level, v.color, v.youtube_id,
             v.duration_ms, v.is_official, v.hidden
      FROM videos v
      WHERE v.is_official = 1 $where
      ORDER BY v.id DESC
    ''', args);
    return r.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Map<String, dynamic>? video(int id) {
    final r = _db.select('SELECT * FROM videos WHERE id = ?', [id]);
    return r.isEmpty ? null : Map<String, dynamic>.from(r.first);
  }

  List<Map<String, dynamic>> sentences(int videoId) {
    final r = _db.select(
        'SELECT * FROM sentences WHERE video_id = ? ORDER BY ord', [videoId]);
    return r.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  // Điều kiện SQL: bản dịch [lang] coi là CHƯA CÓ khi thiếu key, rỗng, hoặc là
  // placeholder lỗi dạng "[VI] …" (AI fail/mock cũ lỡ cache) → tự chữa cache hỏng.
  static const _pendingCond = '''
    COALESCE(json_extract(translations_json, '\$."' || ?1 || '"'), '') = ''
    OR json_extract(translations_json, '\$."' || ?1 || '"')
       LIKE '[' || UPPER(?1) || ']%'
  ''';

  /// Các câu CHƯA có bản dịch [lang] của video — chỉ lấy cột cần, lọc + phân
  /// trang ngay trong SQL (không quét cả bảng mỗi vòng dịch nền).
  List<Map<String, dynamic>> pendingSentences(
      int videoId, String lang, int limit) {
    final r = _db.select(
        'SELECT id, text_jp FROM sentences '
        'WHERE video_id = ?2 AND ($_pendingCond) ORDER BY ord LIMIT ?3',
        [lang, videoId, limit]);
    return r.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  /// Số câu còn thiếu bản dịch [lang] của video.
  int pendingTranslationCount(int videoId, String lang) {
    final r = _db.select(
        'SELECT COUNT(*) c FROM sentences '
        'WHERE video_id = ?2 AND ($_pendingCond)',
        [lang, videoId]);
    return r.first['c'] as int;
  }

  /// Thay TOÀN BỘ phụ đề của 1 video bằng danh sách câu mới (admin soạn phụ đề).
  /// Mỗi phần tử: {startMs, endMs, textJp, tokens (List), words (List), vi}.
  void replaceVideoSentences(int videoId, List<Map<String, dynamic>> sents) {
    _db.execute('DELETE FROM sentences WHERE video_id = ?', [videoId]);
    var ord = 0;
    for (final s in sents) {
      _db.execute(
        'INSERT INTO sentences (video_id, ord, start_ms, end_ms, text_jp, tokens_json, words_json, translations_json) VALUES (?,?,?,?,?,?,?,?)',
        [
          videoId,
          ord++,
          s['startMs'],
          s['endMs'],
          s['textJp'],
          jsonEncode(s['tokens'] ?? const []),
          jsonEncode(s['words'] ?? const []),
          jsonEncode({'vi': (s['vi'] as String?) ?? ''}),
        ],
      );
    }
  }

  /// Lưu bản dịch đã sinh cho một câu (cache theo ngôn ngữ).
  void cacheTranslation(int sentenceId, String lang, String text) {
    final r = _db
        .select('SELECT translations_json FROM sentences WHERE id = ?', [sentenceId]);
    if (r.isEmpty) return;
    final map = Map<String, dynamic>.from(
        jsonDecode(r.first['translations_json'] as String) as Map);
    map[lang] = text;
    _db.execute('UPDATE sentences SET translations_json = ? WHERE id = ?',
        [jsonEncode(map), sentenceId]);
  }

  // ---------------- Progress ----------------

  Map<String, dynamic> progress(int userId) {
    final r =
        _db.select('SELECT * FROM progress WHERE user_id = ?', [userId]);
    if (r.isEmpty) {
      _db.execute('INSERT INTO progress (user_id) VALUES (?)', [userId]);
      return progress(userId);
    }
    return Map<String, dynamic>.from(r.first);
  }

  void saveProgress(int userId, Map<String, dynamic> p) {
    _db.execute(
      'UPDATE progress SET goal_words=?, today_words=?, total_words=?, streak=?, last_study_day=? WHERE user_id=?',
      [
        p['goal_words'],
        p['today_words'],
        p['total_words'],
        p['streak'],
        p['last_study_day'],
        userId,
      ],
    );
  }

  // ---------------- Vocabulary ----------------

  List<Map<String, dynamic>> vocabList(int userId) {
    final r = _db.select(
        'SELECT id, term, reading, meaning, jlpt FROM vocab WHERE user_id = ? ORDER BY id DESC',
        [userId]);
    return r.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  int vocabCount(int userId) =>
      _db.select('SELECT COUNT(*) c FROM vocab WHERE user_id = ?', [userId])
          .first['c'] as int;

  /// Thêm từ; nếu đã có (cùng term) thì trả về bản cũ, không tạo trùng.
  Map<String, dynamic> addVocab(int userId, String term, String reading,
      String meaning, String jlpt) {
    final dup = _db.select(
        'SELECT id, term, reading, meaning, jlpt FROM vocab WHERE user_id = ? AND term = ?',
        [userId, term]);
    if (dup.isNotEmpty) return Map<String, dynamic>.from(dup.first);
    _db.execute(
      'INSERT INTO vocab (user_id, term, reading, meaning, jlpt, created_at) VALUES (?,?,?,?,?,?)',
      [userId, term, reading, meaning, jlpt, DateTime.now().millisecondsSinceEpoch],
    );
    final id = _db.lastInsertRowId;
    return {
      'id': id,
      'term': term,
      'reading': reading,
      'meaning': meaning,
      'jlpt': jlpt
    };
  }

  void deleteVocab(int userId, int id) {
    _db.execute('DELETE FROM vocab WHERE user_id = ? AND id = ?', [userId, id]);
  }

  /// Đã có video OFFICIAL với youtubeId này chưa (chặn thêm trùng hàng loạt).
  bool officialVideoExists(String youtubeId) {
    final r = _db.select(
        'SELECT 1 FROM videos WHERE youtube_id = ? AND is_official = 1 LIMIT 1',
        [youtubeId]);
    return r.isNotEmpty;
  }

  /// Câu phụ đề GIẢ chèn kèm khi tạo video (giữ màn Study không rỗng cho tới
  /// khi có phụ đề thật). Nhận diện video "chưa có phụ đề" đều dựa vào hằng này.
  static const kSubPlaceholder = '字幕はまだありません';

  /// Đưa video CHƯA có phụ đề thật (chỉ có câu placeholder) về duration 0.
  ///
  /// Trước 11/8/2026 câu placeholder có end_ms=60000 và video duration_ms=60000
  /// → app lấy mốc cuối của phụ đề làm độ dài bài, nên video 20 phút tự bắn
  /// màn "đã học xong bài" sau đúng 1 phút. Đưa cả hai về 0 để app biết
  /// "chưa có phụ đề" thay vì "bài dài 1 phút". Tách thành hàm để test được.
  void fixPlaceholderDurations() {
    _db.execute(
        'UPDATE sentences SET end_ms = 0 WHERE text_jp = ? AND end_ms <> 0',
        [kSubPlaceholder]);
    _db.execute(
        'UPDATE videos SET duration_ms = 0 WHERE duration_ms > 0 AND NOT EXISTS '
        '(SELECT 1 FROM sentences s WHERE s.video_id = videos.id AND s.text_jp <> ?)',
        [kSubPlaceholder]);
  }

  /// Video đã có phụ đề THẬT chưa (có ít nhất 1 câu không phải placeholder).
  bool videoHasRealSubs(int videoId) {
    final r = _db.select(
        'SELECT 1 FROM sentences WHERE video_id = ? AND text_jp <> ? LIMIT 1',
        [videoId, kSubPlaceholder]);
    return r.isNotEmpty;
  }

  /// Tạo video người dùng thêm (YouTube). Kèm 1 câu placeholder để màn Study
  /// hoạt động; phụ đề AI (ASR) là tính năng sau.
  ///
  /// ⚠️ duration_ms và end_ms của câu placeholder đều = 0 CÓ CHỦ Ý: app tính
  /// "đã học xong bài" theo mốc cuối của phụ đề, nên mọi giá trị > 0 (trước đây
  /// là 60000) sẽ khiến video dài 20 phút tự báo hoàn thành sau 1 phút.
  int createVideo({
    required String title,
    required String channel,
    required String level,
    required String youtubeId,
    int? ownerUserId,
    bool official = false,
    String? ytTitle,
    String? ytChannel,
  }) {
    _db.execute(
      'INSERT INTO videos (title, channel, level, color, youtube_id, duration_ms, owner_user_id, is_official, yt_title, yt_channel) VALUES (?,?,?,?,?,?,?,?,?,?)',
      [title, channel, level, 0xFF0EA5E9, youtubeId, 0, ownerUserId, official ? 1 : 0, ytTitle, ytChannel],
    );
    final vid = _db.lastInsertRowId;
    _db.execute(
      'INSERT INTO sentences (video_id, ord, start_ms, end_ms, text_jp, tokens_json, words_json, translations_json) VALUES (?,?,?,?,?,?,?,?)',
      [
        vid,
        0,
        0,
        0, // end_ms = 0 → app KHÔNG coi đây là video dài 60 giây
        kSubPlaceholder,
        jsonEncode([
          {'surface': kSubPlaceholder, 'tappable': false}
        ]),
        '[]',
        // KHÔNG hứa tính năng tương lai ở đây: câu này hiện trong app nên phải
        // nói đúng việc người học làm được NGAY (App Store 2.1 loại nội dung
        // kiểu "sẽ có ở bản sau").
        jsonEncode({
          'vi': 'Video này chưa có phụ đề trong XS GO. Bấm nút CC trên trình '
              'phát để dùng phụ đề của YouTube.'
        }),
      ],
    );
    return vid;
  }

  /// Xoá video CỦA user (chỉ khi owner_user_id khớp). Trả số dòng đã xoá:
  /// 0 = không phải video của user (hoặc video seed dùng chung) → không xoá.
  int deleteVideo(int id, int userId) {
    _db.execute(
        'DELETE FROM videos WHERE id = ? AND owner_user_id = ?', [id, userId]);
    return _db.updatedRows;
  }

  // ---------------- Admin: videos (kiểm duyệt mọi video) ----------------

  /// Admin xoá BẤT KỲ video nào (kể cả seed/của user khác).
  void adminDeleteVideo(int id) {
    _db.execute('DELETE FROM videos WHERE id = ?', [id]);
  }

  /// Admin sửa video: đổi tiêu đề/kênh/level, gắn/bỏ cờ official, ẩn/hiện.
  void adminUpdateVideo(int id,
      {String? title,
      String? channel,
      String? level,
      bool? official,
      bool? hidden}) {
    final sets = <String>[];
    final args = <Object?>[];
    if (title != null) {
      sets.add('title = ?');
      args.add(title);
    }
    if (channel != null) {
      sets.add('channel = ?');
      args.add(channel);
    }
    if (level != null) {
      sets.add('level = ?');
      args.add(level);
    }
    if (official != null) {
      sets.add('is_official = ?');
      args.add(official ? 1 : 0);
    }
    if (hidden != null) {
      sets.add('hidden = ?');
      args.add(hidden ? 1 : 0);
    }
    if (sets.isEmpty) return;
    args.add(id);
    _db.execute('UPDATE videos SET ${sets.join(', ')} WHERE id = ?', args);
  }

  // ---------------- Playlists (danh sách phát) ----------------

  /// Danh sách phát kèm video (chỉ video chính thức & không ẩn) — cho Khám phá.
  List<Map<String, dynamic>> playlists() {
    final pls = _db.select('SELECT * FROM playlists ORDER BY position, id');
    return pls.map((p) {
      final vids = _db.select('''
        SELECT v.id, v.title, v.channel, v.level, v.color, v.youtube_id,
               v.duration_ms
        FROM playlist_videos pv
        JOIN videos v ON v.id = pv.video_id
        WHERE pv.playlist_id = ? AND v.hidden = 0 AND v.is_official = 1
        ORDER BY pv.position, pv.video_id
      ''', [p['id']]);
      return {
        ...Map<String, dynamic>.from(p),
        'videos': vids.map((r) => Map<String, dynamic>.from(r)).toList(),
      };
    }).toList();
  }

  int createPlaylist(
      {required String title,
      String description = '',
      String level = '',
      int color = 0xFF0EA5E9,
      int position = 0,
      String section = 'home'}) {
    _db.execute(
      'INSERT INTO playlists (title, description, level, color, position, section, created_at) VALUES (?,?,?,?,?,?,?)',
      [title, description, level, color, position, section,
        DateTime.now().millisecondsSinceEpoch],
    );
    return _db.lastInsertRowId;
  }

  /// Xoá nhiều video một lần (admin dọn nhanh — kể cả video seed/official).
  /// Sentences + playlist_videos tự xoá theo (ON DELETE CASCADE).
  /// Gói trong MỘT transaction: nhanh hơn hẳn (1 fsync) và không xoá dở dang.
  int adminDeleteVideos(List<int> ids) {
    var n = 0;
    _db.execute('BEGIN');
    try {
      for (final id in ids) {
        _db.execute('DELETE FROM videos WHERE id = ?', [id]);
        n += _db.updatedRows;
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return n;
  }

  void updatePlaylist(int id,
      {String? title,
      String? description,
      String? level,
      int? position,
      String? section}) {
    final sets = <String>[];
    final args = <Object?>[];
    if (title != null) {
      sets.add('title = ?');
      args.add(title);
    }
    if (description != null) {
      sets.add('description = ?');
      args.add(description);
    }
    if (level != null) {
      sets.add('level = ?');
      args.add(level);
    }
    if (position != null) {
      sets.add('position = ?');
      args.add(position);
    }
    if (section != null) {
      sets.add('section = ?');
      args.add(section);
    }
    if (sets.isEmpty) return;
    args.add(id);
    _db.execute('UPDATE playlists SET ${sets.join(', ')} WHERE id = ?', args);
  }

  void deletePlaylist(int id) {
    _db.execute('DELETE FROM playlists WHERE id = ?', [id]);
  }

  bool playlistExists(int id) =>
      _db.select('SELECT 1 FROM playlists WHERE id = ?', [id]).isNotEmpty;

  void addVideoToPlaylist(int playlistId, int videoId, {int position = 0}) {
    _db.execute(
      'INSERT OR REPLACE INTO playlist_videos (playlist_id, video_id, position) VALUES (?,?,?)',
      [playlistId, videoId, position],
    );
  }

  void removeVideoFromPlaylist(int playlistId, int videoId) {
    _db.execute(
        'DELETE FROM playlist_videos WHERE playlist_id = ? AND video_id = ?',
        [playlistId, videoId]);
  }

  // ---------------- Phản hồi người dùng ----------------

  int addFeedback(
      {int? userId,
      String email = '',
      String category = '',
      required String message}) {
    _db.execute(
      'INSERT INTO feedback (user_id, email, category, message, created_at) VALUES (?,?,?,?,?)',
      [userId, email, category, message, DateTime.now().millisecondsSinceEpoch],
    );
    return _db.lastInsertRowId;
  }

  List<Map<String, dynamic>> feedbackList({int limit = 200}) {
    final r = _db.select('''
      SELECT f.id, f.email, f.category, f.message, f.created_at, u.email AS user_email
      FROM feedback f
      LEFT JOIN users u ON u.id = f.user_id
      ORDER BY f.id DESC
      LIMIT ?
    ''', [limit]);
    return r.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  void deleteFeedback(int id) {
    _db.execute('DELETE FROM feedback WHERE id = ?', [id]);
  }

  // ---------------- Translation cache ----------------

  String? cachedTranslation(String hash, String lang) {
    final r = _db.select(
        'SELECT translated FROM translation_cache WHERE hash = ? AND lang = ?',
        [hash, lang]);
    return r.isEmpty ? null : r.first['translated'] as String;
  }

  void putTranslation(String hash, String lang, String translated) {
    _db.execute(
        'INSERT OR REPLACE INTO translation_cache (hash, lang, translated) VALUES (?,?,?)',
        [hash, lang, translated]);
  }

  void dispose() => _db.dispose();
}

// ---------------- Dữ liệu seed (khớp app Flutter) ----------------

class _SeedSentence {
  final int startMs, endMs;
  final String textJp;
  final List<Map<String, dynamic>> tokens;
  final List<Map<String, dynamic>> words;
  final String vi;
  const _SeedSentence(
      this.startMs, this.endMs, this.textJp, this.tokens, this.words, this.vi);
}

class _SeedVideo {
  final String title, channel, level;
  final int color, durationMs;
  final String? youtubeId;
  final List<_SeedSentence> sentences;
  const _SeedVideo(this.title, this.channel, this.level, this.color,
      this.durationMs, this.youtubeId, this.sentences);
}

const _seedVideos = <_SeedVideo>[
  _SeedVideo(
    '毎日の挨拶 — Chào hỏi hằng ngày',
    'XS GO · Bite Size Japanese',
    'N5',
    0xFF2563EB,
    17000,
    null,
    [
      _SeedSentence(0, 3000, 'お早うございます。', [
        {'surface': 'お早う', 'reading': 'おはよう', 'tappable': true},
        {'surface': 'ございます', 'tappable': false},
        {'surface': '。', 'tappable': false},
      ], [
        {'term': 'お早う', 'reading': 'おはよう', 'meaning': 'chào buổi sáng (thân mật)', 'jlpt': 'N5'},
        {'term': 'ございます', 'reading': 'ございます', 'meaning': 'kính ngữ, thể lịch sự', 'jlpt': 'N5'},
      ], 'Chào buổi sáng ạ.'),
      _SeedSentence(3000, 7000, '初めまして、田中です。', [
        {'surface': '初めまして', 'reading': 'はじめまして', 'tappable': true},
        {'surface': '、', 'tappable': false},
        {'surface': '田中', 'reading': 'たなか', 'tappable': true},
        {'surface': 'です', 'tappable': false},
        {'surface': '。', 'tappable': false},
      ], [
        {'term': '初めまして', 'reading': 'はじめまして', 'meaning': 'rất vui được gặp (lần đầu)', 'jlpt': 'N5'},
        {'term': '田中', 'reading': 'たなか', 'meaning': 'Tanaka (tên người)', 'jlpt': 'N5'},
        {'term': 'です', 'reading': 'です', 'meaning': 'là (thể lịch sự)', 'jlpt': 'N5'},
      ], 'Rất vui được gặp bạn, tôi là Tanaka.'),
      _SeedSentence(7000, 12000, '日本語を勉強しています。', [
        {'surface': '日本語', 'reading': 'にほんご', 'tappable': true},
        {'surface': 'を', 'tappable': false},
        {'surface': '勉強', 'reading': 'べんきょう', 'tappable': true},
        {'surface': 'して', 'tappable': false},
        {'surface': 'います', 'tappable': false},
        {'surface': '。', 'tappable': false},
      ], [
        {'term': '日本語', 'reading': 'にほんご', 'meaning': 'tiếng Nhật', 'jlpt': 'N5'},
        {'term': '勉強', 'reading': 'べんきょう', 'meaning': 'học tập, học hành', 'jlpt': 'N5'},
        {'term': 'しています', 'reading': 'しています', 'meaning': 'đang làm (thể tiếp diễn)', 'jlpt': 'N5'},
      ], 'Tôi đang học tiếng Nhật.'),
      _SeedSentence(12000, 17000, 'よろしくお願いします。', [
        {'surface': 'よろしく', 'tappable': true},
        {'surface': 'お願い', 'reading': 'おねがい', 'tappable': true},
        {'surface': 'します', 'tappable': false},
        {'surface': '。', 'tappable': false},
      ], [
        {'term': 'よろしく', 'reading': 'よろしく', 'meaning': 'mong được giúp đỡ / chiếu cố', 'jlpt': 'N5'},
        {'term': 'お願いします', 'reading': 'おねがいします', 'meaning': 'xin nhờ, làm ơn', 'jlpt': 'N5'},
      ], 'Rất mong được giúp đỡ.'),
    ],
  ),
  _SeedVideo(
    'ビジネス日本語 — Chào hỏi công sở',
    'XS GO · Business Talk',
    'N3',
    0xFF0EA5E9,
    9000,
    null,
    [
      _SeedSentence(0, 4000, 'お世話になっております。', [
        {'surface': 'お世話', 'reading': 'おせわ', 'tappable': true},
        {'surface': 'になっております', 'tappable': false},
        {'surface': '。', 'tappable': false},
      ], [
        {'term': 'お世話', 'reading': 'おせわ', 'meaning': 'sự chăm sóc, giúp đỡ', 'jlpt': 'N3'},
      ], 'Cảm ơn anh/chị đã luôn giúp đỡ.'),
      _SeedSentence(4000, 9000, '本日はよろしくお願いいたします。', [
        {'surface': '本日', 'reading': 'ほんじつ', 'tappable': true},
        {'surface': 'は', 'tappable': false},
        {'surface': 'よろしく', 'tappable': true},
        {'surface': 'お願いいたします', 'tappable': false},
        {'surface': '。', 'tappable': false},
      ], [
        {'term': '本日', 'reading': 'ほんじつ', 'meaning': 'hôm nay (trang trọng)', 'jlpt': 'N3'},
      ], 'Hôm nay rất mong được hợp tác.'),
    ],
  ),
  // Video có YouTube thật để test player. ⚠️ youtubeId là PLACEHOLDER (video
  // embed được để chứng minh tích hợp) — sếp thay bằng video học tiếng Nhật thật.
  _SeedVideo(
    'Tích hợp YouTube (demo) — thay video thật sau',
    'XS GO · YouTube player',
    'N5',
    0xFF06B6D4,
    17000,
    'dQw4w9WgXcQ',
    [
      _SeedSentence(0, 3000, 'お早うございます。', [
        {'surface': 'お早う', 'reading': 'おはよう', 'tappable': true},
        {'surface': 'ございます', 'tappable': false},
        {'surface': '。', 'tappable': false},
      ], [
        {'term': 'お早う', 'reading': 'おはよう', 'meaning': 'chào buổi sáng', 'jlpt': 'N5'},
      ], 'Chào buổi sáng ạ.'),
      _SeedSentence(3000, 8000, '日本語を勉強しています。', [
        {'surface': '日本語', 'reading': 'にほんご', 'tappable': true},
        {'surface': 'を', 'tappable': false},
        {'surface': '勉強', 'reading': 'べんきょう', 'tappable': true},
        {'surface': 'しています', 'tappable': false},
        {'surface': '。', 'tappable': false},
      ], [
        {'term': '日本語', 'reading': 'にほんご', 'meaning': 'tiếng Nhật', 'jlpt': 'N5'},
        {'term': '勉強', 'reading': 'べんきょう', 'meaning': 'học tập', 'jlpt': 'N5'},
      ], 'Tôi đang học tiếng Nhật.'),
    ],
  ),
];
