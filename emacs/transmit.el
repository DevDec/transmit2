;;; transmit.el --- Description -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Declan Brown
;;
;; Author: Declan Brown <declanbrown@decsmacbook>
;; Maintainer: Declan Brown <declanbrown@decsmacbook>
;; Created: March 19, 2026
;; Modified: March 19, 2026
;; Version: 0.0.1
;; Keywords: abbrev bib c calendar comm convenience data docs emulations extensions faces files frames games hardware help hypermedia i18n internal languages lisp local maint mail matching mouse multimedia news outlines processes terminals tex text tools unix vc wp
;; Homepage: https://github.com/declanbrown/transmit
;; Package-Requires: ((emacs "24.3"))
;;
;; This file is not part of GNU Emacs.
;;
;;; Commentary:
;;
;;  Description
;;
;;; Code:



;;; transmit.el --- SFTP file transfer plugin for Emacs -*- lexical-binding: t -*-

;; Author: Port of transmit2 (https://github.com/DevDec/transmit2)
;; Version: 1.0.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: sftp, files, upload, remote

;;; Commentary:
;;
;; Emacs port of the transmit2 Neovim plugin.
;;
;; Requires the same C binary that ships with transmit2, placed in a
;; bin/ directory alongside this file:
;;   bin/transmit-linux    (Linux)
;;   bin/transmit-macos    (macOS)
;;   bin/transmit-windows.exe  (Windows)
;;
;; The SFTP config JSON file format is identical to the Neovim plugin,
;; and the transmit.json state file is written to `user-emacs-directory'
;; (compatible with the Neovim plugin's state if you point both at the
;; same location via `transmit-data-file').
;;
;; Quick start:
;;
;;   (require 'transmit)
;;   (transmit-setup "/path/to/sftp-config.json")
;;
;; Or with use-package:
;;
;;   (use-package transmit
;;     :load-path "/path/to/transmit.el"
;;     :config
;;     (transmit-setup "/path/to/sftp-config.json"))
;;
;; Commands:
;;   M-x transmit-select-server     - Pick server + remote for current project
;;   M-x transmit-upload-file       - Upload current buffer's file
;;   M-x transmit-remove-file       - Remove current buffer's file from remote
;;   M-x transmit-watch-directory   - Watch cwd for changes and auto-upload
;;   M-x transmit-stop-watching     - Stop all file watchers
;;   M-x transmit-disconnect        - Close SFTP connection
;;   M-x transmit-show-queue        - Show the upload queue
;;   M-x transmit-clear-queue       - Clear pending (non-active) queue items
;;   M-x transmit-show-log          - Show the debug log buffer

;;; Code:

(require 'json)
(require 'filenotify)
(require 'cl-lib)


;;;; ─── Constants ──────────────────────────────────────────────────────────────

(defconst transmit--phase-init        "init")
(defconst transmit--phase-username    "username")
(defconst transmit--phase-auth-method "auth_method")
(defconst transmit--phase-key         "key")
(defconst transmit--phase-password    "password")
(defconst transmit--phase-ready       "ready")
(defconst transmit--phase-active      "active")

(defconst transmit--excluded-patterns
  (list "\\.vim\\.bak$"
        "\\.sw[a-z]$"
        "\\.tmp$"
        "\\.git"
        "node_modules"
        "__pycache__"
        "\\.DS_Store$")
  "Filename patterns excluded from file-watching and uploads.")


;;;; ─── Customization ──────────────────────────────────────────────────────────

(defgroup transmit nil
  "SFTP file transfer plugin."
  :group 'tools
  :prefix "transmit-")

(defcustom transmit-keepalive-timeout (* 5 60)
  "Seconds of inactivity before closing the SFTP connection."
  :type 'integer
  :group 'transmit)

(defcustom transmit-auth-timeout 30
  "Seconds to wait for SFTP authentication before giving up."
  :type 'integer
  :group 'transmit)

(defcustom transmit-log-level 2
  "Minimum log level: 1=DEBUG  2=INFO  3=WARN  4=ERROR."
  :type '(choice (const :tag "DEBUG" 1)
                 (const :tag "INFO"  2)
                 (const :tag "WARN"  3)
                 (const :tag "ERROR" 4))
  :group 'transmit)

(defcustom transmit-data-file
  (expand-file-name "transmit.json" user-emacs-directory)
  "Path to the JSON file that records per-directory server selections.
This file is compatible with the Neovim transmit2 plugin's state file."
  :type 'file
  :group 'transmit)


;;;; ─── Internal State ─────────────────────────────────────────────────────────

(defvar transmit--server-config (make-hash-table :test 'equal)
  "Parsed server configurations keyed by server name.")

(defvar transmit--queue '()
  "List of pending SFTP operations.
Each item is a plist: (:id N :type TYPE :filename F :working-dir D :processing BOOL)")

(defvar transmit--next-queue-id 1 "Monotonically increasing queue item ID.")

(defvar transmit--process nil           "The live transmit child process, or nil.")
(defvar transmit--process-buf ""        "Partial output accumulator (for line-splitting).")
(defvar transmit--phase transmit--phase-init "Current handshake phase.")
(defvar transmit--connecting nil        "Non-nil while a connection attempt is in progress.")
(defvar transmit--connection-ready nil  "Non-nil when the SFTP session is fully established.")
(defvar transmit--is-exiting nil        "Non-nil during `kill-emacs'.")
(defvar transmit--pending-callback nil  "Callback to invoke once the connection is ready.")

(defvar transmit--keepalive-timer nil   "Timer that closes idle connections.")
(defvar transmit--auth-timeout-timer nil "Timer that aborts slow authentication.")

(defvar transmit--current-progress '(:file nil :percent nil)
  "Progress of the in-flight transfer: (:file STRING :percent 0-100).")

;; file-watchers: hash-table  root-dir -> (hash-table  subdir -> descriptor)
(defvar transmit--watchers (make-hash-table :test 'equal))

(defvar transmit--auto-upload-hook-installed nil
  "Non-nil if `after-save-hook' has been patched for auto-upload.")


;;;; ─── Logging ────────────────────────────────────────────────────────────────

(defconst transmit--log-level-names '(1 "DEBUG" 2 "INFO" 3 "WARN" 4 "ERROR"))

(defun transmit--log (level message &optional notify)
  "Write MESSAGE at log LEVEL to *transmit-log*.
If NOTIFY is non-nil, also echo to the minibuffer."
  (when (>= level transmit-log-level)
    (let* ((name (or (plist-get transmit--log-level-names level) "UNKNOWN"))
           (ts   (format-time-string "[%Y-%m-%d %H:%M:%S]"))
           (line (format "%s [%s] %s\n" ts name message)))
      (with-current-buffer (get-buffer-create "*transmit-log*")
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert line)))))
  (when notify
    (message "Transmit [%s]: %s"
             (cl-case level (1 "DEBUG") (2 "INFO") (3 "WARN") (4 "ERROR") (t "?"))
             message)))


;;;; ─── State-file I/O ─────────────────────────────────────────────────────────

(defun transmit--read-data ()
  "Return the transmit.json state as a hash-table (string keys), or nil."
  (condition-case err
      (if (file-exists-p transmit-data-file)
          (let ((json-object-type 'hash-table)
                (json-array-type  'list)
                (json-key-type    'string))
            (json-read-file transmit-data-file))
        ;; Create an empty state file on first use
        (let ((tbl (make-hash-table :test 'equal)))
          (transmit--write-data tbl)
          tbl))
    (error
     (transmit--log 4 (format "Failed to read transmit.json: %s" err) t)
     nil)))

(defun transmit--write-data (data)
  "Persist DATA (hash-table) to transmit.json.  Returns non-nil on success."
  (condition-case err
      (progn
        (make-directory (file-name-directory transmit-data-file) t)
        (with-temp-file transmit-data-file
          (insert (json-encode data)))
        t)
    (error
     (transmit--log 4 (format "Failed to write transmit.json: %s" err) t)
     nil)))

(defun transmit--working-dir-has-selection-p (dir)
  "Return non-nil if DIR has an active server/remote selection."
  (let* ((data  (transmit--read-data))
         (entry (and data (gethash dir data))))
    (and entry (gethash "remote" entry))))

(defun transmit--get-selected-server (&optional dir)
  "Return the server name selected for DIR (default: `default-directory')."
  (let* ((cwd   (expand-file-name (or dir default-directory)))
         (data  (transmit--read-data))
         (entry (and data (gethash cwd data))))
    (and entry (gethash "server_name" entry))))

(defun transmit--get-selected-remote (&optional dir)
  "Return the remote name selected for DIR."
  (let* ((cwd   (expand-file-name (or dir default-directory)))
         (data  (transmit--read-data))
         (entry (and data (gethash cwd data))))
    (and entry (gethash "remote" entry))))

(defun transmit--get-server-config (&optional dir)
  "Return the ServerConfig hash-table for the server selected in DIR."
  (let ((server (transmit--get-selected-server dir)))
    (and server (gethash server transmit--server-config))))

(defun transmit--update-selection (server-name remote &optional dir)
  "Record that DIR uses SERVER-NAME / REMOTE.
Passing \"none\" for SERVER-NAME clears the selection."
  (let* ((cwd  (expand-file-name (or dir default-directory)))
         (data (or (transmit--read-data) (make-hash-table :test 'equal))))
    (if (string= server-name "none")
        (remhash cwd data)
      (let ((entry (or (gethash cwd data) (make-hash-table :test 'equal))))
        (puthash "server_name" server-name entry)
        (puthash "remote"      remote      entry)
        (puthash cwd entry data)))
    (transmit--write-data data)))


;;;; ─── Binary Discovery ───────────────────────────────────────────────────────

(defun transmit--binary-path ()
  "Return the path to the platform-appropriate transmit binary, or nil."
  (let* ((this-file (or load-file-name
                        (and (boundp 'byte-compile-current-file)
                             byte-compile-current-file)
                        buffer-file-name))
         (plugin-dir (and this-file (file-name-directory this-file)))
         (bin-dir    (and plugin-dir (expand-file-name "bin" plugin-dir)))
         (binary-name
          (cond
           ((eq system-type 'darwin)                      "transmit-macos")
           ((memq system-type '(gnu gnu/linux gnu/kfreebsd)) "transmit-linux")
           ((memq system-type '(windows-nt ms-dos cygwin))   "transmit-windows.exe")
           (t (transmit--log 4 "Unsupported OS" t) nil))))
    (when (and bin-dir binary-name)
      (let ((path (expand-file-name binary-name bin-dir)))
        (cond
         ((file-executable-p path) path)
         ((file-exists-p path)
          ;; Try chmod +x
          (call-process "chmod" nil nil nil "+x" path)
          (if (file-executable-p path)
              path
            (transmit--log 4 (format "Cannot make executable: %s" path) t)
            nil))
         (t
          (transmit--log 4 (format "Binary not found: %s" path) t)
          nil))))))


;;;; ─── Queue ──────────────────────────────────────────────────────────────────

(defun transmit--enqueue (type filename working-dir)
  "Push a TYPE (\"upload\"/\"remove\") operation for FILENAME in WORKING-DIR.
Returns the new queue-item ID, or nil on error."
  (unless (member type '("upload" "remove"))
    (transmit--log 4 (format "Invalid operation type: %s" type) t)
    (cl-return-from transmit--enqueue nil))
  (let ((id transmit--next-queue-id))
    (cl-incf transmit--next-queue-id)
    (setq transmit--queue
          (nconc transmit--queue
                 (list (list :id id
                             :type type
                             :filename filename
                             :working-dir working-dir
                             :processing nil))))
    (transmit--log 1 (format "Queued [%d]: %s %s" id type filename))
    (transmit--ensure-connection #'transmit--process-next)
    id))

(defun transmit--queue-head () "Return the first queue item, or nil." (car transmit--queue))

(defun transmit--dequeue () "Remove the first queue item." (setq transmit--queue (cdr transmit--queue)))

(defun transmit--find-queue-item (id)
  "Return (item . index) for queue item with ID, or nil."
  (cl-loop for item in transmit--queue
           for i from 0
           when (= (plist-get item :id) id)
           return (cons item i)))


;;;; ─── Timers ─────────────────────────────────────────────────────────────────

(defun transmit--reset-keepalive ()
  "Restart the idle-disconnect timer."
  (when transmit--keepalive-timer (cancel-timer transmit--keepalive-timer))
  (setq transmit--keepalive-timer
        (run-with-timer
         transmit-keepalive-timeout nil
         (lambda ()
           (when transmit--process
             (condition-case nil
                 (process-send-string transmit--process "exit\n")
               (error nil))
             (setq transmit--process nil
                   transmit--phase transmit--phase-init
                   transmit--connecting nil
                   transmit--connection-ready nil)
             (transmit--log 2 "SFTP closed after inactivity" t))
           (setq transmit--keepalive-timer nil)))))

(defun transmit--start-auth-timeout ()
  "Start the authentication watchdog timer."
  (when transmit--auth-timeout-timer (cancel-timer transmit--auth-timeout-timer))
  (setq transmit--auth-timeout-timer
        (run-with-timer
         transmit-auth-timeout nil
         (lambda ()
           (when (and transmit--connecting (not transmit--connection-ready))
             (transmit--log 4 "SFTP authentication timed out" t)
             (when transmit--process
               (delete-process transmit--process)
               (setq transmit--process nil))
             (setq transmit--phase transmit--phase-init
                   transmit--connecting nil
                   transmit--connection-ready nil))
           (setq transmit--auth-timeout-timer nil)))))

(defun transmit--stop-auth-timeout ()
  "Cancel the authentication watchdog timer."
  (when transmit--auth-timeout-timer
    (cancel-timer transmit--auth-timeout-timer)
    (setq transmit--auth-timeout-timer nil)))


;;;; ─── Process: command dispatch ─────────────────────────────────────────────

(defun transmit--process-next ()
  "Send the head of the queue to the live SFTP process."
  (let ((item (transmit--queue-head)))
    (when (and item (not (plist-get item :processing)))
      (let* ((cfg       (transmit--get-server-config (plist-get item :working-dir)))
             (data      (transmit--read-data))
             (cwd       (plist-get item :working-dir))
             (filename  (plist-get item :filename))
             (relative  (file-relative-name filename cwd))
             (entry     (and data (gethash cwd data)))
             (rname     (and entry (gethash "remote" entry)))
             (remotes   (and cfg (gethash "remotes" cfg)))
             (rbase     (and remotes rname (gethash rname remotes))))
        (unless (and cfg rbase)
          (transmit--log 4 (format "No remote configured for %s" cwd) t)
          (transmit--dequeue)
          (cl-return-from transmit--process-next nil))
        (let* ((remote-path (concat rbase "/" relative))
               (cmd (cl-case (intern (plist-get item :type))
                      (upload (format "upload %s %s\n" filename remote-path))
                      (remove (format "remove %s\n" remote-path)))))
          (when cmd
            (plist-put item :processing t)
            (transmit--log 1 (format "Sending: %s" (string-trim cmd)))
            (process-send-string transmit--process cmd)))))))


;;;; ─── Process: output filter ────────────────────────────────────────────────

(defun transmit--filter (proc string)
  "Process PROC output STRING, splitting on newlines and driving the state machine."
  (setq transmit--process-buf (concat transmit--process-buf string))
  (let ((cfg (transmit--get-server-config)))
    ;; Process one complete line at a time
    (while (string-match "\n" transmit--process-buf)
      (let* ((pos  (match-beginning 0))
             (line (substring transmit--process-buf 0 pos)))
        (setq transmit--process-buf (substring transmit--process-buf (1+ pos)))
        (unless (string= line "")
          (transmit--log 1 (format "< %s" line))
          (transmit--handle-line proc line cfg))))))

(defun transmit--handle-line (proc line cfg)
  "Route LINE through the connection state machine using PROC and CFG."
  (let ((creds (and cfg (gethash "credentials" cfg))))
    (cond
     ;; ── Handshake phases ────────────────────────────────────────────────────
     ((and (string= transmit--phase transmit--phase-init)
           (string-match-p "Enter SSH hostname" line))
      (process-send-string proc (concat (gethash "host" creds) "\n"))
      (setq transmit--phase transmit--phase-username))

     ((and (string= transmit--phase transmit--phase-username)
           (string-match-p "Enter SSH username" line))
      (process-send-string proc (concat (gethash "username" creds) "\n"))
      (setq transmit--phase transmit--phase-auth-method))

     ((and (string= transmit--phase transmit--phase-auth-method)
           (string-match-p "Authentication method" line))
      (let ((auth-type (or (gethash "auth_type" creds) "key")))
        (process-send-string proc (concat auth-type "\n"))
        (setq transmit--phase
              (if (string= auth-type "password")
                  transmit--phase-password
                transmit--phase-key))))

     ((and (string= transmit--phase transmit--phase-password)
           (string-match-p "Enter password" line))
      (process-send-string proc (concat (gethash "password" creds) "\n"))
      (setq transmit--phase transmit--phase-ready))

     ((and (string= transmit--phase transmit--phase-key)
           (string-match-p "Enter path to private key" line))
      (process-send-string proc (concat (gethash "identity_file" creds) "\n"))
      (setq transmit--phase transmit--phase-ready))

     ((and (string= transmit--phase transmit--phase-ready)
           (string-match-p "Connected to" line))
      (setq transmit--phase          transmit--phase-active
            transmit--connecting     nil
            transmit--connection-ready t)
      (transmit--stop-auth-timeout)
      (transmit--log 2 "SFTP connection established" t)
      (when transmit--pending-callback
        (let ((cb transmit--pending-callback))
          (setq transmit--pending-callback nil)
          (funcall cb))))

     ;; ── Active transfer responses ────────────────────────────────────────────
     ((string= transmit--phase transmit--phase-active)
      (cond
       ;; PROGRESS|/path/to/file|42
       ((string-match "^PROGRESS|\\(.*\\)|\\([0-9]+\\)$" line)
        (let ((file (match-string 1 line))
              (pct  (string-to-number (match-string 2 line))))
          (when (and file (>= pct 0) (<= pct 100))
            (setq transmit--current-progress (list :file file :percent pct)))))

       ;; Success / failure
       ((or (string-match-p "^1|Upload succeeded" line)
            (string-match-p "^1|Remove succeeded" line)
            (string-match-p "^0|" line))
        (let ((item (transmit--queue-head)))
          (when (and item (plist-get item :processing))
            (transmit--log 1 (format "Done %s: %s"
                                     (plist-get item :type)
                                     (plist-get item :filename)))
            (transmit--dequeue)
            (setq transmit--current-progress '(:file nil :percent nil))
            (transmit--reset-keepalive)
            (if transmit--queue
                (transmit--process-next)
              (message "Transmit: All transfers complete")))))))

     (t nil))))                          ; ignore unrecognised lines


;;;; ─── Process: sentinel ─────────────────────────────────────────────────────

(defun transmit--sentinel (_proc event)
  "Handle process EVENT (typically exit or signal)."
  (transmit--log 3 (format "Process event: %s" (string-trim event)))
  (setq transmit--connection-ready nil
        transmit--process          nil
        transmit--connecting       nil
        transmit--current-progress '(:file nil :percent nil))
  (transmit--stop-auth-timeout)
  (unless transmit--is-exiting
    (transmit--log 3 "SFTP connection lost — reconnecting…" t)
    ;; Mark all in-flight items as pending again
    (dolist (item transmit--queue)
      (plist-put item :processing nil))
    (transmit--ensure-connection #'transmit--process-next)))


;;;; ─── Connection lifecycle ───────────────────────────────────────────────────

(defun transmit--ensure-connection (&optional callback)
  "Make sure an SFTP connection is live, then call CALLBACK.
If already connected, CALLBACK is called immediately.
If connecting, CALLBACK is stored and called once the handshake completes.
If not connected, the child process is started."
  (cond
   ;; Already live
   ((and transmit--process transmit--connection-ready)
    (when callback (funcall callback))
    (transmit--reset-keepalive))

   ;; Already trying to connect — queue the callback
   (transmit--connecting
    (when callback
      (let ((prev transmit--pending-callback))
        (setq transmit--pending-callback
              (if prev
                  (lambda () (funcall prev) (funcall callback))
                callback)))))

   ;; Need to connect
   (t
    (let ((cfg (transmit--get-server-config)))
      (unless cfg
        (transmit--log 4 "No SFTP server configured for current directory" t)
        (cl-return-from transmit--ensure-connection nil))
      (let ((binary (transmit--binary-path)))
        (unless binary
          (cl-return-from transmit--ensure-connection nil))
        (setq transmit--connecting       t
              transmit--phase            transmit--phase-init
              transmit--process-buf      ""
              transmit--pending-callback callback)
        (transmit--start-auth-timeout)
        (transmit--log 2 (format "Connecting to %s…"
                                  (gethash "host" (gethash "credentials" cfg))) t)
        (setq transmit--process
              (make-process
               :name     "transmit"
               :buffer   nil
               :command  (list binary)
               :filter   #'transmit--filter
               :sentinel #'transmit--sentinel
               :noquery  t)))))))


;;;; ─── File exclusion helpers ────────────────────────────────────────────────

(defun transmit--excluded-p (path)
  "Return non-nil if PATH matches any exclusion pattern."
  (cl-some (lambda (pat) (string-match-p pat path))
           transmit--excluded-patterns))


;;;; ─── File watching ──────────────────────────────────────────────────────────

(defun transmit--watch-callback (event)
  "Handle a filenotify EVENT, uploading or removing the affected file."
  ;; EVENT: (DESCRIPTOR ACTION FILE [FILE1])
  (let* ((action (nth 1 event))
         (file   (nth 2 event)))
    (when (and file (not (transmit--excluded-p file)))
      (cond
       ((eq action 'deleted)
        (let ((root (transmit--find-watch-root file)))
          (when root (transmit--enqueue "remove" file root))))

       ((memq action '(created changed))
        (when (and (file-regular-p file)
                   (not (transmit--excluded-p file)))
          (let ((root (transmit--find-watch-root file)))
            (when root (transmit--enqueue "upload" file root)))))))))

(defun transmit--find-watch-root (file)
  "Return the watch root that FILE lives under, or nil."
  (cl-loop for root being the hash-keys of transmit--watchers
           when (string-prefix-p root file)
           return root))

(defun transmit--watch-dir (root)
  "Recursively watch ROOT and its sub-directories.
Returns the number of directories successfully watched."
  (if (gethash root transmit--watchers)
      (progn (message "Transmit: already watching %s" root) 0)
    (unless (file-directory-p root)
      (transmit--log 4 (format "Not a directory: %s" root) t)
      (cl-return-from transmit--watch-dir 0))
    (let ((subdirs (transmit--list-subdirs root))
          (tbl (make-hash-table :test 'equal))
          (count 0))
      (puthash root tbl transmit--watchers)
      (dolist (dir subdirs)
        (unless (or (transmit--excluded-p dir)
                    (gethash dir tbl))
          (condition-case err
              (let ((desc (file-notify-add-watch
                           dir '(change) #'transmit--watch-callback)))
                (puthash dir desc tbl)
                (cl-incf count))
            (error
             (transmit--log 3 (format "Could not watch %s: %s" dir err))))))
      (message "Transmit: watching %d director%s under %s"
               count (if (= count 1) "y" "ies") root)
      count)))

(defun transmit--list-subdirs (root)
  "Return a list of ROOT and all its sub-directories (excluding hidden/excluded)."
  (let (result)
    (when (file-directory-p root)
      (push root result)
      (dolist (entry (directory-files-recursively root "" t))
        (when (and (file-directory-p entry)
                   (not (transmit--excluded-p entry)))
          (push entry result))))
    result))

(defun transmit--stop-watching (&optional root)
  "Stop watching ROOT, or all roots if ROOT is nil.  Returns count removed."
  (let ((count 0))
    (if root
        (when-let ((tbl (gethash root transmit--watchers)))
          (maphash (lambda (_dir desc)
                     (condition-case nil (file-notify-rm-watch desc) (error nil))
                     (cl-incf count))
                   tbl)
          (remhash root transmit--watchers))
      ;; Stop all
      (maphash (lambda (_root tbl)
                 (maphash (lambda (_dir desc)
                            (condition-case nil (file-notify-rm-watch desc) (error nil))
                            (cl-incf count))
                          tbl))
               transmit--watchers)
      (clrhash transmit--watchers))
    count))


;;;; ─── High-level file operations ────────────────────────────────────────────

(defun transmit--upload (file &optional working-dir)
  "Queue FILE for upload.  Returns queue-item ID or nil."
  (let* ((f    (or file (buffer-file-name)))
         (cwd  (expand-file-name (or working-dir default-directory))))
    (unless f
      (message "Transmit: buffer has no associated file")
      (cl-return-from transmit--upload nil))
    (unless (file-regular-p f)
      (message "Transmit: not a regular file: %s" f)
      (cl-return-from transmit--upload nil))
    (unless (transmit--working-dir-has-selection-p cwd)
      (message "Transmit: no server configured for %s" cwd)
      (cl-return-from transmit--upload nil))
    (transmit--enqueue "upload" (expand-file-name f) cwd)))

(defun transmit--remove (file &optional working-dir)
  "Queue FILE for remote removal.  Returns queue-item ID or nil."
  (let* ((f   (or file (buffer-file-name)))
         (cwd (expand-file-name (or working-dir default-directory))))
    (unless f
      (message "Transmit: buffer has no associated file")
      (cl-return-from transmit--remove nil))
    (unless (transmit--working-dir-has-selection-p cwd)
      (message "Transmit: no server configured for %s" cwd)
      (cl-return-from transmit--remove nil))
    (transmit--enqueue "remove" (expand-file-name f) cwd)))


;;;; ─── Auto-upload on save ────────────────────────────────────────────────────

(defun transmit--after-save-hook ()
  "Upload the saved buffer if its project directory has a server selected."
  (when (and buffer-file-name
             (transmit--working-dir-has-selection-p
              (expand-file-name default-directory)))
    (transmit--upload buffer-file-name default-directory)))


;;;; ─── Server / remote selection UI ──────────────────────────────────────────

(defun transmit--server-names ()
  "Return a list of configured server names (without \"none\")."
  (let (names)
    (maphash (lambda (k _v) (push k names)) transmit--server-config)
    (sort names #'string<)))

(defun transmit--remote-names (server-name)
  "Return a sorted list of remote names for SERVER-NAME."
  (let* ((cfg     (gethash server-name transmit--server-config))
         (remotes (and cfg (gethash "remotes" cfg)))
         names)
    (when remotes
      (maphash (lambda (k _v) (push k names)) remotes))
    (sort names #'string<)))


;;;; ─── Setup ──────────────────────────────────────────────────────────────────

;;;###autoload
(defun transmit-setup (config-location)
  "Initialise Transmit from the JSON file at CONFIG-LOCATION.
This is the entry point; call it from your init file."
  (interactive "fTransmit config file: ")
  (unless (file-exists-p config-location)
    (user-error "Transmit: config file not found: %s" config-location))
  (condition-case err
      (let ((json-object-type 'hash-table)
            (json-array-type  'list)
            (json-key-type    'string))
        (let ((parsed (json-read-file config-location)))
          (clrhash transmit--server-config)
          (maphash (lambda (k v) (puthash k v transmit--server-config)) parsed)
          (transmit--log 2
            (format "Loaded %d server(s) from %s"
                    (hash-table-count transmit--server-config)
                    config-location) t)))
    (error
     (user-error "Transmit: failed to parse config: %s" err)))

  ;; Register interactive commands
  (transmit--register-commands)

  ;; Kill-Emacs cleanup
  (add-hook 'kill-emacs-hook #'transmit--on-kill-emacs)

  ;; Check if current directory already has a server selection and set up
  ;; auto-upload / watching accordingly
  (let ((cfg (transmit--get-server-config)))
    (when cfg
      (when (gethash "upload_on_bufwrite" cfg)
        (transmit--install-auto-upload))
      (when (gethash "watch_for_changes" cfg)
        (transmit-watch-directory)))))

(defun transmit--register-commands ()
  "Define all user-facing interactive commands."
  ;; (Commands are defined with ###autoload below; this is a no-op hook
  ;; so callers don't have to know that.)
  nil)

(defun transmit--on-kill-emacs ()
  "Tear down cleanly when Emacs exits."
  (setq transmit--is-exiting t)
  (transmit--stop-watching)
  (when transmit--process
    (condition-case nil
        (process-send-string transmit--process "exit\n")
      (error nil))
    (delete-process transmit--process)
    (setq transmit--process nil))
  (when transmit--keepalive-timer   (cancel-timer transmit--keepalive-timer))
  (when transmit--auth-timeout-timer (cancel-timer transmit--auth-timeout-timer))
  (setq transmit--queue '()))

(defun transmit--install-auto-upload ()
  "Add the auto-upload after-save hook (idempotent)."
  (unless transmit--auto-upload-hook-installed
    (add-hook 'after-save-hook #'transmit--after-save-hook)
    (setq transmit--auto-upload-hook-installed t)
    (transmit--log 2 "Auto-upload on save enabled" t)))


;;;; ─── Interactive commands ───────────────────────────────────────────────────

;;;###autoload
(defun transmit-select-server ()
  "Interactively pick a server and remote for the current project directory."
  (interactive)
  (let ((servers (transmit--server-names)))
    (unless servers
      (user-error "Transmit: no servers configured"))
    (let* ((choice (completing-read
                    (format "Transmit server [%s]: "
                            (or (transmit--get-selected-server) "none"))
                    (cons "none" servers) nil t))
           (cwd (expand-file-name default-directory)))
      (if (string= choice "none")
          (progn
            (transmit--update-selection "none" nil cwd)
            (message "Transmit: cleared server selection for %s" cwd))
        (let ((remotes (transmit--remote-names choice)))
          (unless remotes
            (user-error "Transmit: no remotes defined for server '%s'" choice))
          (let ((remote (completing-read
                         (format "Remote for %s: " choice)
                         remotes nil t)))
            (transmit--update-selection choice remote cwd)
            (message "Transmit: %s → %s" choice remote)
            ;; Apply auto-upload / watching for the newly chosen config
            (let ((cfg (gethash choice transmit--server-config)))
              (when (and cfg (gethash "upload_on_bufwrite" cfg))
                (transmit--install-auto-upload))
              (when (and cfg (gethash "watch_for_changes" cfg))
                (transmit-watch-directory)))))))))

;;;###autoload
(defun transmit-upload-file (&optional file)
  "Upload FILE (default: current buffer's file) to the configured remote."
  (interactive)
  (transmit--upload file))

;;;###autoload
(defun transmit-remove-file (&optional file)
  "Remove FILE (default: current buffer's file) from the configured remote."
  (interactive)
  (transmit--remove file))

;;;###autoload
(defun transmit-watch-directory (&optional dir)
  "Watch DIR (default: `default-directory') for changes and auto-upload."
  (interactive)
  (let* ((root (expand-file-name (or dir default-directory)))
         (cfg  (transmit--get-server-config root)))
    (unless cfg
      (user-error "Transmit: no server configured for %s" root))
    (let ((excluded (gethash "exclude_watch_directories" cfg)))
      ;; Rebuild exclusion list to include project-specific excludes
      (transmit--watch-dir root))))

;;;###autoload
(defun transmit-stop-watching (&optional dir)
  "Stop watching DIR (default: all directories)."
  (interactive)
  (let ((n (transmit--stop-watching (and dir (expand-file-name dir)))))
    (message "Transmit: removed %d watcher%s" n (if (= n 1) "" "s"))))

;;;###autoload
(defun transmit-disconnect ()
  "Send 'exit' to the SFTP process and close the connection."
  (interactive)
  (if transmit--process
      (progn
        (process-send-string transmit--process "exit\n")
        (message "Transmit: disconnecting…"))
    (message "Transmit: not connected")))

;;;###autoload
(defun transmit-show-queue ()
  "Display the current upload queue in a temporary buffer."
  (interactive)
  (if (null transmit--queue)
      (message "Transmit: queue is empty")
    (with-output-to-temp-buffer "*transmit-queue*"
      (princ (format "%-6s %-8s %-12s %s\n" "ID" "STATUS" "TYPE" "FILE"))
      (princ (make-string 72 ?─))
      (princ "\n")
      (dolist (item transmit--queue)
        (princ (format "%-6d %-8s %-12s %s\n"
                       (plist-get item :id)
                       (if (plist-get item :processing) "ACTIVE" "pending")
                       (plist-get item :type)
                       (file-name-nondirectory (plist-get item :filename))))))))

;;;###autoload
(defun transmit-clear-queue ()
  "Remove all pending (non-active) items from the queue."
  (interactive)
  (let ((before (length transmit--queue)))
    (setq transmit--queue
          (cl-remove-if-not (lambda (i) (plist-get i :processing))
                            transmit--queue))
    (let ((cleared (- before (length transmit--queue))))
      (message "Transmit: cleared %d item%s" cleared (if (= cleared 1) "" "s")))))

;;;###autoload
(defun transmit-cancel-item (id)
  "Cancel queue item with numeric ID (non-active items only)."
  (interactive "nQueue item ID to cancel: ")
  (let ((found (transmit--find-queue-item id)))
    (if (null found)
        (message "Transmit: item %d not found" id)
      (let ((item (car found))
            (idx  (cdr found)))
        (if (plist-get item :processing)
            (message "Transmit: item %d is active, cannot cancel" id)
          (setq transmit--queue (cl-remove-if (lambda (i) (= (plist-get i :id) id))
                                              transmit--queue))
          (message "Transmit: cancelled item %d (%s)" id
                   (file-name-nondirectory (plist-get item :filename))))))))

;;;###autoload
(defun transmit-show-log ()
  "Switch to the Transmit debug log buffer."
  (interactive)
  (pop-to-buffer (get-buffer-create "*transmit-log*")))

;;;###autoload
(defun transmit-show-progress ()
  "Echo the current transfer progress."
  (interactive)
  (let ((f   (plist-get transmit--current-progress :file))
        (pct (plist-get transmit--current-progress :percent)))
    (if f
        (message "Transmit: uploading %s … %d%%" (file-name-nondirectory f) pct)
      (message "Transmit: no transfer in progress"))))

;;;###autoload
(defun transmit-status ()
  "Show a one-line status summary in the minibuffer."
  (interactive)
  (let ((server  (or (transmit--get-selected-server) "none"))
        (remote  (or (transmit--get-selected-remote) "none"))
        (qlen    (length transmit--queue))
        (conn    (cond (transmit--connection-ready "connected")
                       (transmit--connecting       "connecting…")
                       (t                          "disconnected"))))
    (message "Transmit: %s → %s | %s | queue: %d" server remote conn qlen)))


;;;; ─── Public API (for status-line integrations etc.) ───────────────────────

(defun transmit-get-progress ()
  "Return current progress plist (:file STRING :percent N), or nils."
  transmit--current-progress)

(defun transmit-queue-length ()
  "Return the number of pending/active queue items."
  (length transmit--queue))

(defun transmit-connection-status ()
  "Return (connected . connecting) booleans."
  (cons transmit--connection-ready transmit--connecting))

(defun transmit-current-server ()
  "Return the server name selected for `default-directory', or nil."
  (transmit--get-selected-server))

(defun transmit-current-remote ()
  "Return the remote name selected for `default-directory', or nil."
  (transmit--get-selected-remote))

(provide 'transmit)
;;; transmit.el ends here
