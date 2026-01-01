;;; src/service/tweet.lisp

(defpackage twitter-like.service.tweet
  (:use :cl)
  (:import-from :babel
                :string-to-octets)
  (:import-from :twitter-like.model.tweet
                :find-tweet-by-id
                :find-tweets-by-user-id
                :create-tweet-record
                :delete-tweet-record
                :tweet-user-id)
  (:import-from :twitter-like.util.logger
                :log-error)
  (:import-from :twitter-like.util.time
                :get-unix-time)
  (:import-from :ironclad
                :byte-array-to-hex-string
                :random-data)
  (:export :count-tweet-chars
           :validate-content
           :create-tweet
           :delete-tweet
           :get-tweet-by-id
           :get-tweets-by-user
           :check-and-increment-rate-limit
           :+tweet-rate-limit+
           :+tweet-rate-window+
           :get-unix-time))

(in-package :twitter-like.service.tweet)

;;; ============================================================
;;; レート制限（OWASP準拠 - スライディングウィンドウ + Lua原子的操作）
;;; ============================================================

(defconstant +tweet-rate-limit+ 60
  "ツイート投稿回数上限/1時間")

(defconstant +tweet-rate-window+ 3600
  "ツイートレート制限ウィンドウ: 1時間（秒）")

;;; Redis Luaスクリプト（原子的レート制限）
;;; ZREMRANGEBYSCORE → ZCARD → 条件付きZADD → EXPIRE を一括実行
(defparameter +rate-limit-lua-script+
  "local key = KEYS[1]
local now = tonumber(ARGV[1])
local window_start = tonumber(ARGV[2])
local limit = tonumber(ARGV[3])
local window = tonumber(ARGV[4])
local member = ARGV[5]

-- 古いエントリを削除
redis.call('ZREMRANGEBYSCORE', key, '-inf', window_start)

-- 現在のカウントを取得
local count = redis.call('ZCARD', key)

if count >= limit then
  -- 制限超過: 最古のエントリのスコアを取得してreset_timeを計算
  local oldest = redis.call('ZRANGE', key, 0, 0, 'WITHSCORES')
  local reset_time = 0
  if oldest and #oldest >= 2 then
    reset_time = tonumber(oldest[2]) + window
  end
  return {0, 0, reset_time}  -- {allowed=0, remaining=0, reset_time}
else
  -- 許可: カウントを増加
  redis.call('ZADD', key, now, member)
  redis.call('EXPIRE', key, window + 60)
  return {1, limit - count - 1, 0}  -- {allowed=1, remaining, reset_time=0}
end")

(defun check-and-increment-rate-limit (user-id)
  "ツイート投稿のレート制限をチェックし、許可された場合はカウントを増加（原子的）

  注意: Redis Luaスクリプトにより、チェックとインクリメントを原子的に実行。
  レースコンディションを防止し、同時投稿での上限超過を防ぐ。

  戻り値: (values allowed-p remaining-count reset-time)"
  (let* ((key (format nil "rate:tweet:user:~A" user-id))
         (now (get-unix-time))
         (window-start (- now +tweet-rate-window+))
         ;; member は Sorted Set 内で一意である必要がある
         ;; CSPRNG を使用して衝突を防止（8バイト = 16進数16文字）
         (member (format nil "~A:~A" now
                         (byte-array-to-hex-string
                           (random-data 8))))
         ;; Luaスクリプトを実行（EVAL）
         (result (red:eval +rate-limit-lua-script+
                           1  ; KEYSの数
                           key
                           (write-to-string now)
                           (write-to-string window-start)
                           (write-to-string +tweet-rate-limit+)
                           (write-to-string +tweet-rate-window+)
                           member)))
    ;; result は (allowed remaining reset_time) のリスト
    (let ((allowed (first result))
          (remaining (second result))
          (reset-time (third result)))
      (values (= allowed 1)
              remaining
              (when (> reset-time 0) reset-time)))))

;;; ============================================================
;;; 文字数カウント（Twitter互換 - 絵文字2カウント）
;;; ============================================================

(defun count-tweet-chars (text)
  "UTF-16コードユニット単位で文字数をカウント

  現在のTwitter（X）と同様に、絵文字を2カウントとして扱います:
  - 通常の文字（BMP）: 1文字 = 1カウント
  - 絵文字等（サロゲートペア）: 1文字 = 2カウント

  例:
  - \"Hello\" → 5
  - \"你好世界\" → 4
  - \"👍\" → 2（サロゲートペア D83D DC4D）"
  (let ((utf16-bytes (string-to-octets text :encoding :utf-16le)))
    (/ (length utf16-bytes) 2)))

;;; ============================================================
;;; バリデーション
;;; ============================================================

(defun validate-content (content)
  "ツイート本文のバリデーション
  戻り値: (values valid-p error-message)"
  (cond
    ((not (stringp content))
     (values nil "Content is required"))
    ((zerop (length content))
     (values nil "Content cannot be empty"))
    ((> (count-tweet-chars content) 140)
     (values nil "Content must be 140 characters or less"))
    (t
     (values t nil))))

;;; ============================================================
;;; ツイート操作
;;; ============================================================

(defun create-tweet (user-id content)
  "新規ツイートを作成
  戻り値: (values tweet error-message error-type error-id)
  error-type: :validation（バリデーションエラー）または :internal（内部エラー）
  error-id: 内部エラー時のみ付与（サポート問い合わせ用）"
  (multiple-value-bind (valid-p error-message) (validate-content content)
    (unless valid-p
      (return-from create-tweet (values nil error-message :validation nil))))
  (handler-case
      (let ((tweet (create-tweet-record user-id content)))
        (values tweet nil nil nil))
    (error (e)
      ;; 内部エラー: 詳細はservice層でログに記録し、クライアントには汎用メッセージのみ返す
      ;; セキュリティ: 例外詳細はログのみに記録（クライアントに漏洩させない）
      (let ((error-id (log-error "Tweet creation failed"
                                  :context (list :|user_id| user-id
                                                 :|error| (princ-to-string e)))))
        (values nil "An internal error occurred" :internal error-id)))))

(defun delete-tweet (tweet-id user-id)
  "ツイートを削除（所有権チェック付き）
  戻り値: (values success-p error-message error-type error-id)
  error-id: 内部エラー時のみ付与（サポート問い合わせ用）"
  (let ((tweet (find-tweet-by-id tweet-id)))
    (unless tweet
      (return-from delete-tweet (values nil "Tweet not found" :not-found nil)))
    (unless (= (tweet-user-id tweet) user-id)
      (return-from delete-tweet (values nil "Not authorized" :forbidden nil)))
    (handler-case
        (progn
          (delete-tweet-record tweet)
          (values t nil nil nil))
      (error (e)
        ;; 内部エラー: 詳細はservice層でログに記録し、クライアントには汎用メッセージのみ返す
        ;; セキュリティ: 例外詳細はログのみに記録（クライアントに漏洩させない）
        (let ((error-id (log-error "Tweet deletion failed"
                                    :context (list :|tweet_id| tweet-id
                                                   :|user_id| user-id
                                                   :|error| (princ-to-string e)))))
          (values nil "An internal error occurred" :internal error-id))))))

(defun get-tweet-by-id (tweet-id)
  "IDでツイートを取得"
  (find-tweet-by-id tweet-id))

(defun get-tweets-by-user (user-id &key (limit 20) (offset 0))
  "ユーザーのツイート一覧を取得"
  (find-tweets-by-user-id user-id :limit limit :offset offset))
