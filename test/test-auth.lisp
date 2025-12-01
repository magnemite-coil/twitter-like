(defpackage twitter-like-test.auth
  (:use :cl :rove)
  (:import-from :dexador)
  (:import-from :dexador.error)
  (:import-from :com.inuoe.jzon
                :parse
                :stringify))

(in-package :twitter-like-test.auth)

(defun make-url (path)
  (format nil "~A~A" (twitter-like-test:get-test-base-url) path))

(defun json-post (path payload &key headers)
  "シンプルなJSON POSTヘルパー"
  (handler-case
      (dex:post (make-url path)
                :headers (append '(("Content-Type" . "application/json")
                                   ("Connection" . "close"))
                                 headers)
                :content (com.inuoe.jzon:stringify payload))
    (dexador.error:http-request-failed (e)
      (values (dexador:response-body e)
              (dexador:response-status e)
              (dexador:response-headers e)))))

(defun safe-get (path &key headers)
  (handler-case
      (dex:get (make-url path)
               :headers (append '(("Connection" . "close")) headers))
    (dexador.error:http-request-failed (e)
      (values (dexador:response-body e)
              (dexador:response-status e)
              (dexador:response-headers e)))))

(defun extract-session-cookie (set-cookie-header)
  "Set-Cookieヘッダーから送信用Cookie文字列を抽出（最初のname=valueのみ）"
  (when set-cookie-header
    (let ((semicolon-pos (position #\; set-cookie-header)))
      (if semicolon-pos
          (subseq set-cookie-header 0 semicolon-pos)
          set-cookie-header))))

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
