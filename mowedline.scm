
;; This file is part of mowedline.
;; Copyright (C) 2011-2017  John J. Foerch
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

(include "llog")

(module mowedline
    *

(import chicken scheme)

(use srfi-1
     srfi-4 ;; homogeneous numeric vectors
     srfi-13 ;; string
     srfi-14 ;; character sets
     srfi-18 ;; threads
     srfi-69 ;; hash tables
     fmt
     gochan
     coops
     data-structures
     (prefix dbus dbus:)
     extras
     filepath
     (prefix imperative-command-line-a icla:)
     miscmacros
     ports
     posix
     xft
     (except xlib make-xrectangle
                  xrectangle-x xrectangle-y
                  xrectangle-width xrectangle-height)
     (prefix xlib-utils xu:)
     xtypes)

(import llog)

(include "version")
(include "mowedline-dbus-context")

(include "utils")


;;;
;;; Globals
;;;

(define current-xcontext (make-parameter #f))

(define xcontexts (list))

(define *widgets* (make-hash-table test: equal?))

(define *default-widgets* (list))

(define *command-line-windows* (list))

(define *internal-events* (gochan 64))

(define %quit-mowedline #f) ;; will be bound to a quit continuation
(define (quit-mowedline . _)
  (%quit-mowedline #t))

(define (switch-to-desktop desktop)
  (xu:switch-to-desktop (current-xcontext) desktop))


;;;
;;; Button
;;;

(define-record button
  xrectangle handler)


;;;
;;; Window
;;;

(define window-background (make-parameter #f))
(define window-lower (make-parameter #t))
(define window-position (make-parameter 'top))

(define window-get-next-id
  (let ((last -1))
    (lambda ()
      (inc! last)
      last)))

(define-class <window> ()
  ((id: initform: (window-get-next-id))
   (%xcontext: initform: (current-xcontext))
   (position: initform: (window-position))
   (height: initform: #f)
   (width: initform: #f)
   (%baseline: initform: #f)
   (margin-top: initform: 0)
   (margin-right: initform: 0)
   (margin-bottom: initform: 0)
   (margin-left: initform: 0)
   (background: initform: (window-background))
   (widgets: initform: (list))
   (%fonts: initform: (list))))

(define (window . args)
  (receive (props widgets)
      (split-properties args)
    (apply make <window> widgets: widgets props)))

(define (window-create-xwindow xcontext x y width height background)
  (xu:with-xcontext xcontext (display screen window)
    (let ((attr (make-xsetwindowattributes))
          (flags #f)
          (visual (xdefaultvisual display screen))
          (visual-depth COPYFROMPARENT))
      (cond
       ((eq? 'inherit background)
        (set! flags (bitwise-ior CWBACKPIXMAP CWBORDERPIXEL CWOVERRIDEREDIRECT))
        (set-xsetwindowattributes-background_pixmap! attr PARENTRELATIVE))
       ((eq? 'transparent background)
        (let ((vinfo (make-xvisualinfo)))
          (xmatchvisualinfo display screen 32 TRUECOLOR vinfo)
          (set! visual (xvisualinfo-visual vinfo))
          (set! visual-depth (xvisualinfo-depth vinfo))
          (set! flags (bitwise-ior CWBACKPIXEL CWBORDERPIXEL CWCOLORMAP CWOVERRIDEREDIRECT))
          (set-xsetwindowattributes-background_pixel! attr (xblackpixel display screen))
          (set-xsetwindowattributes-colormap!
           attr (xcreatecolormap display window (xvisualinfo-visual vinfo) ALLOCNONE))))
       (else
        (set! flags (bitwise-ior CWBACKPIXEL CWBORDERPIXEL CWOVERRIDEREDIRECT))
        (set-xsetwindowattributes-background_pixel! attr (xblackpixel display screen))))
      (set-xsetwindowattributes-border_pixel! attr (xblackpixel display screen))
      (set-xsetwindowattributes-override_redirect! attr 1)
      (xcreatewindow display window x y width height 0
                     visual-depth INPUTOUTPUT visual
                     flags attr))))

(define (window-calculate-geometry window)
  (xu:with-xcontext (slot-value window %xcontext:)
      (xcontext display)
    (let* ((shei (xu:screen-or-xinerama-screen-height xcontext))
           (position (slot-value window position:))
           (width (or (slot-value window width:)
                      (- (xu:screen-or-xinerama-screen-width xcontext)
                         (slot-value window margin-left:)
                         (slot-value window margin-right:))))
           (height (or (slot-value window height:)
                       (fold max 1 (map widget-preferred-height
                                        (slot-value window widgets:)))))
           (window-left (+ (xu:screen-or-xinerama-screen-left xcontext)
                           (slot-value window margin-left:)))
           (window-top (+ (xu:screen-or-xinerama-screen-top xcontext)
                          (case position
                            ((bottom) (- shei (slot-value window margin-bottom:) height))
                            (else (slot-value window margin-top:))))))
      (list window-left window-top width height))))

(define (window-set-struts! window)
  (let* ((xcontext (slot-value window %xcontext:))
         (strut-height (+ (slot-value window height:)
                          (slot-value window margin-top:)
                          (slot-value window margin-bottom:)))
         (strut-left (xu:screen-or-xinerama-screen-left xcontext))
         (strut-right (+ strut-left (slot-value window margin-left:)
                         (slot-value window width:) -1
                         (slot-value window margin-right:)))
         (position (slot-value window position:)))
    (xu:window-property-set xcontext "_NET_WM_STRUT"
                            (xu:make-numbers-property
                             (if (eq? position 'bottom)
                                 (list 0 0 0 strut-height)
                                 (list 0 0 strut-height 0))))
    (xu:window-property-set xcontext "_NET_WM_STRUT_PARTIAL"
                            (xu:make-numbers-property
                             (if (eq? position 'bottom)
                                 (list 0 0 0 strut-height 0 0 0 0
                                       0 0 strut-left strut-right)
                                 (list 0 0 strut-height 0 0 0 0 0
                                       strut-left strut-right 0 0))))))

(define-method (initialize-instance (window <window>))
  (call-next-method)
  (xu:with-xcontext (slot-value window %xcontext:)
      (xcontext display)
    (for-each (lambda (widget) (widget-set-window! widget window))
              (slot-value window widgets:))
    (match-let (((window-left window-top width height)
                 (window-calculate-geometry window)))
      (let ((xwindow (window-create-xwindow xcontext
                                            window-left window-top width height
                                            (slot-value window background:))))
        (assert xwindow)
        (let* ((xcontext (xu:make-xcontext xcontext window: xwindow)))
          (set! (slot-value window %xcontext:) xcontext)
          (set! (slot-value window width:) width)
          (set! (slot-value window height:) height)
          (set! (slot-value window %baseline:)
                (fold max 1 (map widget-preferred-baseline
                                 (slot-value window widgets:))))
          (for-each widget-init (slot-value window widgets:))
          (window-update-widget-dimensions! window)

          ;; Window Properties
          ;;
          (xstorename display xwindow "mowedline")
          (xsetwmclientmachine display xwindow (xu:make-text-property (get-host-name)))
          (xu:window-property-set xcontext "_NET_WM_PID"
                                  (xu:make-number-property (current-process-id)))
          (xu:window-property-set xcontext "_NET_WM_WINDOW_TYPE"
                                  (xu:make-atom-property xcontext "_NET_WM_WINDOW_TYPE_DOCK"))
          (xu:window-property-set xcontext "_NET_WM_DESKTOP"
                                  (xu:make-number-property #xffffffff))
          (xu:window-property-set xcontext "_NET_WM_STATE"
                                  (xu:make-atom-property xcontext "_NET_WM_STATE_BELOW"))
          (xu:window-property-append xcontext "_NET_WM_STATE"
                                     (xu:make-atom-property xcontext "_NET_WM_STATE_STICKY"))
          (xu:window-property-append xcontext "_NET_WM_STATE"
                                     (xu:make-atom-property xcontext "_NET_WM_STATE_SKIP_TASKBAR"))
          (xu:window-property-append xcontext "_NET_WM_STATE"
                                     (xu:make-atom-property xcontext "_NET_WM_STATE_SKIP_PAGER"))
          (window-set-struts! window)

          (xu:set-wm-protocols xcontext '(WM_DELETE_WINDOW))

          (when (window-lower)
            (xlowerwindow display xwindow))

          (xmapwindow display xwindow)
          (xnextevent display (make-xevent))
          (window-expose window)

          (xu:xcontext-data-set! xcontext window)
          (xu:add-event-handler! xcontext
                                 CLIENTMESSAGE
                                 #f
                                 window-handle-event/clientmessage
                                 #f)
          (xu:add-event-handler! xcontext
                                 EXPOSE
                                 EXPOSUREMASK
                                 window-handle-event/expose
                                 #f)
          (xu:add-event-handler! xcontext
                                 BUTTONPRESS
                                 BUTTONPRESSMASK
                                 window-handle-event/buttonpress
                                 #f)
          (xu:update-event-mask! xcontext)
          (push! xcontext xcontexts))))))

(define-method (print-object (x <window>) port)
  (fmt port "#<window " (slot-value x id:) ">"))

(define (window-get-create-font window font)
  (let ((fonts (slot-value window %fonts:)))
    (or (alist-ref font fonts)
        (xu:with-xcontext (slot-value window %xcontext:)
          (display screen)
        (let ((fontref (xft-font-open/name display screen font)))
          (set! (slot-value window %fonts:)
                (cons (cons font fontref)
                      fonts))
          fontref)))))

(define window-expose
  (case-lambda
   ((window xrectangle)
    ;; exposing a given rectangle means drawing all widgets which
    ;; intersect that rectangle, passing the rectangle in to them so they
    ;; can use it as a mask (via a region).
    (xu:with-xcontext (slot-value window %xcontext:) (xcontext display)
      (let ((xwindow (xu:xcontext-window xcontext))
            (widgets (slot-value window widgets:))
            (r (xcreateregion)))
        (xunionrectwithregion xrectangle (xcreateregion) r)
        (llog expose "window ~A, ~A"
              (slot-value window id:)
              (xrectangle->string xrectangle))
        (for-each
         (lambda (widget)
           ;; does this widget intersect xrectangle?
           (let* ((wrect (slot-value widget %xrectangle:))
                  (x (xrectangle-x wrect))
                  (y 0)
                  (width (xrectangle-width wrect))
                  (height (slot-value window height:)))
             (when (and (> width 0)
                        (member (xrectinregion r x y width height)
                                (L RECTANGLEPART RECTANGLEIN)))
               ;;intersect r with wrect and pass result to widget-draw
               (let ((wreg (xcreateregion))
                     (out (xcreateregion)))
                 (xunionrectwithregion wrect out wreg)
                 (xintersectregion r wreg out)
                 (widget-draw widget out)))))
         widgets)
        ;; if the entire window is not filled with widgets, we may need to
        ;; clear the area to the right of the last widget.
        (unless (null? widgets)
          (let* ((lastwidget (last widgets))
                 (wrect (slot-value lastwidget %xrectangle:))
                 (p (+ (xrectangle-x wrect)
                       (xrectangle-width wrect)))
                 (m (+ (xrectangle-x xrectangle)
                       (xrectangle-width xrectangle))))
            (when (> m p)
              (xcleararea display xwindow
                          p 0 (- m p) (slot-value window height:)
                          0))))
        (xflush display))))
    ((window)
     (window-expose window
                    (make-xrectangle
                     0 0 (slot-value window width:)
                     (slot-value window height:))))))

;; window-update-widget-dimensions! sets x coordinates and widths of all
;; widgets in window.  returns #f if nothing changed, otherwise an
;; xrectangle of the changed area.
;;
(define (window-update-widget-dimensions! window)
  (let* ((widgets (slot-value window widgets:))
         (widsum 0)
         (flexsum 0)
         (wids (map       ;; sum widths & flexes, and accumulate widths
                (lambda (widget)
                  (inc! flexsum (max 0 (slot-value widget flex:)))
                  (and-let* ((wid (widget-preferred-width widget)))
                    (inc! widsum wid)
                    wid))
                widgets))
         (remainder (- (slot-value window width:) widsum))
         (x 0)
         (rmin #f)  ;; redraw range
         (rmax #f))
    (define (flex-allocate flex)
      (if (zero? flexsum)
          #f
          (let ((flexwid (inexact->exact (round (* (/ flex flexsum) remainder)))))
            (set! remainder (- remainder flexwid))
            (set! flexsum (- flexsum flex))
            flexwid)))
    (for-each
     (lambda (widget wid)
       (let* ((rect (slot-value widget %xrectangle:))
              (wid (or wid (flex-allocate (slot-value widget flex:))))
              (oldx (xrectangle-x rect))
              (oldwid (xrectangle-width rect)))
         (unless (and (= oldx x)
                      (= oldwid wid))
           (set! rmin (min (or rmin x) oldx x))
           (let ((rt (+ x wid))
                 (oldrt (+ oldx oldwid)))
             (set! rmax (max (or rmax rt) oldrt rt))))
         (set-xrectangle-x! rect x)
         (set-xrectangle-width! rect wid)
         (inc! x wid)))
     widgets
     wids)
    (if rmin
        (make-xrectangle rmin 0 (- rmax rmin) (slot-value window height:))
        #f)))

(define (window-widget-at-position window x)
  (find
   (lambda (widget)
     (let ((wrect (slot-value widget %xrectangle:)))
       (and (>= x (xrectangle-x wrect))
            (< x (+ (xrectangle-x wrect)
                    (xrectangle-width wrect))))))
   (slot-value window widgets:)))

(define (window-handle-event/clientmessage xcontext event)
  (xu:with-xcontext xcontext (display)
    (let ((WM_PROTOCOLS (xinternatom display "WM_PROTOCOLS" 1))
          (WM_DELETE_WINDOW (xinternatom display "WM_DELETE_WINDOW" 1)))
      (when (and (= WM_PROTOCOLS (xclientmessageevent-message_type event))
                 (= WM_DELETE_WINDOW (first (xu:xclientmessageevent-data-l event))))
        (quit-mowedline)))))

(define (window-handle-event/expose xcontext event)
  (and-let* ((window (xu:xcontext-data xcontext))
             (x (xexposeevent-x event))
             (y (xexposeevent-y event))
             (width (xexposeevent-width event))
             (height (xexposeevent-height event)))
    (window-expose window (make-xrectangle x y width height))))

(define (window-handle-event/buttonpress xcontext event)
  (let ((window (xu:xcontext-data xcontext)))
  (parameterize ((current-xcontext (slot-value window %xcontext:)))
    (and-let* ((widget (window-widget-at-position
                        window (xbuttonpressedevent-x event)))
               (button (widget-button-at-position
                        widget (xbuttonpressedevent-x event))))
      ((button-handler button) widget)))))

(define (mowedline-handle-event/root-configurenotify root-xcontext event)
  (let ((root-window-size
         (L (xconfigureevent-width event)
            (xconfigureevent-height event)))
        (props (xu:xcontext-data root-xcontext)))
    (unless (equal? root-window-size (alist-ref 'size props))
      (xu:xcontext-data-set! root-xcontext
                             (alist-update! 'size root-window-size props equal?))
      (for-each
       (lambda (xc)
         (let ((window (xu:xcontext-data xc)))
           (when (instance-of? window <window>)
             (xu:with-xcontext xc (display)
               (match-let (((window-left window-top width height)
                            (window-calculate-geometry window)))
                 (set! (slot-value window width:) width)
                 (set! (slot-value window height:) height)
                 (let ((xwindow (xu:xcontext-window xc)))
                   (xmoveresizewindow display xwindow window-left window-top
                                      width height))
                 (window-update-widget-dimensions! window)
                 (window-set-struts! window))))))
       xcontexts))))


;;;
;;; Widgets
;;;

(define-generic (widget-draw widget region))
(define-generic (widget-preferred-height widget))
(define-generic (widget-preferred-width widget))
(define-generic (widget-preferred-baseline widget))
(define-generic (widget-set-window! widget window))
(define-generic (widget-init widget))
(define-generic (widget-update widget params))

(define widget-background-color (make-parameter #f))
(define widget-flex (make-parameter 0))

(define-class <widget> ()
  ((name: initform: #f)
   (flex: initform: (widget-flex))
   (%window:)
   (%xrectangle: initform: (make-xrectangle 0 0 0 0))
   (background-color: initform: (widget-background-color))
   (%buttons: initform: (list))
   (init: initform: #f)))

(define-method (initialize-instance (widget <widget>))
  (call-next-method)
  (and-let* ((name (slot-value widget name:)))
    (when (hash-table-exists? *widgets* name)
      (error "duplicate widget name"))
    (hash-table-set! *widgets* name widget)))

(define-method (print-object (x <widget>) port)
  (fmt port "#<"
       (string-trim-both (->string (class-name (class-of x)))
                         char-set:symbol)
       (let ((name (slot-value x name:)))
         (if name (cat " \"" name "\"") ""))
       ">"))

(define-method (widget-set-window! (widget <widget>) (window <window>))
  (set! (slot-value widget %window:) window))

(define-method (widget-init (widget <widget>))
  (let ((window (slot-value widget %window:))
        (init (slot-value widget init:)))
    (set-xrectangle-height! (slot-value widget %xrectangle:)
                            (slot-value window height:))
    (when init
      (init widget))))

(define-method (widget-preferred-baseline (widget <widget>)) 0)
(define-method (widget-preferred-height (widget <widget>)) 1)
(define-method (widget-preferred-width (widget <widget>))
  (if (> (slot-value widget flex:) 0)
      #f
      1))

(define-method (widget-draw (widget <widget>) region)
  (let ((window (slot-value widget %window:)))
    (xu:with-xcontext (slot-value window %xcontext:) (xcontext display)
      (let* ((xwindow (xu:xcontext-window xcontext))
             (wrect (slot-value widget %xrectangle:))
             (x (xrectangle-x wrect))
             (attr (make-xwindowattributes))
             (_ (xgetwindowattributes display xwindow attr))
             (visual (xwindowattributes-visual attr))
             (colormap (xwindowattributes-colormap attr))
             (draw (xftdraw-create display xwindow visual colormap)))
        (define (make-color c)
          (apply make-xftcolor display visual colormap
                 (ensure-list c)))
        (let ((background-color (slot-value widget background-color:)))
          (xftdraw-set-clip! draw region)
          (if background-color
              (xft-draw-rect draw (make-color background-color) x 0
                             (xrectangle-width wrect)
                             (xrectangle-height wrect))
              (xcleararea display xwindow x 0
                          (xrectangle-width wrect)
                          (xrectangle-height wrect)
                          0)))))))

(define (widget-button-at-position widget x)
  (find
   (lambda (button)
     (let ((rect (button-xrectangle button)))
       (and (>= x (xrectangle-x rect))
            (< x (+ (xrectangle-x rect)
                    (xrectangle-width rect))))))
   (slot-value widget %buttons:)))


(include "mowedline-widgets-basic.scm")
(include "mowedline-widgets-ewmh.scm")


;;;
;;; Server
;;;

(define (update widget-or-name . params)
  (llog (update "~S ~S" widget-or-name params)
    (and-let*
        ((widget (if (string? widget-or-name)
                     (hash-table-ref/default *widgets* widget-or-name #f)
                     widget-or-name)))
      (widget-update widget params)
      (let ((window (slot-value widget %window:)))
        (window-expose window (or (window-update-widget-dimensions! window)
                                  (slot-value widget %xrectangle:))))
      #t)))

(define (log-watch symlist . params)
  (for-each
   (lambda (x)
     (case (string-ref x 0)
       ((#\-) (llog-unwatch (string->symbol (string-drop x 1))))
       ((#\+) (llog-watch (string->symbol (string-drop x 1))))
       (else (llog-watch (string->symbol x)))))
   (string-split symlist ", "))
  #t)

(define (dbus-client-quit)
  ;;XXX: special quit procedure for dbus thread. quitting from the dbus
  ;;     thread prevents dbus from replying to its caller, so instead, we
  ;;     send the quit message to the internal-events thread.
  (gochan-send *internal-events* quit-mowedline)
  #t)

(define (dbus-introspect-part part)
  (lambda ()
    (string-append
     "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"
             \"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">
<node>
  <node name=\"" part "\" />
</node>")))

(define (dbus-introspect)
  (string-append
   "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"
             \"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">
<node name=\"" mowedline-dbus-path "\">
  <interface name=\"org.freedesktop.DBus.Introspectable\">
    <method name=\"Introspect\">
      <arg name=\"xml_data\" type=\"s\" direction=\"out\"/>
    </method>
  </interface>
  <interface name=\"" (symbol->string mowedline-dbus-interface) "\">
    <method name=\"log\">
      <arg name=\"symlist\" type=\"s\" direction=\"in\"/>
    </method>
    <method name=\"quit\"></method>
    <method name=\"update\">
      <arg name=\"widget\" type=\"s\" direction=\"in\"/>
      <arg name=\"value\" type=\"s\" direction=\"in\"/>
      <arg name=\"success\" type=\"b\" direction=\"out\"/>
    </method>
  </interface>
</node>"))

(define (make-command-line-windows)
  (for-each
   (lambda (widgets) (make <window> widgets: widgets))
   *command-line-windows*)
  (set! *command-line-windows* (list))
  (unless (null? *default-widgets*)
    (make <window> widgets: (reverse! *default-widgets*))
    (set! *default-widgets* (list))))

(define (maybe-make-default-window)
  (unless (find (lambda (xc) (instance-of? (xu:xcontext-data xc) <window>))
                xcontexts)
    (make <window>
      widgets:
      (L (make <text-widget>
           name: "default"
           flex: 1
           text: "mowedline")))))

(define bypass-startup-script (make-parameter #f))

(define startup-script (make-parameter #f))

(define (load-startup-script)
  (let* ((~ (get-environment-variable "HOME"))
         (path (or (startup-script)
                   (find file-read-access?
                         (L (filepath:join-path (L ~ ".mowedline"))
                            (filepath:join-path (L (xdg-config-home)
                                                   "mowedline" "init.scm")))))))
    (when path
      (eval '(import mowedline))
      (load path))))

(define (register-dbus-introspection)
  (let loop ((path "/")
             (segments (string-split mowedline-dbus-path "/")))
    (cond
     ((null? segments)
      (let ((context
             (dbus:make-context service: mowedline-dbus-service
                                interface: 'org.freedesktop.DBus.Introspectable
                                path: mowedline-dbus-path)))
        (dbus:register-method context "Introspect" dbus-introspect)))
     (else
      (let* ((segment (car segments))
             (next-path
              (string-append path (if (string=? path "/") "" "/") segment))
             (context
              (dbus:make-context service: mowedline-dbus-service
                                 interface: 'org.freedesktop.DBus.Introspectable
                                 path: path)))
        (dbus:register-method context "Introspect" (dbus-introspect-part segment))
        (loop next-path (cdr segments)))))))

(define (mowedline)
  (xu:with-xcontext (xu:make-xcontext display: (xopendisplay #f))
      (xcontext display screen)
    (assert display)

    (push! xcontext xcontexts) ;; root xcontext

    (xu:xcontext-data-set!
     xcontext `((size . ,(L (xdisplaywidth display screen)
                            (xdisplayheight display screen)))))
    (xu:add-event-handler! xcontext CONFIGURENOTIFY STRUCTURENOTIFYMASK
                           mowedline-handle-event/root-configurenotify
                           #f)
    (xu:update-event-mask! xcontext)

    (parameterize ((current-xcontext xcontext))
      (let ((x-fd (xconnectionnumber display))
            (event (make-xevent)))
        (make-command-line-windows)
        (unless (bypass-startup-script)
          (load-startup-script))
        (maybe-make-default-window)

        (dbus:enable-polling-thread! enable: #f)
        (dbus:register-method mowedline-dbus-context "update" update)
        (dbus:register-method mowedline-dbus-context "quit" dbus-client-quit)
        (dbus:register-method mowedline-dbus-context "log" log-watch)
        (register-dbus-introspection)

        (define (x-eventloop)
          (unless (> (xpending display) 0)
            (thread-wait-for-i/o! x-fd input:))
          (xnextevent display event)
          (xu:handle-event event xcontexts)
          (x-eventloop))

        (define (dbus-eventloop)
          (if (dbus:poll-for-message)
              (thread-yield!)
              (thread-sleep! 0.01))
          (dbus-eventloop))

        (define (internal-events-eventloop)
          ((gochan-recv *internal-events*))
          (internal-events-eventloop))

        (call/cc
         (lambda (return)
           (set! %quit-mowedline return)
           (thread-start! x-eventloop)
           (thread-start! internal-events-eventloop)
           (dbus-eventloop)))))
    (xclosedisplay display)))

(define (mowedline-start)
  (thread-start! (lambda () (mowedline) (exit))))


;;;
;;; Command Line
;;;

(icla:help-heading
 (sprintf "mowedline version ~A, by John J. Foerch" version))

(icla:define-command-group server-options
 ((q)
  doc: "bypass .mowedline"
  (bypass-startup-script #t))
 ((config path)
  doc: "use config file instead of .mowedline"
  (startup-script path))
 ((text-widget name)
  (push! (make <text-widget>
           name: name)
         *default-widgets*))
 ((clock)
  (push! (make <clock>)
         *default-widgets*))
 ((active-window-title)
  (push! (make <active-window-title>)
         *default-widgets*))
 ((bg color)
  doc: "set default background-color"
  (widget-background-color color))
 ((fg color)
  doc: "set the default text color"
  (text-widget-color color))
 ((flex value)
  doc: "set the default flex value"
  (widget-flex (string->number value)))
 ((position value)
  doc: "set the default window position (top or bottom)"
  (window-position (string->symbol value)))
 ((window)
  doc: "make a window containing the foregoing widgets"
  (set! *command-line-windows*
        (cons (reverse! *default-widgets*) *command-line-windows*))
  (set! *default-widgets* (list))))

)
