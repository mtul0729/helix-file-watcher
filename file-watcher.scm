(require "helix-file-watcher.scm")
(require "helix/editor.scm")
(require (prefix-in helix. "helix/commands.scm"))
(require "helix/misc.scm")
(require "helix/ext.scm")
(require "helix/static.scm")
(require-builtin steel/time)

(provide spawn-watcher)

(define global-watcher (make-empty-watcher))
(define global-watcher-controller (watch-controller global-watcher))

(define (all-open-files)
  (~>> (editor-all-documents)
       (map editor-document->path)
       (filter id)
       (map try-canonicalize-path)
       (filter id)))

(define (try-canonicalize-path x)
  (with-handler (lambda (err)
                  (log::info! (to-string "Failed canonicalizing path: " x err))
                  #f)
                (canonicalize-path x)))

(define (path->doc-id path)
  (define paths
    (filter (lambda (doc-id) (equal? (editor-document->path doc-id) path)) (editor-all-documents)))

  (if (= (length paths) 1) (car paths) #f))

(define (try-file-last-modified x)
  (with-handler (lambda (err)
                  (log::info! (to-string "failed reading file metadata: " x err))
                  #f)
                (fs-metadata-modified (file-metadata x))))

;; reload file only if the write time isn't the same as it is for helix
(define (maybe-reload x [thunk #f])
  (define doc-id (path->doc-id x))
  (when doc-id
    (define helix-doc-last-saved (editor-document-last-saved doc-id))
    (define file-last-modified (try-file-last-modified x))

    ;; Racing helix... no good
    (when (and file-last-modified
               (system-time<? helix-doc-last-saved file-last-modified))
      (log::info! (to-string "reloading file: " x))
      (editor-document-reload doc-id)
      (when thunk
        (thunk)))))

(define (handle-event-paths! delay-ms paths)
  (unless (empty? paths)
    ;; Give helix time to finish its own edit before deciding to update.
    (enqueue-thread-local-callback-with-delay
     delay-ms
     (lambda () (for-each maybe-reload paths)))))

(define (loop-events delay-ms)
  (define paths (receive-paths! global-watcher))
  (with-handler
   (lambda (err)
     (log::info! (to-string "err" err))
     (loop-events delay-ms))
   (when paths
     (hx.with-context (lambda () (handle-event-paths! delay-ms paths))))
   (loop-events delay-ms)))

(define *started* #f)

(define (sync-watcher!)
  (with-handler (lambda (err)
                  (log::info! (to-string "failed syncing file watcher: " err)))
                (set-watched-files! global-watcher-controller (all-open-files))))

(define (reset-watcher!)
  (sync-watcher!))

(register-hook! 'document-opened
                (lambda (_)
                  (when *started*
                    (reset-watcher!))))

(register-hook! 'document-closed
                (lambda (_)
                  (when *started*
                    (reset-watcher!))))

;;@doc
;; Spawn a file watcher which will reload
(define (spawn-watcher [delay-ms 2000])
  (unless *started*
    (log::info! "watching open files")
    (reset-watcher!)
    (set! *started* #t)
    (spawn-native-thread (lambda ()
                           (log::info! "starting event loop")
                           (loop-events delay-ms)))))
