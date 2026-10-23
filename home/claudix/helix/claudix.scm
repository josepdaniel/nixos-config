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
;;
;; Read a thread: hover (space+k) on its range. List threads: the diagnostics
;; picker (space+d / space+D). Jump between threads: ]d and [d.
;; Code actions (space+a) on a thread offer resolve / apply.

(require "helix/configuration.scm")
(require "helix/editor.scm")
(require "helix/misc.scm")
(require "helix/static.scm")
(require (prefix-in helix. "helix/commands.scm"))

(provide cc cc! ccn cc-resolve cc-status)

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
