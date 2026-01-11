(defpackage twitter-like-test.tweet
  (:use :cl :rove)
  (:import-from :twitter-like-test
                :get-test-base-url
                :extract-session-cookie
                :json-post
                :safe-get
                :safe-delete)
  (:import-from :com.inuoe.jzon
                :parse
                :stringify)
  (:import-from :ironclad
                :byte-array-to-hex-string
                :random-data))

(in-package :twitter-like-test.tweet)

;;; ============================================================
;;; ヘルパー関数
;;; ============================================================

(defun make-url (path)
  (format nil "~A~A" (twitter-like-test:get-test-base-url) path))

(defun clear-rate-limits ()
  "レート制限データをクリア"
  (handler-case
      (when twitter-like.middleware.session:*redis-connection*
        (red:flushdb))
    (error () nil)))

(defun register-and-get-session ()
  "テスト用ユーザーを登録してセッション情報を取得
  注意: 乱数を付与してユーザー名の一意性を確保（同秒衝突対策）"
  ;; 登録前にレート制限をクリア
  (clear-rate-limits)
  (let* ((random-suffix (ironclad:byte-array-to-hex-string
                          (ironclad:random-data 3)))
         (username (format nil "tw~A~A" (mod (get-universal-time) 100000) random-suffix))
         (password "this-is-a-very-secure-password"))
    (multiple-value-bind (body status headers)
        (twitter-like-test:json-post "/api/auth/register"
                   (let ((h (make-hash-table :test 'equal)))
                     (setf (gethash "username" h) username
                           (gethash "password" h) password)
                     h))
      (declare (ignore body))
      ;; 登録失敗時は即エラー（テストの前提条件が満たされない）
      (unless (= status 201)
        (error "Failed to register test user: ~A (status ~A)" username status))
      ;; セッションCookieとCSRFトークンを取得
      (let* ((set-cookie (gethash "set-cookie" headers))
             (cookie (twitter-like-test:extract-session-cookie set-cookie)))
        ;; /api/auth/me でCSRFトークン取得
        (multiple-value-bind (me-body me-status me-headers)
            (dex:get (make-url "/api/auth/me")
                     :headers `(("cookie" . ,cookie)))
          (declare (ignore me-body me-status))
          (values cookie
                  (gethash "x-csrf-token" me-headers)
                  username))))))

(setup
  ;; テスト環境セットアップ
  (twitter-like-test:setup-test-env)
  ;; ツイートテーブルが存在することを保証
  (mito:ensure-table-exists 'twitter-like.model.tweet:tweet)
  ;; レート制限データをクリア（前回のテストの影響を除去）
  (handler-case
      (when twitter-like.middleware.session:*redis-connection*
        (red:flushdb))
    (error () nil)))

(teardown
  ;; テストデータクリーンアップ
  (twitter-like-test:cleanup-test-data)
  ;; テスト環境クリーンアップ
  (twitter-like-test:teardown-test-env))

;;; ============================================================
;;; POST /api/tweets テスト
;;; ============================================================

(deftest test-create-tweet-requires-auth
  (testing "POST /api/tweets without auth returns 401"
    (multiple-value-bind (body status headers)
        (twitter-like-test:json-post "/api/tweets"
                   (let ((h (make-hash-table :test 'equal)))
                     (setf (gethash "content" h) "Hello, Twitter!")
                     h))
      (declare (ignore body headers))
      (ok (= status 401) "Should return 401 Unauthorized"))))

(deftest test-create-tweet-requires-csrf
  (testing "POST /api/tweets without CSRF token returns 403"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      (declare (ignore csrf username))
      (multiple-value-bind (body status headers)
          (twitter-like-test:json-post "/api/tweets"
                     (let ((h (make-hash-table :test 'equal)))
                       (setf (gethash "content" h) "Hello, Twitter!")
                       h)
                     :headers `(("cookie" . ,cookie)))
        (declare (ignore body headers))
        (ok (= status 403) "Should return 403 Forbidden")))))

(deftest test-create-tweet-happy-path
  (testing "POST /api/tweets with valid content returns 201"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      (declare (ignore username))
      (multiple-value-bind (body status headers)
          (twitter-like-test:json-post "/api/tweets"
                     (let ((h (make-hash-table :test 'equal)))
                       (setf (gethash "content" h) "Hello, Twitter!")
                       h)
                     :headers `(("cookie" . ,cookie)
                                ("x-csrf-token" . ,csrf)))
        (declare (ignore headers))
        (ok (= status 201) "Should return 201 Created")
        (let ((response (com.inuoe.jzon:parse body)))
          (ok (gethash "tweet" response) "Response should contain tweet")
          (ok (string= (gethash "content" (gethash "tweet" response))
                       "Hello, Twitter!")
              "Tweet content should match"))))))

(deftest test-create-tweet-content-too-long
  (testing "POST /api/tweets with content > 140 chars returns 400"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      (declare (ignore username))
      (let ((long-content (make-string 141 :initial-element #\a)))
        (multiple-value-bind (body status headers)
            (twitter-like-test:json-post "/api/tweets"
                       (let ((h (make-hash-table :test 'equal)))
                         (setf (gethash "content" h) long-content)
                         h)
                       :headers `(("cookie" . ,cookie)
                                  ("x-csrf-token" . ,csrf)))
          (declare (ignore headers))
          (ok (= status 400) "Should return 400 Bad Request")
          (let ((response (com.inuoe.jzon:parse body)))
            (ok (search "140" (gethash "error" response))
                "Error message should mention 140 character limit")))))))

(deftest test-create-tweet-empty-content
  (testing "POST /api/tweets with empty content returns 400"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      (declare (ignore username))
      (multiple-value-bind (body status headers)
          (twitter-like-test:json-post "/api/tweets"
                     (let ((h (make-hash-table :test 'equal)))
                       (setf (gethash "content" h) "")
                       h)
                     :headers `(("cookie" . ,cookie)
                                ("x-csrf-token" . ,csrf)))
        (declare (ignore headers))
        (ok (= status 400) "Should return 400 Bad Request")
        (let ((response (com.inuoe.jzon:parse body)))
          (ok (gethash "error" response)
              "Error message should be present"))))))

;;; ============================================================
;;; GET /api/tweets/:id テスト
;;; ============================================================

(deftest test-get-tweet-not-found
  (testing "GET /api/tweets/:id with non-existent ID returns 404"
    (multiple-value-bind (body status headers)
        (twitter-like-test:safe-get "/api/tweets/999999")
      (declare (ignore body headers))
      (ok (= status 404) "Should return 404 Not Found"))))

(deftest test-get-tweet-happy-path
  (testing "GET /api/tweets/:id returns tweet with user info"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      ;; ツイートを作成
      (multiple-value-bind (create-body create-status create-headers)
          (twitter-like-test:json-post "/api/tweets"
                     (let ((h (make-hash-table :test 'equal)))
                       (setf (gethash "content" h) "Test tweet for GET")
                       h)
                     :headers `(("cookie" . ,cookie)
                                ("x-csrf-token" . ,csrf)))
        (declare (ignore create-headers))
        (ok (= create-status 201))
        (let* ((create-response (com.inuoe.jzon:parse create-body))
               (tweet-id (gethash "id" (gethash "tweet" create-response))))
          ;; 作成したツイートを取得
          (multiple-value-bind (get-body get-status get-headers)
              (twitter-like-test:safe-get (format nil "/api/tweets/~A" tweet-id))
            (declare (ignore get-headers))
            (ok (= get-status 200) "Should return 200 OK")
            (let ((response (com.inuoe.jzon:parse get-body)))
              (ok (gethash "tweet" response) "Response should contain tweet")
              (ok (gethash "user" (gethash "tweet" response))
                  "Tweet should include user info")
              (ok (string= (gethash "username" (gethash "user" (gethash "tweet" response)))
                           username)
                  "User should match creator"))))))))

;;; ============================================================
;;; DELETE /api/tweets/:id テスト
;;; ============================================================

(deftest test-delete-tweet-requires-csrf
  (testing "DELETE /api/tweets/:id without CSRF token returns 403"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      (declare (ignore username))
      ;; ツイートを作成
      (multiple-value-bind (body status headers)
          (twitter-like-test:json-post "/api/tweets"
                     (let ((h (make-hash-table :test 'equal)))
                       (setf (gethash "content" h) "Tweet to test CSRF")
                       h)
                     :headers `(("cookie" . ,cookie)
                                ("x-csrf-token" . ,csrf)))
        (declare (ignore headers))
        (ok (= status 201))
        (let* ((response (com.inuoe.jzon:parse body))
               (tweet-id (gethash "id" (gethash "tweet" response))))
          ;; CSRFトークンなしで削除を試みる
          (multiple-value-bind (del-body del-status del-headers)
              (twitter-like-test:safe-delete
                (format nil "/api/tweets/~A" tweet-id)
                :headers `(("cookie" . ,cookie)))  ; CSRFトークンなし
            (declare (ignore del-body del-headers))
            (ok (= del-status 403) "Should return 403 Forbidden")))))))

(deftest test-delete-tweet-requires-ownership
  (testing "DELETE /api/tweets/:id by non-owner returns 403"
    ;; ユーザー1がツイート作成
    (multiple-value-bind (cookie1 csrf1 username1) (register-and-get-session)
      (declare (ignore username1))
      (multiple-value-bind (body status headers)
          (twitter-like-test:json-post "/api/tweets"
                     (let ((h (make-hash-table :test 'equal)))
                       (setf (gethash "content" h) "Owner's tweet")
                       h)
                     :headers `(("cookie" . ,cookie1)
                                ("x-csrf-token" . ,csrf1)))
        (declare (ignore headers))
        (ok (= status 201))
        (let* ((response (com.inuoe.jzon:parse body))
               (tweet-id (gethash "id" (gethash "tweet" response))))
          ;; ユーザー2が削除しようとする
          (multiple-value-bind (cookie2 csrf2 username2) (register-and-get-session)
            (declare (ignore username2))
            (multiple-value-bind (del-body del-status del-headers)
                (twitter-like-test:safe-delete
                  (format nil "/api/tweets/~A" tweet-id)
                  :headers `(("cookie" . ,cookie2)
                             ("x-csrf-token" . ,csrf2)))
              (declare (ignore del-body del-headers))
              (ok (= del-status 403) "Should return 403 Forbidden"))))))))

(deftest test-delete-tweet-happy-path
  (testing "DELETE /api/tweets/:id by owner returns 200"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      (declare (ignore username))
      ;; ツイートを作成
      (multiple-value-bind (create-body create-status create-headers)
          (twitter-like-test:json-post "/api/tweets"
                     (let ((h (make-hash-table :test 'equal)))
                       (setf (gethash "content" h) "Tweet to delete")
                       h)
                     :headers `(("cookie" . ,cookie)
                                ("x-csrf-token" . ,csrf)))
        (declare (ignore create-headers))
        (ok (= create-status 201))
        (let* ((create-response (com.inuoe.jzon:parse create-body))
               (tweet-id (gethash "id" (gethash "tweet" create-response))))
          ;; 作成したツイートを削除
          (multiple-value-bind (del-body del-status del-headers)
              (twitter-like-test:safe-delete
                (format nil "/api/tweets/~A" tweet-id)
                :headers `(("cookie" . ,cookie)
                           ("x-csrf-token" . ,csrf)))
            (declare (ignore del-headers))
            (ok (= del-status 200) "Should return 200 OK")
            (let ((response (com.inuoe.jzon:parse del-body)))
              (ok (gethash "message" response)
                  "Response should contain message")))
          ;; 削除後に取得を試みる
          (multiple-value-bind (get-body get-status get-headers)
              (twitter-like-test:safe-get (format nil "/api/tweets/~A" tweet-id))
            (declare (ignore get-body get-headers))
            (ok (= get-status 404) "Tweet should be deleted")))))))

;;; ============================================================
;;; GET /api/users/:username/tweets テスト
;;; ============================================================

(deftest test-get-user-tweets-user-not-found
  (testing "GET /api/users/:username/tweets with non-existent user returns 404"
    (multiple-value-bind (body status headers)
        (twitter-like-test:safe-get "/api/users/nonexistent_user_12345/tweets")
      (declare (ignore body headers))
      (ok (= status 404) "Should return 404 Not Found"))))

(deftest test-get-user-tweets-happy-path
  (testing "GET /api/users/:username/tweets returns tweets with pagination"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      ;; 複数のツイートを作成
      (loop for i from 1 to 3
            do (twitter-like-test:json-post "/api/tweets"
                          (let ((h (make-hash-table :test 'equal)))
                            (setf (gethash "content" h)
                                  (format nil "Tweet ~A" i))
                            h)
                          :headers `(("cookie" . ,cookie)
                                     ("x-csrf-token" . ,csrf))))
      ;; ユーザーのツイート一覧を取得
      (multiple-value-bind (body status headers)
          (twitter-like-test:safe-get (format nil "/api/users/~A/tweets" username))
        (declare (ignore headers))
        (ok (= status 200) "Should return 200 OK")
        (let ((response (com.inuoe.jzon:parse body)))
          (ok (gethash "tweets" response) "Response should contain tweets")
          (ok (>= (length (gethash "tweets" response)) 3)
              "Should have at least 3 tweets")
          (ok (gethash "pagination" response)
              "Response should contain pagination"))))))

(deftest test-get-user-tweets-pagination
  (testing "GET /api/users/:username/tweets respects limit parameter"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      ;; 5件のツイートを作成
      (loop for i from 1 to 5
            do (twitter-like-test:json-post "/api/tweets"
                          (let ((h (make-hash-table :test 'equal)))
                            (setf (gethash "content" h)
                                  (format nil "Pagination test ~A" i))
                            h)
                          :headers `(("cookie" . ,cookie)
                                     ("x-csrf-token" . ,csrf))))
      ;; limit=2でツイート一覧を取得
      (multiple-value-bind (body status headers)
          (twitter-like-test:safe-get (format nil "/api/users/~A/tweets?limit=2" username))
        (declare (ignore headers))
        (ok (= status 200) "Should return 200 OK")
        (let ((response (com.inuoe.jzon:parse body)))
          (ok (= (length (gethash "tweets" response)) 2)
              "Should return exactly 2 tweets")
          (let ((pagination (gethash "pagination" response)))
            (ok (= (gethash "limit" pagination) 2)
                "Limit should be 2")
            (ok (gethash "has_more" pagination)
                "Should have more tweets")))))))

;;; ============================================================
;;; 無効パラメータテスト（Phase 2）
;;; ============================================================

(deftest test-get-user-tweets-non-integer-max-id
  (testing "GET /api/users/:username/tweets with non-integer max_id returns 400"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      (declare (ignore cookie csrf))
      (multiple-value-bind (body status headers)
          (twitter-like-test:safe-get
            (format nil "/api/users/~A/tweets?max_id=abc" username))
        (declare (ignore body headers))
        (ok (= status 400) "Should return 400 Bad Request for non-integer max_id")))))

(deftest test-get-user-tweets-non-integer-since-id
  (testing "GET /api/users/:username/tweets with non-integer since_id returns 400"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      (declare (ignore cookie csrf))
      (multiple-value-bind (body status headers)
          (twitter-like-test:safe-get
            (format nil "/api/users/~A/tweets?since_id=abc" username))
        (declare (ignore body headers))
        (ok (= status 400) "Should return 400 Bad Request for non-integer since_id")))))

(deftest test-get-user-tweets-non-integer-count
  (testing "GET /api/users/:username/tweets with non-integer count returns 400"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      (declare (ignore cookie csrf))
      (multiple-value-bind (body status headers)
          (twitter-like-test:safe-get
            (format nil "/api/users/~A/tweets?count=abc" username))
        (declare (ignore body headers))
        (ok (= status 400) "Should return 400 Bad Request for non-integer count")))))

(deftest test-get-user-tweets-overflow-max-id
  (testing "GET /api/users/:username/tweets with overflow max_id returns 400"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      (declare (ignore cookie csrf))
      ;; bigint 範囲超過（9223372036854775807 = 2^63-1）
      (multiple-value-bind (body status headers)
          (twitter-like-test:safe-get
            (format nil "/api/users/~A/tweets?max_id=99999999999999999999999" username))
        (declare (ignore body headers))
        (ok (= status 400) "Should return 400 Bad Request for overflow max_id")))))

;;; ============================================================
;;; レート制限テスト（POST /api/tweets 429）
;;; ============================================================

(defun simulate-rate-limit-exceeded (user-id)
  "レート制限超過をシミュレート（Redisに直接カウントを設定）"
  (let* ((now (twitter-like.util.time:get-unix-time))
         (key (format nil "rate:tweet:user:~A" user-id)))
    ;; 61件のエントリを追加（制限は60件）
    (loop for i from 1 to 61
          do (red:zadd key (- now i) (format nil "~A" (- now i))))
    ;; TTLを設定
    (red:expire key 3600)))

(deftest test-create-tweet-rate-limit
  (testing "POST /api/tweets returns 429 with Retry-After header when rate limited"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      (declare (ignore username))
      ;; /api/auth/me でuser_idを取得
      (multiple-value-bind (me-body me-status me-headers)
          (dex:get (make-url "/api/auth/me")
                   :headers `(("cookie" . ,cookie)))
        (declare (ignore me-status me-headers))
        (let* ((me-response (com.inuoe.jzon:parse me-body))
               (user-id (gethash "id" (gethash "user" me-response))))
          ;; レート制限超過をシミュレート
          (simulate-rate-limit-exceeded user-id)
          ;; ツイート投稿を試みる
          (multiple-value-bind (body status headers)
              (twitter-like-test:json-post "/api/tweets"
                         (let ((h (make-hash-table :test 'equal)))
                           (setf (gethash "content" h) "This should be rate limited")
                           h)
                         :headers `(("cookie" . ,cookie)
                                    ("x-csrf-token" . ,csrf)))
            (ok (= status 429) "Should return 429 Too Many Requests")
            ;; Retry-After ヘッダーの確認
            (ok (gethash "retry-after" headers)
                "Should have Retry-After header")
            ;; X-RateLimit-* ヘッダーの確認
            (ok (gethash "x-ratelimit-limit" headers)
                "Should have X-RateLimit-Limit header")
            (ok (gethash "x-ratelimit-remaining" headers)
                "Should have X-RateLimit-Remaining header")
            (ok (string= (gethash "x-ratelimit-remaining" headers) "0")
                "X-RateLimit-Remaining should be 0")
            (ok (gethash "x-ratelimit-reset" headers)
                "Should have X-RateLimit-Reset header")
            ;; エラーメッセージの確認
            (let ((response (com.inuoe.jzon:parse body)))
              (ok (gethash "error" response)
                  "Should have error message"))))))))

;;; ============================================================
;;; Content-Type検証テスト（POST /api/tweets 415）
;;; ============================================================

(deftest test-create-tweet-invalid-content-type
  (testing "POST /api/tweets with text/plain returns 415"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      (declare (ignore username))
      (multiple-value-bind (body status headers)
          (handler-case
              (dex:post (make-url "/api/tweets")
                        :headers `(("Content-Type" . "text/plain")
                                   ("Connection" . "close")
                                   ("cookie" . ,cookie)
                                   ("x-csrf-token" . ,csrf))
                        :content "Hello, Twitter!")
            (dexador.error:http-request-failed (e)
              (values (dexador:response-body e)
                      (dexador:response-status e)
                      (dexador:response-headers e))))
        (declare (ignore body headers))
        (ok (= status 415) "Should return 415 Unsupported Media Type")))))

;;; ============================================================
;;; 絵文字文字数カウントテスト
;;; ============================================================

(deftest test-create-tweet-emoji-counts-as-two
  (testing "POST /api/tweets with 70 emojis (=140 chars) succeeds"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      (declare (ignore username))
      ;; 70個の絵文字 = 70 × 2 = 140文字
      (let ((emoji-content (format nil "~{~A~}" (loop repeat 70 collect "👍"))))
        (multiple-value-bind (body status headers)
            (twitter-like-test:json-post "/api/tweets"
                       (let ((h (make-hash-table :test 'equal)))
                         (setf (gethash "content" h) emoji-content)
                         h)
                       :headers `(("cookie" . ,cookie)
                                  ("x-csrf-token" . ,csrf)))
          (declare (ignore headers body))
          (ok (= status 201) "Should return 201 Created"))))))

(deftest test-create-tweet-emoji-over-limit
  (testing "POST /api/tweets with 71 emojis (=142 chars) returns 400"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      (declare (ignore username))
      ;; 71個の絵文字 = 71 × 2 = 142文字
      (let ((emoji-content (format nil "~{~A~}" (loop repeat 71 collect "👍"))))
        (multiple-value-bind (body status headers)
            (twitter-like-test:json-post "/api/tweets"
                       (let ((h (make-hash-table :test 'equal)))
                         (setf (gethash "content" h) emoji-content)
                         h)
                       :headers `(("cookie" . ,cookie)
                                  ("x-csrf-token" . ,csrf)))
          (declare (ignore headers))
          (ok (= status 400) "Should return 400 Bad Request")
          (let ((response (com.inuoe.jzon:parse body)))
            (ok (search "140" (gethash "error" response))
                "Error message should mention 140 character limit")))))))

;;; ============================================================
;;; 無効パラメータテスト（残り）
;;; ============================================================

(deftest test-get-user-tweets-invalid-limit
  (testing "GET /api/users/:username/tweets with limit=200 uses default"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      (declare (ignore cookie csrf))
      ;; limit=200（範囲外）→ デフォルト20にフォールバック
      (multiple-value-bind (body status headers)
          (twitter-like-test:safe-get
            (format nil "/api/users/~A/tweets?limit=200" username))
        (declare (ignore headers))
        (ok (= status 200) "Should return 200 OK")
        (let* ((response (com.inuoe.jzon:parse body))
               (pagination (gethash "pagination" response)))
          (ok (= (gethash "limit" pagination) 20)
              "Should use default limit 20"))))))

(deftest test-get-user-tweets-non-integer-limit
  (testing "GET /api/users/:username/tweets with limit=abc returns 400"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      (declare (ignore cookie csrf))
      ;; limit=abc（非整数）→ 400エラー
      (multiple-value-bind (body status headers)
          (twitter-like-test:safe-get
            (format nil "/api/users/~A/tweets?limit=abc" username))
        (declare (ignore body headers))
        (ok (= status 400) "Should return 400 Bad Request for non-integer limit")))))

(deftest test-get-user-tweets-invalid-count
  (testing "GET /api/users/:username/tweets with count=200 uses default"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      (declare (ignore cookie csrf))
      ;; count=200（上限100を超過）→ デフォルト20にフォールバック
      (multiple-value-bind (body status headers)
          (twitter-like-test:safe-get
            (format nil "/api/users/~A/tweets?count=200" username))
        (declare (ignore headers))
        (ok (= status 200) "Should return 200 OK")
        (let* ((response (com.inuoe.jzon:parse body))
               (pagination (gethash "pagination" response)))
          (ok (= (gethash "count" pagination) 20)
              "Should use default count 20 for out-of-range value"))))))

(deftest test-get-user-tweets-non-integer-offset
  (testing "GET /api/users/:username/tweets with offset=abc returns 400"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      (declare (ignore cookie csrf))
      ;; offset=abc（非整数）→ 400エラー
      (multiple-value-bind (body status headers)
          (twitter-like-test:safe-get
            (format nil "/api/users/~A/tweets?offset=abc" username))
        (declare (ignore body headers))
        (ok (= status 400) "Should return 400 Bad Request for non-integer offset")))))

;;; ============================================================
;;; カーソルページネーション成功系テスト（Phase 2）
;;; ============================================================

(deftest test-cursor-pagination-with-max-id
  (testing "GET /api/users/:username/tweets with count returns correct cursors"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      ;; 5件のツイートを作成
      (let ((created-ids nil))
        (loop for i from 1 to 5
              do (multiple-value-bind (body status headers)
                     (twitter-like-test:json-post "/api/tweets"
                                (let ((h (make-hash-table :test 'equal)))
                                  (setf (gethash "content" h)
                                        (format nil "Cursor test ~A" i))
                                  h)
                                :headers `(("cookie" . ,cookie)
                                           ("x-csrf-token" . ,csrf)))
                   (declare (ignore headers))
                   (when (= status 201)
                     (let ((tweet (gethash "tweet" (com.inuoe.jzon:parse body))))
                       (when tweet
                         (push (gethash "id" tweet) created-ids))))))
        (ok (>= (length created-ids) 5) "Should have created 5 tweets")
        ;; 最初のページを取得（count=2）
        (multiple-value-bind (body status headers)
            (twitter-like-test:safe-get
              (format nil "/api/users/~A/tweets?count=2" username))
          (declare (ignore headers))
          (ok (= status 200) "First page should return 200 OK")
          (when (= status 200)
            (let* ((response (com.inuoe.jzon:parse body))
                   (tweets (gethash "tweets" response))
                   (cursors (gethash "cursors" response))
                   (pagination (gethash "pagination" response)))
              (ok (>= (length tweets) 2) "First page should have at least 2 tweets")
              (ok pagination "Should have pagination object")
              (ok cursors "Should have cursors object")
              (when pagination
                (ok (gethash "has_more" pagination) "Should have more tweets")))))))))

(deftest test-cursor-pagination-with-since-id
  (testing "GET /api/users/:username/tweets with since_id returns filtered tweets"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      ;; 3件のツイートを作成し、IDを記録
      (let ((created-ids nil))
        (loop for i from 1 to 3
              do (multiple-value-bind (body status headers)
                     (twitter-like-test:json-post "/api/tweets"
                                (let ((h (make-hash-table :test 'equal)))
                                  (setf (gethash "content" h)
                                        (format nil "Since test ~A" i))
                                  h)
                                :headers `(("cookie" . ,cookie)
                                           ("x-csrf-token" . ,csrf)))
                   (declare (ignore headers))
                   (when (= status 201)
                     (let ((tweet (gethash "tweet" (com.inuoe.jzon:parse body))))
                       (when tweet
                         (push (gethash "id" tweet) created-ids))))))
        (ok (>= (length created-ids) 3) "Should have created 3 tweets")
        ;; created-ids は新しい順（ID大→小）になっている
        ;; 一番古い（最初に作成された）ツイートのIDを取得
        (when (>= (length created-ids) 3)
          (let ((oldest-id (first (last created-ids))))  ; 最小ID
            (multiple-value-bind (body status headers)
                (twitter-like-test:safe-get
                  (format nil "/api/users/~A/tweets?since_id=~A" username oldest-id))
              (declare (ignore headers))
              (ok (= status 200) "Should return 200 OK")
              (when (= status 200)
                (let* ((response (com.inuoe.jzon:parse body))
                       (tweets (gethash "tweets" response)))
                  ;; since_id より大きいIDのツイートのみ返される（2件）
                  (ok (= (length tweets) 2) "Should return 2 tweets newer than since_id"))))))))))

(deftest test-offset-too-large
  (testing "GET /api/users/:username/tweets with offset > 10000 returns 400"
    (multiple-value-bind (cookie csrf username) (register-and-get-session)
      (declare (ignore cookie csrf))
      ;; offset=10001（上限超過）→ 400エラー
      (multiple-value-bind (body status headers)
          (twitter-like-test:safe-get
            (format nil "/api/users/~A/tweets?offset=10001" username))
        (declare (ignore headers))
        (ok (= status 400) "Should return 400 Bad Request for offset > 10000")
        (let ((response (com.inuoe.jzon:parse body)))
          (ok (search "10000" (gethash "error" response))
              "Error message should mention maximum offset"))))))
