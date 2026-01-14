(defpackage twitter-like-test.request
  (:use :cl :rove)
  (:import-from :twitter-like.util.request
                ;; エクスポート済み関数
                :parse-cookie-string
                :clamp-pagination-count
                ;; エクスポート済み定数
                :+max-bigint+
                :+max-offset+))
  ;; 注: flexi-streams は twitter-like 本体の依存に含まれているため追加不要
  ;; (twitter-like.asd の :depends-on に :flexi-streams が含まれている)
  ;; 既存テスト（test-session.lisp等）との一貫性のため、
  ;; :import-from ではなく直接パッケージプレフィックス (flexi-streams:...) を使用する

(in-package :twitter-like-test.request)

;;; ============================================================
;;; 環境ガードについて
;;; ============================================================

;;; このテストファイルは純粋関数のテストのため、以下の環境ガードは不要:
;;; - APP_ENV チェック（Redis/DB接続を使用しないため）
;;; - Redis ホスト/ポート ホワイトリスト（Redis接続を使用しないため）
;;; - PostgreSQL 接続確認（DB接続を使用しないため）
;;;
;;; 参考: test-session.lisp では Redis を使用するため、
;;; 多層セキュリティガード（APP_ENV, Redis whitelist等）を実装している。
;;; 詳細は test/test-session.lisp L30-74 を参照。

;;; ============================================================
;;; ヘルパー関数
;;; ============================================================

;;; 注: test-session.lisp では *config* ハッシュテーブルを直接差し替えるパターンを使用。
;;; 将来的にテスト間で設定差し替えのユーティリティを共通化する場合は、
;;; test/util.lisp 等に統合を検討する。

(defun with-env-var (name value thunk)
  "環境変数を一時的に設定してthunkを実行、完了後に復元
   value が NIL の場合は環境変数を削除"
  (let ((original (uiop:getenv name)))
    (unwind-protect
        (progn
          (if value
              (sb-posix:setenv name value 1)
              (sb-posix:unsetenv name))
          (funcall thunk))
      ;; 必ず復元
      (if original
          (sb-posix:setenv name original 1)
          (sb-posix:unsetenv name)))))

;;; setup/teardown 不要（純粋関数のテスト）

;;; ============================================================
;;; 定数テスト
;;; ============================================================

(deftest test-constants
  (testing "+max-body-size+ is 1MB (DoS protection)"
    (ok (= twitter-like.util.request::+max-body-size+ (* 1 1024 1024))
        "Should be 1MB (1048576 bytes)"))

  (testing "+max-bigint+ is PostgreSQL bigint maximum"
    (ok (= +max-bigint+ 9223372036854775807)
        "Should be 2^63 - 1"))

  (testing "+max-offset+ is 10000 (performance protection)"
    (ok (= +max-offset+ 10000)
        "Should be 10000")))

;;; ============================================================
;;; parse-cookie-string テスト
;;; ============================================================

(deftest test-parse-cookie-string
  ;; 正常系
  (testing "parses simple session_id cookie"
    (ok (string= (parse-cookie-string "session_id=abc123") "abc123")
        "Should extract session_id value"))

  (testing "parses session_id from multiple cookies"
    (ok (string= (parse-cookie-string "other=value; session_id=abc123; another=test")
                 "abc123")
        "Should find session_id among multiple cookies"))

  (testing "handles no space after semicolon (RFC 6265 compatible)"
    (ok (string= (parse-cookie-string "other=value;session_id=abc123")
                 "abc123")
        "Should parse without space after semicolon"))

  (testing "handles leading/trailing whitespace in pairs"
    (ok (string= (parse-cookie-string "  session_id=abc123  ")
                 "abc123")
        "Should trim whitespace from cookie pairs"))

  (testing "returns empty string for session_id with no value"
    ;; session_id= の場合、= より後は空文字列
    (ok (string= (parse-cookie-string "session_id=") "")
        "Should return empty string for empty value"))

  (testing "handles value containing equals sign"
    ;; session_id=abc=def の場合、値は abc=def
    (ok (string= (parse-cookie-string "session_id=abc=def") "abc=def")
        "Should include equals sign in value"))

  ;; 異常系
  (testing "returns NIL for missing session_id"
    (ok (null (parse-cookie-string "other=value; another=test"))
        "Should return NIL when session_id is not present"))

  (testing "returns NIL for empty string"
    (ok (null (parse-cookie-string ""))
        "Should return NIL for empty string"))

  (testing "returns NIL for NIL input"
    (ok (null (parse-cookie-string nil))
        "Should return NIL for NIL input"))

  ;; セキュリティテスト
  (testing "handles malformed cookie string safely"
    ;; session_id=abc で即座に return するため、以降の不正な部分は無視される
    (ok (string= (parse-cookie-string "session_id=abc;=;broken;;;") "abc")
        "Should extract value and ignore malformed parts"))

  ;; RFC 6265準拠: URL-encoded値の扱い
  (testing "preserves URL-encoded session_id value"
    ;; RFC 6265: Cookie値はURL-encodeされる場合がある
    ;; parse-cookie-stringはデコードせず、そのまま返す（デコードは呼び出し側の責務）
    (ok (string= (parse-cookie-string "session_id=abc%3D123") "abc%3D123")
        "Should preserve URL-encoded value as-is (decoding is caller's responsibility)")))

