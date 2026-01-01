(defpackage twitter-like.model.user
  (:use :cl :mito)
  (:import-from :twitter-like.util.time
                :format-timestamp)
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
             :not-null t
             :accessor user-username)
   (password :col-type (:varchar 255)
             :not-null t
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

(defun slot-value-or-json-null (object slot-name)
  "スロットの値を取得、未束縛またはNILの場合はJSON nullを返す"
  (let ((value (if (slot-boundp object slot-name)
                   (slot-value object slot-name)
                   nil)))
    ;; JzonではNILはfalseに変換されるため、nullには'nullシンボルを使う
    (if value value 'null)))

(defun user-to-public-json (user)
  "ユーザーを公開用JSON形式（hash-table）に変換
  register/loginレスポンス用（emailを含まない）"
  (when user
    (let ((result (make-hash-table :test 'equal)))
      (setf (gethash "id" result) (mito:object-id user))
      (setf (gethash "username" result) (user-username user))
      (setf (gethash "display_name" result) (slot-value-or-json-null user 'display_name))
      (setf (gethash "bio" result) (slot-value-or-json-null user 'bio))
      (setf (gethash "created_at" result) (format-timestamp (mito:object-created-at user)))
      result)))

(defun user-to-private-json (user)
  "ユーザーをプライベート用JSON形式（hash-table）に変換
  /api/auth/meレスポンス用（emailを含む）"
  (when user
    (let ((result (make-hash-table :test 'equal)))
      (setf (gethash "id" result) (mito:object-id user))
      (setf (gethash "username" result) (user-username user))
      (setf (gethash "email" result) (slot-value-or-json-null user 'email))
      (setf (gethash "display_name" result) (slot-value-or-json-null user 'display_name))
      (setf (gethash "bio" result) (slot-value-or-json-null user 'bio))
      (setf (gethash "created_at" result) (format-timestamp (mito:object-created-at user)))
      result)))
