(defpackage twitter-like-test.session
  (:use :cl :rove)
  (:import-from :twitter-like.middleware.session
                ;; Connection management
                :ensure-redis-connected
                :disconnect-redis
                :*redis-connection*
                ;; Session CRUD
                :create-session
                :get-session-user-id
                :get-csrf-token
                :delete-session
                :touch-session
                ;; Session expiration
                :session-idle-expired-p
                :session-absolute-expired-p
                ;; Session security
                :rotate-session
                ;; Cookie building
                :build-session-cookie
                :build-session-clear-cookie)
  (:import-from :twitter-like.util.crypto
                :generate-session-id)
  (:import-from :twitter-like.util.time
                :get-unix-time)
  (:import-from :twitter-like.config
                :load-config
                :get-config
                :*config*)  ; 本番環境テストで直接操作するためインポート
  (:import-from :cl-dotenv
                :load-env))
;; 注意: red: プレフィックス（cl-redis）はパッケージのニックネームとして
;; 暗黙的に利用可能。明示的なインポートは不要。

(in-package :twitter-like-test.session)

(setup
  ;; テスト環境の設定をロード（インポート済み関数を使用）
  (when (probe-file ".env.test")
    (load-env ".env.test"))
  (load-config)

  ;; === 環境ガード（本番環境への誤接続を防止） ===
  ;; APP_ENV が "test" であることを確認
  (unless (string= (get-config "app-env") "test")
    (error "SECURITY: APP_ENV must be 'test' for running unit tests. Current: ~A"
           (get-config "app-env")))

  ;; Redis DB番号がテスト用DB（0または1）であることを確認
  ;; 詳細は .claude/project/architecture.md 参照
  (let ((redis-db (get-config "redis-db")))
    (unless (member redis-db '(0 1) :test #'eql)
      (error "SECURITY: Redis DB must be 0 or 1 for tests. Current: ~A" redis-db))
    ;; DB 0 使用時は追加の警告（Docker環境以外での誤使用を検出）
    (when (and (eql redis-db 0)
               (not (uiop:getenv "DOCKER_ENV")))
      (warn "WARNING: Using Redis DB 0 outside Docker environment. Ensure this is intentional.")))

  ;; Redis HOST のホワイトリスト検証（厳格モード）
  ;; 非テスト環境のRedisへの誤接続を防止するため、ホワイトリスト外は即時エラー
  (let ((redis-host (get-config "redis-host")))
    (unless (member redis-host '("localhost" "127.0.0.1" "redis") :test #'string=)
      (error "SECURITY: Redis host '~A' is not in whitelist (localhost, 127.0.0.1, redis). Aborting tests." redis-host)))

  ;; Redis PORT のホワイトリスト検証
  ;; 標準ポート（6379）または一般的なテスト用ポート（6380）のみ許可
  (let ((redis-port (get-config "redis-port")))
    (unless (member redis-port '(6379 6380) :test #'eql)
      (error "SECURITY: Redis port ~A is not in whitelist (6379, 6380). Aborting tests." redis-port)))

  ;; Redis接続を確保（サーバー起動は不要）
  (ensure-redis-connected)

  ;; 接続確認
  (let ((redis-db (get-config "redis-db")))
    (handler-case
        (progn
          (red:dbsize)  ; 接続テスト
          (format t "~&✓ Redis connected to test database (DB ~A)~%" redis-db))
      (error (e)
        (error "SECURITY: Failed to connect to Redis: ~A" e)))))

(teardown
  ;; === クリーンアップ戦略 ===
  ;; 各テストは unwind-protect + red:del で個別にクリーンアップ
  ;;
  ;; なぜ flushdb を使わないか:
  ;; 1. 他のテスト（統合テスト等）との干渉を避ける
  ;; 2. 並列実行時の安全性を確保
  ;; 3. テストの独立性を保証（各テストが自己完結）
  ;;
  ;; 既存の setup.lisp:cleanup-test-data は flushdb を使用するが、
  ;; それは統合テスト（サーバー起動を伴う）用の設計
  ;; ユニットテストでは per-test cleanup が適切
  nil)

;;; ============================================================
;;; session-idle-expired-p テスト
;;; ============================================================

