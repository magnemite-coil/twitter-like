(defpackage twitter-like-test.auth-service
  (:use :cl :rove)
  (:import-from :twitter-like.service.auth
                :check-login-rate-limit
                :decrement-login-rate-limit
                :check-register-rate-limit
                :check-account-lockout
                :record-login-failure
                :clear-login-failures
                :register-user
                :authenticate-user
                ;; レート制限定数（テストの期待値算出に使用）
                :+login-rate-limit+
                :+register-rate-limit+
                ;; ロックアウト閾値定数（テストの期待値算出に使用）
                :+lockout-threshold+)
  (:import-from :twitter-like.model.user
                :user-username
                :find-user-by-username)
  (:import-from :twitter-like.config
                :load-config
                :get-config
                :*config*)
  (:import-from :twitter-like.util.time
                :get-unix-time)
  (:import-from :twitter-like.middleware.session
                :ensure-redis-connected)
  (:import-from :twitter-like.db
                :ensure-db-connected)
  (:import-from :cl-dotenv
                :load-env))
;; 注意: red: プレフィックス（cl-redis）はパッケージのニックネームとして
;; 暗黙的に利用可能。明示的なインポートは不要。
;;
;; 注意: mito:delete-dao はプレフィックス形式で呼び出す（:import-from しない）。
;; 理由: 既存のテストファイル（test-session.lisp等）との一貫性を保つため。
;; cleanup-test-user 内で (mito:delete-dao user) として使用する。

(in-package :twitter-like-test.auth-service)

;;; ============================================================
;;; ヘルパー関数
;;; ============================================================

(defun cleanup-test-user (username)
  "テスト用ユーザーをDBとRedisから削除
   テストファイル内にローカル定義（テストの独立性を維持）

   クリーンアップ対象:
   - DB: userテーブルのレコード
   - Redis: アカウントロックアウト関連キー

   クリーンアップ順序:
   - Redisを先に削除することで、DB削除が失敗しても
     Redisにゴミデータが残らないようにする"
  (handler-case
      (progn
        ;; Redis のロックアウト情報を削除（DBより先に削除）
        ;; 理由: DB削除失敗時でもRedisの孤立データを防ぐ
        (red:del (format nil "lockout:user:~A:count" username))
        (red:del (format nil "lockout:user:~A:locked_until" username))
        ;; DB からユーザーを削除
        (let ((user (find-user-by-username username)))
          (when user
            (mito:delete-dao user))))
    (error (e)
      (format t "~&Warning: Failed to cleanup user ~A: ~A~%" username e))))

;;; ============================================================
;;; setup/teardown
;;; ============================================================

