(defpackage twitter-like-test.rate-limit-redis
  (:use :cl :rove)
  (:import-from :twitter-like.util.rate-limit
                :check-and-increment
                :increment
                :decrement)
  (:import-from :twitter-like.util.time
                :get-unix-time)
  (:import-from :twitter-like.config
                :load-config
                :get-config)
  (:import-from :twitter-like.middleware.session
                :ensure-redis-connected)
  (:import-from :ironclad
                :byte-array-to-hex-string
                :random-data)
  (:import-from :cl-dotenv
                :load-env))

(in-package :twitter-like-test.rate-limit-redis)

;;; ============================================================
;;; テストユーティリティ
;;; ============================================================

(defun make-test-action ()
  "ユニークなテスト用アクション名を生成（本番キーとの衝突回避）"
  (format nil "test-~A" (ironclad:byte-array-to-hex-string
                          (ironclad:random-data 8))))

;;; ============================================================
;;; 環境ガード（test-session.lisp L37-81 と同一）
;;; ============================================================

(setup
  ;; 環境設定ロード
  (when (probe-file ".env.test")
    (load-env ".env.test"))
  (load-config)

  ;; APP_ENV検証
  (unless (string= (get-config "app-env") "test")
    (error "SECURITY: APP_ENV must be 'test' for running unit tests."))

  ;; Redis DB番号検証 + DB=0警告
  (let ((redis-db (get-config "redis-db")))
    (unless (member redis-db '(0 1) :test #'eql)
      (error "SECURITY: Redis DB must be 0 or 1 for tests."))
    (when (and (eql redis-db 0)
               (not (uiop:getenv "DOCKER_ENV")))
      (warn "WARNING: Using Redis DB 0 outside Docker environment.")))

  ;; Redis HOST ホワイトリスト検証（test-session.lisp L59-63）
  (let ((redis-host (get-config "redis-host")))
    (unless (member redis-host '("localhost" "127.0.0.1" "redis") :test #'string=)
      (error "SECURITY: Redis host '~A' is not in whitelist." redis-host)))

  ;; Redis PORT ホワイトリスト検証（test-session.lisp L66-69）
  (let ((redis-port (get-config "redis-port")))
    (unless (member redis-port '(6379 6380) :test #'eql)
      (error "SECURITY: Redis port ~A is not in whitelist." redis-port)))

  ;; Redis接続確保
  (ensure-redis-connected))

(teardown nil)

;;; ============================================================
;;; check-and-increment テスト
;;; ============================================================

(deftest test-check-and-increment
  (testing "check-and-increment first access within limit"
    (let* ((action (make-test-action))
           (key (format nil "rate:~A:user:test-user" action)))
      (unwind-protect
          (multiple-value-bind (allowed remaining reset member-id)
              (check-and-increment action :user "test-user" 10 60)
            (ok allowed "First access should be allowed")
            (ok (= remaining 9) "Remaining should be limit - 1 = 9")
            (ok (null reset) "Reset time should be nil when allowed")
            (ok (null member-id) "Member-id should be nil for default :always mode"))
        (red:del key))))

  (testing "check-and-increment consecutive accesses"
    (let* ((action (make-test-action))
           (key (format nil "rate:~A:user:test-user" action)))
      (unwind-protect
          (progn
            ;; 5 consecutive accesses
            (dotimes (i 5)
              (check-and-increment action :user "test-user" 10 60))
            ;; 6th access
            (multiple-value-bind (allowed remaining reset member-id)
                (check-and-increment action :user "test-user" 10 60)
              (declare (ignore reset member-id))
              (ok allowed "6th access should be allowed")
              (ok (= remaining 4) "Remaining should be 10 - 6 = 4")))
        (red:del key))))

  (testing "check-and-increment at limit (limit-th access)"
    (let* ((action (make-test-action))
           (key (format nil "rate:~A:user:test-user" action)))
      (unwind-protect
          (progn
            ;; Fill up to limit - 1
            (dotimes (i 9)
              (check-and-increment action :user "test-user" 10 60))
            ;; limit-th access (10th)
            (multiple-value-bind (allowed remaining reset member-id)
                (check-and-increment action :user "test-user" 10 60)
              (declare (ignore reset member-id))
              (ok allowed "Limit-th access should be allowed")
              (ok (= remaining 0) "Remaining should be 0")))
        (red:del key))))

  (testing "check-and-increment over limit (limit+1 access)"
    (let* ((action (make-test-action))
           (key (format nil "rate:~A:user:test-user" action)))
      (unwind-protect
          (progn
            ;; Fill up to limit
            (dotimes (i 10)
              (check-and-increment action :user "test-user" 10 60))
            ;; limit+1 access (11th)
            (multiple-value-bind (allowed remaining reset member-id)
                (check-and-increment action :user "test-user" 10 60)
              (declare (ignore member-id))
              (ok (not allowed) "Over-limit access should be blocked")
              (ok (= remaining 0) "Remaining should be 0")
              (ok reset "Reset time should be non-nil when blocked")))
        (red:del key)))))

