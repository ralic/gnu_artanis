;;  -*-  indent-tabs-mode:nil; coding: utf-8 -*-
;;  Copyright (C) 2014,2015,2016,2017
;;      "Mu Lei" known as "NalaGinrut" <NalaGinrut@gmail.com>
;;  Artanis is free software: you can redistribute it and/or modify
;;  it under the terms of the GNU General Public License and GNU
;;  Lesser General Public License published by the Free Software
;;  Foundation, either version 3 of the License, or (at your option)
;;  any later version.

;;  Artanis is distributed in the hope that it will be useful,
;;  but WITHOUT ANY WARRANTY; without even the implied warranty of
;;  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;  GNU General Public License and GNU Lesser General Public License
;;  for more details.

;;  You should have received a copy of the GNU General Public License
;;  and GNU Lesser General Public License along with this program.
;;  If not, see <http://www.gnu.org/licenses/>.

(define-module (artanis page)
  #:use-module (artanis utils)
  #:use-module (artanis env)
  #:use-module (artanis config)
  #:use-module (artanis cookie)
  #:use-module (artanis tpl)
  #:use-module (artanis tpl sxml)
  #:use-module (artanis db)
  #:use-module (artanis route)
  #:use-module (artanis websocket)
  #:use-module (artanis server http)
  #:use-module (srfi srfi-19)
  #:use-module (web uri)
  #:use-module (web http)
  #:use-module (ice-9 match)
  #:use-module (ice-9 iconv)
  #:use-module ((rnrs) #:select (bytevector-length bytevector?))
  #:export (params
            response-emit
            throw-auth-needed
            tpl->html
            redirect-to
            tpl->response
            reject-method
            response-error-emit
            server-handler
            init-hook
            emit-response-with-file
            static-page-emitter))

;; the params will be searched in binding-list first, then search from qstr
;; TODO: qstr should be independent from rules binding.
(define (params rc key)
  (or (assoc-ref (rc-bt rc) key)
      (get-from-qstr rc key)))