(setup
  ;; .env.test 読み込み
  (when (probe-file ".env.test")
    (load-env ".env.test"))
  (load-config)

  ;; 層1: APP_ENV チェック
  (unless (string= (get-config "app-env") "test")
    (error "SECURITY: APP_ENV must be 'test'. Current: ~A"
           (get-config "app-env")))

  ;; 層2: DB名チェック（本番DBへの誤接続防止）
  (let ((db-name (get-config "db-name")))
    (unless (string= db-name "twitter_like_test")
      (error "SECURITY: DB_NAME must be 'twitter_like_test'. Current: ~A" db-name)))

  ;; 層3: DB HOSTホワイトリスト検証
  (let ((db-host (get-config "db-host")))
    (unless (member db-host '("localhost" "127.0.0.1" "postgres" "db") :test #'string=)
      (error "SECURITY: DB_HOST '~A' not in whitelist (localhost, 127.0.0.1, postgres, db)" db-host)))

  ;; 層4: DB PORTホワイトリスト検証
  (let ((db-port (get-config "db-port")))
    (unless (member db-port '(5432 5433) :test #'eql)
      (error "SECURITY: DB_PORT ~A not in whitelist (5432, 5433)" db-port)))

  ;; 層5: DB USERホワイトリスト検証
  ;; 注意: ローカル環境のユーザー名も許可（key-person を追加）
  (let ((db-user (get-config "db-user")))
    (unless (member db-user '("twitter_like_test" "postgres" "test" "key-person") :test #'string=)
      (error "SECURITY: DB_USER '~A' not in whitelist (twitter_like_test, postgres, test, key-person)" db-user)))

  ;; 層6: Redis DB番号チェック
  (let ((redis-db (get-config "redis-db")))
    (unless (member redis-db '(0 1) :test #'eql)
      (error "SECURITY: Redis DB must be 0 or 1. Current: ~A" redis-db))
    ;; DB 0 使用時は追加の警告（Docker環境以外での誤使用を検出）
    (when (and (eql redis-db 0)
               (not (uiop:getenv "DOCKER_ENV")))
      (warn "WARNING: Using Redis DB 0 outside Docker environment. Ensure this is intentional.")))

  ;; 層7: Redis接続先ホワイトリスト
  (let ((redis-host (get-config "redis-host")))
    (unless (member redis-host '("localhost" "127.0.0.1" "redis") :test #'string=)
      (error "SECURITY: Redis host '~A' not in whitelist" redis-host)))

  ;; 層8: Redis PORT ホワイトリスト
  (let ((redis-port (get-config "redis-port")))
    (unless (member redis-port '(6379 6380) :test #'eql)
      (error "SECURITY: Redis port ~A is not in whitelist (6379, 6380). Aborting tests." redis-port)))

  ;; 層9: Redis接続確保
  (ensure-redis-connected)

  ;; 層10: DB接続確保
  (ensure-db-connected)

  ;; 層11: 接続確認（DBが利用可能であることを確認）
  ;; 注: DB名は層2で事前検証済み。ここでは接続が確立されていることを確認。
  ;; mito:retrieve-by-sql の戻り値形式はMitoバージョンにより異なるため、
  ;; シンプルな接続テストのみ行う。
  (handler-case
      (mito:retrieve-by-sql "SELECT 1")
    (error (e)
      (error "SECURITY: Failed to verify database connection: ~A" e)))

  ;; 層12: 接続確認ログ
  (let ((redis-db (get-config "redis-db"))
        (db-name (get-config "db-name")))
    (format t "~&✓ Test environment ready: Redis DB ~A, PostgreSQL ~A~%" redis-db db-name)))

(teardown
  ;; === クリーンアップ戦略 ===
  ;; 各テストは unwind-protect + red:del / cleanup-test-user で個別にクリーンアップ
  ;;
  ;; なぜ flushdb / 一括削除を使わないか:
  ;; 1. 他のテスト（統合テスト等）との干渉を避ける
  ;; 2. 並列実行時の安全性を確保
  ;; 3. テストの独立性を保証（各テストが自己完結）
  ;;
  ;; 既存の setup.lisp:cleanup-test-data は flushdb を使用するが、
  ;; それは統合テスト（サーバー起動を伴う）用の設計
  ;; ユニットテストでは per-test cleanup が適切
  nil)

;;; ============================================================
;;; check-login-rate-limit / decrement-login-rate-limit テスト
;;; ============================================================

(deftest test-login-rate-limit-functions
  (testing "check-login-rate-limit allows first attempt"
    (let ((test-ip (format nil "test-ip-~A" (get-universal-time))))
      (unwind-protect
          (multiple-value-bind (allowed remaining reset member-id)
              (check-login-rate-limit test-ip)
            (ok allowed "First attempt should be allowed")
            (ok (= remaining (1- +login-rate-limit+))
                (format nil "Remaining should be ~A" (1- +login-rate-limit+)))
            (ok (null reset) "Reset time should be nil when allowed")
            (ok member-id "Member ID should be returned for optimistic mode"))
        ;; cleanup
        (red:del (format nil "rate:login:ip:~A" test-ip)))))

  (testing "decrement-login-rate-limit reduces count on success"
    (let ((test-ip (format nil "test-ip-dec-~A" (get-universal-time))))
      (unwind-protect
          (progn
            ;; 1回目のチェック（カウント増加）
            (multiple-value-bind (allowed1 remaining1 reset1 member-id1)
                (check-login-rate-limit test-ip)
              (declare (ignore reset1))
              (ok allowed1 "First attempt should be allowed")
              (ok (= remaining1 (1- +login-rate-limit+))
                  (format nil "After first check, remaining should be ~A" (1- +login-rate-limit+)))
              ;; デクリメント（成功時）
              (ok (decrement-login-rate-limit test-ip member-id1)
                  "Decrement should return T")
              ;; 再チェック（カウントが減っているはず）
              (multiple-value-bind (allowed2 remaining2 reset2 member-id2)
                  (check-login-rate-limit test-ip)
                (declare (ignore reset2 member-id2))
                (ok allowed2 "Second attempt should also be allowed")
                (ok (= remaining2 (1- +login-rate-limit+))
                    (format nil "After decrement + check, remaining should be back to ~A"
                            (1- +login-rate-limit+))))))
        ;; cleanup
        (red:del (format nil "rate:login:ip:~A" test-ip)))))

  (testing "check-login-rate-limit blocks after limit exceeded"
    (let ((test-ip (format nil "test-ip-block-~A" (get-universal-time))))
      (unwind-protect
          (progn
            ;; limit回チェック（レート制限上限まで消費）
            (loop for i from 1 to +login-rate-limit+
                  do (check-login-rate-limit test-ip))
            ;; limit+1回目はブロック
            (multiple-value-bind (allowed remaining reset member-id)
                (check-login-rate-limit test-ip)
              (ok (not allowed) "6th attempt should be blocked")
              (ok (= remaining 0) "Remaining should be 0")
              (ok reset "Reset time should be provided")
              (ok (null member-id) "Member ID should be nil when blocked")))
        ;; cleanup
        (red:del (format nil "rate:login:ip:~A" test-ip)))))

  (testing "decrement-login-rate-limit returns NIL for invalid member-id"
    (let ((test-ip (format nil "test-ip-invalid-~A" (get-universal-time))))
      (unwind-protect
          (progn
            ;; 1回目のチェック（カウント増加）
            (check-login-rate-limit test-ip)
            ;; 無効なmember-idでデクリメント
            (ok (not (decrement-login-rate-limit test-ip "invalid-member-id"))
                "Should return NIL for invalid member-id"))
        ;; cleanup
        (red:del (format nil "rate:login:ip:~A" test-ip))))))