(deftest test-session-idle-expired-p
  (testing "session-idle-expired-p returns NIL within timeout (29 min)"
    (let* ((session-id (generate-session-id))
           (key (format nil "session:~A" session-id))
           (now (get-unix-time)))
      (unwind-protect
          (progn
            (red:hset key "last_accessed_at" (write-to-string (- now 1740)))  ; 29分前
            (red:expire key 3600)
            (ok (not (session-idle-expired-p session-id))
                "Should return NIL for session accessed 29 minutes ago"))
        (red:del key))))

  (testing "session-idle-expired-p returns NIL at boundary (30 min - 10 sec margin)"
    ;; 注意: 境界値テストはテスト実行中の時間経過やCI負荷でフレークする可能性があるため、
    ;; 10秒のマージンを持たせている（1790秒 = 29分50秒前）
    (let* ((session-id (generate-session-id))
           (key (format nil "session:~A" session-id))
           (now (get-unix-time)))
      (unwind-protect
          (progn
            (red:hset key "last_accessed_at" (write-to-string (- now 1790)))  ; 29分50秒前（10秒マージン）
            (red:expire key 3600)
            (ok (not (session-idle-expired-p session-id))
                "Should return NIL for session accessed 29m50s ago (within timeout with margin)"))
        (red:del key))))

  (testing "session-idle-expired-p returns T after timeout (31 min)"
    (let* ((session-id (generate-session-id))
           (key (format nil "session:~A" session-id))
           (now (get-unix-time)))
      (unwind-protect
          (progn
            (red:hset key "last_accessed_at" (write-to-string (- now 1860)))  ; 31分前
            (red:expire key 3600)
            (ok (session-idle-expired-p session-id)
                "Should return T for session accessed 31 minutes ago"))
        (red:del key))))

  (testing "session-idle-expired-p returns NIL for non-existent session"
    (ok (not (session-idle-expired-p "non-existent-session-id-12345"))
        "Should return NIL for non-existent session")))

;;; ============================================================
;;; session-absolute-expired-p テスト
;;; ============================================================

(deftest test-session-absolute-expired-p
  (testing "session-absolute-expired-p returns NIL within timeout (6 days)"
    (let* ((session-id (generate-session-id))
           (key (format nil "session:~A" session-id))
           (now (get-unix-time)))
      (unwind-protect
          (progn
            (red:hset key "created_at" (write-to-string (- now (* 6 24 3600))))  ; 6日前
            (red:expire key 3600)
            (ok (not (session-absolute-expired-p session-id))
                "Should return NIL for session created 6 days ago"))
        (red:del key))))

  (testing "session-absolute-expired-p returns NIL at boundary (7 days - 10 sec margin)"
    ;; 注意: 境界値テストはテスト実行中の時間経過やCI負荷でフレークする可能性があるため、
    ;; 10秒のマージンを持たせている（604790秒 = 6日23時間59分50秒前）
    (let* ((session-id (generate-session-id))
           (key (format nil "session:~A" session-id))
           (now (get-unix-time)))
      (unwind-protect
          (progn
            (red:hset key "created_at" (write-to-string (- now 604790)))  ; 7日 - 10秒（マージン）
            (red:expire key 3600)
            (ok (not (session-absolute-expired-p session-id))
                "Should return NIL for session created 6d23h59m50s ago (within timeout with margin)"))
        (red:del key))))

  (testing "session-absolute-expired-p returns T after timeout (8 days)"
    (let* ((session-id (generate-session-id))
           (key (format nil "session:~A" session-id))
           (now (get-unix-time)))
      (unwind-protect
          (progn
            (red:hset key "created_at" (write-to-string (- now (* 8 24 3600))))  ; 8日前
            (red:expire key 3600)
            (ok (session-absolute-expired-p session-id)
                "Should return T for session created 8 days ago"))
        (red:del key))))

  (testing "session-absolute-expired-p returns NIL for non-existent session"
    (ok (not (session-absolute-expired-p "non-existent-session-id-67890"))
        "Should return NIL for non-existent session")))

;;; ============================================================
;;; build-session-cookie テスト
;;; ============================================================

