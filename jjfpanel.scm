
(import chicken scheme extras foreign)

(use coops
     lolevel
     miscmacros
     posix
     xlib)


;;;
;;; Globals
;;;

(define *display* (xopendisplay #f))
(assert *display*)

(define *window* #f)


;;;
;;; Widgets
;;;

(define-generic (widget-draw widget x))

(define-class <widget> ()
  ((name)
   (position initform: 'left)
   (flex initform: #f)
   (gc)))

;; Text Widget
;;
(define-class <text-widget> (<widget>)
  ((text initform: "")
   (font)))

(define (make-text-widget name text screen font)
  (let ((w (make <text-widget>
             'name name
             'text text
             'font font))
        (gc (xcreategc *display* *window* 0 #f)))
    (xsetbackground *display* gc (xblackpixel *display* screen))
    (xsetforeground *display* gc (xwhitepixel *display* screen))
    (xsetfunction *display* gc GXCOPY)
    (xsetfont *display* gc (xfontstruct-fid font))
    (set! (slot-value w 'gc) gc)
    w))

(define-method (widget-draw (widget <text-widget>) x)
  (let ((text (slot-value widget 'text))
        (baseline (xfontstruct-ascent (slot-value widget 'font))))
    (xdrawimagestring *display*
                      *window*
                      (slot-value widget 'gc)
                      x baseline text (string-length text))))


(define *widgets* (list))



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

(define (xtextproperty-make textp)
  (let ((tp (make-xtextproperty)))
    (set-xtextproperty-value! tp (location textp))
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

(define (set-struts win strut-callback)
  (window-property-set win "_NET_WM_STRUT_PARTIAL"
                       (vector "CARDINAL" 32 (strut-callback) 12)))



(define (get-font font-name)
  (let ((font (xloadqueryfont *display* font-name)))
    (assert font)
    font))


(let* ((screen (xdefaultscreen *display*))
       (swid (xdisplaywidth *display* screen))
       (shei (xdisplayheight *display* screen))
       (attr (make-xsetwindowattributes))
       (vis (make-visual))
       (font (get-font "-misc-fixed-bold-*-*-*-*-100-*-*-*-*-*-*"))
       ;; i find even these common fonts extend a pixel lower than their
       ;; declared descent.  tsk tsk.
       (whei (+ (xfontstruct-ascent font) (xfontstruct-descent font) 2)))
  (set-xsetwindowattributes-background_pixel! attr (xblackpixel *display* screen))
  (set-xsetwindowattributes-border_pixel! attr (xblackpixel *display* screen))
  (set-xsetwindowattributes-override_redirect! attr 1)
  (set-visual-class! vis COPYFROMPARENT)

  (set! *window* (xcreatewindow
                  *display*
                  (xrootwindow *display* screen)
                  0 0 swid whei 0
                  (xdefaultdepth *display* screen)
                  INPUTOUTPUT vis
                  (bitwise-ior CWBACKPIXEL CWBORDERPIXEL CWOVERRIDEREDIRECT)
                  attr))
  (assert *window*)

  ;;
  ;; Window Properties
  ;;
  (xstorename *display* *window* "jjfpanel")

  (let ((p (make-xtextproperty))
        (str (xtextproperty-make (get-host-name))))
    (xstringlisttotextproperty str 1 p)
    (xsetwmclientmachine *display* *window* p))

  (window-property-set *window* "_NET_WM_PID"
                       (make-number-property (current-process-id)))
  (window-property-set *window* "_NET_WM_WINDOW_TYPE"
                       (make-atom-property "_NET_WM_TYPE_DOCK"))
  (window-property-set *window* "_NET_WM_DESKTOP"
                       (make-number-property #xffffffff))
  (window-property-set *window* "_NET_WM_STATE"
                       (make-atom-property "_NET_WM_STATE_BELOW"))
  (window-property-append *window* "_NET_WM_STATE"
                          (make-atom-property "_NET_WM_STATE_STICKY"))
  (window-property-append *window* "_NET_WM_STATE"
                          (make-atom-property "_NET_WM_STATE_SKIP_TASKBAR"))
  (window-property-append *window* "_NET_WM_STATE"
                          (make-atom-property "_NET_WM_STATE_SKIP_PAGER"))

  ;; Struts: left, right, top, bottom,
  ;;         left_start_y, left_end_y, right_start_y, right_end_y,
  ;;         top_start_x, top_end_x, bottom_start_x, bottom_end_x
  ;;
  ;; so for a top panel, we set top, top_start_x, and top_end_x.
  (set-struts *window*
              (foreign-lambda* c-pointer ()
                "unsigned long strut[12] = { 0, 0, 40, 0, 0, 0, 0, 0, 0, 0, 0, 0 };"
                "C_return(strut);"))

  (let ((d-atom (xinternatom *display* "WM_DELETE_WINDOW" 1)))
    (let-location ((atm unsigned-long d-atom))
      (xsetwmprotocols *display* *window* (location atm) 1)))


  (define (handleexpose)
    (let ((ws *widgets*)
          (left 10)
          (right swid))
      (while (not (null? ws))
        (let ((w (car ws)))
          (widget-draw w left))
        (set! ws (cdr ws)))))

  (let ((event (make-xevent)))
    (define (eventloop return)
      (xnextevent *display* event)
      (let ((type (xevent-type event)))
        (cond
         ((= type CLIENTMESSAGE)
          (display "closed!\n")
          (return #t))

         ((= type EXPOSE)
          (handleexpose)
          (display "expose\n"))

         ((= type BUTTONPRESS)
          (display "buttonpress\n")
          (return #t))

         (else
          (display "event ")
          (display (xevent-type event))
          (display "\n"))))
      (eventloop return))


    (push! (make-text-widget "some-text"
                             "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
                             screen
                             font)
           *widgets*)
    (xselectinput *display* *window*
                  (bitwise-ior EXPOSUREMASK
                               BUTTONPRESSMASK
                               STRUCTURENOTIFYMASK))
    (xmapwindow *display* *window*)
    (xnextevent *display* event)
    (handleexpose)
    (xflush *display*)
    (call/cc eventloop)))

(xclosedisplay *display*)