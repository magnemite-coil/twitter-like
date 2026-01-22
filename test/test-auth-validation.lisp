(defpackage twitter-like-test.auth-validation
  (:use :cl :rove)
  (:import-from :twitter-like.service.auth
                :validate-username
                :validate-password))

(in-package :twitter-like-test.auth-validation)

;;; ============================================================
;;; 環境ガードについて
;;; ============================================================

;;; このテストファイルは純粋関数のテストのため、以下の環境ガードは不要:
;;; - APP_ENV チェック（Redis/DB接続を使用しないため）
;;; - Redis ホスト/ポート ホワイトリスト（Redis接続を使用しないため）
;;; - PostgreSQL 接続確認（DB接続を使用しないため）
;;;
;;; 参考: test-session.lisp では Redis を使用するため、
;;; 多層セキュリティガード（APP_ENV, Redis whitelist等）を実装している。
;;; 詳細は test/test-session.lisp L30-74 を参照。

;;; setup/teardown 不要（純粋関数のテスト）

;;; ============================================================
;;; validate-username テスト
;;; ============================================================

(deftest test-validate-username
  ;; 正常系
  (testing "valid username returns T"
    (multiple-value-bind (valid error) (validate-username "validuser123")
      (ok valid "Should return T for valid username")
      (ok (null error) "Error should be nil")))

  ;; 境界値
  (testing "minimum length (3 chars) is valid"
    (ok (validate-username "abc") "3-char username should be valid"))

  (testing "maximum length (20 chars) is valid"
    (ok (validate-username (make-string 20 :initial-element #\a))
        "20-char username should be valid"))

  ;; エラーケース
  (testing "nil returns error"
    (multiple-value-bind (valid error) (validate-username nil)
      (ok (not valid) "Should return NIL for nil input")
      (ok (string= error "Username is required")
          "Error message should indicate required")))

  (testing "non-string returns error"
    (multiple-value-bind (valid error) (validate-username 123)
      (ok (not valid) "Should return NIL for non-string")
      (ok (string= error "Username is required")
          "Error message should indicate required")))

  (testing "empty string returns error"
    (multiple-value-bind (valid error) (validate-username "")
      (ok (not valid) "Should return NIL for empty string")
      (ok (search "at least 3" error)
          "Error should mention minimum length")))

  (testing "too short (2 chars) returns error"
    (multiple-value-bind (valid error) (validate-username "ab")
      (ok (not valid) "Should return NIL for 2-char username")
      (ok (search "at least 3" error)
          "Error should mention minimum length")))

  (testing "too long (21 chars) returns error"
    (multiple-value-bind (valid error) (validate-username (make-string 21 :initial-element #\a))
      (ok (not valid) "Should return NIL for 21-char username")
      (ok (search "at most 20" error)
          "Error should mention maximum length")))

  (testing "invalid characters (@) returns error"
    (multiple-value-bind (valid error) (validate-username "user@name")
      (ok (not valid) "Should return NIL for username with @")
      (ok (search "letters, numbers, and underscores" error)
          "Error should list allowed characters")))

  (testing "spaces returns error"
    (multiple-value-bind (valid error) (validate-username "user name")
      (ok (not valid) "Should return NIL for username with space")
      (ok (search "letters, numbers, and underscores" error)
          "Error should list allowed characters")))

  (testing "underscore is allowed"
    (ok (validate-username "valid_user_123")
        "Username with underscore should be valid")))

;;; ============================================================
;;; validate-password テスト
;;; ============================================================

(deftest test-validate-password
  ;; 正常系
  (testing "valid password returns T"
    (ok (validate-password "this-is-a-secure-password")
        "Valid password should return T"))

  ;; 境界値
  (testing "minimum length (15 chars) is valid"
    (ok (validate-password "123456789012345")
        "15-char password should be valid"))

  (testing "maximum length (128 chars) is valid"
    (ok (validate-password (make-string 128 :initial-element #\a))
        "128-char password should be valid"))

  ;; エラーケース
  (testing "nil returns error"
    (multiple-value-bind (valid error) (validate-password nil)
      (ok (not valid) "Should return NIL for nil input")
      (ok (string= error "Password is required")
          "Error message should indicate required")))

  (testing "non-string returns error"
    (multiple-value-bind (valid error) (validate-password 12345)
      (ok (not valid) "Should return NIL for non-string")
      (ok (string= error "Password is required")
          "Error message should indicate required")))

  (testing "empty string returns error"
    (multiple-value-bind (valid error) (validate-password "")
      (ok (not valid) "Should return NIL for empty string")
      (ok (search "at least 15" error)
          "Error should mention minimum length")))

  (testing "too short (14 chars) returns error"
    (multiple-value-bind (valid error) (validate-password "12345678901234")
      (ok (not valid) "Should return NIL for 14-char password")
      (ok (search "at least 15" error)
          "Error should mention minimum length")))

  (testing "too long (129 chars) returns error"
    (multiple-value-bind (valid error) (validate-password (make-string 129 :initial-element #\a))
      (ok (not valid) "Should return NIL for 129-char password")
      (ok (search "at most 128" error)
          "Error should mention maximum length"))))
