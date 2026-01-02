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
