;;; src/model/tweet.lisp

(defpackage twitter-like.model.tweet
  (:use :cl :mito)
  (:import-from :local-time
                :format-timestring
                :+iso-8601-format+)
  (:import-from :twitter-like.model.user
                :user
                :find-user-by-id
                :user-to-public-json)
  (:export :tweet
           :tweet-user-id
           :tweet-content
           :find-tweet-by-id
           :find-tweets-by-user-id
           :create-tweet-record
           :delete-tweet-record
           :tweet-to-json))

(in-package :twitter-like.model.tweet)

(mito:deftable tweet ()
  ((user-id :col-type :integer
            :col-name "user_id"
            :accessor tweet-user-id)
   (content :col-type (:varchar 140)
            :accessor tweet-content)))

(defun find-tweet-by-id (id)
  "IDでツイートを検索"
  (mito:find-dao 'tweet :id id))

(defun find-tweets-by-user-id (user-id &key (limit 20) (offset 0))
  "ユーザーIDでツイートを検索（新しい順）
  注意: created_at DESC, id DESC で並べ替え。
  同時刻のレコードの順序を決定的にするため、id も降順で指定。"
  (mito:select-dao 'tweet
    (sxql:where (:= :user_id user-id))
    (sxql:order-by (:desc :created_at) (:desc :id))
    (sxql:limit limit)
    (sxql:offset offset)))

(defun create-tweet-record (user-id content)
  "ツイートを作成"
  (mito:create-dao 'tweet
                   :user-id user-id
                   :content content))

(defun delete-tweet-record (tweet)
  "ツイートを削除"
  (mito:delete-dao tweet))

(defun format-timestamp (timestamp)
  "タイムスタンプをISO 8601形式に変換"
  (when timestamp
    (local-time:format-timestring nil timestamp
                                   :format local-time:+iso-8601-format+)))

(defun tweet-to-json (tweet &key include-user)
  "ツイートをJSON形式（hash-table）に変換

  注意: include-userがtの場合、find-user-by-idが呼び出されるため、
  一覧取得時にN+1クエリが発生する可能性があります。
  Phase 1では許容範囲として扱い、Phase 2でJOINによる最適化を検討します。"
  (when tweet
    (let ((result (make-hash-table :test 'equal)))
      (setf (gethash "id" result) (mito:object-id tweet))
      (setf (gethash "user_id" result) (tweet-user-id tweet))
      (setf (gethash "content" result) (tweet-content tweet))
      (setf (gethash "created_at" result) (format-timestamp (mito:object-created-at tweet)))
      (when include-user
        (let ((user (find-user-by-id (tweet-user-id tweet))))
          (setf (gethash "user" result) (user-to-public-json user))))
      result)))