;;; ============================================================
;;; check-and-increment increment-on モード別テスト
;;; ============================================================

(deftest test-check-and-increment-modes
  (testing "increment-on :always mode"
    (let* ((action (make-test-action))
           (key (format nil "rate:~A:user:test-user" action)))
      (unwind-protect
          (progn
            (multiple-value-bind (allowed remaining reset member-id)
                (check-and-increment action :user "test-user" 10 60 :increment-on :always)
              (declare (ignore reset))
              (ok allowed "Should be allowed")
              (ok (= remaining 9) "Remaining should be limit - 1 = 9")
              (ok (null member-id) "Member-id should be nil for :always"))
            ;; ZSET件数の検証
            (ok (= (red:zcard key) 1) "ZSET should have 1 entry after :always"))
        (red:del key))))

  (testing "increment-on :check mode"
    (let* ((action (make-test-action))
           (key (format nil "rate:~A:user:test-user" action)))
      (unwind-protect
          (progn
            (multiple-value-bind (allowed remaining reset member-id)
                (check-and-increment action :user "test-user" 10 60 :increment-on :check)
              (declare (ignore reset))
              (ok allowed "Should be allowed")
              (ok (= remaining 9) "Remaining should be limit - 1 = 9")
              (ok (null member-id) "Member-id should be nil for :check"))
            ;; ZSET件数の検証
            (ok (= (red:zcard key) 1) "ZSET should have 1 entry after :check"))
        (red:del key))))

  (testing "increment-on :optimistic mode"
    (let* ((action (make-test-action))
           (key (format nil "rate:~A:user:test-user" action)))
      (unwind-protect
          (progn
            (multiple-value-bind (allowed remaining reset member-id)
                (check-and-increment action :user "test-user" 10 60 :increment-on :optimistic)
              (declare (ignore reset))
              (ok allowed "Should be allowed")
              (ok (= remaining 9) "Remaining should be limit - 1 = 9")
              (ok member-id "Member-id should be non-nil for :optimistic")
              (ok (stringp member-id) "Member-id should be a string"))
            ;; ZSET件数の検証
            (ok (= (red:zcard key) 1) "ZSET should have 1 entry after :optimistic"))
        (red:del key))))

  (testing "increment-on :manual mode"
    (let* ((action (make-test-action))
           (key (format nil "rate:~A:user:test-user" action)))
      (unwind-protect
          (progn
            (multiple-value-bind (allowed remaining reset member-id)
                (check-and-increment action :user "test-user" 10 60 :increment-on :manual)
              (declare (ignore reset))
              (ok allowed "Should be allowed")
              (ok (= remaining 10) "Remaining should be limit = 10 (no decrement)")
              (ok (null member-id) "Member-id should be nil for :manual"))
            ;; ZSET件数の検証（増加していないこと）
            (ok (= (red:zcard key) 0) "ZSET should have 0 entries after :manual"))
        (red:del key)))))

;;; ============================================================
;;; check-and-increment ウィンドウ期限テスト
;;; ============================================================

(deftest test-check-and-increment-window
  (testing "entries within window are counted"
    (let* ((action (make-test-action))
           (key (format nil "rate:~A:user:test-user" action)))
      (unwind-protect
          (progn
            ;; Create entry via normal call
            (check-and-increment action :user "test-user" 10 60)
            ;; Verify it's counted
            (multiple-value-bind (allowed remaining reset member-id)
                (check-and-increment action :user "test-user" 10 60)
              (declare (ignore reset member-id))
              (ok allowed "Should be allowed")
              (ok (= remaining 8) "Remaining should be 8 (2 entries counted)")))
        (red:del key))))

  (testing "entries outside window are excluded"
    (let* ((action (make-test-action))
           (key (format nil "rate:~A:user:test-user" action))
           (now (get-unix-time))
           (window 60)
           (old-time (- now window 100)))  ; 100 seconds beyond window
      (unwind-protect
          (progn
            ;; Manually add old entry (outside window)
            (red:zadd key old-time "old-member")
            ;; Check should not count the old entry
            (multiple-value-bind (allowed remaining reset member-id)
                (check-and-increment action :user "test-user" 10 60)
              (declare (ignore reset member-id))
              (ok allowed "Should be allowed")
              ;; Old entry should be cleaned up by ZREMRANGEBYSCORE
              (ok (= remaining 9) "Remaining should be 9 (old entry excluded)")))
        (red:del key)))))

;;; ============================================================
;;; check-and-increment identifier型テスト
;;; ============================================================

