
;; mowedline: programmable status bar for X
;; Copyright (C) 2011  John J. Foerch
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

(import chicken scheme extras foreign)

(use srfi-1
     srfi-4 ;; homogeneous numeric vectors
     srfi-69 ;; hash tables
     coops
     dbus
     environments
     filepath
     list-utils
     lolevel
     miscmacros
     posix
     xlib)


(define version "0.0")


;;;
;;; Language
;;;

(define L list)
(define rest cdr)


;;;
;;; Globals
;;;

(define *display* #f)

(define *screen* #f)

(define *windows* (list))

(define *widgets* (make-hash-table test: equal?))


;;;
;;; Window
;;;

(define-generic (window-expose window))

(define-class <window> ()
  ((screen initform: (xdefaultscreen *display*))
   (position initform: 'top)
   (height initform: #f)
   (width initform: #f)
   (widgets initform: (list))
   (xwindow)))

(define-method (initialize-instance (window <window>))
  (call-next-method)
  (let* ((screen (slot-value window 'screen))
         (shei (xdisplayheight *display* screen))
         (position (slot-value window 'position))
         (width (or (slot-value window 'width) (xdisplaywidth *display* screen)))
         (height (or (slot-value window 'height)
                     (fold max 1 (map widget-height (slot-value window 'widgets)))))
         (window-top (case position
                       ((bottom) (- shei height))
                       (else 0)))
         (xwindow (xcreatesimplewindow
                   *display*
                   (xrootwindow *display* screen)
                   0 window-top width height 0
                   (xblackpixel *display* screen)
                   (xwhitepixel *display* screen))))
    (assert xwindow)
    (set! (slot-value window 'width) width)
    (set! (slot-value window 'height) height)
    (set! (slot-value window 'xwindow) xwindow)
    (for-each (lambda (widget) (widget-set-window! widget window))
              (slot-value window 'widgets))

    (let ((attr (make-xsetwindowattributes)))
      (set-xsetwindowattributes-background_pixel! attr (xblackpixel *display* screen))
      (set-xsetwindowattributes-border_pixel! attr (xblackpixel *display* screen))
      (set-xsetwindowattributes-override_redirect! attr 1)
      (xchangewindowattributes *display* xwindow
                               (bitwise-ior CWBACKPIXEL CWBORDERPIXEL CWOVERRIDEREDIRECT)
                               attr))

    ;; Window Properties
    ;;
    (xstorename *display* xwindow "mowedline")

    (let ((p (make-xtextproperty))
          (str (make-text-property (get-host-name))))
      (xstringlisttotextproperty str 1 p)
      (xsetwmclientmachine *display* xwindow p))

    (window-property-set xwindow "_NET_WM_PID"
                         (make-number-property (current-process-id)))
    (window-property-set xwindow "_NET_WM_WINDOW_TYPE"
                         (make-atom-property "_NET_WM_TYPE_DOCK"))
    (window-property-set xwindow "_NET_WM_DESKTOP"
                         (make-number-property #xffffffff))
    (window-property-set xwindow "_NET_WM_STATE"
                         (make-atom-property "_NET_WM_STATE_BELOW"))
    (window-property-append xwindow "_NET_WM_STATE"
                            (make-atom-property "_NET_WM_STATE_STICKY"))
    (window-property-append xwindow "_NET_WM_STATE"
                            (make-atom-property "_NET_WM_STATE_SKIP_TASKBAR"))
    (window-property-append xwindow "_NET_WM_STATE"
                            (make-atom-property "_NET_WM_STATE_SKIP_PAGER"))

    ;; Struts: left, right, top, bottom,
    ;;         left_start_y, left_end_y, right_start_y, right_end_y,
    ;;         top_start_x, top_end_x, bottom_start_x, bottom_end_x
    ;;
    ;; so for a top panel, we set top, top_start_x, and top_end_x.
    (window-property-set xwindow "_NET_WM_STRUT_PARTIAL"
                         (make-numbers-property
                          (if (eq? position 'bottom)
                              (list 0 0 0 height 0 0 0 0 0 0 0 0)
                              (list 0 0 height 0 0 0 0 0 0 0 0 0))))

    (let ((d-atom (xinternatom *display* "WM_DELETE_WINDOW" 1)))
      (let-location ((atm unsigned-long d-atom))
        (xsetwmprotocols *display* xwindow (location atm) 1)))

    (push! window *windows*)))

(define-method (window-expose (window <window>))
  (let* ((taken 0)
         (flex 0)
         (wids (map (lambda (x)
                      (if* (slot-value x 'flex)
                           (begin (set! flex (+ flex it))
                                  #f)
                           (let ((wid (widget-width x)))
                             (set! taken (+ taken wid))
                             wid)))
                    (slot-value window 'widgets)))
         ;;XXX: we should be using the width of the window, not the screen.
         (remainder (- (xdisplaywidth *display* (slot-value window 'screen))
                       taken))
         (flexunit (if (> flex 0) (/ remainder flex) 0))
         (left 10))
    (for-each
     (lambda (w wid)
       (cond (wid (widget-draw w left wid)
                  (set! left (+ left wid)))
             (else (let ((wid (* flexunit (slot-value w 'flex))))
                     (widget-draw w left wid)
                     (set! left (+ left wid))))))
     (slot-value window 'widgets)
     wids)))


;;;
;;; Widgets
;;;

(define-generic (widget-draw widget x wid))
(define-generic (widget-height widget))
(define-generic (widget-update widget params))
(define-generic (widget-width widget))
(define-generic (widget-set-window! widget window))

(define-class <widget> ()
  ((name)
   (flex initform: #f)
   (window)
   (gc)))

(define-method (initialize-instance (widget <widget>))
  (call-next-method)
  (when (hash-table-exists? *widgets* (slot-value widget 'name))
    (error "duplicate widget name"))
  (hash-table-set! *widgets* (slot-value widget 'name) widget))

(define-method (widget-set-window! (widget <widget>) (window <window>))
  (set! (slot-value widget 'window) window))

(define-method (widget-height (widget <widget>)) 1)
(define-method (widget-width (widget <widget>)) 1)

;; Text Widget
;;
(define-class <text-widget> (<widget>)
  ((text initform: "")
   (font initform: (or (get-font "9x15bold")
                       (get-font "*")
                       (error "no font")))))

(define-method (widget-set-window! (widget <text-widget>) (window <window>))
  (call-next-method)
  (let ((gc (xcreategc *display*
                       (slot-value window 'xwindow)
                       0 #f)))
    (xsetbackground *display* gc (xblackpixel *display* (slot-value window 'screen)))
    (xsetforeground *display* gc (xwhitepixel *display* (slot-value window 'screen)))
    (xsetfunction *display* gc GXCOPY)
    (xsetfont *display* gc (xfontstruct-fid (slot-value widget 'font)))
    ;;(xsetregion *display* gc (xcreateregion))
    (set! (slot-value widget 'gc) gc)))

(define-method (widget-draw (widget <text-widget>) x wid)
  ;; XCreateRegion() --> pointer to region
  ;; XUnionRectWithRegion()
  ;; XDestroyRegion()
  ;; (xoffsetregion r x 0)

  ; (xunionrectwithregion rect src dest)
  ; (let ((r (xcreateregion)))
  ;   (xsetregion *display* gc r))
  (let ((text (slot-value widget 'text))
        (baseline (xfontstruct-ascent (slot-value widget 'font))))
    (xdrawimagestring *display*
                      (slot-value (slot-value widget 'window) 'xwindow)
                      (slot-value widget 'gc)
                      x baseline text (string-length text))))

(define-method (widget-height (widget <text-widget>))
  ;; i find even common fonts extend a pixel lower than their
  ;; declared descent.  tsk tsk.
  (let ((font (slot-value widget 'font)))
    (+ (xfontstruct-ascent font) (xfontstruct-descent font) 2)))

(define-method (widget-update (widget <text-widget>) params)
  ;; after update, the caller will call draw.  but efficiency could be
  ;; gained if the caller knew if our width changed, thus determining how
  ;; much of the window needed to be redrawn.
  (set! (slot-value widget 'text) (first params)))

(define-method (widget-width (widget <text-widget>))
  (xtextwidth (slot-value widget 'font)
              (slot-value widget 'text)
              (string-length (slot-value widget 'text))))



;;;
;;; Window Property Utils
;;;

(define (property-type property)
  (vector-ref property 0))
(define (property-format property)
  (vector-ref property 1))
(define (property-data property)
  (vector-ref property 2))
(define (property-count property)
  (vector-ref property 3))

(define (make-atom-property atom-name)
  (let ((data (xinternatom *display* atom-name 0)))
    (let-location ((data unsigned-long data))
      (vector "ATOM" 32
              (location data)    
              1))))

(define (make-number-property number)
  (let-location ((data unsigned-long number))
    (vector "CARDINAL" 32 (location data) 1)))

(define (make-numbers-property numbers)
  (let* ((vec (list->u32vector numbers))
         (len (u32vector-length vec))
         (lvec ((foreign-lambda* c-pointer ((u32vector s) (int length))
                  "unsigned long * lvec = malloc(sizeof(unsigned long) * length);"
                  "int i;"
                  "for (i = 0; i < length; i++) {"
                  "    lvec[i] = s[i];"
                  "}"
                  "C_return(lvec);")
                vec len)))
    (set-finalizer! lvec free)
    (vector "CARDINAL" 32 lvec len)))

(define (make-text-property textp)
  (let ((tp (make-xtextproperty)))
    (set-xtextproperty-value! tp (make-locative textp))
    (set-xtextproperty-encoding! tp XA_STRING)
    (set-xtextproperty-format! tp 32)
    (set-xtextproperty-nitems! tp 1)
    tp))

(define (window-property-set win key value)
  (xchangeproperty *display* win
                   (xinternatom *display* key 0)
                   (xinternatom *display* (property-type value) 0)
                   (property-format value)
                   PROPMODEREPLACE
                   (property-data value)
                   (property-count value)))

(define (window-property-append win key value)
  (xchangeproperty *display* win
                   (xinternatom *display* key 0)
                   (xinternatom *display* (property-type value) 0)
                   (property-format value)
                   PROPMODEAPPEND
                   (property-data value)
                   (property-count value)))


(define (get-font font-name)
  (let ((font (xloadqueryfont *display* font-name)))
    font))


(define (update . params)
  (let* ((name (first params))
         (widget (hash-table-ref *widgets* name)))
    (widget-update widget (cdr params))
    (window-expose (slot-value widget 'window))))


(define (start-server commands)
  (set! *display* (xopendisplay #f))
  (assert *display*)

  (let ((event (make-xevent))
        (done #f))

    (define (quit . params)
      (set! done #t))

    (define (eventloop)
      (when (> (xpending *display*) 0)
        (xnextevent *display* event)
        (let ((type (xevent-type event)))
          (cond
           ((= type CLIENTMESSAGE)
            (set! done #t))
           ((= type EXPOSE)
            (let* ((xwindow (xexposeevent-window event))
                   (window (find (lambda (win)
                                   (equal? (slot-value win 'xwindow) xwindow))
                                 *windows*)))
              (window-expose window)))
           ((= type BUTTONPRESS)
            (set! done #t)))))
      (dbus:poll-for-message)
      (unless done
        (eventloop)))

    (if* (find file-read-access?
               (L (filepath:join-path (L "~" ".mowedline"))
                  (filepath:join-path (L "~" ".config" "mowedline" "init.scm"))))
         (let ((env (environment-copy (interaction-environment))))
           (environment-extend! env 'make make)
           (load it (lambda (form) (eval form env)))))

    ;; now command line options get processed, somehow

    (when (null? *windows*)
      (make <window>
        'widgets
        (L (make <text-widget>
             'name "default"
             'text "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"))))

    (let ((dbus-context
           (dbus:make-context service: 'mowedline.server
                              interface: 'mowedline.interface)))
      (dbus:enable-polling-thread! enable: #f)
      (dbus:register-method dbus-context "update" update)
      (dbus:register-method dbus-context "quit" quit))

    (for-each
     (lambda (w)
       (xselectinput *display*
                     (slot-value w 'xwindow)
                     (bitwise-ior EXPOSUREMASK
                                  BUTTONPRESSMASK
                                  STRUCTURENOTIFYMASK))
       (xmapwindow *display* (slot-value w 'xwindow))
       (xnextevent *display* event)
       (window-expose w))
     *windows*)
    (xflush *display*)
    (eventloop))
  (xclosedisplay *display*))


(define (start-client commands)
  (for-each
   (lambda (cmd)
     (let* ((def (find-command-def (car cmd) client-options)))
       (apply (command-body def) (cdr cmd))))
   commands))


(define-syntax make-command
  (syntax-rules (#:doc)
    ((make-command (name . args) #:doc doc . body)
     (vector '(name . args) doc (lambda args . body)))
    ((make-command (name . args) . body)
     (vector '(name . args) #f (lambda args . body)))))

(define (command-name command-def)
  (first (vector-ref command-def 0)))

(define (command-args command-def)
  (rest (vector-ref command-def 0)))

(define (command-doc command-def)
  (vector-ref command-def 1))

(define (command-body command-def)
  (vector-ref command-def 2))


(define (find-command-def name command-set)
  (find (lambda (x) (equal? name (symbol->string (command-name x))))
   command-set))


(define server-options
  (L (make-command (text-widget name) 1)
     (make-command (bg color) 1)
     (make-command (fg color) 1)
     (make-command (screen screen) 1)
     (make-command (position position) 1)))


(define client-options
  (L (make-command (quit)
       doc: "quit the program"
       (let ((dbus-context
              (dbus:make-context service: 'mowedline.server
                                 interface: 'mowedline.interface)))
         (dbus:call dbus-context "quit")))

     (make-command (read widget source)
       doc: "updates widget by reading lines from source"
       (let ((dbus-context
              (dbus:make-context service: 'mowedline.server
                                 interface: 'mowedline.interface)))
         ;; read source until EOF, calling update for each line
         (cond ((equal? source "stdin:")
                (read-line))
               (else
                ))
         1))

     (make-command (update widget value)
       doc: "updates widget with value"
       (let ((dbus-context
              (dbus:make-context service: 'mowedline.server
                                 interface: 'mowedline.interface)))
         (dbus:call dbus-context "update" widget value)))))


(define special-options
  (L (make-command (help)
       doc: "displays this help"
       (let ((longest
              (fold max 0
                    (map
                     (lambda (def)
                       (apply + 2 (string-length (symbol->string (command-name def)))
                              (* 3 (length (command-args def)))
                              (map (compose string-length symbol->string)
                                   (command-args def))))
                     (append server-options client-options special-options))))
             (docspc 3))
         (define (help-section option-group)
           (for-each
            (lambda (def)
              (let ((col1 (apply string-append " -" (symbol->string (command-name def))
                                 (map (lambda (a)
                                        (string-append " <" (symbol->string a) ">"))
                                      (command-args def)))))
                (display col1)
                (when (command-doc def)
                  (dotimes (_ (+ docspc (- longest (string-length col1)))) (display " "))
                  (display (command-doc def)))
                (newline)))
            option-group))
         (printf "mowedline version ~A, by John J. Foerch~%" version)
         (printf "~%SPECIAL OPTIONS  (evaluate first one and exit)~%~%")
         (help-section special-options)
         (printf "~%SERVER OPTIONS  (only valid when starting the server)~%~%")
         (help-section server-options)
         (printf "~%CLIENT OPTIONS~%~%")
         (help-section client-options)
         (newline)))

    (make-command (version)
      doc: "prints the version"
      (printf "mowedline version ~A, by John J. Foerch~%" version))))


(define (make-commands-stucture)
  (vector '() '() '()))

(define (optype-internal-index optype)
  (case optype
    ((server-options) 0)
    ((client-options) 1)
    ((special-options) 2)))

(define (add-command! commands optype command)
  (let ((k (optype-internal-index optype)))
    (vector-set! commands k (cons command (vector-ref commands k)))))

(define (get-server-commands commands)
  (reverse (vector-ref commands 0)))

(define (get-client-commands commands)
  (reverse (vector-ref commands 1)))

(define (get-special-commands commands)
  (reverse (vector-ref commands 2)))

(define (mkcmd op args)
  (cons op args))

(define parse-command-line
  (case-lambda
   ((input count out)
    (if (null? input)
        out
        (let* ((opsym (first input))
               (input (rest input))
               (count (- count 1))
               (op (string-trim opsym #\-))
               (def #f)
               (optype (find (lambda (optype)
                               (set! def (find-command-def op (eval optype)))
                               def)
                             '(server-options client-options special-options))))
          (unless def
            (error (sprintf "unexpected symbol ~S~%" opsym)))
          (let ((narg (length (command-args def))))
            (when (< count narg)
              (error (sprintf "~A requires ~A arguments, but only ~A were given"
                              op narg count)))
            (let ((command (mkcmd op (take input narg))))
              (add-command! out optype command)
              (parse-command-line (list-tail input narg) (- count narg) out))))))
   ((input . args) (parse-command-line input (length input) (make-commands-stucture)))))

(let* ((commands (parse-command-line (command-line-arguments)))
       (server-commands (get-server-commands commands))
       (client-commands (get-client-commands commands))
       (special-commands (get-special-commands commands)))
  (cond
   ((not (null? special-commands))
    (let* ((cmd (first special-commands))
           (def (find-command-def (car cmd) special-options)))
      (apply (command-body def) (cdr cmd)))
    (unless (and (null? (rest special-commands))
                 (null? server-commands)
                 (null? client-commands))
      (printf "~%Warning: the following commands were ignored:~%")
      (for-each
       (lambda (x) (printf "  ~S~%" x))
       (append! (rest special-commands) server-commands client-commands))))
   ((member "mowedline.server" (dbus:discover-services))
    (when (not (null? server-commands))
      (printf "Warning: the following commands were ignored because the daemon is already running:~%")
      (for-each
       (lambda (x) (printf "  ~S~%" x))
       server-commands))
    (start-client client-commands))
   (else
    (process-fork (lambda () (start-server server-commands)))
    ;; wait for the server to be ready?
    (start-client client-commands))))

;; (put 'foreign-lambda* 'scheme-indent-function 2)
;; (put 'let-location 'scheme-indent-function 1)
;; (put 'match 'scheme-indent-function 1)
;; (put 'make-command 'scheme-indent-function 1)
