;; :zed-preview — open the current file in Zed's markdown preview.
;;
;; Zed has no CLI flag for the preview, so this opens the file with the zed
;; CLI, waits for the window to take focus, then types Zed's default Linux
;; binding for markdown::OpenPreview (ctrl-shift-v) with wtype (Wayland).

(require "helix/editor.scm")
(require "helix/misc.scm")

(provide zed-preview)

(define (zed-preview-path)
  (editor-document->path (editor->doc-id (editor-focus))))

;;@doc
;; Open the current file in Zed and switch it to the markdown preview.
(define (zed-preview)
  (define path (zed-preview-path))
  (cond
    [(not path) (set-status! "zed-preview: current buffer has no file")]
    [else
     (spawn-process
      (command "sh"
               (list "-c"
                     "zeditor \"$1\" && sleep 0.8 && wtype -M ctrl -M shift v -m shift -m ctrl"
                     "zed-preview"
                     path)))
     (set-status! (string-append "zed-preview: opened " path))]))
