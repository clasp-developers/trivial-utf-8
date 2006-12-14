;;; Minimal utf-8 decoding and encoding library.
;;;
;;; See http://common-lisp.net/project/trivial-utf-8/

(defpackage :trivial-utf-8
  (:use :common-lisp)
  (:export :utf-8-byte-length
           :string-to-utf-8-bytes
           :write-utf-8-bytes
           :utf-8-group-size
           :utf-8-bytes-to-string
           :read-utf-8-string
           :utf-8-decoding-error))

(in-package :trivial-utf-8)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter *optimize*
    '(optimize (speed 3) (safety 0) (space 0) (debug 1)
      (compilation-speed 0))))

(defun utf-8-byte-length (string)
  "Calculate the amount of bytes needed to encode a string."
  (declare (type string string)
           #'*optimize*)
  (let ((length (length string)))
    (loop :for char :across string
          :do (let ((code (char-code char)))
                (when (> code 127)
                  (incf length
                        (cond ((< code 2048) 1)
                              ((< code 65536) 2)
                              (t 3))))))
    length))

(defun get-utf-8-bytes (char-code buffer &optional (start 0))
  "Create the bytes that encode a character. Writes these bytes to
buffer, starting at the position indicated by the optional start
argument, and returns this start position plus the amount of bytes
written."
  (declare (type fixnum char-code start)
           (type (simple-array (unsigned-byte 8)) buffer)
           #.*optimize*)
  (flet ((add-byte (value)
           (setf (elt buffer start) value)
           (incf start)))
    (cond ((< char-code 128)
           (add-byte char-code))
          ((< char-code 2048)
           (add-byte (logior #b11000000 (ldb (byte 5 6) char-code)))
           (add-byte (logior #b10000000 (ldb (byte 6 0) char-code))))
          ((< char-code 65536)
           (add-byte (logior #b11100000 (ldb (byte 4 12) char-code)))
           (add-byte (logior #b10000000 (ldb (byte 6 6) char-code)))
           (add-byte (logior #b10000000 (ldb (byte 6 0) char-code))))
          (t
           (add-byte (logior #b11110000 (ldb (byte 3 18) char-code)))
           (add-byte (logior #b10000000 (ldb (byte 6 12) char-code)))
           (add-byte (logior #b10000000 (ldb (byte 6 6) char-code)))
           (add-byte (logior #b10000000 (ldb (byte 6 0) char-code)))))
    start))

(defun string-to-utf-8-bytes (string &key null-terminate)
  "Convert a string into an array of unsigned bytes containing its
utf-8 representation."
  (declare (type string string)
           #.*optimize*)
  (let ((buffer (make-array (+ (the fixnum (utf-8-byte-length string))
                               (if null-terminate 1 0))
                            :element-type '(unsigned-byte 8)))
        (position 0))
    (loop :for char :across string
          :do (setf position (get-utf-8-bytes (char-code char)
                                               buffer position)))
    (when null-terminate
      (setf (elt buffer (1- (length buffer))) 0))
    buffer))

(defun write-utf-8-bytes (string output &key null-terminate)
  "Write a string to a byte-stream, encoding it as utf-8."
  (declare (type string string)
           (type stream output)
           #.*optimize*)
  (let ((buffer (make-array 4 :element-type '(unsigned-byte 8))))
    (loop :for char :across string
          :do (loop :for i :from 0
                    :below (the fixnum (get-utf-8-bytes (char-code char)
                                                         buffer))
                    :do (write-byte (elt buffer i) output))))
  (when null-terminate
    (write-byte 0 output)))

(define-condition utf-8-decoding-error (simple-error)
  ((message :initarg :message)
   (byte :initarg :byte :initform nil))
  (:report (lambda (err stream)
             (format stream (slot-value err 'message)
                     (slot-value err 'byte)))))

(declaim (inline utf-8-group-size))
(defun utf-8-group-size (byte)
  "Determine the amount of bytes that are part of the character
starting with a given byte."
  (declare (type fixnum byte)
           #.*optimize*)
  (cond ((zerop (logand byte #b10000000)) 1)
        ((= (logand byte #b11100000) #b11000000) 2)
        ((= (logand byte #b11110000) #b11100000) 3)
        ((= (logand byte #b11111000) #b11110000) 4)
        (t (error 'utf-8-decoding-error :byte byte
                  :message "Invalid byte at start of character: 0x~X"))))

(defun utf-8-string-length (bytes)
  "Calculate the length of the string encoded by the given bytes."
  (declare (type (simple-array (unsigned-byte 8)) bytes)
           #.*optimize*)
  (loop :with i = 0
        :with string-length = 0
        :with array-length = (length bytes)
        :while (< i array-length)
        :do (progn
              (incf (the fixnum string-length) 1)
              (incf i (utf-8-group-size (elt bytes i))))
        :finally (return string-length)))

(defun get-utf-8-character (bytes group-size &optional (start 0))
  "Given an array of bytes and the amount of bytes to use,
extract the character starting at the given start position."
  (declare (type (simple-array (unsigned-byte 8)) bytes)
           (type fixnum group-size start)
           #.*optimize*)
  (labels ((next-byte ()
             (prog1 (elt bytes start)
               (incf start)))
           (six-bits (byte)
             (unless (= (logand byte #b11000000) #b10000000)
               (error 'utf-8-decoding-error :byte byte
                      :message "Invalid byte 0x~X inside a character."))
             (ldb (byte 6 0) byte)))
    (case group-size
      (1 (next-byte))
      (2 (logior (ash (ldb (byte 5 0) (next-byte)) 6)
                 (six-bits (next-byte))))
      (3 (logior (ash (ldb (byte 4 0) (next-byte)) 12)
                 (ash (six-bits (next-byte)) 6)
                 (six-bits (next-byte))))
      (4 (logior (ash (ldb (byte 3 0) (next-byte)) 18)
                 (ash (six-bits (next-byte)) 12)
                 (ash (six-bits (next-byte)) 6)
                 (six-bits (next-byte)))))))

(defun utf-8-bytes-to-string (bytes)
  "Convert a byte array containing utf-8 encoded characters into
the string it encodes." 
 (declare (type (array (unsigned-byte 8)) bytes)
           #.*optimize*)
  (loop :with buffer = (make-string (utf-8-string-length bytes))
        :with array-position = 0
        :with string-position = 0
        :with array-length = (length bytes)
        :while (< array-position array-length)
        :do (let* ((char (elt bytes array-position))
                   (current-group (utf-8-group-size char)))
              (when (> (+ current-group array-position) array-length)
                (error 'utf-8-decoding-error
                       :message "Unfinished character at end of byte array."))
              (setf (char buffer string-position)
                 (code-char (get-utf-8-character bytes current-group
                                                 array-position)))
              (incf string-position 1)
              (incf array-position current-group))
        :finally (return buffer)))

(defun read-utf-8-string (input &key null-terminated stop-at-eof
                          char-length byte-length)
  "Read utf-8 encoded data from a byte stream and construct a
string with the characters found. When null-terminated is given
it will stop reading at a null character, stop-at-eof tells it to
stop at the end of file without raising an error, and the
char-length and byte-length parameters can be used to specify the
max amount of characters or bytes to read."
  (declare (type stream input)
           (type fixnum byte-length char-length)
           #.*optimize*)
  (let ((buffer (make-array 4 :element-type '(unsigned-byte 8)))
        (bytes-read 0)
        (string (make-array 64 :element-type 'character
                            :adjustable t :fill-pointer 0)))
    (loop
      (when (or (and byte-length (>= bytes-read byte-length))
                (and char-length (= char-length (length string))))
        (return))
      (let ((next-char (read-byte input (not stop-at-eof) :eof)))
        (when (or (eq next-char :eof)
                  (and null-terminated (eq next-char 0)))
          (return))
        (let ((current-group (utf-8-group-size next-char)))
          (incf bytes-read current-group)
          (cond ((= current-group 1)
                 (vector-push-extend (code-char next-char) string))
                (t
                 (setf (elt buffer 0) next-char)
                 (loop :for i :from 1 :below current-group
                       :for next-char = (read-byte input nil :eof)
                       :do (when (eq next-char :eof)
                             (error 'utf-8-decoding-error
                                    :message "Unfinished character at end of input."))
                       :do (setf (elt buffer i) next-char))
                 (vector-push-extend (code-char (get-utf-8-character
                                                 buffer current-group))
                                     string))))))
    string))

;;; Copyright (c) 2006 Marijn Haverbeke
;;;
;;; This software is provided 'as-is', without any express or implied
;;; warranty. In no event will the authors be held liable for any
;;; damages arising from the use of this software.
;;;
;;; Permission is granted to anyone to use this software for any
;;; purpose, including commercial applications, and to alter it and
;;; redistribute it freely, subject to the following restrictions:
;;;
;;; 1. The origin of this software must not be misrepresented; you must
;;;    not claim that you wrote the original software. If you use this
;;;    software in a product, an acknowledgment in the product
;;;    documentation would be appreciated but is not required.
;;;
;;; 2. Altered source versions must be plainly marked as such, and must
;;;    not be misrepresented as being the original software.
;;;
;;; 3. This notice may not be removed or altered from any source
;;;    distribution.