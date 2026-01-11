(defpackage twitter-like.util.rate-limit
  (:use :cl)
  (:import-from :twitter-like.util.time
                :get-unix-time)
  (:import-from :ironclad
                :byte-array-to-hex-string
                :random-data)
  (:export :check-and-increment
           :decrement
           :increment
           :ensure-integer
           :+rate-limit-lua-script+
           :+rate-limit-decrement-lua-script+
           ;; IETF RateLimit structured headers (draft-ietf-httpapi-ratelimit-headers)
           :format-ratelimit-header
           :format-ratelimit-policy-header
           :build-ratelimit-headers))

(in-package :twitter-like.util.rate-limit)

(defparameter +rate-limit-lua-script+
  "local key = KEYS[1]
local now = tonumber(ARGV[1])
local window_start = tonumber(ARGV[2])
local limit = tonumber(ARGV[3])
local window = tonumber(ARGV[4])
local member = ARGV[5]
local increment_mode = ARGV[6]

redis.call('ZREMRANGEBYSCORE', key, '-inf', window_start)
local count = redis.call('ZCARD', key)

if count >= limit then
  local oldest = redis.call('ZRANGE', key, 0, 0, 'WITHSCORES')
  local reset_time = 0
  if oldest and #oldest >= 2 then
    reset_time = tonumber(oldest[2]) + window
  end
  return {0, 0, reset_time, ''}
else
  if increment_mode == 'always' or increment_mode == 'check' or increment_mode == 'optimistic' then
    redis.call('ZADD', key, now, member)
    redis.call('EXPIRE', key, window + 60)
    if increment_mode == 'optimistic' then
      return {1, limit - count - 1, 0, member}
    else
      return {1, limit - count - 1, 0, ''}
    end
  else
    return {1, limit - count, 0, ''}
  end
end")

(defparameter +rate-limit-decrement-lua-script+
  "local key = KEYS[1]
local member = ARGV[1]
local removed = redis.call('ZREM', key, member)
return removed")

(defun ensure-integer (val &optional (default 0))
  "値を整数に変換。文字列・数値に対応、nilやパース失敗時はdefaultを返す
   用途: Redis Luaスクリプトの戻り値の型正規化"
  (cond
    ((null val) default)
    ((integerp val) val)
    ((stringp val)
     (handler-case (parse-integer val :junk-allowed nil)
       (error () default)))
    (t default)))

(defun check-and-increment (action identifier-type identifier limit window
                            &key (increment-on :always))
  "汎用レート制限関数（スライディングウィンドウ + Lua原子的操作）

  引数:
    action          - アクション名（文字列: \"login\", \"tweet\", \"register\"等）
    identifier-type - 識別子の種類（:ip または :user）
    identifier      - 識別子の値（IPアドレス or ユーザーID）
    limit           - 許容回数
    window          - ウィンドウ幅（秒）
    increment-on    - カウント増加タイミング
                      :always     - 常に増加（デフォルト、register用）
                      :check      - チェック時に増加（tweet用）
                      :optimistic - 試行時にカウント、成功時にデクリメント（login用: 推奨）
                      :manual     - 非推奨: 原子性なし

  戻り値: (values allowed-p remaining reset-time member-id)"
  (let* ((key (format nil "rate:~A:~A:~A"
                      action
                      (string-downcase (symbol-name identifier-type))
                      identifier))
         (now (get-unix-time))
         (window-start (- now window))
         (member (format nil "~A:~A" now
                         (byte-array-to-hex-string (random-data 8))))
         (increment-mode (string-downcase (symbol-name increment-on)))
         (result (red:eval +rate-limit-lua-script+
                           1
                           key
                           (write-to-string now)
                           (write-to-string window-start)
                           (write-to-string limit)
                           (write-to-string window)
                           member
                           increment-mode)))
    (let ((allowed (ensure-integer (first result) 0))
          (remaining (ensure-integer (second result) 0))
          (reset-time (ensure-integer (third result) 0))
          (member-id (fourth result)))
      (values (= allowed 1)
              remaining
              (when (> reset-time 0) reset-time)
              (when (and (stringp member-id) (plusp (length member-id)))
                member-id)))))

(defun increment (action identifier-type identifier window)
  "レート制限カウントを手動で増加（非推奨: 原子性なし）"
  (let* ((key (format nil "rate:~A:~A:~A"
                      action
                      (string-downcase (symbol-name identifier-type))
                      identifier))
         (now (get-unix-time))
         (member (format nil "~A:~A" now
                         (byte-array-to-hex-string (random-data 8)))))
    (red:zadd key now member)
    (red:expire key (+ window 60))))

(defun decrement (action identifier-type identifier window member-id)
  "レート制限カウントを減少（:optimistic モード成功時用）

  引数:
    action          - アクション名（文字列: \"login\"等）
    identifier-type - 識別子の種類（:ip または :user）
    identifier      - 識別子の値（IPアドレス or ユーザーID）
    window          - ウィンドウ幅（秒）
    member-id       - check-and-increment の戻り値 member-id

  戻り値: t（成功）または nil（該当エントリなし）"
  (declare (ignore window))
  (let* ((key (format nil "rate:~A:~A:~A"
                      action
                      (string-downcase (symbol-name identifier-type))
                      identifier)))
    (let ((removed (red:eval +rate-limit-decrement-lua-script+
                             1
                             key
                             member-id)))
      (= (ensure-integer removed 0) 1))))

;;; ============================================================
;;; IETF RateLimit Structured Headers
;;; draft-ietf-httpapi-ratelimit-headers-09/10
;;; https://datatracker.ietf.org/doc/html/draft-ietf-httpapi-ratelimit-headers
;;; ============================================================

(defun format-ratelimit-header (remaining reset-seconds &optional (policy-name "default"))
  "IETF RateLimit構造化ヘッダーを生成（draft-ietf-httpapi-ratelimit-headers-09/10準拠）
   形式: \"default\";r=50;t=30

   引数:
     remaining     - 残り回数（quota units remaining）
     reset-seconds - リセットまでの秒数（delay-seconds）
     policy-name   - ポリシー識別子（デフォルト: \"default\"）

   戻り値: ヘッダー値の文字列
   参考: https://datatracker.ietf.org/doc/html/draft-ietf-httpapi-ratelimit-headers"
  (format nil "\"~A\";r=~A;t=~A"
          policy-name remaining reset-seconds))

(defun format-ratelimit-policy-header (limit window &optional (policy-name "default"))
  "IETF RateLimit-Policy構造化ヘッダーを生成（draft-ietf-httpapi-ratelimit-headers-09/10準拠）
   形式: \"default\";q=100;w=60

   引数:
     limit       - レート制限上限（quota allocated）
     window      - ウィンドウ幅（秒）
     policy-name - ポリシー識別子（デフォルト: \"default\"）

   戻り値: ヘッダー値の文字列
   参考: https://datatracker.ietf.org/doc/html/draft-ietf-httpapi-ratelimit-headers"
  (format nil "\"~A\";q=~A;w=~A"
          policy-name limit window))

(defun build-ratelimit-headers (limit remaining reset-time window &optional (now nil))
  "レート制限レスポンス用の全ヘッダーをplistで返す
   IETF標準ヘッダー（draft-09/10準拠） + 現行X-RateLimit-*ヘッダー（後方互換）

   引数:
     limit      - レート制限上限
     remaining  - 残り回数
     reset-time - リセット時刻（Unix epoch秒）
     window     - ウィンドウ幅（秒）
     now        - 現在時刻（省略時は自動取得）

   戻り値: plist形式のヘッダー
     (:ratelimit \"\\\"default\\\";r=50;t=30\"
      :ratelimit-policy \"\\\"default\\\";q=60;w=3600\"
      :retry-after \"30\"
      :x-ratelimit-limit \"60\"
      :x-ratelimit-remaining \"50\"
      :x-ratelimit-reset \"1704268800\")

   参考: https://datatracker.ietf.org/doc/html/draft-ietf-httpapi-ratelimit-headers"
  (let* ((current-time (or now (get-unix-time)))
         (reset-seconds (max 0 (- reset-time current-time))))
    (list :ratelimit (format-ratelimit-header remaining reset-seconds)
          :ratelimit-policy (format-ratelimit-policy-header limit window)
          :retry-after (write-to-string reset-seconds)
          :x-ratelimit-limit (write-to-string limit)
          :x-ratelimit-remaining (write-to-string remaining)
          :x-ratelimit-reset (write-to-string reset-time))))
