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
           :+rate-limit-decrement-lua-script+))

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
