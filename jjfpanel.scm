
(import chicken scheme extras foreign)

(use dbus
     miscmacros
     posix)

;;;
;;; Startup
;;;

;; is the server running?
;;   yes -> (start-client)
;;   no -> fork, (start-server), (start-client)

(define dbus-context
  (dbus:make-context service: 'jjfpanel.server
                     interface: 'jjfpanel.interface))
(dbus:enable-polling-thread! enable: #f)

(pp (dbus:discover-services))

(if (member "jjfpanel.server" (dbus:discover-services))
    (printf "found server!~%")
    (process-fork
     (lambda () (process-execute "./jjfpanel-server"))))



;;;
;;; Client Mode
;;;

(printf "hello, world~%")
