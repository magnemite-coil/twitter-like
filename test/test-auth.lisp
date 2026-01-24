(defpackage twitter-like-test.auth
  (:use :cl :rove)
  (:import-from :twitter-like-test
                :get-test-base-url
                :extract-session-cookie
                :json-post
                :safe-get)
  (:import-from :twitter-like.util.time
                :get-unix-time)
  (:import-from :com.inuoe.jzon
                :parse
                :stringify))

(in-package :twitter-like-test.auth)

(defun make-url (path)
  (format nil "~A~A" (twitter-like-test:get-test-base-url) path))

(setup
  ;; テスト環境セットアップ
  (twitter-like-test:setup-test-env))

(teardown
  ;; テストデータクリーンアップ
  (twitter-like-test:cleanup-test-data)
  ;; テスト環境クリーンアップ
  (twitter-like-test:teardown-test-env))

(deftest test-register-login-logout-flow
  (testing "Register -> me -> logout happy path with CSRF"
    (let* ((username (format nil "authtest_~A" (get-universal-time)))
           (password "this-is-a-very-secure-password")
           (register-values (multiple-value-list
                             (json-post "/api/auth/register"
                                        (let ((h (make-hash-table :test 'equal)))
                                          (setf (gethash "username" h) username
                                                (gethash "password" h) password)
                                          h))))
           (register-status (second register-values))
           (register-headers (third register-values))
           (cookie-header (let* ((set-cookie (gethash "set-cookie" register-headers))
                                 (sc-string (cond
                                              ((stringp set-cookie) set-cookie)
                                              ((and (listp set-cookie) (stringp (first set-cookie)))
                                               (first set-cookie))
                                              (t nil))))
                            (when sc-string
                              (let* ((eq-pos (position #\= sc-string))
                                     (semi-pos (position #\; sc-string :start (or eq-pos 0)))
                                     (sid (when eq-pos
                                            (subseq sc-string (1+ eq-pos)
                                                    (or semi-pos (length sc-string))))))
                                (format nil "session_id=~A" sid))))))
      (ok (= register-status 201) "Register should return 201")
      (ok cookie-header "Set-Cookie should be present after register")
      ;; /api/auth/me でセッション確認 & CSRF取得
      (multiple-value-bind (body status headers)
          (safe-get "/api/auth/me" :headers `(("cookie" . ,cookie-header)))
        (ok (= status 200) "me should return 200")
        (let* ((response (com.inuoe.jzon:parse body))
               (csrf (gethash "x-csrf-token" headers)))
          (ok csrf "X-CSRF-Token should be returned from /api/auth/me")
          (ok (string= (gethash "username" (gethash "user" response)) username)
              "me should return the same username")
          ;; ログアウト（CSRF必須）
          (multiple-value-bind (logout-body logout-status logout-headers)
              (dex:post (make-url "/api/auth/logout")
                        :headers `(("cookie" . ,cookie-header)
                                   ("x-csrf-token" . ,csrf)))
            (declare (ignore logout-body logout-headers))
            (ok (= logout-status 200) "Logout should return 200")))))))

(deftest test-logout-requires-csrf
  (testing "POST /api/auth/logout without CSRF token returns 403"
    (let* ((username (format nil "csrf_~A" (mod (get-universal-time) 100000000)))
           (password "this-is-a-very-secure-password"))
      ;; ユーザー登録
      (multiple-value-bind (body status headers)
          (json-post "/api/auth/register"
                     (let ((h (make-hash-table :test 'equal)))
                       (setf (gethash "username" h) username
                             (gethash "password" h) password)
                       h))
        (declare (ignore body))
        (ok (= status 201) "Register should return 201")
        (let* ((set-cookie (gethash "set-cookie" headers))
               (sc-string (cond
                            ((stringp set-cookie) set-cookie)
                            ((and (listp set-cookie) (stringp (first set-cookie)))
                             (first set-cookie))
                            (t nil)))
               (cookie-header (when sc-string
                                (let* ((eq-pos (position #\= sc-string))
                                       (semi-pos (position #\; sc-string :start (or eq-pos 0)))
                                       (sid (when eq-pos
                                              (subseq sc-string (1+ eq-pos)
                                                      (or semi-pos (length sc-string))))))
                                  (format nil "session_id=~A" sid)))))
          ;; CSRFトークンなしでlogout試行
          (handler-case
              (dex:post (make-url "/api/auth/logout")
                        :headers `(("cookie" . ,cookie-header)))
            (dexador.error:http-request-failed (e)
              (let* ((response-status (dexador:response-status e))
                     (response-body (dexador:response-body e))
                     (parsed (when response-body (com.inuoe.jzon:parse response-body))))
                (ok (= response-status 403) "Should return 403 Forbidden")
                (ok (stringp (gethash "error" parsed)) "Error message should be present")
                ;; 重要: クライアント起因エラーなのでerror_idは含まれない
                (ok (null (gethash "error_id" parsed))
                    "error_id should NOT be present for client-caused CSRF errors")))))))))

(deftest test-login-rate-limit
  (testing "Login rate limit returns 429 after threshold"
    (let* ((username (format nil "rl~8,'0d" (mod (get-universal-time) 100000000)))
           (password "this-is-a-very-secure-password"))
      ;; まずユーザー登録（成功させてアカウントを作る）
      (multiple-value-bind (_body _status headers)
          (json-post "/api/auth/register"
                     (let ((h (make-hash-table :test 'equal)))
                       (setf (gethash "username" h) username
                             (gethash "password" h) password)
                       h))
        (declare (ignore _body _status headers)))
      ;; パスワード誤りで6回ログイン試行（5回までは401、6回目で429想定）
      (loop for i from 1 to 6
            do (multiple-value-bind (body status headers)
                   (json-post "/api/auth/login"
                              (let ((h (make-hash-table :test 'equal)))
                                (setf (gethash "username" h) username
                                      (gethash "password" h) "wrong-password")
                                h))
                 (declare (ignore headers))
                 (cond
                   ((<= i 5)
                    (ok (= status 401)
                        (format nil "Attempt ~A should be 401" i)))
                   (t
                    (ok (= status 429)
                        "6th attempt should be rate limited (429)")
                    (let ((resp (com.inuoe.jzon:parse body)))
                      (ok (stringp (gethash "error" resp))
                          "Error message present")))))))))

;;; ============================================================
;;; Phase 1: Content-Type検証テスト
;;; ============================================================

(deftest test-register-content-type-validation
  (testing "POST /api/auth/register without Content-Type returns 415"
    (handler-case
        (dex:post (make-url "/api/auth/register")
                  :content "{\"username\":\"test\",\"password\":\"password123456789\"}"
                  :headers '(("Connection" . "close")))
      (dexador.error:http-request-failed (e)
        (ok (= (dexador:response-status e) 415)
            "Should return 415 Unsupported Media Type")
        (let ((response (com.inuoe.jzon:parse (dexador:response-body e))))
          (ok (null (gethash "error_id" response))
              "error_id should NOT be present for client errors")))))

  (testing "POST /api/auth/register with text/plain returns 415"
    (handler-case
        (dex:post (make-url "/api/auth/register")
                  :content "{\"username\":\"test\",\"password\":\"password123456789\"}"
                  :headers '(("Content-Type" . "text/plain")
                             ("Connection" . "close")))
      (dexador.error:http-request-failed (e)
        (ok (= (dexador:response-status e) 415)
            "Should return 415 for text/plain")
        (let ((response (com.inuoe.jzon:parse (dexador:response-body e))))
          (ok (null (gethash "error_id" response))
              "error_id should NOT be present for client errors"))))))

(deftest test-login-content-type-validation
  (testing "POST /api/auth/login without Content-Type returns 415"
    (handler-case
        (dex:post (make-url "/api/auth/login")
                  :content "{\"username\":\"test\",\"password\":\"password123456789\"}"
                  :headers '(("Connection" . "close")))
      (dexador.error:http-request-failed (e)
        (ok (= (dexador:response-status e) 415)
            "Should return 415 Unsupported Media Type")
        (let ((response (com.inuoe.jzon:parse (dexador:response-body e))))
          (ok (null (gethash "error_id" response))
              "error_id should NOT be present for client errors")))))

  (testing "POST /api/auth/login with text/plain returns 415"
    (handler-case
        (dex:post (make-url "/api/auth/login")
                  :content "{\"username\":\"test\",\"password\":\"password123456789\"}"
                  :headers '(("Content-Type" . "text/plain")
                             ("Connection" . "close")))
      (dexador.error:http-request-failed (e)
        (ok (= (dexador:response-status e) 415)
            "Should return 415 for text/plain")
        (let ((response (com.inuoe.jzon:parse (dexador:response-body e))))
          (ok (null (gethash "error_id" response))
              "error_id should NOT be present for client errors"))))))

;;; ============================================================
;;; Phase 1: JSONパースエラーテスト
;;; ============================================================

(deftest test-register-json-parse-errors
  (testing "POST /api/auth/register with empty body returns 400"
    (handler-case
        (dex:post (make-url "/api/auth/register")
                  :content ""
                  :headers '(("Content-Type" . "application/json")
                             ("Connection" . "close")))
      (dexador.error:http-request-failed (e)
        (ok (= (dexador:response-status e) 400)
            "Should return 400 Bad Request")
        ;; クライアント起因エラーなのでerror_idは含まれない
        (handler-case
            (let ((response (com.inuoe.jzon:parse (dexador:response-body e))))
              (ok (null (gethash "error_id" response))
                  "error_id should NOT be present for client errors"))
          (com.inuoe.jzon:json-parse-error ()
            ;; レスポンスがJSONでない場合、error_idは含まれていない
            (ok t "Response is not JSON, so error_id cannot be present"))))))

  (testing "POST /api/auth/register with invalid JSON returns 400"
    (handler-case
        (dex:post (make-url "/api/auth/register")
                  :content "{invalid json}"
                  :headers '(("Content-Type" . "application/json")
                             ("Connection" . "close")))
      (dexador.error:http-request-failed (e)
        (ok (= (dexador:response-status e) 400)
            "Should return 400 for invalid JSON")
        ;; クライアント起因エラーなのでerror_idは含まれない
        (handler-case
            (let ((response (com.inuoe.jzon:parse (dexador:response-body e))))
              (ok (null (gethash "error_id" response))
                  "error_id should NOT be present for client errors"))
          (com.inuoe.jzon:json-parse-error ()
            ;; レスポンスがJSONでない場合、error_idは含まれていない
            (ok t "Response is not JSON, so error_id cannot be present")))))))

(deftest test-login-json-parse-errors
  (testing "POST /api/auth/login with empty body returns 400"
    (handler-case
        (dex:post (make-url "/api/auth/login")
                  :content ""
                  :headers '(("Content-Type" . "application/json")
                             ("Connection" . "close")))
      (dexador.error:http-request-failed (e)
        (ok (= (dexador:response-status e) 400)
            "Should return 400 Bad Request")
        ;; クライアント起因エラーなのでerror_idは含まれない
        (handler-case
            (let ((response (com.inuoe.jzon:parse (dexador:response-body e))))
              (ok (null (gethash "error_id" response))
                  "error_id should NOT be present for client errors"))
          (com.inuoe.jzon:json-parse-error ()
            ;; レスポンスがJSONでない場合、error_idは含まれていない
            (ok t "Response is not JSON, so error_id cannot be present"))))))

  (testing "POST /api/auth/login with invalid JSON returns 400"
    (handler-case
        (dex:post (make-url "/api/auth/login")
                  :content "{invalid json}"
                  :headers '(("Content-Type" . "application/json")
                             ("Connection" . "close")))
      (dexador.error:http-request-failed (e)
        (ok (= (dexador:response-status e) 400)
            "Should return 400 for invalid JSON")
        ;; クライアント起因エラーなのでerror_idは含まれない
        (handler-case
            (let ((response (com.inuoe.jzon:parse (dexador:response-body e))))
              (ok (null (gethash "error_id" response))
                  "error_id should NOT be present for client errors"))
          (com.inuoe.jzon:json-parse-error ()
            ;; レスポンスがJSONでない場合、error_idは含まれていない
            (ok t "Response is not JSON, so error_id cannot be present")))))))

;;; ============================================================
;;; Phase 1: username検証テスト
;;; ============================================================

(deftest test-login-username-validation
  (testing "POST /api/auth/login without username returns 400"
    (multiple-value-bind (body status headers)
        (json-post "/api/auth/login"
                   (let ((h (make-hash-table :test 'equal)))
                     (setf (gethash "password" h) "password123456789")
                     h))
      (declare (ignore headers))
      (ok (= status 400) "Should return 400")
      (let ((response (com.inuoe.jzon:parse body)))
        (ok (search "Username" (gethash "error" response))
            "Error should mention Username")
        (ok (null (gethash "error_id" response))
            "error_id should NOT be present for client errors"))))

  (testing "POST /api/auth/login with empty username returns 400"
    (multiple-value-bind (body status headers)
        (json-post "/api/auth/login"
                   (let ((h (make-hash-table :test 'equal)))
                     (setf (gethash "username" h) ""
                           (gethash "password" h) "password123456789")
                     h))
      (declare (ignore headers))
      (ok (= status 400) "Should return 400")
      (let ((response (com.inuoe.jzon:parse body)))
        (ok (null (gethash "error_id" response))
            "error_id should NOT be present for client errors")))))

;;; ============================================================
;;; Phase 1: セッションなしテスト
;;; ============================================================

(deftest test-logout-without-session
  (testing "POST /api/auth/logout without session returns 401"
    (handler-case
        (dex:post (make-url "/api/auth/logout")
                  :headers '(("Connection" . "close")))
      (dexador.error:http-request-failed (e)
        (ok (= (dexador:response-status e) 401)
            "Should return 401 Unauthorized")))))

(deftest test-me-without-session
  (testing "GET /api/auth/me without session returns 401"
    (multiple-value-bind (body status headers)
        (safe-get "/api/auth/me")
      (declare (ignore body headers))
      (ok (= status 401) "Should return 401 Unauthorized"))))

;;; ============================================================
;;; Phase 1: 無効なセッションIDテスト
;;; ============================================================

(deftest test-logout-with-invalid-session
  (testing "POST /api/auth/logout with invalid session ID returns 401"
    (handler-case
        (dex:post (make-url "/api/auth/logout")
                  :headers '(("cookie" . "session_id=invalid-session-id-here")
                             ("Connection" . "close")))
      (dexador.error:http-request-failed (e)
        (ok (= (dexador:response-status e) 401)
            "Should return 401 for invalid session")))))

(deftest test-me-with-invalid-session
  (testing "GET /api/auth/me with invalid session ID returns 401"
    (multiple-value-bind (body status headers)
        (safe-get "/api/auth/me"
                  :headers '(("cookie" . "session_id=invalid-session-id-here")))
      (declare (ignore body headers))
      (ok (= status 401) "Should return 401 for invalid session"))))

;;; ============================================================
;;; Phase 2: アカウントロックアウトテスト
;;; ============================================================

(defun clear-login-rate-limits ()
  "ログイン関連のレート制限データをクリア（テスト用ヘルパー）
  注意: テスト環境専用。パターンマッチでキーを削除するため、
        他のテストに影響を与える可能性がある点に注意"
  (handler-case
      (let ((keys (red:keys "rate:login:ip:*")))
        (when keys
          (dolist (key keys)
            (red:del key))))
    (error () nil)))

(deftest test-login-account-lockout
  (testing "POST /api/auth/login returns 429 after account lockout"
    ;; 重要: IPレート制限データをクリア（レート制限とロックアウトの競合を防ぐ）
    ;; +login-rate-limit+ と +lockout-threshold+ が両方5回のため、
    ;; 各ループ後にIPレート制限をクリアしないと先に発動してしまう
    (clear-all-rate-limits)
    (let* ((username (format nil "locktest_~A" (get-universal-time)))
           (password "this-is-a-very-secure-password"))
      (unwind-protect
          (progn
            ;; 1. ユーザー登録
            (json-post "/api/auth/register"
                       (let ((h (make-hash-table :test 'equal)))
                         (setf (gethash "username" h) username
                               (gethash "password" h) password)
                         h))
            ;; 2. 5回失敗してロックアウト発動
            ;; 注意: 各失敗後にIPレート制限をクリアしてロックアウトが発動するようにする
            (loop for i from 1 to 5
                  do (progn
                       (json-post "/api/auth/login"
                                  (let ((h (make-hash-table :test 'equal)))
                                    (setf (gethash "username" h) username
                                          (gethash "password" h) "wrong-password!!")
                                    h))
                       ;; IPレート制限をクリア（ロックアウトデータは保持）
                       (clear-login-rate-limits)))
            ;; 3. 正しいパスワードでもロックアウト
            (multiple-value-bind (body status headers)
                (json-post "/api/auth/login"
                           (let ((h (make-hash-table :test 'equal)))
                             (setf (gethash "username" h) username
                                   (gethash "password" h) password)
                             h))
              (declare (ignore headers))
              (ok (= status 429) "Should return 429")
              (let ((response (com.inuoe.jzon:parse body)))
                (ok (search "locked" (gethash "error" response))
                    "Error should mention account locked")
                ;; クライアント起因エラーなのでerror_idは含まれない
                (ok (null (gethash "error_id" response))
                    "error_id should NOT be present for client errors"))))
        ;; cleanup: ロックアウトデータとレート制限データを削除
        (handler-case
            (progn
              (red:del (format nil "lockout:user:~A:count" username))
              (red:del (format nil "lockout:user:~A:locked_until" username))
              (clear-all-rate-limits))
          (error () nil))))))

;;; ============================================================
;;; Phase 2: セッションタイムアウトテスト
;;; ============================================================

(defvar *test-counter* 0
  "テスト用のユニークIDカウンター")

(defun generate-unique-id ()
  "テスト用のユニークなIDを生成（15文字以内）"
  (incf *test-counter*)
  (format nil "~A~A" (mod (get-internal-real-time) 1000000) *test-counter*))

(defun extract-session-id-from-headers (headers)
  "ヘッダーからセッションIDを抽出するヘルパー"
  (let* ((set-cookie (gethash "set-cookie" headers))
         (sc-string (cond
                      ((stringp set-cookie) set-cookie)
                      ((and (listp set-cookie) (stringp (first set-cookie)))
                       (first set-cookie))
                      (t nil))))
    (when sc-string
      (let* ((eq-pos (position #\= sc-string))
             (semi-pos (position #\; sc-string :start (or eq-pos 0))))
        (when eq-pos
          (subseq sc-string (1+ eq-pos)
                  (or semi-pos (length sc-string))))))))

(defun clear-all-rate-limits ()
  "すべてのレート制限データをクリア（テスト用ヘルパー）
  注意: テスト環境専用"
  (handler-case
      (progn
        ;; すべてのレート制限キーをクリア
        (let ((keys (red:keys "rate:*")))
          (when keys
            (dolist (key keys) (red:del key))))
        ;; ロックアウトキーもクリア
        (let ((keys (red:keys "lockout:*")))
          (when keys
            (dolist (key keys) (red:del key)))))
    (error () nil)))

(deftest test-logout-session-absolute-timeout
  (testing "POST /api/auth/logout with expired session (absolute timeout) returns 401"
    ;; レート制限をクリア
    (clear-all-rate-limits)
    (let* ((username (format nil "to_abs_~A" (generate-unique-id)))
           (password "this-is-a-very-secure-password"))
      ;; 1. ユーザー登録・ログイン
      (multiple-value-bind (body status headers)
          (json-post "/api/auth/register"
                     (let ((h (make-hash-table :test 'equal)))
                       (setf (gethash "username" h) username
                             (gethash "password" h) password)
                       h))
        (declare (ignore body))
        (ok (= status 201) "Register should return 201")
        (let* ((session-id (extract-session-id-from-headers headers))
               (cookie (format nil "session_id=~A" session-id)))
          (ok session-id "Session ID should be extracted from Set-Cookie header")
          (when session-id
            ;; 2. セッションの絶対有効期限を過去に設定（Redis直接操作）
            (let ((session-key (format nil "session:~A" session-id)))
              (red:hset session-key "created_at"
                        (write-to-string (- (get-unix-time) 700000))))  ; 7日以上前
            ;; 3. ログアウト試行（期限切れエラーを期待）
            (handler-case
                (dex:post (make-url "/api/auth/logout")
                          :headers `(("cookie" . ,cookie)
                                     ("x-csrf-token" . "dummy")
                                     ("Connection" . "close")))
              (dexador.error:http-request-failed (e)
                (ok (= (dexador:response-status e) 401)
                    "Should return 401 Session expired")))))))))

(deftest test-logout-session-idle-timeout
  (testing "POST /api/auth/logout with expired session (idle timeout) returns 401"
    ;; レート制限をクリア
    (clear-all-rate-limits)
    (let* ((username (format nil "to_idl_~A" (generate-unique-id)))
           (password "this-is-a-very-secure-password"))
      ;; 1. ユーザー登録・ログイン
      (multiple-value-bind (body status headers)
          (json-post "/api/auth/register"
                     (let ((h (make-hash-table :test 'equal)))
                       (setf (gethash "username" h) username
                             (gethash "password" h) password)
                       h))
        (declare (ignore body))
        (ok (= status 201) "Register should return 201")
        (let* ((session-id (extract-session-id-from-headers headers))
               (cookie (format nil "session_id=~A" session-id)))
          (ok session-id "Session ID should be extracted from Set-Cookie header")
          (when session-id
            ;; 2. セッションのアイドルタイムアウトを過去に設定（Redis直接操作）
            (let ((session-key (format nil "session:~A" session-id)))
              (red:hset session-key "last_accessed_at"
                        (write-to-string (- (get-unix-time) 2000))))  ; 30分以上前
            ;; 3. ログアウト試行（期限切れエラーを期待）
            (handler-case
                (dex:post (make-url "/api/auth/logout")
                          :headers `(("cookie" . ,cookie)
                                     ("x-csrf-token" . "dummy")
                                     ("Connection" . "close")))
              (dexador.error:http-request-failed (e)
                (ok (= (dexador:response-status e) 401)
                    "Should return 401 Session expired")))))))))

(deftest test-me-session-absolute-timeout
  (testing "GET /api/auth/me with expired session (absolute timeout) returns 401"
    ;; レート制限をクリア
    (clear-all-rate-limits)
    (let* ((username (format nil "me_abs_~A" (generate-unique-id)))
           (password "this-is-a-very-secure-password"))
      ;; 1. ユーザー登録・ログイン
      (multiple-value-bind (body status headers)
          (json-post "/api/auth/register"
                     (let ((h (make-hash-table :test 'equal)))
                       (setf (gethash "username" h) username
                             (gethash "password" h) password)
                       h))
        (declare (ignore body))
        (ok (= status 201) "Register should return 201")
        (let* ((session-id (extract-session-id-from-headers headers))
               (cookie (format nil "session_id=~A" session-id)))
          (ok session-id "Session ID should be extracted from Set-Cookie header")
          (when session-id
            ;; 2. セッションの絶対有効期限を過去に設定（Redis直接操作）
            (let ((session-key (format nil "session:~A" session-id)))
              (red:hset session-key "created_at"
                        (write-to-string (- (get-unix-time) 700000))))  ; 7日以上前
            ;; 3. me試行（期限切れエラーを期待）
            (multiple-value-bind (body status headers)
                (safe-get "/api/auth/me"
                          :headers `(("cookie" . ,cookie)))
              (declare (ignore body headers))
              (ok (= status 401) "Should return 401 Session expired"))))))))

(deftest test-me-session-idle-timeout
  (testing "GET /api/auth/me with expired session (idle timeout) returns 401"
    ;; レート制限をクリア
    (clear-all-rate-limits)
    (let* ((username (format nil "me_idl_~A" (generate-unique-id)))
           (password "this-is-a-very-secure-password"))
      ;; 1. ユーザー登録・ログイン
      (multiple-value-bind (body status headers)
          (json-post "/api/auth/register"
                     (let ((h (make-hash-table :test 'equal)))
                       (setf (gethash "username" h) username
                             (gethash "password" h) password)
                       h))
        (declare (ignore body))
        (ok (= status 201) "Register should return 201")
        (let* ((session-id (extract-session-id-from-headers headers))
               (cookie (format nil "session_id=~A" session-id)))
          (ok session-id "Session ID should be extracted from Set-Cookie header")
          (when session-id
            ;; 2. セッションのアイドルタイムアウトを過去に設定（Redis直接操作）
            (let ((session-key (format nil "session:~A" session-id)))
              (red:hset session-key "last_accessed_at"
                        (write-to-string (- (get-unix-time) 2000))))  ; 30分以上前
            ;; 3. me試行（期限切れエラーを期待）
            (multiple-value-bind (body status headers)
                (safe-get "/api/auth/me"
                          :headers `(("cookie" . ,cookie)))
              (declare (ignore body headers))
              (ok (= status 401) "Should return 401 Session expired"))))))))

;;; ============================================================
;;; Phase 2: register レート制限テスト (R-5)
;;; ============================================================

(deftest test-register-rate-limit
  (testing "POST /api/auth/register returns 429 with RateLimit headers after threshold"
    ;; レート制限をクリア
    (clear-all-rate-limits)
    ;; +register-rate-limit+ = 3 なので、4回目で429
    (loop for i from 1 to 4
          for username = (format nil "regrl_~A_~A" (generate-unique-id) i)
          do (multiple-value-bind (body status headers)
                 (json-post "/api/auth/register"
                            (let ((h (make-hash-table :test 'equal)))
                              (setf (gethash "username" h) username
                                    (gethash "password" h) "this-is-a-very-secure-password")
                              h))
               (if (<= i 3)
                   (ok (= status 201)
                       (format nil "Attempt ~A should succeed (201)" i))
                   (progn
                     (ok (= status 429)
                         "4th attempt should be rate limited (429)")
                     ;; RateLimitヘッダーの検証（小文字で返ってくる）
                     (ok (gethash "ratelimit" headers)
                         "RateLimit header should be present")
                     (ok (gethash "ratelimit-policy" headers)
                         "RateLimit-Policy header should be present")
                     (ok (gethash "retry-after" headers)
                         "Retry-After header should be present")
                     ;; error_id の非存在確認（クライアント起因エラー）
                     (let ((response (com.inuoe.jzon:parse body)))
                       (ok (null (gethash "error_id" response))
                           "error_id should NOT be present for client errors"))))))))

;;; ============================================================
;;; Phase 3: ユーザーDB不整合テスト (M-5)
;;; ============================================================

(deftest test-me-user-deleted-from-db
  (testing "GET /api/auth/me returns 401 when user is deleted from database"
    ;; レート制限をクリア
    (clear-all-rate-limits)
    (let* ((username (format nil "del_~A" (generate-unique-id)))
           (password "this-is-a-very-secure-password"))
      ;; 1. ユーザー登録
      (multiple-value-bind (body status headers)
          (json-post "/api/auth/register"
                     (let ((h (make-hash-table :test 'equal)))
                       (setf (gethash "username" h) username
                             (gethash "password" h) password)
                       h))
        (declare (ignore body))
        (ok (= status 201) "Register should return 201")
        (let* ((session-id (extract-session-id-from-headers headers))
               (cookie (format nil "session_id=~A" session-id)))
          (ok session-id "Session ID should be extracted")
          (when session-id
            ;; 2. ユーザーをDBから直接削除
            (let ((user (twitter-like.model.user:find-user-by-username username)))
              (when user
                (mito:delete-dao user)))
            ;; 3. me試行（ユーザー不在エラーを期待）
            (multiple-value-bind (body status headers)
                (safe-get "/api/auth/me"
                          :headers `(("cookie" . ,cookie)))
              (declare (ignore body headers))
              (ok (= status 401) "Should return 401 when user not found"))))))))
