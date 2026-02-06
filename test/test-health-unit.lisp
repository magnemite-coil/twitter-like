;;; ============================================================
;;; test/test-health-unit.lisp
;;; Health Handler ユニットテスト（サーバー不要）
;;; ============================================================

(defpackage twitter-like-test.health-unit
  (:use :cl :rove)
  (:import-from :twitter-like.config
                :load-config
                :get-config)
  (:import-from :twitter-like.handler.health
                :collect-health-data))

(in-package :twitter-like-test.health-unit)

;;; ============================================================
;;; パッケージ命名について
;;; ============================================================
;;;
;;; 既存パターン: twitter-like-test.<機能名>
;;; 本ファイル:   twitter-like-test.health-unit
;;;
;;; "-unit" サフィックスを使用する理由:
;;; 1. 同一機能（health）に対して統合テスト（test-health.lisp）と
;;;    ユニットテスト（test-health-unit.lisp）の両方が存在する
;;; 2. 統合テストとユニットテストは依存関係が異なる:
;;;    - 統合テスト: サーバー起動、DB/Redis接続が必要
;;;    - ユニットテスト: 設定ロードのみ、外部依存なし
;;; 3. ファイル名で役割を明示することで、テスト実行時の
;;;    トラブルシューティングを容易にする

;;; ============================================================
;;; モック関数ファクトリ（collect-health-data の引数として使用）
;;; ============================================================

;;; 正常系モック（DB/Redis接続成功をシミュレート）
(defun make-successful-db-check ()
  "DB接続成功をシミュレート（error を発生させない）"
  (lambda () nil))

(defun make-successful-redis-check ()
  "Redis接続成功をシミュレート（error を発生させない）"
  (lambda () nil))