(deftest test-build-session-cookie
  (testing "build-session-cookie includes security attributes (development)"
    (let ((cookie (build-session-cookie "test-session-id-12345")))
      (ok (search "session_id=test-session-id-12345" cookie)
          "Should contain session ID")
      (ok (search "HttpOnly" cookie)
          "Should include HttpOnly attribute")
      (ok (search "SameSite=Lax" cookie)
          "Should include SameSite=Lax attribute")
      (ok (search "Path=/" cookie)
          "Should include Path=/ attribute")
      (ok (search "Max-Age=" cookie)
          "Should include Max-Age attribute")
      ;; 開発環境ではSecure属性が含まれないことを明示的に検証
      (ok (not (search "Secure" cookie))
          "Should NOT include Secure attribute in development")))

  (testing "build-session-cookie includes Secure attribute in production"
    ;; *config* の "app-env" を一時的に "production" に上書き
    ;; 注意: Roveはデフォルトで直列実行のため、*config*の一時差し替えは安全
    ;; 並列テスト実行時はレース条件の余地があるため、テスト直列実行を前提とする
    (let ((original-app-env (get-config "app-env")))
      (unwind-protect
          (progn
            (setf (gethash "app-env" *config*) "production")
            (let ((cookie (build-session-cookie "test-session-id-prod")))
              (ok (search "Secure" cookie)
                  "Should include Secure attribute in production")
              (ok (search "HttpOnly" cookie)
                  "Should still include HttpOnly in production")
              (ok (search "SameSite=Lax" cookie)
                  "Should still include SameSite=Lax in production")))
        ;; 必ず元の値に復元（unwind-protectで保証）
        (setf (gethash "app-env" *config*) original-app-env)))))

;;; ============================================================
;;; build-session-clear-cookie テスト
;;; ============================================================

(deftest test-build-session-clear-cookie
  (testing "build-session-clear-cookie includes all security attributes (development)"
    ;; 削除Cookieも同一属性で上書きしないとCookieが残存するリスクがあるため、
    ;; 生成時と同じ属性を検証する（OWASP推奨）
    (let ((cookie (build-session-clear-cookie)))
      (ok (search "Max-Age=0" cookie)
          "Should set Max-Age=0 for deletion")
      (ok (search "HttpOnly" cookie)
          "Should include HttpOnly for security")
      (ok (search "SameSite=Lax" cookie)
          "Should include SameSite=Lax attribute")
      (ok (search "Path=/" cookie)
          "Should include Path=/ attribute")
      ;; 開発環境ではSecure属性が含まれないことを明示的に検証
      (ok (not (search "Secure" cookie))
          "Should NOT include Secure attribute in development")))

  (testing "build-session-clear-cookie includes Secure attribute in production"
    ;; *config* の "app-env" を一時的に "production" に上書き
    ;; 注意: Roveはデフォルトで直列実行のため、*config*の一時差し替えは安全
    (let ((original-app-env (get-config "app-env")))
      (unwind-protect
          (progn
            (setf (gethash "app-env" *config*) "production")
            (let ((cookie (build-session-clear-cookie)))
              (ok (search "Secure" cookie)
                  "Should include Secure attribute in production")
              (ok (search "HttpOnly" cookie)
                  "Should still include HttpOnly in production")
              (ok (search "SameSite=Lax" cookie)
                  "Should still include SameSite=Lax in production")
              (ok (search "Path=/" cookie)
                  "Should still include Path=/ in production")
              (ok (search "Max-Age=0" cookie)
                  "Should still set Max-Age=0 for deletion in production")))
        ;; 必ず元の値に復元（unwind-protectで保証）
        (setf (gethash "app-env" *config*) original-app-env)))))

;;; ============================================================
;;; session CRUD テスト
;;; ============================================================

