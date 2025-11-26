(defpackage twitter-like-test.health
  (:use :cl :rove)
  (:import-from :dexador)
  (:import-from :com.inuoe.jzon
                :parse))

(in-package :twitter-like-test.health)

(setup
  ;; テスト環境セットアップ
  (twitter-like-test:setup-test-env))

(teardown
  ;; テストデータクリーンアップ
  (twitter-like-test:cleanup-test-data)
  ;; テスト環境クリーンアップ
  (twitter-like-test:teardown-test-env))

(deftest test-health-endpoint
  (testing "Health check endpoint"
    (multiple-value-bind (body status headers)
        (dex:get (format nil "~A/api/health" (twitter-like-test:get-test-base-url)))
      ;; ステータスコード確認
      (ok (= status 200)
          "Status code should be 200")

      ;; Content-Type確認
      (ok (search "application/json" (gethash "content-type" headers))
          "Content-Type should be application/json")

      ;; レスポンスボディ確認
      (let ((response (com.inuoe.jzon:parse body)))
        (ok (string= (gethash "status" response) "healthy")
            "Status should be 'healthy'")
        (ok (string= (gethash "database" response) "connected")
            "Database should be 'connected'")
        (ok (string= (gethash "redis" response) "connected")
            "Redis should be 'connected'")
        (ok (gethash "timestamp" response)
            "Timestamp should be present")))))
