(defpackage twitter-like.util.crypto
  (:use :cl)
  (:import-from :ironclad
                :make-random-salt
                :pbkdf2-hash-password
                :pbkdf2-check-password
                :random-data
                :byte-array-to-hex-string)
  (:import-from :flexi-streams
                :string-to-octets)
  (:export :hash-password
           :verify-password
           :generate-session-id
           :generate-csrf-token
           :constant-time-string=
           :mask-session-id))

(in-package :twitter-like.util.crypto)

(defconstant +pbkdf2-iterations+ 600000
  "PBKDF2イテレーション回数（OWASP 2024-2025推奨）")

(defconstant +salt-size+ 16
  "ソルト長（128ビット = 16バイト）")

(defconstant +key-length+ 32
  "出力長（256ビット = 32バイト）")

(defconstant +session-id-size+ 16
  "セッションID長（128ビット = 16バイト）")

(defconstant +csrf-token-size+ 16
  "CSRFトークン長（128ビット = 16バイト）")

(defun hash-password (password)
  "パスワードをPBKDF2-HMAC-SHA256でハッシュ化
  戻り値: Ironcladのpbkdf2ハッシュ構造体（ソルトを含む）"
  (let ((salt (ironclad:make-random-salt :size +salt-size+)))
    (ironclad:pbkdf2-hash-password
     (flexi-streams:string-to-octets password :external-format :utf-8)
     :salt salt
     :iterations +pbkdf2-iterations+
     :digest :sha256
     :key-length +key-length+)))

(defun verify-password (password hash)
  "パスワードとハッシュを比較
  定数時間比較が内部で行われる（Ironcladの実装）"
  (ironclad:pbkdf2-check-password
   (flexi-streams:string-to-octets password :external-format :utf-8)
   hash))

(defun generate-session-id ()
  "128ビットの暗号学的に安全なセッションIDを生成
  戻り値: 32文字の16進数文字列"
  (ironclad:byte-array-to-hex-string
   (ironclad:random-data +session-id-size+)))

(defun generate-csrf-token ()
  "128ビットの暗号学的に安全なCSRFトークンを生成
  戻り値: 32文字の16進数文字列"
  (ironclad:byte-array-to-hex-string
   (ironclad:random-data +csrf-token-size+)))

(defun constant-time-string= (a b)
  "文字列の定数時間比較（タイミング攻撃対策）
  長さが異なる場合でも処理時間を一定に保つ"
  (let ((a-len (length a))
        (b-len (length b)))
    (if (/= a-len b-len)
        ;; 長さが異なる場合も定数時間で処理
        (progn
          ;; ダミー比較を実行して処理時間を揃える
          (let ((dummy-result 0))
            (dotimes (i (max a-len b-len))
              (let ((a-char (if (< i a-len) (char-code (char a i)) 0))
                    (b-char (if (< i b-len) (char-code (char b i)) 0)))
                (setf dummy-result (logior dummy-result (logxor a-char b-char)))))
            ;; 長さが違うので常にfalse
            nil))
        ;; 長さが同じ場合の比較
        (zerop (reduce #'logior
                       (map 'list
                            (lambda (x y) (logxor (char-code x) (char-code y)))
                            a b)
                       :initial-value 0)))))

(defun mask-session-id (session-id)
  "セッションIDをマスク化（先頭4文字のみ表示）
  例: 'a3f2b1c4d5e6f789...' -> 'a3f2****...'
  デバッグ目的でのトレースは可能だが、セキュリティリスクを最小化"
  (if (and session-id (> (length session-id) 4))
      (format nil "~A****..." (subseq session-id 0 4))
      "****"))