(defun make-normal-disk-usage (&optional (percent 50))
  "正常なディスク使用率を返すモック"
  (lambda ()
    (let ((result (make-hash-table :test 'equal)))
      (setf (gethash "status" result) "ok")
      (setf (gethash "usage_percent" result) percent)
      result)))

(defun make-normal-memory-usage (&optional (usage-mb 256))
  "正常なメモリ使用量を返すモック"
  (lambda ()
    (let ((result (make-hash-table :test 'equal)))
      (setf (gethash "status" result) "ok")
      (setf (gethash "usage_mb" result) usage-mb)
      result)))

;;; ============================================================
;;; 障害シミュレーション用モック関数
;;; ============================================================

(defun make-failing-db-check ()
  "DB接続失敗をシミュレート（error を発生）"
  (lambda ()
    (error "Simulated DB connection failure")))

(defun make-failing-redis-check ()
  "Redis接続失敗をシミュレート（error を発生）"
  (lambda ()
    (error "Simulated Redis connection failure")))

(defun make-high-disk-usage (&optional (percent 95))
  "高ディスク使用率を返すモック（正常応答）"
  (lambda ()
    (let ((result (make-hash-table :test 'equal)))
      (setf (gethash "status" result) "ok")
      (setf (gethash "usage_percent" result) percent)
      result)))

(defun make-throwing-disk-check ()
  "ディスクチェックで error を発生させるモック"
  (lambda ()
    (error "Simulated disk check failure")))

(defun make-throwing-memory-check ()
  "メモリチェックで error を発生させるモック"
  (lambda ()
    (error "Simulated memory check failure")))

(defun make-unknown-disk-result ()
  "ディスクチェックが status=unknown を返すモック（error なし）"
  (lambda ()
    (let ((result (make-hash-table :test 'equal)))
      (setf (gethash "status" result) "unknown")
      result)))

(defun make-unknown-memory-result ()
  "メモリチェックが status=unknown を返すモック（error なし）"
  (lambda ()
    (let ((result (make-hash-table :test 'equal)))
      (setf (gethash "status" result) "unknown")
      result)))

;;; ============================================================
;;; setup/teardown
;;; ============================================================

(setup
  ;; 設定ロード
  (when (probe-file ".env.test")
    (cl-dotenv:load-env ".env.test"))
  (twitter-like.config:load-config)

  ;; 環境ガード（本番環境での誤実行を防止）
  (unless (string= (get-config "app-env") "test")
    (error "SECURITY: APP_ENV must be 'test' for running unit tests. Current: ~A"
           (get-config "app-env"))))

(teardown
  nil)

;;; ============================================================
;;; ユニットテスト: DB障害
;;; ============================================================

(deftest test-health-db-failure
  (testing "Health check returns unhealthy when DB check fails"
    (let* ((result (collect-health-data
                     :db-check-fn (make-failing-db-check)
                     :redis-check-fn (make-successful-redis-check)
                     :disk-check-fn (make-normal-disk-usage)
                     :memory-check-fn (make-normal-memory-usage)))
           (health-data (getf result :health-data))
           (http-status (getf result :http-status)))
      (ok (= http-status 503)
          "Should return 503 when DB is disconnected")
      (ok (string= (gethash "status" health-data) "unhealthy")
          "Status should be 'unhealthy'")
      (ok (string= (gethash "database" health-data) "disconnected")
          "Database should be 'disconnected'")
      (ok (gethash "timestamp" health-data)
          "Timestamp should be present"))))

;;; ============================================================
;;; ユニットテスト: Redis障害
;;; ============================================================

(deftest test-health-redis-failure
  (testing "Health check returns unhealthy when Redis check fails"
    (let* ((result (collect-health-data
                     :db-check-fn (make-successful-db-check)
                     :redis-check-fn (make-failing-redis-check)
                     :disk-check-fn (make-normal-disk-usage)
                     :memory-check-fn (make-normal-memory-usage)))
           (health-data (getf result :health-data))
           (http-status (getf result :http-status)))
      (ok (= http-status 503)
          "Should return 503 when Redis is disconnected")
      (ok (string= (gethash "status" health-data) "unhealthy")
          "Status should be 'unhealthy'")
      (ok (string= (gethash "redis" health-data) "disconnected")
          "Redis should be 'disconnected'")
      (ok (gethash "timestamp" health-data)
          "Timestamp should be present"))))

;;; ============================================================
;;; ユニットテスト: 複合障害（DB + Redis）
;;; ============================================================

(deftest test-health-multiple-failures
  (testing "Health check handles multiple failures"
    (let* ((result (collect-health-data
                     :db-check-fn (make-failing-db-check)
                     :redis-check-fn (make-failing-redis-check)
                     :disk-check-fn (make-normal-disk-usage)
                     :memory-check-fn (make-normal-memory-usage)))
           (health-data (getf result :health-data))
           (http-status (getf result :http-status)))
      (ok (= http-status 503)
          "Should return 503")
      (ok (string= (gethash "status" health-data) "unhealthy")
          "Status should be 'unhealthy'")
      (ok (string= (gethash "database" health-data) "disconnected")
          "Database should be 'disconnected'")
      (ok (string= (gethash "redis" health-data) "disconnected")
          "Redis should be 'disconnected'")
      (ok (gethash "timestamp" health-data)
          "Timestamp should be present"))))

;;; ============================================================
;;; ユニットテスト: ディスク使用率
;;; ============================================================

(deftest test-health-disk-degraded
  (testing "Health check returns degraded when disk usage > 90%"
    (let* ((result (collect-health-data
                     :db-check-fn (make-successful-db-check)
                     :redis-check-fn (make-successful-redis-check)
                     :disk-check-fn (make-high-disk-usage 91)
                     :memory-check-fn (make-normal-memory-usage)))
           (health-data (getf result :health-data))
           (http-status (getf result :http-status)))
      ;; degradedでも200を返す（設計通り）
      (ok (= http-status 200)
          "Should return 200 even when degraded")
      (ok (string= (gethash "status" health-data) "degraded")
          "Status should be 'degraded'")
      (let ((disk (gethash "disk" health-data)))
        (ok (= (gethash "usage_percent" disk) 91)
            "Disk usage should be 91%")))))

(deftest test-health-disk-critical
  (testing "Health check handles critical disk usage (95%)"
    (let* ((result (collect-health-data
                     :db-check-fn (make-successful-db-check)
                     :redis-check-fn (make-successful-redis-check)
                     :disk-check-fn (make-high-disk-usage 95)
                     :memory-check-fn (make-normal-memory-usage)))
           (health-data (getf result :health-data)))
      (ok (string= (gethash "status" health-data) "degraded")
          "Status should be 'degraded'"))))

;;; ============================================================
;;; ユニットテスト: ディスク/メモリチェックでエラー発生
;;; ============================================================

(deftest test-health-disk-check-error
  (testing "Health check catches disk check error and returns status=unknown"
    (let* ((result (collect-health-data
                     :db-check-fn (make-successful-db-check)
                     :redis-check-fn (make-successful-redis-check)
                     :disk-check-fn (make-throwing-disk-check)
                     :memory-check-fn (make-normal-memory-usage)))
           (health-data (getf result :health-data))
           (http-status (getf result :http-status)))
      ;; 任意チェックのエラーでは全体ステータスは healthy を維持
      (ok (= http-status 200)
          "Should return 200 (optional check failure)")
      (ok (string= (gethash "status" health-data) "healthy")
          "Overall status should remain 'healthy'")
      (let ((disk (gethash "disk" health-data)))
        (ok (string= (gethash "status" disk) "unknown")
            "Disk status should be 'unknown' after error")))))

(deftest test-health-memory-check-error
  (testing "Health check catches memory check error and returns status=unknown"
    (let* ((result (collect-health-data
                     :db-check-fn (make-successful-db-check)
                     :redis-check-fn (make-successful-redis-check)
                     :disk-check-fn (make-normal-disk-usage)
                     :memory-check-fn (make-throwing-memory-check)))
           (health-data (getf result :health-data))
           (http-status (getf result :http-status)))
      ;; 任意チェックのエラーでは全体ステータスは healthy を維持
      (ok (= http-status 200)
          "Should return 200 (optional check failure)")
      (ok (string= (gethash "status" health-data) "healthy")
          "Overall status should remain 'healthy'")
      (let ((memory (gethash "memory" health-data)))
        (ok (string= (gethash "status" memory) "unknown")
            "Memory status should be 'unknown' after error")))))

;;; ============================================================
;;; ユニットテスト: 実関数が status=unknown を返すケース
;;; ============================================================

(deftest test-health-disk-unknown-result
  (testing "Health check handles disk unknown result (no error)"
    (let* ((result (collect-health-data
                     :db-check-fn (make-successful-db-check)
                     :redis-check-fn (make-successful-redis-check)
                     :disk-check-fn (make-unknown-disk-result)
                     :memory-check-fn (make-normal-memory-usage)))
           (health-data (getf result :health-data))
           (http-status (getf result :http-status)))
      (ok (= http-status 200)
          "Should return 200")
      (let ((disk (gethash "disk" health-data)))
        (ok (string= (gethash "status" disk) "unknown")
            "Disk status should be 'unknown'")))))

(deftest test-health-memory-unknown-result
  (testing "Health check handles memory unknown result (no error)"
    (let* ((result (collect-health-data
                     :db-check-fn (make-successful-db-check)
                     :redis-check-fn (make-successful-redis-check)
                     :disk-check-fn (make-normal-disk-usage)
                     :memory-check-fn (make-unknown-memory-result)))
           (health-data (getf result :health-data))
           (http-status (getf result :http-status)))
      (ok (= http-status 200)
          "Should return 200")
      (let ((memory (gethash "memory" health-data)))
        (ok (string= (gethash "status" memory) "unknown")
            "Memory status should be 'unknown'")))))

;;; ============================================================
;;; 回帰テスト: ステータス優先順位（unhealthy > degraded）
;;; ============================================================

(deftest test-health-status-priority-unhealthy-over-degraded
  (testing "Status priority: unhealthy is not overwritten by degraded"
    (let* ((result (collect-health-data
                     :db-check-fn (make-failing-db-check)
                     :redis-check-fn (make-successful-redis-check)
                     :disk-check-fn (make-high-disk-usage 95)
                     :memory-check-fn (make-normal-memory-usage)))
           (health-data (getf result :health-data))
           (http-status (getf result :http-status)))
      ;; DB障害でunhealthy → ディスク高使用率でもdegradedに上書きされない
      (ok (= http-status 503)
          "Should return 503 (unhealthy takes priority)")
      (ok (string= (gethash "status" health-data) "unhealthy")
          "Status should remain 'unhealthy', not 'degraded'")
      (ok (string= (gethash "database" health-data) "disconnected")
          "Database should be 'disconnected'")
      ;; ディスク情報は正常に取得されている
      (let ((disk (gethash "disk" health-data)))
        (ok (= (gethash "usage_percent" disk) 95)
            "Disk usage should still be reported as 95%")))))

(deftest test-health-status-priority-redis-failure-with-high-disk
  (testing "Status priority: Redis failure with high disk usage"
    (let* ((result (collect-health-data
                     :db-check-fn (make-successful-db-check)
                     :redis-check-fn (make-failing-redis-check)
                     :disk-check-fn (make-high-disk-usage 92)
                     :memory-check-fn (make-normal-memory-usage)))
           (health-data (getf result :health-data))
           (http-status (getf result :http-status)))
      ;; Redis障害でunhealthy → ディスク高使用率でもdegradedに上書きされない
      (ok (= http-status 503)
          "Should return 503 (unhealthy takes priority)")
      (ok (string= (gethash "status" health-data) "unhealthy")
          "Status should remain 'unhealthy', not 'degraded'"))))

;;; ============================================================
;;; ユニットテスト: 正常系（全チェックOK）
;;; ============================================================

(deftest test-health-all-normal
  (testing "Health check returns healthy when all checks pass"
    (let* ((result (collect-health-data
                     :db-check-fn (make-successful-db-check)
                     :redis-check-fn (make-successful-redis-check)
                     :disk-check-fn (make-normal-disk-usage 50)
                     :memory-check-fn (make-normal-memory-usage 256)))
           (health-data (getf result :health-data))
           (http-status (getf result :http-status)))
      (ok (= http-status 200)
          "Should return 200 when all checks pass")
      (ok (string= (gethash "status" health-data) "healthy")
          "Status should be 'healthy'")
      (ok (string= (gethash "database" health-data) "connected")
          "Database should be 'connected'")
      (ok (string= (gethash "redis" health-data) "connected")
          "Redis should be 'connected'")
      (ok (gethash "timestamp" health-data)
          "Timestamp should be present")
      (let ((disk (gethash "disk" health-data)))
        (ok (= (gethash "usage_percent" disk) 50)
            "Disk usage should be 50%"))
      (let ((memory (gethash "memory" health-data)))
        (ok (= (gethash "usage_mb" memory) 256)
            "Memory usage should be 256MB")))))

;;; ============================================================
;;; ユニットテスト: 境界値（ディスク使用率90%ちょうど）
;;; ============================================================

(deftest test-health-disk-at-threshold
  (testing "Health check remains healthy at exactly 90% disk usage"
    (let* ((result (collect-health-data
                     :db-check-fn (make-successful-db-check)
                     :redis-check-fn (make-successful-redis-check)
                     :disk-check-fn (make-high-disk-usage 90)
                     :memory-check-fn (make-normal-memory-usage)))
           (health-data (getf result :health-data))
           (http-status (getf result :http-status)))
      ;; 条件は "> 90" なので、90%ちょうどでは degraded にならない
      (ok (= http-status 200)
          "Should return 200 at exactly 90%")
      (ok (string= (gethash "status" health-data) "healthy")
          "Status should be 'healthy' at exactly 90% (threshold is > 90)"))))
