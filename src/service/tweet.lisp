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
  (:import-from :twitter-like.model.user
                :find-user-by-username)
  (:import-from :twitter-like.util.logger
                :log-error)
  (:import-from :twitter-like.util.time
                :get-unix-time
                :format-timestamp)
  (:import-from :twitter-like.util.json
                :value-or-json-null)
  (:import-from :twitter-like.util.rate-limit
                :check-and-increment)
  (:import-from :ironclad
                :byte-array-to-hex-string
                :random-data)
  (:export :count-tweet-chars
           :validate-content
           :create-tweet
           :delete-tweet
           :get-tweet-by-id
           :get-tweets-by-user
           :get-user-by-username
           :check-and-increment-rate-limit
           :+tweet-rate-limit+
           :+tweet-rate-window+
           :get-unix-time
           ;; Phase 2
           :find-tweets-with-user-by-user-id
           :get-tweets-by-user-with-user-info))

(in-package :twitter-like.service.tweet)

;;; ============================================================
;;; レート制限（OWASP準拠 - スライディングウィンドウ + Lua原子的操作）
;;; ============================================================

(defconstant +tweet-rate-limit+ 60
  "ツイート投稿回数上限/1時間")

(defconstant +tweet-rate-window+ 3600
  "ツイートレート制限ウィンドウ: 1時間（秒）")

(defun check-and-increment-rate-limit (user-id)
  "ツイート投稿のレート制限（後方互換ラッパー）
  Phase 2: util/rate-limit.lisp の汎用関数を使用

  戻り値: (values allowed-p remaining-count reset-time)"
  (multiple-value-bind (allowed-p remaining reset-time member-id)
      (check-and-increment "tweet" :user user-id
                           +tweet-rate-limit+ +tweet-rate-window+
                           :increment-on :check)
    (declare (ignore member-id))
    (values allowed-p remaining reset-time)))

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

(defun get-user-by-username (username)
  "ユーザー名でユーザーを取得
  handler → service → model のレイヤー構造を維持するためのラッパー関数"
  (find-user-by-username username))

;;; ============================================================
;;; Phase 2: N+1クエリ解消（JOINによる一括取得）
;;; ============================================================

(defun row-to-tweet-json (row)
  "JOIN結果の行をJSON形式のハッシュテーブルに変換"
  (let ((tweet-json (make-hash-table :test 'equal))
        (user-json (make-hash-table :test 'equal)))
    ;; Tweet部分
    (setf (gethash "id" tweet-json) (getf row :|id|))
    (setf (gethash "user_id" tweet-json) (getf row :|user_id|))
    (setf (gethash "content" tweet-json) (getf row :|content|))
    (setf (gethash "created_at" tweet-json) (format-timestamp (getf row :|created_at|)))
    ;; User部分
    (setf (gethash "id" user-json) (getf row :|user_id_from_join|))
    (setf (gethash "username" user-json) (getf row :|username|))
    (setf (gethash "display_name" user-json) (value-or-json-null (getf row :|display_name|)))
    (setf (gethash "bio" user-json) (value-or-json-null (getf row :|bio|)))
    (setf (gethash "created_at" user-json) (format-timestamp (getf row :|user_created_at|)))
    (setf (gethash "user" tweet-json) user-json)
    tweet-json))

(defun find-tweets-with-user-by-user-id (user-id &key max-id since-id (count 20) (offset 0) (mode :cursor))
  "ツイートとユーザー情報を一括取得（N+1クエリ回避、cursor/offset両対応）"
  ;; 防御的チェック: countがnilの場合はデフォルト値を使用
  (let ((effective-count (or count 20))
        (conditions (list (list := :t.user_id user-id))))
    (when (eq mode :cursor)
      (when max-id
        (push (list :<= :t.id max-id) conditions))
      (when since-id
        (push (list :> :t.id since-id) conditions)))
    (let ((where-clause (cons :and (nreverse conditions))))
      (mito:retrieve-by-sql
        (if (eq mode :offset)
            (sxql:select (:t.id :t.user_id :t.content :t.created_at
                          (:as :u.id :user_id_from_join)
                          :u.username :u.display_name :u.bio
                          (:as :u.created_at :user_created_at))
              (sxql:from (:as :tweet :t))
              (sxql:inner-join (:as :user :u) :on (:= :t.user_id :u.id))
              (sxql:where where-clause)
              (sxql:order-by (:desc :t.id))
              (sxql:limit (1+ effective-count))
              (sxql:offset offset))
            (sxql:select (:t.id :t.user_id :t.content :t.created_at
                          (:as :u.id :user_id_from_join)
                          :u.username :u.display_name :u.bio
                          (:as :u.created_at :user_created_at))
              (sxql:from (:as :tweet :t))
              (sxql:inner-join (:as :user :u) :on (:= :t.user_id :u.id))
              (sxql:where where-clause)
              (sxql:order-by (:desc :t.id))
              (sxql:limit (1+ effective-count))))))))

(defun get-tweets-by-user-with-user-info (user-id &key max-id since-id (count 20) (offset 0) (mode :cursor))
  "ユーザーのツイート一覧を取得（ユーザー情報付き、N+1解消、cursor/offset両対応）
   戻り値: (values tweets-json has-more next-max-id next-since-id)"
  ;; 防御的チェック: countがnilの場合はデフォルト値を使用
  (let* ((effective-count (or count 20))
         (rows (find-tweets-with-user-by-user-id user-id
                                                  :max-id max-id
                                                  :since-id since-id
                                                  :count effective-count
                                                  :offset offset
                                                  :mode mode))
         (has-more (> (length rows) effective-count))
         (trimmed-rows (if has-more
                           (butlast rows)
                           rows))
         (last-row (first (last trimmed-rows)))
         (last-id (when last-row (getf last-row :|id|)))
         (first-id (when trimmed-rows (getf (first trimmed-rows) :|id|)))
         (next-max-id (when (and last-id (eq mode :cursor))
                        (1- last-id)))
         (next-since-id (when (and first-id (eq mode :cursor))
                          first-id)))
    (values (mapcar #'row-to-tweet-json trimmed-rows)
            has-more
            next-max-id
            next-since-id)))
