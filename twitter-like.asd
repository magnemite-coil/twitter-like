(defsystem "twitter-like"
  :version "0.1.0"
  :author "Your Name"
  :license "MIT"
  :depends-on (:caveman2
               :clack
               :clack-handler-hunchentoot
               :hunchentoot
               :woo
               :mito
               :sxql
               :com.inuoe.jzon        ; Jzon (JSON処理)
               :cl-redis
               :ironclad
               :cl-dotenv
               :lack
               :lack-request
               :lack-response
               :lack-middleware-static  ; 静的ファイル配信
               :flexi-streams
               :local-time
               :bordeaux-threads      ; マルチスレッド対応（ロガー用）
               :str                   ; 文字列操作ユーティリティ
               :cl-ppcre              ; 正規表現（バリデーション用）
               :babel)                ; 文字エンコーディング
  :components ((:module "src"
                :components
                ((:file "config")                              ; 最初に読み込む
                 (:module "util"
                  :depends-on ("config")
                  :components
                  ((:file "logger")
                   (:file "response")
                   (:file "crypto")
                   (:file "time")
                   (:file "json")
                   (:file "rate-limit" :depends-on ("time"))
                   (:file "request" :depends-on ("logger"))))                          ; 認証用暗号ユーティリティ
                 (:file "db" :depends-on ("config"))          ; configに依存
                 (:module "middleware"
                  :depends-on ("config" "util")
                  :components
                  ((:file "security")
                   (:file "cors")
                   (:file "session")))
                 (:module "model"
                  :depends-on ("config" "db")
                  :components
                  ((:file "user")
                   (:file "tweet")))                           ; ツイートモデル
                 (:module "service"
                  :depends-on ("config" "model" "middleware" "util")
                  :components
                  ((:file "auth")
                   (:file "tweet")))                           ; ツイートサービス
                 (:module "handler"
                  :depends-on ("config" "util" "db" "middleware" "model" "service")
                  :components
                  ((:file "health")
                   (:file "auth")
                   (:file "tweet")
                   (:file "csp-report")))                           ; ツイートハンドラー
                 (:file "web" :depends-on ("config" "util" "middleware" "handler"))  ; handlerに依存
                 (:file "main" :depends-on ("config" "db" "web" "handler" "middleware" "util" "model" "service")))))
  :description "2012年頃のTwitterをリバースエンジニアリングするプロジェクト"
  :in-order-to ((test-op (test-op "twitter-like/tests"))))

(defsystem "twitter-like/tests"
  :depends-on (:twitter-like
               :rove
               :dexador)              ; HTTPクライアント（テスト用）
  :components ((:module "test"
                :components
                (;; 共通ユーティリティ（最初に読み込む）
                 (:file "util")
                 (:file "setup")
                 (:file "test-config" :depends-on ("setup" "util"))
                 (:file "test-db" :depends-on ("setup"))
                 (:file "test-health" :depends-on ("setup"))
                 (:file "test-auth" :depends-on ("setup"))
                 (:file "test-tweet" :depends-on ("setup"))
                 ;; 新規追加（setupへの依存なし - 独自に初期化）
                 ;; 理由: ユニットテストはHTTPサーバーを起動せず、
                 ;; 対象関数のみをテストするため軽量な独自setupを使用
                 (:file "test-crypto")
                 (:file "test-session")
                 (:file "test-request" :depends-on ("util"))
                 ;; 認証バリデーション（純粋関数、setup不要）
                 (:file "test-auth-validation")
                 ;; 認証サービス（Redis/DB依存、独自setup）
                 (:file "test-auth-service")
                 ;; ミドルウェアユニットテスト（util依存）
                 (:file "test-cors" :depends-on ("util"))
                 (:file "test-security" :depends-on ("util"))
                 ;; ハンドラーユニットテスト
                 (:file "test-csp-report")
                 ;; Health Handler ユニットテスト（サーバー起動不要、独自setup）
                 (:file "test-health-unit"))))
  :perform (test-op (op c) (symbol-call :rove :run c)))