;;; ============================================================
;;; parse-x-forwarded-for テスト
;;; ============================================================

(deftest test-parse-x-forwarded-for
  ;; 注意: 未エクスポート関数のため :: でアクセス
  ;; let で関数参照を束縛することで、各テストケースでの記述を簡潔にする
  (let ((parse-xff #'twitter-like.util.request::parse-x-forwarded-for))

    ;; 正常系
    (testing "extracts first IP from single IP"
      (ok (string= (funcall parse-xff "192.168.1.1") "192.168.1.1")
          "Should return the single IP"))

    (testing "extracts first IP from multiple IPs"
      (ok (string= (funcall parse-xff "203.0.113.195, 70.41.3.18, 150.172.238.178")
                   "203.0.113.195")
          "Should return first IP (client IP)"))

    (testing "handles IPv6 address"
      (ok (string= (funcall parse-xff "2001:db8::1, 192.168.1.1")
                   "2001:db8::1")
          "Should handle IPv6 addresses"))

    (testing "trims whitespace around IP"
      (ok (string= (funcall parse-xff "  192.168.1.1  , 10.0.0.1")
                   "192.168.1.1")
          "Should trim leading/trailing whitespace"))

    (testing "handles single IP with trailing comma"
      (ok (string= (funcall parse-xff "192.168.1.1,") "192.168.1.1")
          "Should handle trailing comma"))

    ;; 異常系
    (testing "returns NIL for empty string"
      (ok (null (funcall parse-xff ""))
          "Should return NIL for empty string"))

    (testing "returns NIL for NIL input"
      (ok (null (funcall parse-xff nil))
          "Should return NIL for NIL input"))))

;;; ============================================================
;;; clamp-pagination-count テスト
;;; ============================================================

(deftest test-clamp-pagination-count
  ;; 正常系（範囲内の値）
  (testing "returns value within range"
    (ok (= (clamp-pagination-count 50) 50)
        "Should return value as-is when within range"))

  (testing "returns default for NIL"
    (ok (= (clamp-pagination-count nil) 20)
        "Should return default (20) for NIL"))

  ;; 境界値テスト（デフォルト: min=1, max=100, default=20）
  (testing "accepts min value (1)"
    (ok (= (clamp-pagination-count 1) 1)
        "Should accept minimum value"))

  (testing "rejects value below min (0)"
    (ok (= (clamp-pagination-count 0) 20)
        "Should return default for value below min"))

  (testing "accepts max value (100)"
    (ok (= (clamp-pagination-count 100) 100)
        "Should accept maximum value"))

  (testing "rejects value above max (101)"
    (ok (= (clamp-pagination-count 101) 20)
        "Should return default for value above max"))

  ;; 負数テスト
  (testing "rejects negative value"
    (ok (= (clamp-pagination-count -1) 20)
        "Should return default for negative value"))

  (testing "rejects large negative value"
    (ok (= (clamp-pagination-count -1000) 20)
        "Should return default for large negative value"))

  ;; 型テスト
  (testing "returns default for string"
    (ok (= (clamp-pagination-count "50") 20)
        "Should return default for string input"))

  (testing "returns default for float"
    (ok (= (clamp-pagination-count 50.5) 20)
        "Should return default for float input"))

  ;; カスタムパラメータ
  (testing "respects custom min"
    (ok (= (clamp-pagination-count 5 :min 10 :max 100 :default 30) 30)
        "Should return custom default when below custom min"))

  (testing "respects custom max"
    (ok (= (clamp-pagination-count 150 :min 1 :max 50 :default 25) 25)
        "Should return custom default when above custom max")))

;;; ============================================================
;;; trust-proxy-p テスト
;;; ============================================================

(deftest test-trust-proxy-p
  ;; 注意: 未エクスポート関数のため :: でアクセス
  ;; 環境変数を操作するため、unwind-protect で復元必須

  (testing "returns T when TRUST_PROXY=true"
    (with-env-var "TRUST_PROXY" "true"
      (lambda ()
        (ok (twitter-like.util.request::trust-proxy-p)
            "Should return T for TRUST_PROXY=true"))))

  (testing "returns T when TRUST_PROXY=1"
    (with-env-var "TRUST_PROXY" "1"
      (lambda ()
        (ok (twitter-like.util.request::trust-proxy-p)
            "Should return T for TRUST_PROXY=1"))))

  (testing "returns T when TRUST_PROXY=TRUE (case insensitive)"
    (with-env-var "TRUST_PROXY" "TRUE"
      (lambda ()
        (ok (twitter-like.util.request::trust-proxy-p)
            "Should return T for uppercase TRUE"))))

  (testing "returns NIL when TRUST_PROXY=false"
    (with-env-var "TRUST_PROXY" "false"
      (lambda ()
        (ok (not (twitter-like.util.request::trust-proxy-p))
            "Should return NIL for TRUST_PROXY=false"))))

  (testing "returns NIL when TRUST_PROXY is not set"
    (with-env-var "TRUST_PROXY" nil
      (lambda ()
        (ok (not (twitter-like.util.request::trust-proxy-p))
            "Should return NIL when not set"))))

  (testing "returns NIL for other values (yes, on, etc.)"
    (with-env-var "TRUST_PROXY" "yes"
      (lambda ()
        (ok (not (twitter-like.util.request::trust-proxy-p))
            "Should return NIL for 'yes' (only 'true' and '1' are valid)")))))

;;; ============================================================
;;; read-stream-with-limit テスト
;;; ============================================================

(deftest test-read-stream-with-limit
  ;; 注意: 未エクスポート関数のため :: でアクセス
  ;; let で関数参照を束縛することで、各テストケースでの記述を簡潔にする
  (let ((read-limit #'twitter-like.util.request::read-stream-with-limit))

    ;; 正常系
    (testing "reads stream within limit"
      (let* ((data (make-array 1000 :element-type '(unsigned-byte 8)
                                    :initial-element 65))  ; 'A'
             (stream (flexi-streams:make-in-memory-input-stream data))
             (result (funcall read-limit stream 2000)))
        (ok (= (length result) 1000)
            "Should read all 1000 bytes")))

    (testing "reads exact limit size"
      (let* ((data (make-array 1000 :element-type '(unsigned-byte 8)
                                    :initial-element 66))  ; 'B'
             (stream (flexi-streams:make-in-memory-input-stream data))
             (result (funcall read-limit stream 1000)))
        (ok (= (length result) 1000)
            "Should read all bytes when size equals limit")))

    (testing "preserves data content"
      (let* ((data (make-array 5 :element-type '(unsigned-byte 8)
                                 :initial-contents '(72 101 108 108 111)))  ; "Hello"
             (stream (flexi-streams:make-in-memory-input-stream data))
             (result (funcall read-limit stream 100)))
        (ok (equalp result data)
            "Should preserve exact byte content")))

    ;; 境界テスト
    (testing "returns :overflow when exceeding limit"
      (let* ((data (make-array 2000 :element-type '(unsigned-byte 8)
                                    :initial-element 67))  ; 'C'
             (stream (flexi-streams:make-in-memory-input-stream data))
             (result (funcall read-limit stream 1000)))
        (ok (eq result :overflow)
            "Should return :overflow when stream exceeds limit")))

    (testing "returns :overflow at limit+1"
      (let* ((data (make-array 1001 :element-type '(unsigned-byte 8)
                                    :initial-element 68))  ; 'D'
             (stream (flexi-streams:make-in-memory-input-stream data))
             (result (funcall read-limit stream 1000)))
        (ok (eq result :overflow)
            "Should return :overflow for 1001 bytes with 1000 limit")))

    ;; 空ストリーム
    (testing "returns empty array for empty stream"
      (let* ((data (make-array 0 :element-type '(unsigned-byte 8)))
             (stream (flexi-streams:make-in-memory-input-stream data))
             (result (funcall read-limit stream 1000)))
        (ok (zerop (length result))
            "Should return empty array for empty stream")))

    ;; 小さいデータ
    (testing "handles single byte"
      (let* ((data (make-array 1 :element-type '(unsigned-byte 8)
                                 :initial-element 69))  ; 'E'
             (stream (flexi-streams:make-in-memory-input-stream data))
             (result (funcall read-limit stream 1000)))
        (ok (= (length result) 1)
            "Should handle single byte correctly")))

    ;; 大きいバッファよりも小さいデータ（チャンク読み取りの境界）
    (testing "handles data smaller than internal buffer (4096)"
      (let* ((data (make-array 100 :element-type '(unsigned-byte 8)
                                   :initial-element 70))  ; 'F'
             (stream (flexi-streams:make-in-memory-input-stream data))
             (result (funcall read-limit stream 5000)))
        (ok (= (length result) 100)
            "Should handle data smaller than buffer size")))

    ;; セキュリティ境界値テスト: +max-body-size+ (1MB) ちょうど
    ;; 注意: このテストはメモリを1MB消費するため、CI環境でのリソース制約に注意
    ;; 環境変数 SKIP_LARGE_TESTS=1 でスキップ可能
    (unless (uiop:getenv "SKIP_LARGE_TESTS")
      (testing "accepts exactly +max-body-size+ bytes (1MB boundary)"
        (let* ((max-size twitter-like.util.request::+max-body-size+)  ; 1048576
               (data (make-array max-size :element-type '(unsigned-byte 8)
                                          :initial-element 71))  ; 'G'
               (stream (flexi-streams:make-in-memory-input-stream data))
               (result (funcall read-limit stream max-size)))
          (ok (and (not (eq result :overflow))
                   (= (length result) max-size))
              "Should accept exactly 1MB (the DoS protection boundary)"))))))
