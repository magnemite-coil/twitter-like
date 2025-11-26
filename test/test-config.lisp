(defpackage twitter-like-test.config
  (:use :cl :rove)
  (:import-from :twitter-like.config
                :load-config
                :get-config
                :validate-config))

(in-package :twitter-like-test.config)

(deftest test-load-config
  (testing "Configuration loading"
    ;; .env.test を読み込み
    (when (probe-file ".env.test")
      (cl-dotenv:load-env :file ".env.test"))

    (twitter-like.config:load-config)

    ;; 基本設定の確認
    (ok (string= (twitter-like.config:get-config "app-env") "test")
        "APP_ENV should be 'test'")
    (ok (= (twitter-like.config:get-config "app-port") 8081)
        "APP_PORT should be 8081")
    (ok (string= (twitter-like.config:get-config "db-name") "twitter_like_test")
        "DB_NAME should be 'twitter_like_test'")))

(deftest test-validate-config
  (testing "Configuration validation"
    ;; .env.test を読み込み
    (when (probe-file ".env.test")
      (cl-dotenv:load-env :file ".env.test"))

    (twitter-like.config:load-config)

    ;; 設定検証が成功することを確認
    (ok (twitter-like.config:validate-config)
        "Configuration should be valid")))