(deftest test-session-crud
  (testing "create-session stores session data in Redis"
    (let* ((user-id 12345)
           (session-id (create-session user-id))
           (key (format nil "session:~A" session-id)))
      (unwind-protect
          (progn
            (ok (= (length session-id) 32)
                "Session ID should be 32 characters")
            ;; 注意: red:exists は 0/1 または T/NIL を返す（ライブラリバージョンにより異なる）
            (let ((exists-result (red:exists key)))
              (ok (or (eq exists-result t)
                      (and (integerp exists-result) (plusp exists-result)))
                  "Session should exist in Redis"))
            ;; NIL安全: equalはNILを安全に比較可能
            (ok (equal (red:hget key "user_id") "12345")
                "Session should store user_id")
            (ok (red:hget key "csrf_token")
                "Session should have CSRF token")
            (ok (red:hget key "created_at")
                "Session should have created_at")
            (ok (red:hget key "last_accessed_at")
                "Session should have last_accessed_at")
            ;; TTL検証: +session-ttl+ (604800秒 = 7日) が設定されていることを確認
            ;; テスト実行中の時間経過やCI負荷を考慮し、30秒のマージンを許容
            ;; TTLが正の値であり、期待値以下であることを緩く検証
            (let ((ttl (red:ttl key)))
              (ok (and (integerp ttl)
                       (> ttl (- 604800 30))
                       (<= ttl 604800))
                  (format nil "Session TTL should be ~A seconds (got ~A)" 604800 ttl))))
        (red:del key))))

  (testing "get-session-user-id retrieves correct user ID"
    (let* ((user-id 67890)
           (session-id (create-session user-id)))
      (unwind-protect
          (let ((retrieved-user-id (get-session-user-id session-id)))
            (ok retrieved-user-id "Should retrieve a user ID")
            (ok (= retrieved-user-id user-id)
                "Should retrieve correct user ID"))
        (delete-session session-id))))

  (testing "get-session-user-id returns NIL for invalid session"
    (ok (null (get-session-user-id "invalid-session-id-xxxxx"))
        "Should return NIL for non-existent session"))

  (testing "get-csrf-token retrieves correct token"
    (let* ((session-id (create-session 11111))
           (key (format nil "session:~A" session-id)))
      (unwind-protect
          (let ((stored-token (red:hget key "csrf_token"))
                (retrieved-token (get-csrf-token session-id)))
            ;; NIL安全: 両方がnon-NILであることを先に確認
            (ok stored-token "Stored CSRF token should exist")
            (ok retrieved-token "Retrieved CSRF token should exist")
            (ok (and stored-token retrieved-token
                     (string= stored-token retrieved-token))
                "Should retrieve correct CSRF token"))
        (delete-session session-id))))

  (testing "get-csrf-token returns NIL for invalid session"
    (ok (null (get-csrf-token "invalid-session-id-yyyyy"))
        "Should return NIL for non-existent session"))

  (testing "delete-session removes session from Redis"
    (let* ((session-id (create-session 22222)))
      (delete-session session-id)
      (ok (null (get-session-user-id session-id))
          "Session should be deleted")))

  ;; nil 分岐テスト（防御的コード用、カバレッジ維持用）
  ;; これらは通常のアプリケーションフローでは発生しない分岐をカバーするためのもの
  (testing "get-session-user-id returns NIL when session-id is nil"
    (ok (null (get-session-user-id nil))
        "Should return NIL for nil session-id"))

  (testing "get-csrf-token returns NIL when session-id is nil"
    (ok (null (get-csrf-token nil))
        "Should return NIL for nil session-id"))

  (testing "delete-session does nothing when session-id is nil"
    ;; delete-session returns immediately when session-id is nil
    ;; Verify no side effects on existing sessions
    (let* ((session-id (create-session 99999))
           (key (format nil "session:~A" session-id)))
      (unwind-protect
          (progn
            ;; Passing nil should not affect existing sessions
            (delete-session nil)
            (ok (get-session-user-id session-id)
                "Existing session should not be affected by delete-session nil"))
        (red:del key)))))

;;; ============================================================
;;; touch-session テスト
;;; ============================================================

(deftest test-touch-session
  (testing "touch-session updates last_accessed_at"
    (let* ((session-id (create-session 33333))
           (key (format nil "session:~A" session-id))
           (now (get-unix-time)))
      (unwind-protect
          (progn
            ;; last_accessed_at を人工的に60秒前に設定（sleepを使わない）
            (red:hset key "last_accessed_at" (write-to-string (- now 60)))
            ;; NIL安全: red:hgetがNILを返す可能性を考慮
            (let* ((old-time-str (red:hget key "last_accessed_at"))
                   (old-time (when old-time-str
                               (parse-integer old-time-str :junk-allowed t))))
              (ok old-time "last_accessed_at should exist before touch")
              ;; touch-session を呼び出し
              (ok (touch-session session-id)
                  "Should return T for existing session")
              (let* ((new-time-str (red:hget key "last_accessed_at"))
                     (new-time (when new-time-str
                                 (parse-integer new-time-str :junk-allowed t))))
                (ok new-time "last_accessed_at should exist after touch")
                (ok (and old-time new-time (> new-time old-time))
                    "last_accessed_at should be updated to a newer time"))))
        (delete-session session-id))))

  (testing "touch-session returns NIL for non-existent session"
    (let ((fake-session-id "non-existent-session-id-zzzzz")
          (key "session:non-existent-session-id-zzzzz"))
      ;; エラーが発生しないこと、かつNILを返すことを確認
      (ok (null (touch-session fake-session-id))
          "Should return NIL for non-existent session")
      ;; 不完全なセッションデータが作成されていないことを確認
      ;; 注意: red:exists は 0/1 を返す。Common Lisp では 0 も真なので plusp で判定
      ;; NIL安全: red:existsがNILを返す可能性を考慮
      (let ((exists-result (red:exists key)))
        (ok (or (null exists-result) (zerop exists-result))
            "Should NOT create new session data for non-existent session"))))

  (testing "touch-session returns NIL when session-id is nil"
    (ok (null (touch-session nil))
        "Should return NIL for nil session-id")))