(deftest test-check-and-increment-identifier-types
  (testing "identifier as integer"
    (let* ((action (make-test-action))
           (key (format nil "rate:~A:user:12345" action)))
      (unwind-protect
          (multiple-value-bind (allowed remaining reset member-id)
              (check-and-increment action :user 12345 10 60)
            (declare (ignore reset member-id))
            (ok allowed "Should be allowed with integer identifier")
            (ok (= remaining 9) "Remaining should be 9"))
        (red:del key))))

  (testing "identifier as string"
    (let* ((action (make-test-action))
           (key (format nil "rate:~A:user:12345" action)))
      (unwind-protect
          (multiple-value-bind (allowed remaining reset member-id)
              (check-and-increment action :user "12345" 10 60)
            (declare (ignore reset member-id))
            (ok allowed "Should be allowed with string identifier")
            (ok (= remaining 9) "Remaining should be 9"))
        (red:del key))))

  (testing "identifier-type :ip"
    (let* ((action (make-test-action))
           (key (format nil "rate:~A:ip:192.168.1.1" action)))
      (unwind-protect
          (multiple-value-bind (allowed remaining reset member-id)
              (check-and-increment action :ip "192.168.1.1" 10 60)
            (declare (ignore reset member-id))
            (ok allowed "Should be allowed with :ip identifier-type")
            (ok (= remaining 9) "Remaining should be 9"))
        (red:del key)))))

;;; ============================================================
;;; increment テスト
;;; ============================================================

(deftest test-increment
  (testing "increment adds entry to ZSET"
    (let* ((action (make-test-action))
           (key (format nil "rate:~A:user:test-user" action))
           (window 60))
      (unwind-protect
          (progn
            (increment action :user "test-user" window)
            ;; Verify ZSET has 1 entry
            (ok (= (red:zcard key) 1)
                "ZSET should have 1 entry after increment"))
        (red:del key))))

  (testing "increment sets TTL correctly"
    (let* ((action (make-test-action))
           (key (format nil "rate:~A:user:test-user" action))
           (window 60)
           (expected-ttl (+ window 60)))  ; window + 60
      (unwind-protect
          (progn
            (increment action :user "test-user" window)
            ;; Verify TTL is within expected range (allowing 5s margin)
            (let ((actual-ttl (red:ttl key)))
              (ok (and (>= actual-ttl (- expected-ttl 5))
                       (<= actual-ttl expected-ttl))
                  (format nil "TTL should be within expected range ~A-~A (got ~A)"
                          (- expected-ttl 5) expected-ttl actual-ttl))))
        (red:del key))))

  (testing "increment creates member in timestamp:random format"
    (let* ((action (make-test-action))
           (key (format nil "rate:~A:user:test-user" action))
           (window 60))
      (unwind-protect
          (progn
            (increment action :user "test-user" window)
            ;; Get the member
            (let ((members (red:zrange key 0 -1)))
              (ok (= (length members) 1)
                  "Should have 1 member")
              (let ((member (first members)))
                (ok (search ":" member)
                    "Member should contain colon (timestamp:random format)"))))
        (red:del key)))))

;;; ============================================================
;;; decrement テスト
;;; ============================================================

(deftest test-decrement
  (testing "decrement removes existing member-id"
    (let* ((action (make-test-action))
           (key (format nil "rate:~A:user:test-user" action)))
      (unwind-protect
          (progn
            ;; Use :optimistic to get member-id
            (multiple-value-bind (allowed remaining reset member-id)
                (check-and-increment action :user "test-user" 10 60 :increment-on :optimistic)
              (declare (ignore allowed remaining reset))
              ;; Verify entry exists
              (ok (= (red:zcard key) 1) "Should have 1 entry")
              ;; Decrement
              (let ((result (decrement action :user "test-user" 60 member-id)))
                (ok result "Decrement should return T for existing member-id")
                ;; Verify entry is removed
                (ok (= (red:zcard key) 0) "ZSET should be empty after decrement"))))
        (red:del key))))

  (testing "decrement returns NIL for non-existent member-id"
    (let* ((action (make-test-action))
           (key (format nil "rate:~A:user:test-user" action)))
      (unwind-protect
          (let ((result (decrement action :user "test-user" 60 "non-existent-member-id")))
            (ok (not result) "Decrement should return NIL for non-existent member-id"))
        (red:del key))))

  (testing "decrement returns NIL for empty key"
    (let* ((action (make-test-action)))
      ;; No need to create key - it doesn't exist
      (let ((result (decrement action :user "test-user" 60 "any-member-id")))
        (ok (not result) "Decrement should return NIL for empty key"))))

  (testing "decrement double call returns NIL on second call"
    (let* ((action (make-test-action))
           (key (format nil "rate:~A:user:test-user" action)))
      (unwind-protect
          (progn
            ;; Use :optimistic to get member-id
            (multiple-value-bind (allowed remaining reset member-id)
                (check-and-increment action :user "test-user" 10 60 :increment-on :optimistic)
              (declare (ignore allowed remaining reset))
              ;; First decrement
              (let ((result1 (decrement action :user "test-user" 60 member-id)))
                (ok result1 "First decrement should return T"))
              ;; Second decrement with same member-id
              (let ((result2 (decrement action :user "test-user" 60 member-id)))
                (ok (not result2) "Second decrement should return NIL"))))
        (red:del key)))))
