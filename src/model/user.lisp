(defpackage twitter-like.model.user
  (:use :cl :mito)
  (:import-from :local-time
                :format-timestring
                :+iso-8601-format+)
  (:export :user
           :user-id
           :user-username
           :user-password
           :user-email
           :user-display-name
           :user-bio
           :user-created-at
           :user-updated-at
           :find-user-by-id
           :find-user-by-username
           :create-user
           :user-to-public-json
           :user-to-private-json))

(in-package :twitter-like.model.user)

(mito:deftable user ()
  ((username :col-type (:varchar 20)
             :accessor user-username)
   (password :col-type (:varchar 255)
             :accessor user-password)
   (email :col-type (or (:varchar 255) :null)
          :accessor user-email)
   (display_name :col-type (or (:varchar 100) :null)
                 :accessor user-display-name)
   (bio :col-type (or :text :null)
        :accessor user-bio))
  (:unique-keys username))

(defun find-user-by-id (id)
  "IDでユーザーを検索"
  (mito:find-dao 'user :id id))

(defun find-user-by-username (username)
  "ユーザー名でユーザーを検索"
  (mito:find-dao 'user :username username))

(defun create-user (username password-hash &key email display-name bio)
  "ユーザーを作成（password-hashはハッシュ化済みの値）"
  (mito:create-dao 'user
                   :username username
                   :password password-hash
                   :email email
                   :display_name display-name
                   :bio bio))

(defun format-timestamp (timestamp)
  "タイムスタンプをISO 8601形式に変換"
  (when timestamp
    (local-time:format-timestring nil timestamp
                                   :format local-time:+iso-8601-format+)))

(defun user-to-public-json (user)
  "ユーザーを公開用JSON形式（alist）に変換
  register/loginレスポンス用（emailを含まない）"
  (when user
    (list (cons "id" (mito:object-id user))
          (cons "username" (user-username user))
          (cons "display_name" (user-display-name user))
          (cons "bio" (user-bio user))
          (cons "created_at" (format-timestamp (mito:object-created-at user))))))

(defun user-to-private-json (user)
  "ユーザーをプライベート用JSON形式（alist）に変換
  /api/auth/meレスポンス用（emailを含む）"
  (when user
    (list (cons "id" (mito:object-id user))
          (cons "username" (user-username user))
          (cons "email" (user-email user))
          (cons "display_name" (user-display-name user))
          (cons "bio" (user-bio user))
          (cons "created_at" (format-timestamp (mito:object-created-at user))))))
