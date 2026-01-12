(defpackage twitter-like-test.crypto
  (:use :cl :rove)
  (:import-from :twitter-like.util.crypto
                :hash-password
                :verify-password
                :generate-session-id
                :generate-csrf-token
                :constant-time-string=
                :mask-session-id))

(in-package :twitter-like-test.crypto)

;;; setup/teardown不要（純粋関数のテスト）

;;; ============================================================
;;; hash-password テスト
;;; ============================================================

(deftest test-hash-password
  ;; 最適化: hash-password は600,000イテレーションのPBKDF2を実行するため高コスト
  ;; 同一パスワードのハッシュは共有し、呼び出し回数を最小化する

  ;; 標準パスワードのハッシュを共有（フォーマット・型検証用）
  (let ((standard-hash (hash-password "secure-password-123")))
    (testing "hash-password returns 48-byte array (salt + derived-key)"
      (ok (typep standard-hash '(simple-array (unsigned-byte 8) (*)))
          "Should return byte array")
      (ok (= (length standard-hash) 48)
          "Should be 48 bytes (16 salt + 32 key)")))

  ;; ソルト一意性検証（2回の呼び出しは削減不可）
  (testing "hash-password generates unique salts"
    (let ((hash1 (hash-password "same-password"))
          (hash2 (hash-password "same-password")))
      (ok (not (equalp hash1 hash2))
          "Same password should produce different hashes due to random salt")))

  ;; UTF-8/絵文字/境界値は個別に検証（各1回の呼び出し）
  (testing "hash-password handles UTF-8 correctly"
    (let ((hash (hash-password "安全なパスワード")))
      (ok (= (length hash) 48)
          "Japanese password should hash correctly")))

  (testing "hash-password handles emoji"
    (let ((hash (hash-password "pass👍word")))
      (ok (= (length hash) 48)
          "Emoji password should hash correctly")))

  ;; 境界値テスト（最小・最大長）
  (let ((min-hash (hash-password "123456789012345"))        ; 15文字
        (max-hash (hash-password (make-string 128 :initial-element #\a))))
    (testing "hash-password handles minimum length password"
      (ok (= (length min-hash) 48)
          "15-char password should hash correctly"))
    (testing "hash-password handles maximum length password"
      (ok (= (length max-hash) 48)
          "128-char password should hash correctly"))))

;;; ============================================================
;;; verify-password テスト
;;; ============================================================

(deftest test-verify-password
  (testing "verify-password returns T for correct password"
    (let* ((password "correct-password-here")
           (hash (hash-password password)))
      (ok (verify-password password hash)
          "Should return T for correct password")))

  (testing "verify-password returns NIL for incorrect password"
    (let* ((password "correct-password-here")
           (hash (hash-password password)))
      (ok (not (verify-password "wrong-password-here" hash))
          "Should return NIL for incorrect password")))

  (testing "verify-password returns NIL for short hash"
    (let ((short-hash (make-array 47 :element-type '(unsigned-byte 8)
                                     :initial-element 0)))
      (ok (not (verify-password "any-password" short-hash))
          "Should return NIL for hash shorter than 48 bytes")))

  (testing "verify-password returns NIL for empty hash"
    (let ((empty-hash (make-array 0 :element-type '(unsigned-byte 8))))
      (ok (not (verify-password "any-password" empty-hash))
          "Should return NIL for empty hash")))

  (testing "verify-password returns NIL for nil hash"
    ;; 注意: (length nil) = 0 なので、長さチェックで弾かれる
    (ok (not (verify-password "any-password" nil))
        "Should return NIL for nil hash without error"))

  (testing "verify-password handles UTF-8"
    (let* ((password "パスワード123")
           (hash (hash-password password)))
      (ok (verify-password password hash)
          "Should verify UTF-8 password correctly"))))

;;; ============================================================
;;; constant-time-string= テスト
;;; ============================================================

(deftest test-constant-time-string=
  (testing "constant-time-string= returns T for identical strings"
    (ok (constant-time-string= "csrf-token-123" "csrf-token-123")
        "Should return T for identical strings"))

  (testing "constant-time-string= returns NIL for different strings"
    (ok (not (constant-time-string= "csrf-token-123" "csrf-token-124"))
        "Should return NIL for different strings"))

  (testing "constant-time-string= returns NIL for different lengths"
    (ok (not (constant-time-string= "short" "longer-string"))
        "Should return NIL for different lengths"))

  (testing "constant-time-string= handles empty strings"
    (ok (constant-time-string= "" "")
        "Should return T for two empty strings")
    (ok (not (constant-time-string= "" "a"))
        "Should return NIL for empty vs non-empty"))

  (testing "constant-time-string= works with 32-char tokens"
    (let ((token1 "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4")
          (token2 "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4")
          (token3-last-diff "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d5")
          (token4-first-diff "b1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"))
      (ok (constant-time-string= token1 token2)
          "Should return T for identical 32-char tokens")
      (ok (not (constant-time-string= token1 token3-last-diff))
          "Should return NIL when last char differs")
      (ok (not (constant-time-string= token1 token4-first-diff))
          "Should return NIL when first char differs"))))

;;; ============================================================
;;; generate-session-id テスト
;;; ============================================================

(deftest test-generate-session-id
  (testing "generate-session-id returns 32-char hex string"
    (let* ((session-id (generate-session-id))
           (normalized (string-downcase session-id)))  ; 大文字小文字を正規化
      (ok (= (length session-id) 32)
          "Should be 32 characters")
      (ok (every (lambda (c)
                   (or (digit-char-p c)
                       (find c "abcdef")))
                 normalized)
          "Should contain only hex characters (0-9, a-f after normalization)")))

  (testing "generate-session-id produces unique values"
    (let ((ids (loop repeat 100 collect (generate-session-id))))
      (ok (= (length (remove-duplicates ids :test #'string-equal))  ; case-insensitive比較
             100)
          "100 generated IDs should all be unique"))))

;;; ============================================================
;;; generate-csrf-token テスト
;;; ============================================================

(deftest test-generate-csrf-token
  (testing "generate-csrf-token returns 32-char hex string"
    (let* ((token (generate-csrf-token))
           (normalized (string-downcase token)))  ; 大文字小文字を正規化
      (ok (= (length token) 32)
          "Should be 32 characters")
      (ok (every (lambda (c)
                   (or (digit-char-p c)
                       (find c "abcdef")))
                 normalized)
          "Should contain only hex characters (0-9, a-f after normalization)")))

  (testing "generate-csrf-token produces unique values"
    (let ((tokens (loop repeat 100 collect (generate-csrf-token))))
      (ok (= (length (remove-duplicates tokens :test #'string-equal))  ; case-insensitive比較
             100)
          "100 generated tokens should all be unique"))))

;;; ============================================================
;;; mask-session-id テスト
;;; ============================================================

(deftest test-mask-session-id
  (testing "mask-session-id masks standard session ID"
    (let ((masked (mask-session-id "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4")))
      (ok (string= masked "a1b2****...")
          "Should show first 4 chars with mask")))

  (testing "mask-session-id handles short strings"
    (ok (string= (mask-session-id "abc") "****")
        "3-char string should return ****")
    (ok (string= (mask-session-id "abcd") "****")
        "4-char string should return ****")
    (ok (string= (mask-session-id "abcde") "abcd****...")
        "5-char string should show first 4 chars"))

  (testing "mask-session-id handles nil and empty"
    (ok (string= (mask-session-id nil) "****")
        "nil should return ****")
    (ok (string= (mask-session-id "") "****")
        "empty string should return ****")))