(define (syspage-show file)
  (let ((local-syspage (format #f "~a/sys/pages/~a" (current-toplevel) file)))
    (cond
     ((file-exists? local-syspage)
      (bv-cat local-syspage #f))
     (else
      (bv-cat (string-append (get-conf '(server syspage path)) "/" file) #f)))))

;; ENHANCE: use colored output
(define* (log status mime req #:optional (port (current-error-port)))
  (let* ((uri (request-uri req))
         (path (uri-path uri))
         (qstr (uri-query uri))
         (method (request-method req)))
    (format port "[Remote] ~a @ ~a~%" (remote-info req) (local-time-stamp))
    (format port "[Request] method: ~a, path: ~a, qeury: ~a~%" method path qstr)
    (format port "[Response] status: ~a, MIME: ~a~%~%" status mime)))

(define (render-sys-page status request)
  (define-syntax-rule (status->page s)
    (format #f "~a.html" s))
  (log status 'text/html request)
  (let ((charset (get-conf '(server charset)))
        (mtime (generate-modify-time (current-time))))
    (values
     (build-response #:code status
                     #:headers `((server . ,(get-conf '(server info)))
                                 (last-modified . ,mtime)
                                 (content-type . (text/html (charset . ,charset)))))
     (syspage-show (status->page status))
     'exception)))

(define (rc-conn-recycle rc body)
  (and=> (rc-conn rc) DB-close))

(define (run-after-request-hooks rq body)
  (run-hook *after-request-hook* rq body))

(define (run-before-response-hooks rc body)
  (run-hook *before-response-hook* rc body))

(define (init-after-request-hook)
  (run-after-request! detect-if-connecting-websocket))

(define (init-before-response-hook)
  (run-before-response! rc-conn-recycle))

;; NOTE: If you want to add hook during initialization time, put them here.
(define (init-hook)
  (init-after-request-hook)
  (init-before-response-hook))

(define (handler-render handler rc)
  (define (->bytevector body)
    (cond
     ((bytevector? body) body)
     ((string? body) (string->bytevector body (get-conf '(server charset))))
     (else body))) ; just let it be checked by http-write
  (call-with-values
      (lambda ()
        (if (thunk? handler) 
            (handler) 
            (handler rc)))
    (lambda* (body #:key (pre-headers (prepare-headers '()))
                   (status 200) 
                   (mtime (generate-modify-time (current-time))))
      (let ((reformed-body (->bytevector body)))
        (run-before-response-hooks rc body)
        (let ((type (assq-ref pre-headers 'content-type)))
          (and type (log status (car type) (rc-req rc))))
        (values
         (build-response #:code status
                         #:headers `((server . ,(get-conf '(server info)))
                                     (last-modified . ,mtime)
                                     ,(gen-content-length reformed-body)
                                     ,@pre-headers 
                                     ,@(generate-cookies (rc-set-cookie rc))))
         ;; NOTE: For inner-server, sanitize-response will handle 'HEAD method
         ;;       though rc-method is 'GET when request-method is 'HEAD,
         ;;       sanitize-response only checks method from request.
         reformed-body
         ;; NOTE: return the status while handling the request.
         'ok)))))

(define (format-status-page status request)
  (format (current-error-port) "[EXCEPTION] ~a is abnormal request, status: ~a, "
          (uri-path (request-uri request)) status)
  (display "rendering a sys page for it...\n" (current-error-port)) 
  (render-sys-page status request))

(define (work-with-request request body)
  ;;(DEBUG "work with request~%")
  (catch 'artanis-err
    (lambda ()
      (let* ((rc (new-route-context request body))
             (handler (rc-handler rc)))
        (if handler
            (handler-render handler rc)
            (render-sys-page 404 rc))))
    (lambda (k . e)
      (define port (current-error-port))
      (format port (ERROR-TEXT "GNU Artanis encountered exception!~%"))
      (match e
        (((? procedure? subr) (? string? msg) . args)
         (format port "<~a>~%" (WARN-TEXT (current-filename)))
         (when subr (format port "In procedure ~a :~%"
                            (WARN-TEXT (procedure-name->string subr))))
         (apply format port (REASON-TEXT msg) args)
         (newline port))
        (((? integer? status) (? procedure? subr) (? string? msg) . args)
         (format port "HTTP ~a~%" (STATUS-TEXT status))
         (format port "<~a>~%" (WARN-TEXT (current-filename)))
         (when subr (format port "In procedure ~a :~%"
                            (WARN-TEXT (procedure-name->string subr))))
         (apply format port (REASON-TEXT msg) args)
         (newline port)
         (format-status-page status request))
        (else
         (format port "~a - ~a~%"
                 (WARN-TEXT
                  "BUG: invalid exception format, but we throw it anyway!")
                 e)
         (apply throw k e))))))

(define (response-emit-error status)
  (response-emit "" #:status status))

;; NOTE: last-modfied in #:headers will be ignored, it should be in #:mtime
(define* (response-emit body #:key (status 200) 
                        (headers '())
                        (mtime (current-time)))
  (DEBUG "Response emit headers: ~a~%" headers)
  (values body #:pre-headers (prepare-headers headers) #:status status
          #:mtime (generate-modify-time mtime)))

(define (throw-auth-needed)
  (response-emit
   ""
   #:status 401
   #:headers '((WWW-Authenticate . "Basic realm=\"Secure Area\""))))

(define (server-handler request request-body)
  ;; ENHANCE: could put some stat hook here
  (run-after-request-hooks request request-body)
  (work-with-request request request-body))

(define-syntax-rule (tpl->response sxml/file ...)
  (let ((html (tpl->html sxml/file ...)))
    (if html
        (response-emit html)
        (response-emit "" #:status 404))))

(define* (tpl->html sxml/file #:optional (env (current-module)) (escape? #f))
  (cond
   ((string? sxml/file) ; it's tpl filename
    (tpl-render-from-file sxml/file env))
   ((list? sxml/file) ; it's sxml tpl
    (call-with-output-string (lambda (port) (sxml->xml sxml/file port escape?))))
   (else #f))) ; wrong param causes 404

;; 301 is good for SEO and avoid some client problem
;; Use `URL scheme' incase users need to redirect to HTTPS or others. 
(define* (redirect-to rc path #:key (status 301) (scheme 'http))
  (response-emit
   ""
   #:status status
   #:headers `((location . ,(build-uri scheme #:path path))
               (content-length . 0)
               (content-type . (text/html)))))

(define (reject-method method)
  (throw 'artanis-err 405 "Method is not allowed" method))

;; proc must return the content-in-bytevector
(define (generate-response-with-file filename file-sender)
  (let* ((st (stat filename))
         ;; NOTE: we use ctime for last-modified time
         (mtime (make-time time-utc (stat:ctime st) (stat:ctimensec st)))
         (mime (guess-mime filename)))
    (values mtime 200 file-sender mime)))

;; emit static file with no cache(ETag)
(define* (emit-response-with-file filename out #:optional (headers '()))
  (when (not (file-exists? filename))
    (throw 'artanis-err 404 emit-response-with-file
           "Static file `~a' doesn't exist!" filename))
  (call-with-values
      (lambda ()
        (let* ((in (open-input-file filename))
               (size (stat:size (stat filename))))
         (generate-response-with-file
          filename
          (make-file-sender
           size
           (lambda ()
             ;; TODO: support trunked length requesting for continously downloading
             (sendfile out in size)
             (force-output out)
             (close in))))))
    (lambda (mtime status body mime)
      (cond
       ((= status 200)
        (response-emit body #:status status
                       #:headers `((content-type . ,(list mime))
                                   ,@headers)
                       #:mtime mtime))
       (else (response-emit body #:status status))))))

;; When you don't want to use cache, use static-page-emitter.
(define (static-page-emitter rc)
  (emit-response-with-file (static-filename (rc-path rc))
                           (request-port (rc-req rc))))