;;; ============================================================
;;; check-register-rate-limit テスト
;;; ============================================================

(deftest test-register-rate-limit
  (testing "check-register-rate-limit allows first attempt"
    (let ((test-ip (format nil "test-reg-~A" (get-universal-time))))
      (unwind-protect
          (multiple-value-bind (allowed remaining reset)
              (check-register-rate-limit test-ip)
            (ok allowed "First registration should be allowed")
            (ok (= remaining (1- +register-rate-limit+))
                (format nil "Remaining should be ~A" (1- +register-rate-limit+)))
            (ok (null reset) "Reset time should be nil when allowed"))
        ;; cleanup
        (red:del (format nil "rate:register:ip:~A" test-ip)))))

  (testing "check-register-rate-limit blocks after limit exceeded"
    (let ((test-ip (format nil "test-reg-block-~A" (get-universal-time))))
      (unwind-protect
          (progn
            ;; limit回チェック（レート制限上限まで消費）
            (loop for i from 1 to +register-rate-limit+
                  do (check-register-rate-limit test-ip))
            ;; limit+1回目はブロック
            (multiple-value-bind (allowed remaining reset)
                (check-register-rate-limit test-ip)
              (ok (not allowed) "4th attempt should be blocked")
              (ok (= remaining 0) "Remaining should be 0")
              (ok reset "Reset time should be provided")))
        ;; cleanup
        (red:del (format nil "rate:register:ip:~A" test-ip))))))

;;; ============================================================
;;; アカウントロックアウト テスト
;;; ============================================================

