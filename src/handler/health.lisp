(defpackage twitter-like.handler.health
  (:use :cl)
  (:import-from :twitter-like.util.response
                :response-success
                :response-error)
  (:import-from :twitter-like.util.logger
                :log-error
                :log-warn)
  (:import-from :com.inuoe.jzon
                :stringify)
  (:import-from :str
                :split
                :emptyp
                :replace-all)
  (:export :register-health-routes
           ;; Exported for unit testing
           :collect-health-data))

(in-package :twitter-like.handler.health)

(defun collect-health-data (&key db-check-fn redis-check-fn disk-check-fn memory-check-fn)
  "ヘルスデータを収集するコア関数（テスト可能）

   This is the core logic extracted for testability.
   参考: src/handler/csp-report.lisp:90-149 の process-csp-report

   Args:
     db-check-fn: DB接続チェック関数（error を投げると disconnected）
     redis-check-fn: Redis接続チェック関数（error を投げると disconnected）
     disk-check-fn: ディスク使用率チェック関数（hash-table を返す）
     memory-check-fn: メモリ使用量チェック関数（hash-table を返す）

   Returns:
     A plist with keys:
       :health-data - ヘルスデータのハッシュテーブル
       :http-status - HTTPステータスコード (200 or 503)"
  (let ((health-data (make-hash-table :test 'equal)))
    ;; 基本情報
    (setf (gethash "status" health-data) "healthy")
    (setf (gethash "timestamp" health-data) (local-time:timestamp-to-unix (local-time:now)))

    ;; データベース接続確認
    (handler-case
        (progn
          (funcall db-check-fn)
          (setf (gethash "database" health-data) "connected"))
      (error (e)
        (setf (gethash "database" health-data) "disconnected")
        (setf (gethash "status" health-data) "unhealthy")
        (twitter-like.util.logger:log-error "Database health check failed" :error e)))

    ;; Redis接続確認
    (handler-case
        (progn
          (funcall redis-check-fn)
          (setf (gethash "redis" health-data) "connected"))
      (error (e)
        (setf (gethash "redis" health-data) "disconnected")
        (setf (gethash "status" health-data) "unhealthy")
        (twitter-like.util.logger:log-error "Redis health check failed" :error e)))

    ;; ディスク容量チェック
    (let ((disk-usage
            (handler-case
                (funcall disk-check-fn)
              (error (e)
                (twitter-like.util.logger:log-warn "Disk check failed"
                                                   :context (list :|error| (princ-to-string e)))
                (let ((result (make-hash-table :test 'equal)))
                  (setf (gethash "status" result) "unknown")
                  result)))))
      (setf (gethash "disk" health-data) disk-usage)
      ;; ステータス優先順位: unhealthy が設定済みなら degraded に上書きしない
      (when (and (string= (gethash "status" health-data) "healthy")
                 (gethash "usage_percent" disk-usage)
                 (> (gethash "usage_percent" disk-usage) 90))
        (setf (gethash "status" health-data) "degraded")
        (twitter-like.util.logger:log-warn "Disk usage critical"
                                           :context (list :|usage_percent| (gethash "usage_percent" disk-usage)))))

    ;; メモリ使用量チェック
    (let ((memory-usage
            (handler-case
                (funcall memory-check-fn)
              (error (e)
                (twitter-like.util.logger:log-warn "Memory check failed"
                                                   :context (list :|error| (princ-to-string e)))
                (let ((result (make-hash-table :test 'equal)))
                  (setf (gethash "status" result) "unknown")
                  result)))))
      (setf (gethash "memory" health-data) memory-usage))

    ;; HTTPステータスコードを決定
    (let ((http-status (cond
                         ((string= (gethash "status" health-data) "healthy") 200)
                         ((string= (gethash "status" health-data) "degraded") 200)
                         (t 503))))
      (list :health-data health-data :http-status http-status))))

(defun health-handler (params)
  "ヘルスチェックエンドポイント（薄いラッパー）

   実際のヘルスチェックロジックは collect-health-data に委譲。
   参考: src/handler/csp-report.lisp:138-149 の csp-report-handler"
  (declare (ignore params))
  (handler-case
      (let* ((result (collect-health-data
                       :db-check-fn (lambda ()
                                      (twitter-like.db:ensure-db-connected))
                       :redis-check-fn (lambda ()
                                         (twitter-like.middleware.session:ensure-redis-connected)
                                         (red:ping))
                       :disk-check-fn #'check-disk-usage
                       :memory-check-fn #'check-memory-usage))
             (health-data (getf result :health-data))
             (http-status (getf result :http-status))
             ;; API互換性維持:
             ;; HTTPステータスのみ 200/503 を切り替え、JSON形状は常に同一とする
             ;; （旧設計 docs/design/old/foundation-setup.md:1148-1164 に準拠）
             ;;
             ;; 実装上の注意:
             ;; response-success は 2xx 限定のため、503 では直接 Clack 形式を生成
             ;; content-length-value: Woo では文字列、Hunchentoot では整数で Content-Length を期待
             ;; response.lisp からエクスポート済み
             (json-string (com.inuoe.jzon:stringify health-data))
             (content-length (length (babel:string-to-octets json-string :encoding :utf-8))))
        (list http-status
              (list :content-type "application/json; charset=utf-8"
                    :content-length (twitter-like.util.response:content-length-value content-length)
                    :connection "close")
              (list json-string)))
    (error (e)
      ;; エラーIDを生成してログ記録（既存ロジック維持）
      (let ((error-id (twitter-like.util.logger:log-error
                        "Health check failed"
                        :error e)))
        (response-error 503 "Service Unavailable" :error-id error-id)))))

(defun check-disk-usage ()
  "ディスク容量をチェック（POSIX準拠、移植性向上版）"
  (handler-case
      (let* ((log-dir (uiop:pathname-directory-pathname
                        (twitter-like.config:get-config "log-file")))
             ;; df -P でPOSIX準拠フォーマット（移植性向上、macOS/Linux共通）
             (df-output (uiop:run-program
                          (list "df" "-P" (namestring log-dir))
                          :output :string))
             ;; 1行目はヘッダー、2行目がデータ
             (lines (str:split #\Newline df-output :omit-nulls t))
             (data-line (second lines))
             ;; スペースで分割（空文字列を除去）
             (fields (remove-if #'str:emptyp (str:split #\Space data-line)))
             ;; POSIX準拠フォーマットでは5番目のフィールドが使用率（0-indexed: 4番目）
             ;; フォーマット: Filesystem 512-blocks Used Available Capacity Mounted
             (usage-str (fifth fields))
             (usage-percent (parse-integer (str:replace-all "%" "" usage-str))))
        (let ((result (make-hash-table :test 'equal)))
          (setf (gethash "status" result) "ok")
          (setf (gethash "usage_percent" result) usage-percent)
          result))
    (error (e)
      (twitter-like.util.logger:log-warn "Failed to check disk usage" :error e)
      (let ((result (make-hash-table :test 'equal)))
        (setf (gethash "status" result) "unknown")
        result))))

(defun check-memory-usage ()
  "メモリ使用量をチェック（SBCL専用、他の処理系では'unsupported'を返す）"
  (handler-case
      #+sbcl
      (let* ((dynamic-usage (sb-kernel:dynamic-usage))
             ;; バイトからMBに変換
             (usage-mb (/ dynamic-usage 1024 1024)))
        (let ((result (make-hash-table :test 'equal)))
          (setf (gethash "status" result) "ok")
          (setf (gethash "usage_mb" result) (floor usage-mb))
          result))
      #-sbcl
      (let ((result (make-hash-table :test 'equal)))
        (setf (gethash "status" result) "unsupported")
        (setf (gethash "implementation" result) (lisp-implementation-type))
        result)
    (error (e)
      (twitter-like.util.logger:log-warn "Failed to check memory usage" :error e)
      (let ((result (make-hash-table :test 'equal)))
        (setf (gethash "status" result) "unknown")
        result))))

(defun register-health-routes (app)
  "ヘルスチェックルートをアプリケーションに登録"
  (setf (ningle:route app "/api/health" :method :get) #'health-handler)
  app)
