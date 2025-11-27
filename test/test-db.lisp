(defpackage twitter-like-test.db
  (:use :cl :rove)
  (:import-from :twitter-like.db
                :connect-db
                :disconnect-db
                :ensure-db-connected))

(in-package :twitter-like-test.db)

(deftest test-db-connection
  (testing "Database connection"
    ;; .env.test を読み込み
    (when (probe-file ".env.test")
      (cl-dotenv:load-env :file ".env.test"))

    (twitter-like.config:load-config)

    ;; データベース接続
    (ok (twitter-like.db:connect-db)
        "Should connect to database")

    ;; 接続確認
    (ok (twitter-like.db:ensure-db-connected)
        "Should ensure database connection")

    ;; データベース切断
    (twitter-like.db:disconnect-db)
    (ok t "Should disconnect from database")))
