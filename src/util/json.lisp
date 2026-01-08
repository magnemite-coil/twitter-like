(defpackage twitter-like.util.json
  (:use :cl)
  (:export :value-or-json-null
           :slot-value-or-json-null))

(in-package :twitter-like.util.json)

(defun value-or-json-null (value)
  "値を取得、NILの場合はJSON nullを返す
   用途: plistやプリミティブ値のJSON変換時
   注意: JzonではNILはfalseに変換されるため、nullには'nullシンボルを使う"
  (if value value 'null))

(defun slot-value-or-json-null (object slot-name)
  "スロット値を取得、NILの場合はJSON nullを返す
   用途: MitoオブジェクトのJSON変換時"
  (let ((value (slot-value object slot-name)))
    (if value value 'null)))
