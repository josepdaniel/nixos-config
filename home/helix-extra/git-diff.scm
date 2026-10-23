;; :git-diff / :git-orig — see the original of the file you're editing.
;;
;; :git-diff  opens a vertical split with `git diff` for the current file.
;; :git-orig  opens a vertical split with the file as it is at HEAD, so you
;;            can navigate the old code with normal Helix motions.

(require "helix/editor.scm")
(require "helix/commands.scm")
(require "helix/misc.scm")

(provide git-diff git-orig)

(define (current-path)
  (editor-document->path (editor->doc-id (editor-focus))))

(define (sh-quote s)
  (string-append "'" (string-replace s "'" "'\\''") "'"))

;; Open a vsplit holding the output of `cmd` (run in the file's directory).
(define (scratch-split name lang path cmd)
  (vsplit-new)
  (insert-output (string-append "cd \"$(dirname " (sh-quote path) ")\" && " cmd))
  (set-scratch-buffer-name! name)
  (set-language lang)
  (goto-line 1))

;;@doc
;; Show `git diff` for the current file in a vertical split.
(define (git-diff)
  (define path (current-path))
  (if (not path)
      (set-status! "git-diff: buffer has no file")
      (scratch-split (string-append "diff: " path) "diff" path
                     (string-append "git diff -- " (sh-quote path)))))

;;@doc
;; Show the current file as it is at HEAD in a vertical split.
(define (git-orig)
  (define path (current-path))
  (define lang (editor-document->language (editor->doc-id (editor-focus))))
  (if (not path)
      (set-status! "git-orig: buffer has no file")
      (scratch-split (string-append "HEAD: " path) (or lang "text") path
                     (string-append "git show HEAD:\"$(git ls-files --full-name -- "
                                    (sh-quote path) ")\""))))
