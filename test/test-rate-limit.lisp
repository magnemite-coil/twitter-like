(defpackage twitter-like-test.rate-limit
  (:use :cl :rove)
  (:import-from :twitter-like.util.rate-limit
                :ensure-integer
                :format-ratelimit-header
                :format-ratelimit-policy-header
                :build-ratelimit-headers)
  (:import-from :twitter-like.util.time
                :get-unix-time))

(in-package :twitter-like-test.rate-limit)

;;; setup/teardown不要（純粋関数のテスト）

;;; ============================================================
;;; ensure-integer テスト
;;; ============================================================

(deftest test-ensure-integer
  (testing "ensure-integer with integer input"
    (ok (= (ensure-integer 42) 42)
        "Should return integer as-is")
    (ok (= (ensure-integer -10) -10)
        "Should return negative integer as-is"))

  (testing "ensure-integer with extreme integers"
    (ok (= (ensure-integer most-positive-fixnum) most-positive-fixnum)
        "Should handle most-positive-fixnum")
    (ok (= (ensure-integer most-negative-fixnum) most-negative-fixnum)
        "Should handle most-negative-fixnum"))

  (testing "ensure-integer with string input"
    (ok (= (ensure-integer "123") 123)
        "Should parse numeric string")
    (ok (= (ensure-integer "-5") -5)
        "Should parse negative numeric string"))

  (testing "ensure-integer with nil input"
    (ok (= (ensure-integer nil) 0)
        "Should return 0 for nil")
    (ok (= (ensure-integer nil 10) 10)
        "Should return custom default for nil"))

  (testing "ensure-integer with invalid string"
    (ok (= (ensure-integer "abc") 0)
        "Should return 0 for non-numeric string")
    (ok (= (ensure-integer "") 0)
        "Should return 0 for empty string")
    (ok (= (ensure-integer "3.14") 0)
        "Should return 0 for decimal string (junk-allowed nil)"))

  (testing "ensure-integer with other types"
    (ok (= (ensure-integer 3.14) 0)
        "Should return 0 for float")
    (ok (= (ensure-integer '(1 2 3)) 0)
        "Should return 0 for list")
    (ok (= (ensure-integer 'symbol) 0)
        "Should return 0 for symbol")))

;;; ============================================================
;;; format-ratelimit-header テスト
;;; ============================================================

(deftest test-format-ratelimit-header
  (testing "format-ratelimit-header basic case"
    (ok (string= (format-ratelimit-header 50 30)
                 "\"default\";r=50;t=30")
        "Should format with default policy name"))

  (testing "format-ratelimit-header with custom policy"
    (ok (string= (format-ratelimit-header 10 60 "login")
                 "\"login\";r=10;t=60")
        "Should format with custom policy name"))

  (testing "format-ratelimit-header with zero remaining"
    (ok (string= (format-ratelimit-header 0 120)
                 "\"default\";r=0;t=120")
        "Should format with zero remaining"))

  (testing "format-ratelimit-header with zero reset"
    (ok (string= (format-ratelimit-header 100 0)
                 "\"default\";r=100;t=0")
        "Should format with zero reset seconds")))

;;; ============================================================
;;; format-ratelimit-policy-header テスト
;;; ============================================================

(deftest test-format-ratelimit-policy-header
  (testing "format-ratelimit-policy-header basic case"
    (ok (string= (format-ratelimit-policy-header 100 60)
                 "\"default\";q=100;w=60")
        "Should format with default policy name"))

  (testing "format-ratelimit-policy-header with custom policy"
    (ok (string= (format-ratelimit-policy-header 5 3600 "register")
                 "\"register\";q=5;w=3600")
        "Should format with custom policy name"))

  (testing "format-ratelimit-policy-header with large values"
    (ok (string= (format-ratelimit-policy-header 10000 86400)
                 "\"default\";q=10000;w=86400")
        "Should format with large values")))

;;; ============================================================
;;; build-ratelimit-headers テスト
;;; ============================================================

(deftest test-build-ratelimit-headers
  (testing "build-ratelimit-headers includes all keys"
    (let* ((now 1704268770)
           (reset-time (+ now 30))
           (headers (build-ratelimit-headers 60 50 reset-time 3600 now)))
      (ok (getf headers :ratelimit)
          "Should include :ratelimit key")
      (ok (getf headers :ratelimit-policy)
          "Should include :ratelimit-policy key")
      (ok (getf headers :retry-after)
          "Should include :retry-after key")
      (ok (getf headers :x-ratelimit-limit)
          "Should include :x-ratelimit-limit key")
      (ok (getf headers :x-ratelimit-remaining)
          "Should include :x-ratelimit-remaining key")
      (ok (getf headers :x-ratelimit-reset)
          "Should include :x-ratelimit-reset key")))

  (testing "build-ratelimit-headers calculates reset-seconds correctly"
    (let* ((now 1704268770)
           (reset-time (+ now 60))
           (headers (build-ratelimit-headers 60 50 reset-time 3600 now)))
      (ok (string= (getf headers :retry-after) "60")
          "Retry-After should be 60 (delay-seconds format)")))

  (testing "build-ratelimit-headers handles past reset-time"
    (let* ((now 1704268770)
           (reset-time (- now 10))
           (headers (build-ratelimit-headers 60 50 reset-time 3600 now)))
      (ok (string= (getf headers :retry-after) "0")
          "Retry-After should be 0 for past reset-time (non-negative guarantee)")))

  (testing "build-ratelimit-headers includes X-RateLimit-* headers"
    (let* ((now 1704268770)
           (reset-time (+ now 30))
           (headers (build-ratelimit-headers 60 50 reset-time 3600 now)))
      (ok (string= (getf headers :x-ratelimit-limit) "60")
          "X-RateLimit-Limit should be limit")
      (ok (string= (getf headers :x-ratelimit-remaining) "50")
          "X-RateLimit-Remaining should be remaining")
      (ok (string= (getf headers :x-ratelimit-reset) (write-to-string reset-time))
          "X-RateLimit-Reset should be reset-time")))

  (testing "build-ratelimit-headers with now=nil returns non-negative retry-after"
    (let* ((future-reset (+ (get-unix-time) 30))
           (headers (build-ratelimit-headers 60 50 future-reset 3600 nil)))
      (let ((retry-after (parse-integer (getf headers :retry-after))))
        (ok (>= retry-after 0)
            "Retry-After should be non-negative integer"))))

  (testing "build-ratelimit-headers t and retry-after consistency"
    (let* ((now 1704268770)
           (reset-time (+ now 45))
           (headers (build-ratelimit-headers 60 50 reset-time 3600 now)))
      ;; RateLimitヘッダーの t=45 と :retry-after "45" が一致することを確認
      (ok (search "t=45" (getf headers :ratelimit))
          "RateLimit header should contain t=45")
      (ok (string= (getf headers :retry-after) "45")
          "Retry-After should be 45"))))
