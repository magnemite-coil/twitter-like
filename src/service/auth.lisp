(defpackage twitter-like.service.auth
  (:use :cl)
  (:import-from :cl-ppcre
                :scan)
  (:import-from :twitter-like.util.rate-limit
                :check-and-increment
                :decrement)
  (:export :validate-username
           :validate-password
           :register-user
           :authenticate-user
           :check-rate-limit
           :check-login-rate-limit
           :decrement-login-rate-limit
           :check-register-rate-limit
           :check-account-lockout
           :record-login-failure
           :clear-login-failures
           ;; Rate limit constants (for handler layer IETF headers)
           :+login-rate-limit+
           :+login-rate-window+
           :+register-rate-limit+
           :+register-rate-window+
           ;; Lockout threshold constant (for test assertions)
           :+lockout-threshold+))

(in-package :twitter-like.service.auth)

;;; ============================================================
;;; バリデーション（設計書5.5参照）
;;; ============================================================

(defun validate-username (username)
  "ユーザー名のバリデーション
  - 必須
  - 3-20文字
  - 英数字とアンダースコアのみ
  戻り値: (values valid-p error-message)"
  (cond
    ((not (stringp username))
     (values nil "Username is required"))
    ((< (length username) 3)
     (values nil "Username must be at least 3 characters"))
    ((> (length username) 20)
     (values nil "Username must be at most 20 characters"))
    ((not (ppcre:scan "^[a-zA-Z0-9_]+$" username))
     (values nil "Username can only contain letters, numbers, and underscores"))
    (t
     (values t nil))))

(defun validate-password (password)
  "パスワードのバリデーション
  - 必須
  - 15文字以上、128文字以下
  戻り値: (values valid-p error-message)"
  (cond
    ((not (stringp password))
     (values nil "Password is required"))
    ((< (length password) 15)
     (values nil "Password must be at least 15 characters"))
    ((> (length password) 128)
     (values nil "Password must be at most 128 characters"))
    (t
     (values t nil))))

;;; ============================================================
;;; レート制限（設計書5.4参照）
;;; ============================================================

(defconstant +login-rate-limit+ 5
  "ログイン試行回数上限/15分")

(defconstant +login-rate-window+ 900
  "ログインレート制限ウィンドウ: 15分（秒）")

(defconstant +register-rate-limit+ 3
  "登録試行回数上限/1時間")

(defconstant +register-rate-window+ 3600
  "登録レート制限ウィンドウ: 1時間（秒）")

(defconstant +lockout-threshold+ 5
  "アカウントロックアウト閾値")

(defconstant +lockout-duration+ 1800
  "アカウントロック期間: 30分（秒）")

(defun check-rate-limit (key-type identifier &key (limit +login-rate-limit+) (window +login-rate-window+))
  "レート制限をチェック
  key-type: :login または :register
  identifier: IPアドレス等
  戻り値: (values allowed-p remaining-count)"
  (let* ((key (format nil "rate:~A:ip:~A" key-type identifier))
         (current-count-str (red:get key))
         (current-count (if current-count-str (parse-integer current-count-str :junk-allowed t) 0)))
    (if (>= current-count limit)
        (values nil 0)
        (values t (- limit current-count)))))

(defun increment-rate-limit (key-type identifier &key (window +login-rate-window+))
  "レート制限カウントを増加
   DEPRECATED: 新しいコードでは check-login-rate-limit / check-register-rate-limit を使用してください"
  (let* ((key (format nil "rate:~A:ip:~A" key-type identifier))
         (current-count-str (red:get key))
         (current-count (if current-count-str (parse-integer current-count-str :junk-allowed t) 0)))
    (red:setex key window (write-to-string (1+ current-count)))))

;;; ============================================================
;;; 新レート制限関数（Phase 2: util/rate-limit.lisp ラッパー）
;;; ============================================================

(defun check-login-rate-limit (ip-address)
  "ログインレート制限（:optimistic モード: 試行時にカウント、成功時にデクリメント）
   戻り値: (values allowed-p remaining reset-time member-id)
   - allowed-p: 許可されたか
   - remaining: 残り回数
   - reset-time: リセット時刻（制限超過時のみ）
   - member-id: 成功時のデクリメント用ID（decrement-login-rate-limit に渡す）"
  (check-and-increment "login" :ip ip-address
                       +login-rate-limit+ +login-rate-window+
                       :increment-on :optimistic))

(defun decrement-login-rate-limit (ip-address member-id)
  "ログイン成功時にカウントをデクリメント（:optimistic モード用）
   引数:
     ip-address - IPアドレス
     member-id  - check-login-rate-limit で取得した member-id
   戻り値: t（成功）または nil（該当エントリなし）"
  (decrement "login" :ip ip-address +login-rate-window+ member-id))

