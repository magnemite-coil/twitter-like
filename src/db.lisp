(defpackage twitter-like.db
  (:use :cl)
  (:import-from :mito
                :connect-toplevel
                :disconnect-toplevel)
  (:import-from :mito.connection
                :connected-p
                :*connection*)
  (:export :connect-db
           :disconnect-db
           :ensure-db-connected))

(in-package :twitter-like.db)

(defvar *db-connection* nil
  "データベース接続を保持する変数（Mitoの*connection*と同期）")

(defun connect-db (&key (max-retries 3) (retry-delay 2))
  "PostgreSQLデータベースに接続（リトライ機構付き）"
  (loop for retry from 1 to max-retries
        do (handler-case
               (progn
                 (setf *db-connection*
                       (mito:connect-toplevel :postgres
                                              :host (twitter-like.config:get-config "db-host")
                                              :port (twitter-like.config:get-config "db-port")
                                              :database-name (twitter-like.config:get-config "db-name")
                                              :username (twitter-like.config:get-config "db-user")
                                              :password (twitter-like.config:get-config "db-password")))
                 (format t "✓ Database connected: ~A@~A:~A/~A~%"
                         (twitter-like.config:get-config "db-user")
                         (twitter-like.config:get-config "db-host")
                         (twitter-like.config:get-config "db-port")
                         (twitter-like.config:get-config "db-name"))
                 (return *db-connection*))
             (error (e)
               (format t "⚠ Database connection failed (attempt ~A/~A): ~A~%"
                       retry max-retries e)
               (when (< retry max-retries)
                 (format t "  Retrying in ~A seconds...~%" retry-delay)
                 (sleep retry-delay))))
        finally (error "Failed to connect to database after ~A attempts" max-retries)))

(defun disconnect-db ()
  "データベース接続を切断"
  (when *db-connection*
    (mito:disconnect-toplevel)
    (setf *db-connection* nil)
    (format t "✓ Database disconnected~%")))

(defun ensure-db-connected ()
  "データベース接続を確認、未接続なら接続"
  (unless (and *db-connection* (mito.connection:connected-p))
    (connect-db)))