(deftest test-account-lockout
  (testing "check-account-lockout returns nil for unlocked user"
    (let ((test-user (format nil "locktest_~A" (get-universal-time))))
      (multiple-value-bind (locked remaining)
          (check-account-lockout test-user)
        (ok (not locked) "Should not be locked")
        (ok (= remaining 0) "Remaining should be 0"))))

  (testing "record-login-failure increments count"
    (let* ((test-user (format nil "failtest_~A" (get-universal-time)))
           (count-key (format nil "lockout:user:~A:count" test-user)))
      (unwind-protect
          (progn
            ;; 1回目の失敗
            (multiple-value-bind (locked count) (record-login-failure test-user)
              (ok (not locked) "Should not be locked after 1 failure")
              (ok (= count 1) "Count should be 1"))
            ;; 2回目の失敗
            (multiple-value-bind (locked count) (record-login-failure test-user)
              (ok (not locked) "Should not be locked after 2 failures")
              (ok (= count 2) "Count should be 2")))
        ;; cleanup
        (red:del count-key)
        (red:del (format nil "lockout:user:~A:locked_until" test-user)))))

  (testing "record-login-failure triggers lockout at threshold"
    (let* ((test-user (format nil "lockthresh_~A" (get-universal-time)))
           (count-key (format nil "lockout:user:~A:count" test-user))
           (locked-key (format nil "lockout:user:~A:locked_until" test-user)))
      (unwind-protect
          (progn
            ;; 閾値-1回失敗（あと1回でロック発動）
            (loop for i from 1 to (1- +lockout-threshold+)
                  do (record-login-failure test-user))
            ;; 閾値回目でロック発動
            (multiple-value-bind (locked count) (record-login-failure test-user)
              (ok locked (format nil "Should be locked after ~A failures" +lockout-threshold+))
              (ok (= count +lockout-threshold+)
                  (format nil "Count should be ~A" +lockout-threshold+)))
            ;; ロック状態を確認
            (multiple-value-bind (is-locked remaining)
                (check-account-lockout test-user)
              (ok is-locked "Account should be locked")
              (ok (> remaining 0) "Remaining lockout time should be positive")))
        ;; cleanup
        (red:del count-key)
        (red:del locked-key))))

  (testing "check-account-lockout clears expired lock"
    ;; 注意: 境界値テストはCI負荷や時間経過でフレークする可能性があるため、
    ;; 明確に期限切れの状態（10秒前）でテストする
    (let* ((test-user (format nil "explock_~A" (get-universal-time)))
           (count-key (format nil "lockout:user:~A:count" test-user))
           (locked-key (format nil "lockout:user:~A:locked_until" test-user))
           (now (get-unix-time)))
      (unwind-protect
          (progn
            ;; 過去のロック状態を設定（10秒前に期限切れ）
            (red:setex locked-key 100 (write-to-string (- now 10)))
            (red:setex count-key 100 (write-to-string +lockout-threshold+))
            ;; チェック（期限切れなのでロック解除されるべき）
            (multiple-value-bind (is-locked remaining)
                (check-account-lockout test-user)
              (ok (not is-locked) "Expired lock should be cleared")
              (ok (= remaining 0) "Remaining should be 0"))
            ;; キーが削除されていることを確認
            (ok (null (red:get locked-key)) "locked_until key should be deleted")
            (ok (null (red:get count-key)) "count key should be deleted"))
        ;; cleanup (念のため)
        (red:del count-key)
        (red:del locked-key))))

  (testing "clear-login-failures removes all lockout data"
    (let* ((test-user (format nil "cleartest_~A" (get-universal-time)))
           (count-key (format nil "lockout:user:~A:count" test-user))
           (locked-key (format nil "lockout:user:~A:locked_until" test-user))
           (now (get-unix-time)))
      (unwind-protect
          (progn
            ;; ロック状態を設定
            (red:setex locked-key 100 (write-to-string (+ now 1800)))
            (red:setex count-key 100 "5")
            ;; clear-login-failures を呼び出し
            (clear-login-failures test-user)
            ;; キーが削除されていることを確認
            (ok (null (red:get count-key)) "count key should be deleted")
            (ok (null (red:get locked-key)) "locked_until key should be deleted"))
        ;; cleanup (念のため)
        (red:del count-key)
        (red:del locked-key)))))

;;; ============================================================
;;; register-user テスト
;;; ============================================================