(defun check-register-rate-limit (ip-address)
  "登録レート制限（:always モード: 常にカウント）
   戻り値: (values allowed-p remaining reset-time)
   - allowed-p: 許可されたか
   - remaining: 残り回数
   - reset-time: リセット時刻（制限超過時のみ）"
  (check-and-increment "register" :ip ip-address
                       +register-rate-limit+ +register-rate-window+
                       :increment-on :always))

;;; ============================================================
;;; アカウントロックアウト（設計書5.4参照）
;;; ============================================================

(defun check-account-lockout (username)
  "アカウントロックアウトをチェック
  戻り値: (values locked-p remaining-seconds)"
  (let* ((locked-key (format nil "lockout:user:~A:locked_until" username))
         (locked-until-str (red:get locked-key)))
    (if locked-until-str
        (let* ((locked-until (parse-integer locked-until-str :junk-allowed t))
               (now (twitter-like.middleware.session:get-unix-time))
               (remaining (- locked-until now)))
          (if (> remaining 0)
              (values t remaining)
              (progn
                ;; ロック期間終了、キーを削除
                (red:del locked-key)
                (red:del (format nil "lockout:user:~A:count" username))
                (values nil 0))))
        (values nil 0))))

(defun record-login-failure (username)
  "ログイン失敗を記録、閾値超えでロックアウト
  戻り値: (values locked-p failure-count)"
  (let* ((count-key (format nil "lockout:user:~A:count" username))
         (current-count-str (red:get count-key))
         (current-count (if current-count-str (parse-integer current-count-str :junk-allowed t) 0))
         (new-count (1+ current-count)))
    ;; カウントを更新（ロックアウト期間中は期限を維持）
    (red:setex count-key +lockout-duration+ (write-to-string new-count))

    (if (>= new-count +lockout-threshold+)
        (let* ((now (twitter-like.middleware.session:get-unix-time))
               (locked-until (+ now +lockout-duration+))
               (locked-key (format nil "lockout:user:~A:locked_until" username)))
          (red:setex locked-key +lockout-duration+ (write-to-string locked-until))
          (values t new-count))
        (values nil new-count))))

(defun clear-login-failures (username)
  "ログイン成功時に失敗カウントをクリア"
  (red:del (format nil "lockout:user:~A:count" username))
  (red:del (format nil "lockout:user:~A:locked_until" username)))

;;; ============================================================
;;; ユーザー登録
;;; ============================================================

(defun register-user (username password)
  "ユーザーを登録
  戻り値: (values user error-message error-type internal-error-detail)
  - 成功時: (values user nil nil nil)
  - バリデーション失敗時: (values nil error-message :validation nil)
  - 内部エラー時: (values nil generic-message :internal detail-for-logging)"
  ;; バリデーション
  (multiple-value-bind (valid-username username-error) (validate-username username)
    (unless valid-username
      (return-from register-user (values nil username-error :validation nil))))

  (multiple-value-bind (valid-password password-error) (validate-password password)
    (unless valid-password
      (return-from register-user (values nil password-error :validation nil))))

  ;; ユーザー名の重複チェック
  (when (twitter-like.model.user:find-user-by-username username)
    (return-from register-user (values nil "Username already exists" :validation nil)))

  ;; パスワードハッシュ化とユーザー作成
  (handler-case
      (let* ((password-hash (twitter-like.util.crypto:hash-password password))
             (hash-string (ironclad:byte-array-to-hex-string password-hash))
             (user (twitter-like.model.user:create-user username hash-string)))
        (values user nil nil nil))
    (error (e)
      ;; 内部例外: クライアントには汎用メッセージ、ログには詳細
      (values nil "Registration failed" :internal (format nil "~A" e)))))

;;; ============================================================
;;; 認証
;;; ============================================================

(defun authenticate-user (username password)
  "ユーザー認証
  戻り値: (values user error-message)
  - 成功時: (values user nil)
  - 失敗時: (values nil error-message)

  セキュリティ: タイミング攻撃対策として、ユーザー存在有無に関わらず
  同等の処理時間を確保（ダミーハッシュ検証）"
  (let ((user (twitter-like.model.user:find-user-by-username username)))
    (if user
        ;; ユーザーが存在する場合
        (let* ((stored-hash-str (twitter-like.model.user:user-password user))
               (stored-hash (ironclad:hex-string-to-byte-array stored-hash-str))
               (valid (twitter-like.util.crypto:verify-password password stored-hash)))
          (if valid
              (values user nil)
              (values nil "Invalid username or password")))
        ;; ユーザーが存在しない場合でもダミーハッシュ検証を実行（タイミング攻撃対策）
        (progn
          (let ((dummy-hash (twitter-like.util.crypto:hash-password "dummy-password-for-timing")))
            (twitter-like.util.crypto:verify-password password dummy-hash))
          (values nil "Invalid username or password")))))
