;; This file is part of mowedline.
;; Copyright (C) 2015  John J. Foerch
;;
;; mowedline is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; mowedline is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with mowedline.  If not, see <http://www.gnu.org/licenses/>.

(import chicken scheme)

(use (srfi 1)
     coops
     matchable
     pathname-expand)

;;;
;;; Language
;;;

(define L list)

(define rest cdr)

(define-syntax bind
  (syntax-rules ()
    ((bind pattern exp . body)
     (match exp (pattern . body)))))

(define-syntax bind-lambda
  (syntax-rules ()
    ((bind-lambda pattern . body)
     (match-lambda (pattern . body)))))

(define-syntax bind-lambda*
  (syntax-rules ()
    ((bind-lambda* pattern . body)
     (match-lambda* (pattern . body)))))


;;;
;;; Utils
;;;

(define (ensure-list x)
  (if (list? x)
      x
      (list x)))

(define-inline (*subclass? c1 c2)
  (or (eq? c1 c2) (subclass? c1 c2)))

(define (instance-of? x class)
  (*subclass? (class-of x) class))

(define (split-properties lst)
  (bind (_ props . tail)
      (fold
       (bind-lambda*
        (x (expect-value? props . tail))
        (cond
         (expect-value?
          (cons* #f (cons x props) tail))
         ((symbol? x)
          (cons* #t (cons x props) tail))
         (else
          (cons* #f props x tail))))
       (cons* #f '() '())
       lst)
    (values (reverse! props) (reverse! tail))))

;; text-maybe-pad-left prepends a space on a string or mowedline markup
;; structure iff the text is non-null.
;;
(define (text-maybe-pad-left text)
  (cond
   ((and (string? text)
         (not (string-null? text)))
    (string-append " " text))
   ((and (pair? text)
         (not (null? text)))
    (cons " " text))
   (else text)))

;; widget-update-at-interval calls widget-update on the given widget every
;; interval seconds, with the value returned by (thunk).
;;
(define (widget-update-at-interval widget interval thunk)
  (define (poll-thread widget)
    (lambda ()
      (let loop ()
        (gochan-send
         *internal-events*
         (lambda () (update widget (thunk))))
        (thread-sleep! interval)
        (loop))))
  (thread-start!
   (make-thread (poll-thread widget))))


;;;
;;; Environment
;;;

(define (xdg-config-home)
  (let ((path (get-environment-variable "XDG_CONFIG_HOME")))
    (if (and path (not (string-null? path)))
        path
        (pathname-expand "~/.config"))))