(deftest test-register-user
  ;; 注意: このテストはDBへの接続が必要
  ;; setup で twitter-like.db:ensure-db-connected が呼び出されている

  (testing "register-user fails with invalid username"
    (multiple-value-bind (user error error-type detail)
        (register-user "ab" "valid-password-here!!")
      (ok (null user) "User should be nil")
      (ok (search "at least 3" error) "Error should mention minimum length")
      (ok (eq error-type :validation) "Error type should be :validation")
      (ok (null detail) "No internal detail for validation errors")))

  (testing "register-user fails with invalid password"
    (multiple-value-bind (user error error-type detail)
        (register-user "validusername" "short")
      (ok (null user) "User should be nil")
      (ok (search "at least 15" error) "Error should mention minimum length")
      (ok (eq error-type :validation) "Error type should be :validation")
      (ok (null detail) "No internal detail for validation errors")))

  (testing "register-user succeeds with valid input"
    (let ((test-username (format nil "regtest_~A" (mod (get-universal-time) 100000000))))
      (unwind-protect
          (multiple-value-bind (user error error-type detail)
              (register-user test-username "this-is-a-valid-password")
            (ok user "User should be created")
            (ok (null error) "Error should be nil")
            (ok (null error-type) "Error type should be nil")
            (ok (null detail) "Detail should be nil")
            (ok (string= (user-username user) test-username)
                "Username should match"))
        ;; cleanup: テストユーザーを削除
        (cleanup-test-user test-username))))

  (testing "register-user fails with duplicate username"
    ;; セキュリティ注記（リスク受容）:
    ;; OWASPでは登録時に「Username already exists」と具体的に伝えると
    ;; ユーザー列挙攻撃のリスクがあると指摘されている。
    ;; 参照: https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html
    ;;
    ;; 本プロジェクトでは以下の理由でリスクを受容し、現仕様を維持する:
    ;; 1. 学習目的のプロジェクトであり、ユーザビリティを優先
    ;; 2. レート制限（3回/時間）により大量のユーザー名探索を防止
    ;; 3. 本番環境への移行時にはエラーメッセージの汎用化を検討
    ;;
    ;; 将来の改善案（本番環境向け）:
    ;; - エラーメッセージを "Registration failed. Please try again." に変更
    ;; - 登録成功/失敗に関わらず確認メール送信フローを導入
    (let ((test-username (format nil "duptest_~A" (mod (get-universal-time) 100000000))))
      (unwind-protect
          (progn
            ;; 1回目の登録（成功）
            (register-user test-username "this-is-a-valid-password")
            ;; 2回目の登録（重複エラー）
            (multiple-value-bind (user error error-type detail)
                (register-user test-username "another-valid-password!!")
              (ok (null user) "User should be nil")
              (ok (string= error "Username already exists")
                  "Error should indicate duplicate")
              (ok (eq error-type :validation) "Error type should be :validation")
              (ok (null detail) "No internal detail for validation errors")))
        ;; cleanup
        (cleanup-test-user test-username)))))

;;; ============================================================
;;; authenticate-user テスト
;;; ============================================================

(deftest test-authenticate-user
  ;; 注意: authenticate-user のダミーハッシュ検証（タイミング攻撃対策）をテスト
  ;; 実際のタイミング測定は行わず、振る舞いの一貫性を検証
  ;;
  ;; 将来の拡張ポイント:
  ;; タイミング攻撃対策の有効性を検証するため、存在/非存在ユーザーの
  ;; 認証時間差を測定するテストを追加できる。ただし、CI環境の負荷変動で
  ;; フレークテストになりやすいため、オプショナルテストとして実装を推奨。
  ;; 例: (deftest test-authenticate-timing-consistency ...)

  (testing "authenticate-user returns nil for non-existent user"
    ;; ユーザーが存在しない場合でも、存在する場合と同じエラーメッセージを返すことを確認
    ;; これはタイミング攻撃対策の一部（振る舞いの一貫性）
    ;;
    ;; 注: ユニーク名を生成することで、既存データによるフレークを防止
    (let ((nonexistent-username (format nil "nonexistent_~A" (get-universal-time))))
      ;; 念のため事前確認（存在しないことを確認）
      (assert (null (find-user-by-username nonexistent-username)))
      (multiple-value-bind (user error)
          (authenticate-user nonexistent-username "any-password-here!!")
        (ok (null user) "User should be nil for non-existent user")
        (ok (string= error "Invalid username or password")
            "Error message should be generic (not reveal user existence)"))))

  (testing "authenticate-user returns consistent error for wrong password"
    (let ((test-username (format nil "authtest_~A" (mod (get-universal-time) 100000000))))
      (unwind-protect
          (progn
            ;; ユーザーを作成
            (register-user test-username "correct-password-here!!")
            ;; 間違ったパスワードで認証
            (multiple-value-bind (user error)
                (authenticate-user test-username "wrong-password-here!!!")
              (ok (null user) "User should be nil for wrong password")
              (ok (string= error "Invalid username or password")
                  "Error message should be identical to non-existent user case")))
        ;; cleanup
        (cleanup-test-user test-username))))

  (testing "authenticate-user succeeds with correct credentials"
    (let ((test-username (format nil "authok_~A" (mod (get-universal-time) 100000000)))
          (test-password "correct-password-here!!"))
      (unwind-protect
          (progn
            ;; ユーザーを作成
            (register-user test-username test-password)
            ;; 正しいパスワードで認証
            (multiple-value-bind (user error)
                (authenticate-user test-username test-password)
              (ok user "User should be returned for correct credentials")
              (ok (null error) "Error should be nil")
              (ok (string= (user-username user) test-username)
                  "Username should match")))
        ;; cleanup
        (cleanup-test-user test-username)))))
