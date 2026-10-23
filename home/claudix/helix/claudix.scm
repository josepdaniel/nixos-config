;; claudix: in-Helix review threads for a running Claude Code session.
;;
;; Threads are rendered by the claudix language server (daemon/shim.ts), so
;; this file only needs to turn selections and typed text into LSP commands.
;;
;;   :cc <text>      comment on the selection (a question), or, with a bare
;;                   cursor inside an existing thread, reply to that thread
;;   :cc! <text>     ask Claude to make this change now (still a thread)
;;   :ccn <text>     force a new thread even if the cursor is inside one
;;   :cc-resolve     resolve the thread under the cursor
;;   :cc-status      show the thread tally in the status line
;;   :cc-threads     picker over open threads; enter jumps there and opens hover
;;
;; Read a thread: hover (space+k) on its range. List threads: the diagnostics
;; picker (space+d / space+D). Jump between threads: ]d and [d.
;; Code actions (space+a) on a thread offer resolve / apply.

(require "helix/configuration.scm")
(require "helix/editor.scm")
(require "helix/misc.scm")
(require "helix/static.scm")
(require (prefix-in helix. "helix/commands.scm"))

(provide cc cc! ccn cc-resolve cc-status cc-threads)

(define *lsp-name* "claudix")

;; JSON objects from the LSP may arrive keyed by string or symbol.
(define (get h k)
  (if (hash? h)
      (let ([v (hash-try-get h k)])
        (if (or (void? v) (equal? v #f)) (hash-try-get h (string->symbol k)) v))
      #f))

(define (join-words words)
  (if (null? words) "" (string-join words " ")))

(define (current-uri)
  (define path (editor-document->path (editor->doc-id (editor-focus))))
  (if path (string-append "file://" path) #f))

(define (primary-range)
  (define r (selection->primary-range (current-selection-object)))
  (list (range->from r) (range->to r)))

(define (lsp-exec command arguments on-result)
  (send-lsp-command *lsp-name*
                    "workspace/executeCommand"
                    (hash "command" command "arguments" arguments)
                    on-result))

(define (send-comment text kind force-new?)
  (define uri (current-uri))
  (cond
    [(not uri) (set-status! "claudix: current buffer has no file path")]
    [(equal? text "") (set-status! "claudix: usage  :cc <comment>")]
    [else
     (define r (primary-range))
     (lsp-exec "claudix.comment"
               (list (hash "uri" uri
                           "from" (car r)
                           "to" (cadr r)
                           "text" text
                           "kind" kind
                           "forceNew" force-new?))
               (lambda (result)
                 (if (hash? result)
                     (set-status!
                      (string-append "claudix: "
                                     (if (get result "followup") "replied in " "opened ")
                                     (get result "id")
                                     (if (equal? kind "change") " (change requested)" "")))
                     (set-status! "claudix: no daemon attached? run /claudix in Claude, then :lsp-restart"))))]))

;;@doc
;; Comment on the selection, or reply to the thread under the cursor.
(define (cc . words)
  (send-comment (join-words words) "question" #f))

;;@doc
;; Ask Claude to make this change now. Opens (or continues) a thread.
(define (cc! . words)
  (send-comment (join-words words) "change" #f))

;;@doc
;; Open a new thread on the selection even if the cursor is inside one.
(define (ccn . words)
  (send-comment (join-words words) "question" #t))

;;@doc
;; Resolve the thread under the cursor.
(define (cc-resolve)
  (define uri (current-uri))
  (when uri
    (lsp-exec "claudix.resolve"
              (list (hash "uri" uri "at" (car (primary-range))))
              (lambda (result)
                (define id (and (hash? result) (get result "resolved")))
                (set-status! (if id
                                 (string-append "claudix: resolved " id)
                                 "claudix: no thread under the cursor"))))))

;;@doc
;; Show the review tally in the status line.
(define (cc-status)
  (lsp-exec "claudix.status" (list)
            (lambda (s)
              (if (hash? s)
                  (set-status! (string-append "claudix: " (get s "summary")))
                  (set-status! "claudix: no daemon attached")))))

;; When Claude edits a file on disk, reload the buffer if it has no unsaved
;; changes, so applied suggestions show up without a manual :reload.
(define (uri->path uri)
  (if (and (string? uri) (starts-with? uri "file://")) (substring uri 7 (string-length uri)) uri))

(define (reload-if-clean path)
  (for-each
   (lambda (doc)
     (when (equal? (editor-document->path doc) path)
       (if (editor-document-dirty? doc)
           (set-status! (string-append "claudix: " path " changed on disk (buffer has unsaved edits, not reloaded)"))
           (begin
             (editor-document-reload doc)
             (set-status! (string-append "claudix: reloaded " path))))))
   (editor-all-documents)))

(register-lsp-notification-handler
 *lsp-name*
 "claudix/fileChanged"
 (lambda (params)
   (define path (uri->path (get params "uri")))
   (with-handler (lambda (e) (set-status! (string-append "claudix: reload failed for " path)))
                 (reload-if-clean path))))

;; ---------------------------------------------------------------------------
;; :cc-threads  — a picker over the open threads. Type to filter, up/down or
;; ctrl-n/ctrl-p to move, enter to jump to the thread and open its hover,
;; esc to close. The right pane previews the selected thread.

(require "helix/components.scm")

(define *ccp-threads* '())      ; all threads from the daemon
(define *ccp-filter* "")
(define *ccp-selected* 0)

(define (ccp-truncate s n)
  (if (> (string-length s) n)
      (string-append (substring s 0 (max 0 (- n 1))) "…")
      s))

(define (ccp-matches? t)
  (or (equal? *ccp-filter* "")
      (let ([hay (string-downcase (string-append (get t "id") " " (get t "file") " " (get t "head") " " (get t "status")))])
        (string-contains? hay (string-downcase *ccp-filter*)))))

(define (ccp-visible)
  (filter ccp-matches? *ccp-threads*))

(define (ccp-row t)
  (string-append (get t "marker") "  " (get t "loc") "  " (get t "head")))

(define (ccp-render state rect frame)
  (define rows (ccp-visible))
  (define n (length rows))
  (when (>= *ccp-selected* n) (set! *ccp-selected* (max 0 (- n 1))))
  (define bg (theme-scope-ref "ui.menu"))
  (define text (theme-scope-ref "ui.text"))
  (define dim (style-with-dim text))
  (define sel (theme-scope-ref "ui.menu.selected"))
  (define info (theme-scope-ref "ui.text.info"))
  (define rw (area-width rect))
  (define rh (area-height rect))
  (define w (max 40 (min (- rw 4) (quotient (* rw 9) 10))))
  (define h (max 8 (min (- rh 2) (+ 4 (max 6 (min 18 n))))))
  (define x (quotient (- rw w) 2))
  (define y (quotient (- rh h) 2))
  (define box (area x y w h))
  (buffer/clear-with frame box bg)
  (block/render frame box (make-block bg dim "all" "rounded"))
  (define list-w (quotient w 2))
  (define prev-x (+ x list-w 1))
  (define prev-w (- (+ x w) prev-x 1))
  ;; title + filter line
  (frame-set-string! frame (+ x 2) y (string-append " claudix threads (" (number->string n) ") ") info)
  (frame-set-string! frame (+ x 2) (+ y 1) (ccp-truncate (string-append "> " *ccp-filter*) (- list-w 3)) text)
  ;; rows
  (define max-rows (- h 3))
  (define first (max 0 (- *ccp-selected* (- max-rows 1))))
  (let loop ([rs (drop rows (min first n))] [i first] [row 0])
    (when (and (pair? rs) (< row max-rows))
      (define t (car rs))
      (define ry (+ y 2 row))
      (define style (if (= i *ccp-selected*) sel (if (equal? (get t "status") "open") text dim)))
      (when (= i *ccp-selected*)
        (buffer/clear-with frame (area (+ x 1) ry (- list-w 1) 1) sel))
      (frame-set-string! frame (+ x 2) ry (ccp-truncate (ccp-row t) (- list-w 3)) style)
      (loop (cdr rs) (+ i 1) (+ row 1))))
  ;; preview
  (when (and (> n 0) (> prev-w 8))
    (define t (list-ref rows *ccp-selected*))
    (define lines (get t "preview"))
    (frame-set-string! frame prev-x (+ y 1) (ccp-truncate (get t "loc") prev-w) info)
    (let loop ([ls lines] [row 0])
      (when (and (pair? ls) (< row (- h 3)))
        (frame-set-string! frame prev-x (+ y 2 row) (ccp-truncate (car ls) prev-w) text)
        (loop (cdr ls) (+ row 1))))))

(define (ccp-jump! t)
  (helix.open (get t "path"))
  (helix.goto (get t "lineStr"))
  (enqueue-thread-local-callback-with-delay 60 (lambda () (hover))))

(define (ccp-handle-event state event)
  (define ch (key-event-char event))
  (define mod (key-event-modifier event))
  (define rows (ccp-visible))
  (define n (length rows))
  (define (move! d)
    (when (> n 0) (set! *ccp-selected* (modulo (+ *ccp-selected* d) n)))
    event-result/consume)
  (cond
    [(mouse-event? event) event-result/consume]
    [(key-event-escape? event) event-result/close]
    [(key-event-enter? event)
     (if (> n 0)
         (let ([t (list-ref rows *ccp-selected*)])
           (enqueue-thread-local-callback (lambda () (ccp-jump! t)))
           event-result/close)
         event-result/close)]
    [(or (key-event-down? event) (key-event-tab? event)) (move! 1)]
    [(key-event-up? event) (move! -1)]
    [(and (equal? mod key-modifier-ctrl) (char? ch) (equal? ch #\n)) (move! 1)]
    [(and (equal? mod key-modifier-ctrl) (char? ch) (equal? ch #\p)) (move! -1)]
    [(key-event-backspace? event)
     (define len (string-length *ccp-filter*))
     (when (> len 0) (set! *ccp-filter* (substring *ccp-filter* 0 (- len 1))))
     (set! *ccp-selected* 0)
     event-result/consume]
    [(char? ch)
     (set! *ccp-filter* (string-append *ccp-filter* (string ch)))
     (set! *ccp-selected* 0)
     event-result/consume]
    [else event-result/consume]))

(define (ccp-cursor state rect)
  ;; caret after the filter text, mirroring the geometry in ccp-render
  (define rw (area-width rect))
  (define rh (area-height rect))
  (define n (length (ccp-visible)))
  (define w (max 40 (min (- rw 4) (quotient (* rw 9) 10))))
  (define h (max 8 (min (- rh 2) (+ 4 (max 6 (min 18 n))))))
  (define x (quotient (- rw w) 2))
  (define y (quotient (- rh h) 2))
  (position (+ y 1) (+ x 4 (string-length *ccp-filter*))))

(struct CcPickerState ())

;;@doc
;; Pick a thread from a list; enter jumps to it and opens its hover.
(define (cc-threads)
  (lsp-exec "claudix.status" (list)
            (lambda (s)
              (define ts (and (hash? s) (get s "threads")))
              (cond
                [(not (hash? s)) (set-status! "claudix: no daemon attached? run /claudix in Claude Code")]
                [(or (not ts) (null? ts)) (set-status! "claudix: no open threads")]
                [else
                 (set! *ccp-threads* ts)
                 (set! *ccp-filter* "")
                 (set! *ccp-selected* 0)
                 (push-component!
                  (new-component! "claudix-threads"
                                  (CcPickerState)
                                  ccp-render
                                  (hash "handle_event" ccp-handle-event
                                        "cursor" ccp-cursor)))]))))