;;; ============================================================
;;; rotate-session テスト
;;; ============================================================

(deftest test-rotate-session
  (testing "rotate-session creates new session and deletes old"
    (let* ((user-id 99999)
           (old-session-id (create-session user-id))
           (new-session-id (rotate-session old-session-id user-id)))
      (unwind-protect
          (progn
            (ok (not (string= old-session-id new-session-id))
                "New session ID should be different")
            (ok (null (get-session-user-id old-session-id))
                "Old session should be deleted")
            (ok (= (get-session-user-id new-session-id) user-id)
                "New session should have correct user ID"))
        (delete-session new-session-id))))

  ;; CSRFトークンの再生成検証（セッション固定攻撃対策として重要）
  (testing "rotate-session generates new CSRF token"
    (let* ((user-id 77777)
           (old-session-id (create-session user-id))
           (old-csrf-token (get-csrf-token old-session-id))
           (new-session-id (rotate-session old-session-id user-id))
           (new-csrf-token (get-csrf-token new-session-id)))
      (unwind-protect
          (progn
            (ok old-csrf-token "Old session should have CSRF token")
            (ok new-csrf-token "New session should have CSRF token")
            ;; セッションローテーション時に新しいCSRFトークンが生成されることを確認
            ;; これにより、古いトークンを持つ攻撃者はCSRF攻撃を実行できない
            (ok (not (string= old-csrf-token new-csrf-token))
                "New CSRF token should differ from old (session fixation protection)"))
        (delete-session new-session-id))))

  (testing "rotate-session handles nil old session"
    (let* ((user-id 88888)
           (new-session-id (rotate-session nil user-id)))
      (unwind-protect
          (progn
            (ok new-session-id
                "Should create new session even with nil old session")
            (ok (= (get-session-user-id new-session-id) user-id)
                "New session should have correct user ID"))
        (delete-session new-session-id)))))

;;; ============================================================
;;; disconnect-redis Edge Case Tests (New)
;;; ============================================================

(deftest test-disconnect-redis-edge-cases
  (testing "disconnect-redis does nothing when not connected"
    (let ((original-connection *redis-connection*))
      ;; Verify connection before test (check state consistency)
      (ok (red:ping) "Precondition: Redis connection should be active")
      (unwind-protect
          (progn
            ;; Temporarily set connection to nil
            (setf *redis-connection* nil)
            ;; Verify completes without error
            (disconnect-redis)
            (ok t "Should complete without error when not connected"))
        ;; Restore connection (cleanup contains no assertions)
        (setf *redis-connection* original-connection)))
    ;; Verify connection after restoration (assertion outside unwind-protect)
    (ok (red:ping) "Connection should be restored and functional")))

;;; ============================================================
;;; ensure-redis-connected Edge Case Tests (New)
;;; ============================================================

(deftest test-ensure-redis-connected-edge-cases
  (testing "ensure-redis-connected does nothing when already connected"
    ;; Precondition: already connected via setup
    ;; Save connection object to verify identity
    (let ((original-connection *redis-connection*))
      (ok original-connection
          "Precondition: should be connected")
      ;; Call should complete without error
      (ensure-redis-connected)
      ;; Verify same connection object is maintained
      ;; (no new connection created)
      (ok (eq *redis-connection* original-connection)
          "Connection object should be unchanged (no reconnection)"))))
