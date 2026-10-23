;; :git-peek — inline-ish diff review.
;;
;; Shows the lines that the hunk under the cursor replaced (as of HEAD) in a
;; popup drawn directly beneath the cursor line, so it reads like the removed
;; lines of a unified diff. Esc / q / space close it; any other key closes it
;; and is passed through, so `]g` `git-peek` `]g` `git-peek` walks the hunks.

(require "helix/editor.scm")
(require "helix/misc.scm")
(require "helix/components.scm")
(require "helix/static.scm")

(provide git-peek)

(define (current-path)
  (editor-document->path (editor->doc-id (editor-focus))))

(define (sh-quote s) (string-append "'" (string-replace s "'" "'\\''") "'"))
(define (unwrap r) (if (Ok? r) (Ok->value r) r))

(define (sh-capture cmd)
  (define c (command "sh" (list "-c" cmd)))
  (set-piped-stdout! c)
  (unwrap (wait->stdout (unwrap (spawn-process c)))))

;; Parse `git diff -U0` output into a list of hunks:
;; (list new-start new-count removed-lines)
(define (parse-hunks text)
  (define (range-after s prefix)   ; "-12,3" -> (12 3), "+7" -> (7 1)
    (define parts (split-many (substring s 1 (string-length s)) ","))
    (list (string->number (car parts))
          (if (pair? (cdr parts)) (string->number (cadr parts)) 1)))
  (let loop ([lines (split-many text "\n")] [hunks '()] [cur #f])
    (define (flush) (if cur (cons cur hunks) hunks))
    (cond
      [(null? lines) (reverse (flush))]
      [(starts-with? (car lines) "@@")
       (define ws (split-many (car lines) " "))
       (define new (range-after (caddr ws) "+"))
       (loop (cdr lines) (flush) (list '() (cadr new) (car new)))]
      [(and cur (starts-with? (car lines) "-"))
       (define l (car lines))
       (loop (cdr lines) hunks
             (list (cons (substring l 1 (string-length l)) (car cur)) (cadr cur) (caddr cur)))]
      [else (loop (cdr lines) hunks cur)])))

;; hunk layout: (removed-lines-reversed new-count new-start)
(define (hunk-start h) (caddr h))
(define (hunk-count h) (cadr h))
(define (hunk-removed h) (reverse (car h)))

(define (hunk-at hunks line)
  (let loop ([hs hunks])
    (cond
      [(null? hs) #f]
      [else
       (define h (car hs))
       (define s (hunk-start h))
       (define n (hunk-count h))
       ;; a pure deletion (n = 0) sits between lines s and s+1; helix marks
       ;; it on s+1, so accept either side
       (if (if (= n 0)
               (or (= line s) (= line (+ s 1)))
               (and (>= line s) (<= line (+ s n -1))))
           h
           (loop (cdr hs)))])))

;; ---- popup -----------------------------------------------------------------

(define *peek-lines* '())
(define *peek-row* 0)

(define (peek-truncate s w)
  (if (> (string-length s) w) (substring s 0 w) s))

(define (peek-render state rect frame)
  (define buf (editor-focused-buffer-area))
  (define x (if buf (area-x buf) 0))
  (define w (if buf (area-width buf) (area-width rect)))
  (define n (length *peek-lines*))
  (define h (+ 1 n))
  (define y (min *peek-row* (max 0 (- (area-height rect) h 1))))
  (define a (area x y w h))
  (define minus (theme-scope-ref "diff.minus"))
  (define head (style-with-dim (theme-scope-ref "ui.text")))
  (buffer/clear-with frame a (theme-scope-ref "ui.popup"))
  (frame-set-string! frame x y
                     (peek-truncate (string-append " ── HEAD ──" (if (= n 0) " (only additions)" "")) w) head)
  (let loop ([ls *peek-lines*] [row 1])
    (when (pair? ls)
      (frame-set-string! frame x (+ y row) (peek-truncate (string-append "-" (car ls)) w) minus)
      (loop (cdr ls) (+ row 1)))))

(define (peek-handle-event state event)
  (define ch (key-event-char event))
  (cond
    [(not (key-event? event)) event-result/ignore]
    [(key-event-escape? event) event-result/close]
    [(and (char? ch) (or (equal? ch #\q) (equal? ch #\space))) event-result/close]
    [else event-result/ignore-and-close]))

(struct PeekState ())

;;@doc
;; Show, beneath the cursor, the HEAD lines that the hunk at the cursor replaced.
(define (git-peek)
  (define path (current-path))
  (cond
    [(not path) (set-status! "git-peek: buffer has no file")]
    [else
     (define line (+ 1 (get-current-line-number)))
     (define out (sh-capture (string-append "cd \"$(dirname " (sh-quote path) ")\" && git diff -U0 -- "
                                            (sh-quote path))))
     (define h (hunk-at (parse-hunks out) line))
     (define cur (current-cursor))
     (define pos (and (pair? cur) (car cur)))
     (cond
       [(not h) (set-status! "git-peek: no change at cursor")]
       [else
        (set! *peek-lines* (hunk-removed h))
        (set! *peek-row* (if pos (+ 1 (position-row pos)) 0))
        (push-component!
         (new-component! "git-peek" (PeekState) peek-render
                         (hash "handle_event" peek-handle-event)))])]))
