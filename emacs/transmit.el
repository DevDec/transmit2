;;; transmit.el --- SFTP file transfer plugin for Emacs -*- lexical-binding: t -*-

;; Author: Port of transmit2 (https://github.com/DevDec/transmit2)
;; Version: 1.2.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: sftp, files, upload, remote

;;; Commentary:
;;
;; Emacs port of the transmit2 Neovim plugin.
;;
;; Requires the same C binary that ships with transmit2:
;;   bin/transmit-linux    (Linux)
;;   bin/transmit-macos    (macOS)
;;   bin/transmit-windows.exe  (Windows)
;;
;; Quick start in Doom config.el:
;;
;;   (add-to-list 'load-path "~/projects/transmit2.nvim/emacs/")
;;   (require 'transmit)
;;   (setq transmit-binary-path "~/projects/transmit2.nvim/bin/transmit-linux")
;;   (transmit-setup "~/transmit_sftp/config.json")
;;
;; Commands:
;;   M-x transmit-select-server   - Pick server + remote for current directory
;;   M-x transmit-upload-file     - Upload current buffer's file
;;   M-x transmit-remove-file     - Remove current buffer's file from remote
;;   M-x transmit-watch-directory - Watch cwd for changes and auto-upload
;;   M-x transmit-stop-watching   - Stop all file watchers
;;   M-x transmit-disconnect      - Close SFTP connection
;;   M-x transmit-show-queue      - Show the upload queue
;;   M-x transmit-clear-queue     - Clear pending queue items
;;   M-x transmit-show-log        - Show the debug log buffer
;;   M-x transmit-status          - Show connection/queue summary

;;; Code:

(require 'json)
(require 'filenotify)
(require 'cl-lib)


;;;; ---- Constants ------------------------------------------------------------

(defconst transmit--phase-init        "init")
(defconst transmit--phase-username    "username")
(defconst transmit--phase-auth-method "auth_method")
(defconst transmit--phase-key         "key")
(defconst transmit--phase-password    "password")
(defconst transmit--phase-ready       "ready")
(defconst transmit--phase-active      "active")

(defconst transmit--excluded-patterns
  (list "\\.vim\\.bak$" "\\.sw[a-z]$" "\\.tmp$" "\\.git"
        "node_modules" "__pycache__" "\\.DS_Store$")
  "Filename patterns excluded from file-watching and uploads.")


;;;; ---- Customization --------------------------------------------------------

(defgroup transmit nil
  "SFTP file transfer plugin."
  :group 'tools
  :prefix "transmit-")

(defcustom transmit-keepalive-timeout (* 5 60)
  "Seconds of inactivity before closing the SFTP connection."
  :type 'integer :group 'transmit)

(defcustom transmit-auth-timeout 30
  "Seconds to wait for SFTP authentication before giving up."
  :type 'integer :group 'transmit)

(defcustom transmit-log-level 2
  "Minimum log level: 1=DEBUG 2=INFO 3=WARN 4=ERROR."
  :type '(choice (const :tag "DEBUG" 1) (const :tag "INFO" 2)
                 (const :tag "WARN" 3)  (const :tag "ERROR" 4))
  :group 'transmit)

(defcustom transmit-data-file
  (expand-file-name "transmit.json" user-emacs-directory)
  "Path to the JSON file recording per-directory server selections.
Compatible with the Neovim transmit2 plugin state file."
  :type 'file :group 'transmit)

(defcustom transmit-binary-path nil
  "Explicit path to the transmit binary.
When nil the binary is found automatically.
Example: (setq transmit-binary-path \"~/projects/transmit2.nvim/bin/transmit-linux\")"
  :type '(choice (const :tag "Auto-detect" nil) file)
  :group 'transmit)


;;;; ---- Internal State -------------------------------------------------------

(defvar transmit--server-config (make-hash-table :test 'equal))
(defvar transmit--queue '())
(defvar transmit--next-queue-id 1)
(defvar transmit--process nil)
(defvar transmit--process-buf "")
(defvar transmit--phase transmit--phase-init)
(defvar transmit--connecting nil)
(defvar transmit--connection-ready nil)
(defvar transmit--is-exiting nil)
(defvar transmit--pending-callback nil)
(defvar transmit--keepalive-timer nil)
(defvar transmit--auth-timeout-timer nil)
(defvar transmit--current-progress (list :file nil :percent nil))
(defvar transmit--watchers (make-hash-table :test 'equal))
(defvar transmit--auto-upload-hook-installed nil)


;;;; ---- Logging --------------------------------------------------------------

(defun transmit--log (level message &optional notify)
  "Write MESSAGE at log LEVEL to *transmit-log*.  NOTIFY also echoes it."
  (when (>= level transmit-log-level)
    (let* ((name (cl-case level (1 "DEBUG") (2 "INFO") (3 "WARN") (4 "ERROR") (t "?")))
           (line (format "%s [%s] %s\n"
                         (format-time-string "[%Y-%m-%d %H:%M:%S]") name message)))
      (with-current-buffer (get-buffer-create "*transmit-log*")
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert line)))))
  (when notify
    (message "Transmit [%s]: %s"
             (cl-case level (1 "DEBUG") (2 "INFO") (3 "WARN") (4 "ERROR") (t "?"))
             message)))


;;;; ---- State-file I/O -------------------------------------------------------

(defun transmit--read-data ()
  "Return transmit.json as a hash-table, or nil on error."
  (condition-case err
      (if (file-exists-p transmit-data-file)
          (let ((json-object-type 'hash-table)
                (json-array-type  'list)
                (json-key-type    'string))
            (json-read-file transmit-data-file))
        (let ((tbl (make-hash-table :test 'equal)))
          (transmit--write-data tbl)
          tbl))
    (error
     (transmit--log 4 (format "Failed to read transmit.json: %s" err) t)
     nil)))

(defun transmit--write-data (data)
  "Persist DATA to transmit.json.  Returns non-nil on success."
  (condition-case err
      (progn
        (make-directory (file-name-directory transmit-data-file) t)
        (with-temp-file transmit-data-file (insert (json-encode data)))
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
  "Return the server name selected for DIR, or nil."
  (let* ((cwd   (expand-file-name (or dir default-directory)))
         (data  (transmit--read-data))
         (entry (and data (gethash cwd data))))
    (and entry (gethash "server_name" entry))))

(defun transmit--get-selected-remote (&optional dir)
  "Return the remote name selected for DIR, or nil."
  (let* ((cwd   (expand-file-name (or dir default-directory)))
         (data  (transmit--read-data))
         (entry (and data (gethash cwd data))))
    (and entry (gethash "remote" entry))))

(defun transmit--get-server-config (&optional dir)
  "Return the server config hash-table for the server selected in DIR."
  (let ((server (transmit--get-selected-server dir)))
    (and server (gethash server transmit--server-config))))

(defun transmit--update-selection (server-name remote &optional dir)
  "Record that DIR uses SERVER-NAME / REMOTE.  Pass \"none\" to clear."
  (let* ((cwd  (expand-file-name (or dir default-directory)))
         (data (or (transmit--read-data) (make-hash-table :test 'equal))))
    (if (string= server-name "none")
        (remhash cwd data)
      (let ((entry (or (gethash cwd data) (make-hash-table :test 'equal))))
        (puthash "server_name" server-name entry)
        (puthash "remote"      remote      entry)
        (puthash cwd entry data)))
    (transmit--write-data data)))


;;;; ---- Binary Discovery -----------------------------------------------------

(defun transmit--binary-name ()
  "Return the platform binary filename, or nil."
  (cond
   ((eq system-type 'darwin)                        "transmit-macos")
   ((memq system-type '(gnu gnu/linux gnu/kfreebsd)) "transmit-linux")
   ((memq system-type '(windows-nt ms-dos cygwin))   "transmit-windows.exe")
   (t (transmit--log 4 "Unsupported OS" t) nil)))

(defun transmit--try-binary (path)
  "Return PATH if executable; attempt chmod +x if it exists but is not."
  (when path
    (cond
     ((file-executable-p path) path)
     ((file-exists-p path)
      (call-process "chmod" nil nil nil "+x" path)
      (if (file-executable-p path) path
        (transmit--log 4 (format "Cannot make executable: %s" path) t)
        nil))
     (t nil))))

(defun transmit--binary-path ()
  "Return path to the transmit binary, or nil."
  (cl-block transmit--binary-path
    (let ((bname (transmit--binary-name)))
      (unless bname
        (cl-return-from transmit--binary-path nil))

      ;; 1. Explicit override via custom variable
      (when transmit-binary-path
        (let ((found (transmit--try-binary (expand-file-name transmit-binary-path))))
          (when found
            (cl-return-from transmit--binary-path found))))

      ;; 2. straight.el repos directory
      (let* ((base (or (bound-and-true-p straight-base-dir)
                       (expand-file-name ".local" user-emacs-directory)))
             (path (expand-file-name
                    (concat "straight/repos/transmit2/bin/" bname) base)))
        (let ((found (transmit--try-binary path)))
          (when found
            (cl-return-from transmit--binary-path found))))

      ;; 3. Relative to this .el file (../../bin/ from emacs/transmit.el)
      (let* ((this-file (or load-file-name buffer-file-name))
             (repo-root (and this-file
                             (expand-file-name
                              "../../" (file-name-directory this-file))))
             (path (and repo-root
                        (expand-file-name (concat "bin/" bname) repo-root))))
        (let ((found (transmit--try-binary path)))
          (when found
            (cl-return-from transmit--binary-path found))))

      (transmit--log 4
        (format "Binary '%s' not found. Set `transmit-binary-path'." bname) t)
      nil)))


;;;; ---- Queue ----------------------------------------------------------------

(defun transmit--enqueue (type filename working-dir)
  "Queue a TYPE operation for FILENAME in WORKING-DIR.  Returns ID or nil."
  (cl-block transmit--enqueue
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
      id)))

(defun transmit--queue-head ()
  "Return the first queue item, or nil."
  (car transmit--queue))

(defun transmit--dequeue ()
  "Remove the first queue item."
  (setq transmit--queue (cdr transmit--queue)))

(defun transmit--find-queue-item (id)
  "Return (item . index) for queue item ID, or nil."
  (cl-loop for item in transmit--queue
           for i from 0
           when (= (plist-get item :id) id)
           return (cons item i)))


;;;; ---- Timers ---------------------------------------------------------------

(defun transmit--reset-keepalive ()
  "Restart the idle-disconnect timer."
  (when transmit--keepalive-timer (cancel-timer transmit--keepalive-timer))
  (setq transmit--keepalive-timer
        (run-with-timer transmit-keepalive-timeout nil
          (lambda ()
            (when transmit--process
              (condition-case nil
                  (process-send-string transmit--process "exit\n")
                (error nil))
              (setq transmit--process          nil
                    transmit--phase            transmit--phase-init
                    transmit--connecting       nil
                    transmit--connection-ready nil)
              (transmit--log 2 "SFTP closed after inactivity" t))
            (setq transmit--keepalive-timer nil)))))

(defun transmit--start-auth-timeout ()
  "Start the authentication watchdog timer."
  (when transmit--auth-timeout-timer (cancel-timer transmit--auth-timeout-timer))
  (setq transmit--auth-timeout-timer
        (run-with-timer transmit-auth-timeout nil
          (lambda ()
            (when (and transmit--connecting (not transmit--connection-ready))
              (transmit--log 4 "SFTP authentication timed out" t)
              (when transmit--process
                (delete-process transmit--process)
                (setq transmit--process nil))
              (setq transmit--phase            transmit--phase-init
                    transmit--connecting       nil
                    transmit--connection-ready nil))
            (setq transmit--auth-timeout-timer nil)))))

(defun transmit--stop-auth-timeout ()
  "Cancel the authentication watchdog timer."
  (when transmit--auth-timeout-timer
    (cancel-timer transmit--auth-timeout-timer)
    (setq transmit--auth-timeout-timer nil)))


;;;; ---- Process: command dispatch --------------------------------------------

(defun transmit--process-next ()
  "Send the head of the queue to the live SFTP process."
  (cl-block transmit--process-next
    (let ((item (transmit--queue-head)))
      (when (and item (not (plist-get item :processing)))
        (let* ((cwd      (plist-get item :working-dir))
               (filename (plist-get item :filename))
               (cfg      (transmit--get-server-config cwd))
               (data     (transmit--read-data))
               (entry    (and data (gethash cwd data)))
               (rname    (and entry (gethash "remote" entry)))
               (remotes  (and cfg (gethash "remotes" cfg)))
               (rbase    (and remotes rname (gethash rname remotes))))
          (unless (and cfg rbase)
            (transmit--log 4 (format "No remote configured for %s" cwd) t)
            (transmit--dequeue)
            (cl-return-from transmit--process-next nil))
          (let* ((relative    (file-relative-name filename cwd))
                 (remote-path (concat rbase "/" relative))
                 (cmd (cl-case (intern (plist-get item :type))
                        (upload (format "upload %s %s\n" filename remote-path))
                        (remove (format "remove %s\n"    remote-path)))))
            (when cmd
              (plist-put item :processing t)
              (transmit--log 1 (format "Sending: %s" (string-trim cmd)))
              (process-send-string transmit--process cmd))))))))


;;;; ---- Process: output filter -----------------------------------------------
;;
;; The binary uses prompts that end with ": " (no newline) during the
;; handshake phase, then switches to newline-terminated response lines once
;; connected.  We handle both:
;;   - Incomplete buffer: scanned for prompt patterns after every chunk.
;;   - Complete lines (\n-terminated): processed for PROGRESS/success/failure.

(defun transmit--send (proc text)
  "Send TEXT to PROC and log it at DEBUG level."
  (transmit--log 1 (format "> %s" (string-trim text)))
  (process-send-string proc text))

(defun transmit--check-prompt (proc cfg)
  "Check the incomplete accumulation buffer for handshake prompts and respond."
  (let ((buf transmit--process-buf)
        (creds (and cfg (gethash "credentials" cfg))))
    (cond
     ;; hostname prompt
     ((and (string= transmit--phase transmit--phase-init)
           (string-match-p "Enter SSH hostname" buf))
      (transmit--send proc (concat (gethash "host" creds) "\n"))
      (setq transmit--phase transmit--phase-username)
      (setq transmit--process-buf ""))

     ;; username prompt
     ((and (string= transmit--phase transmit--phase-username)
           (string-match-p "Enter SSH username" buf))
      (transmit--send proc (concat (gethash "username" creds) "\n"))
      (setq transmit--phase transmit--phase-auth-method)
      (setq transmit--process-buf ""))

     ;; auth method prompt
     ((and (string= transmit--phase transmit--phase-auth-method)
           (string-match-p "Authentication method" buf))
      (let ((auth-type (or (gethash "auth_type" creds) "key")))
        (transmit--send proc (concat auth-type "\n"))
        (setq transmit--phase
              (if (string= auth-type "password")
                  transmit--phase-password
                transmit--phase-key))
        (setq transmit--process-buf "")))

     ;; password prompt
     ((and (string= transmit--phase transmit--phase-password)
           (string-match-p "Enter password" buf))
      (transmit--send proc (concat (gethash "password" creds) "\n"))
      (setq transmit--phase transmit--phase-ready)
      (setq transmit--process-buf ""))

     ;; private key prompt
     ((and (string= transmit--phase transmit--phase-key)
           (string-match-p "Enter path to private key" buf))
      (transmit--send proc (concat (expand-file-name (gethash "identity_file" creds)) "\n"))
      (setq transmit--phase transmit--phase-ready)
      (setq transmit--process-buf "")))))

(defun transmit--handle-line (line)
  "Handle a complete newline-terminated LINE from the binary."
  (transmit--log 1 (format "< %s" line))
  (cond
   ;; Connected confirmation
   ((and (string= transmit--phase transmit--phase-ready)
         (string-match-p "Connected to" line))
    (setq transmit--phase           transmit--phase-active
          transmit--connecting      nil
          transmit--connection-ready t)
    (transmit--stop-auth-timeout)
    (transmit--log 2 "SFTP connection established" t)
    (when transmit--pending-callback
      (let ((cb transmit--pending-callback))
        (setq transmit--pending-callback nil)
        (funcall cb))))

   ;; Active: progress update
   ((and (string= transmit--phase transmit--phase-active)
         (string-match "^PROGRESS|\\(.*\\)|\\([0-9]+\\)$" line))
    (let ((file (match-string 1 line))
          (pct  (string-to-number (match-string 2 line))))
      (when (and file (>= pct 0) (<= pct 100))
        (setq transmit--current-progress (list :file file :percent pct)))))

   ;; Active: operation complete (success or failure)
   ((and (string= transmit--phase transmit--phase-active)
         (or (string-match-p "^1|Upload succeeded"  line)
             (string-match-p "^1|Remove succeeded"  line)
             (string-match-p "^0|"                  line)))
    (let ((item (transmit--queue-head)))
      (when (and item (plist-get item :processing))
        (transmit--log 1 (format "Done %s: %s"
                                 (plist-get item :type)
                                 (plist-get item :filename)))
        (transmit--dequeue)
        (setq transmit--current-progress (list :file nil :percent nil))
        (transmit--reset-keepalive)
        (if transmit--queue
            (transmit--process-next)
          (message "Transmit: All transfers complete")))))))

(defun transmit--filter (proc string)
  "Accumulate output STRING from PROC and drive the state machine."
  (setq transmit--process-buf (concat transmit--process-buf string))
  (let ((cfg (transmit--get-server-config)))
    ;; During handshake, check the buffer for prompts (no newline required)
    (unless (string= transmit--phase transmit--phase-active)
      (transmit--check-prompt proc cfg))
    ;; Process all complete newline-terminated lines
    (while (string-match "\n" transmit--process-buf)
      (let* ((pos  (match-beginning 0))
             (line (substring transmit--process-buf 0 pos)))
        (setq transmit--process-buf (substring transmit--process-buf (1+ pos)))
        (unless (string= (string-trim line) "")
          (transmit--handle-line (string-trim line)))))))


;;;; ---- Process: sentinel ----------------------------------------------------

(defun transmit--sentinel (_proc event)
  "Handle process lifecycle EVENT."
  (transmit--log 3 (format "Process event: %s" (string-trim event)))
  (setq transmit--connection-ready nil
        transmit--process          nil
        transmit--connecting       nil
        transmit--current-progress (list :file nil :percent nil))
  (transmit--stop-auth-timeout)
  (unless transmit--is-exiting
    (transmit--log 3 "SFTP connection lost, reconnecting..." t)
    (dolist (item transmit--queue)
      (plist-put item :processing nil))
    (transmit--ensure-connection #'transmit--process-next)))


;;;; ---- Connection lifecycle -------------------------------------------------

(defun transmit--ensure-connection (&optional callback)
  "Ensure an SFTP connection is live, then call CALLBACK."
  (cl-block transmit--ensure-connection
    (cond
     ;; Already connected
     ((and transmit--process transmit--connection-ready)
      (when callback (funcall callback))
      (transmit--reset-keepalive))

     ;; Already connecting — store callback
     (transmit--connecting
      (when callback
        (let ((prev transmit--pending-callback))
          (setq transmit--pending-callback
                (if prev
                    (lambda () (funcall prev) (funcall callback))
                  callback)))))

     ;; Start a new connection
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
          (transmit--log 2
            (format "Connecting to %s..."
                    (gethash "host" (gethash "credentials" cfg))) t)
          ;; Use a PTY so the binary flushes its prompts immediately
          (setq transmit--process
                (make-process
                 :name            "transmit"
                 :buffer          nil
                 :command         (list binary)
                 :connection-type 'pty
                 :filter          #'transmit--filter
                 :sentinel        #'transmit--sentinel
                 :noquery         t))))))))


;;;; ---- File exclusion -------------------------------------------------------

(defun transmit--excluded-p (path)
  "Return non-nil if PATH matches any exclusion pattern."
  (cl-some (lambda (pat) (string-match-p pat path))
           transmit--excluded-patterns))


;;;; ---- File watching --------------------------------------------------------

(defun transmit--watch-callback (event)
  "Handle filenotify EVENT."
  (let* ((action (nth 1 event))
         (file   (nth 2 event)))
    (when (and file (not (transmit--excluded-p file)))
      (cond
       ((eq action 'deleted)
        (let ((root (transmit--find-watch-root file)))
          (when root (transmit--enqueue "remove" file root))))
       ((memq action '(created changed))
        (when (and (file-regular-p file) (not (transmit--excluded-p file)))
          (let ((root (transmit--find-watch-root file)))
            (when root (transmit--enqueue "upload" file root)))))))))

(defun transmit--find-watch-root (file)
  "Return the watch root that FILE lives under, or nil."
  (cl-loop for root being the hash-keys of transmit--watchers
           when (string-prefix-p root file)
           return root))

(defun transmit--watch-dir (root)
  "Watch ROOT and all sub-directories.  Returns number of dirs watched."
  (cl-block transmit--watch-dir
    (when (gethash root transmit--watchers)
      (message "Transmit: already watching %s" root)
      (cl-return-from transmit--watch-dir 0))
    (unless (file-directory-p root)
      (transmit--log 4 (format "Not a directory: %s" root) t)
      (cl-return-from transmit--watch-dir 0))
    (let ((subdirs (transmit--list-subdirs root))
          (tbl     (make-hash-table :test 'equal))
          (count   0))
      (puthash root tbl transmit--watchers)
      (dolist (dir subdirs)
        (unless (or (transmit--excluded-p dir) (gethash dir tbl))
          (condition-case err
              (progn
                (puthash dir
                         (file-notify-add-watch dir '(change) #'transmit--watch-callback)
                         tbl)
                (cl-incf count))
            (error (transmit--log 3 (format "Could not watch %s: %s" dir err))))))
      (message "Transmit: watching %d director%s under %s"
               count (if (= count 1) "y" "ies") root)
      count)))

(defun transmit--list-subdirs (root)
  "Return ROOT and all sub-directories, skipping excluded paths."
  (let (result)
    (when (file-directory-p root)
      (push root result)
      (dolist (entry (directory-files-recursively root "" t))
        (when (and (file-directory-p entry) (not (transmit--excluded-p entry)))
          (push entry result))))
    result))

(defun transmit--stop-watching (&optional root)
  "Stop watching ROOT or all roots.  Returns count removed."
  (let ((count 0))
    (if root
        (when-let ((tbl (gethash root transmit--watchers)))
          (maphash (lambda (_dir desc)
                     (condition-case nil (file-notify-rm-watch desc) (error nil))
                     (cl-incf count))
                   tbl)
          (remhash root transmit--watchers))
      (maphash (lambda (_root tbl)
                 (maphash (lambda (_dir desc)
                            (condition-case nil (file-notify-rm-watch desc) (error nil))
                            (cl-incf count))
                          tbl))
               transmit--watchers)
      (clrhash transmit--watchers))
    count))


;;;; ---- High-level file operations ------------------------------------------

(defun transmit--upload (file &optional working-dir)
  "Queue FILE for upload.  Returns queue-item ID or nil."
  (cl-block transmit--upload
    (let* ((f   (or file (buffer-file-name)))
           (cwd (expand-file-name (or working-dir default-directory))))
      (unless f
        (message "Transmit: buffer has no associated file")
        (cl-return-from transmit--upload nil))
      (unless (file-regular-p f)
        (message "Transmit: not a regular file: %s" f)
        (cl-return-from transmit--upload nil))
      (unless (transmit--working-dir-has-selection-p cwd)
        (message "Transmit: no server configured for %s" cwd)
        (cl-return-from transmit--upload nil))
      (transmit--enqueue "upload" (expand-file-name f) cwd))))

(defun transmit--remove (file &optional working-dir)
  "Queue FILE for remote removal.  Returns queue-item ID or nil."
  (cl-block transmit--remove
    (let* ((f   (or file (buffer-file-name)))
           (cwd (expand-file-name (or working-dir default-directory))))
      (unless f
        (message "Transmit: buffer has no associated file")
        (cl-return-from transmit--remove nil))
      (unless (transmit--working-dir-has-selection-p cwd)
        (message "Transmit: no server configured for %s" cwd)
        (cl-return-from transmit--remove nil))
      (transmit--enqueue "remove" (expand-file-name f) cwd))))


;;;; ---- Auto-upload on save --------------------------------------------------

(defun transmit--after-save-hook ()
  "Upload the saved buffer if its directory has a server selected."
  (when (and buffer-file-name
             (transmit--working-dir-has-selection-p
              (expand-file-name default-directory)))
    (transmit--upload buffer-file-name default-directory)))


;;;; ---- Server / remote selection UI ----------------------------------------

(defun transmit--server-names ()
  "Return a sorted list of configured server names."
  (let (names)
    (maphash (lambda (k _v) (push k names)) transmit--server-config)
    (sort names #'string<)))

(defun transmit--remote-names (server-name)
  "Return a sorted list of remote names for SERVER-NAME."
  (let* ((cfg     (gethash server-name transmit--server-config))
         (remotes (and cfg (gethash "remotes" cfg)))
         names)
    (when remotes (maphash (lambda (k _v) (push k names)) remotes))
    (sort names #'string<)))


;;;; ---- Setup ----------------------------------------------------------------

;;;###autoload
(defun transmit-setup (config-location)
  "Initialise Transmit from the JSON config file at CONFIG-LOCATION."
  (interactive "fTransmit config file: ")
  (setq config-location (expand-file-name config-location))
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
                    (hash-table-count transmit--server-config) config-location) t)))
    (error (user-error "Transmit: failed to parse config: %s" err)))
  (add-hook 'kill-emacs-hook #'transmit--on-kill-emacs)
  (let ((cfg (transmit--get-server-config)))
    (when cfg
      (when (gethash "upload_on_bufwrite" cfg) (transmit--install-auto-upload))
      (when (gethash "watch_for_changes"  cfg) (transmit-watch-directory)))))

(defun transmit--on-kill-emacs ()
  "Clean up on Emacs exit."
  (setq transmit--is-exiting t)
  (transmit--stop-watching)
  (when transmit--process
    (condition-case nil
        (process-send-string transmit--process "exit\n")
      (error nil))
    (delete-process transmit--process)
    (setq transmit--process nil))
  (when transmit--keepalive-timer    (cancel-timer transmit--keepalive-timer))
  (when transmit--auth-timeout-timer (cancel-timer transmit--auth-timeout-timer))
  (setq transmit--queue '()))

(defun transmit--install-auto-upload ()
  "Add the auto-upload after-save hook (idempotent)."
  (unless transmit--auto-upload-hook-installed
    (add-hook 'after-save-hook #'transmit--after-save-hook)
    (setq transmit--auto-upload-hook-installed t)
    (transmit--log 2 "Auto-upload on save enabled" t)))


;;;; ---- Interactive commands -------------------------------------------------

;;;###autoload
(defun transmit-select-server ()
  "Interactively pick a server and remote for the current project directory."
  (interactive)
  (let ((servers (transmit--server-names)))
    (unless servers (user-error "Transmit: no servers configured"))
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
                         (format "Remote for %s: " choice) remotes nil t)))
            (transmit--update-selection choice remote cwd)
            (message "Transmit: %s -> %s" choice remote)
            (let ((cfg (gethash choice transmit--server-config)))
              (when (and cfg (gethash "upload_on_bufwrite" cfg))
                (transmit--install-auto-upload))
              (when (and cfg (gethash "watch_for_changes" cfg))
                (transmit-watch-directory)))))))))

;;;###autoload
(defun transmit-upload-file (&optional file)
  "Upload FILE (default: current buffer) to the configured remote."
  (interactive)
  (transmit--upload file))

;;;###autoload
(defun transmit-remove-file (&optional file)
  "Remove FILE (default: current buffer) from the configured remote."
  (interactive)
  (transmit--remove file))

;;;###autoload
(defun transmit-watch-directory (&optional dir)
  "Watch DIR (default: current directory) for changes and auto-upload."
  (interactive)
  (let* ((root (expand-file-name (or dir default-directory)))
         (cfg  (transmit--get-server-config root)))
    (unless cfg (user-error "Transmit: no server configured for %s" root))
    (transmit--watch-dir root)))

;;;###autoload
(defun transmit-stop-watching (&optional dir)
  "Stop watching DIR, or all directories if DIR is nil."
  (interactive)
  (let ((n (transmit--stop-watching (and dir (expand-file-name dir)))))
    (message "Transmit: removed %d watcher%s" n (if (= n 1) "" "s"))))

;;;###autoload
(defun transmit-disconnect ()
  "Close the SFTP connection."
  (interactive)
  (if transmit--process
      (progn
        (process-send-string transmit--process "exit\n")
        (message "Transmit: disconnecting..."))
    (message "Transmit: not connected")))

;;;###autoload
(defun transmit-show-queue ()
  "Display the current upload queue."
  (interactive)
  (if (null transmit--queue)
      (message "Transmit: queue is empty")
    (with-output-to-temp-buffer "*transmit-queue*"
      (princ (format "%-6s %-8s %-12s %s\n" "ID" "STATUS" "TYPE" "FILE"))
      (princ (make-string 72 ?-))
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
    (let ((n (- before (length transmit--queue))))
      (message "Transmit: cleared %d item%s" n (if (= n 1) "" "s")))))

;;;###autoload
(defun transmit-cancel-item (id)
  "Cancel queue item ID (non-active items only)."
  (interactive "nQueue item ID to cancel: ")
  (let ((found (transmit--find-queue-item id)))
    (if (null found)
        (message "Transmit: item %d not found" id)
      (let ((item (car found)))
        (if (plist-get item :processing)
            (message "Transmit: item %d is active, cannot cancel" id)
          (setq transmit--queue
                (cl-remove-if (lambda (i) (= (plist-get i :id) id))
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
        (message "Transmit: uploading %s ... %d%%" (file-name-nondirectory f) pct)
      (message "Transmit: no transfer in progress"))))

;;;###autoload
(defun transmit-status ()
  "Show a one-line connection/queue summary."
  (interactive)
  (message "Transmit: %s -> %s | %s | queue: %d"
           (or (transmit--get-selected-server) "none")
           (or (transmit--get-selected-remote) "none")
           (cond (transmit--connection-ready "connected")
                 (transmit--connecting       "connecting...")
                 (t                          "disconnected"))
           (length transmit--queue)))


;;;; ---- Public API -----------------------------------------------------------

(defun transmit-get-progress ()      transmit--current-progress)
(defun transmit-queue-length ()      (length transmit--queue))
(defun transmit-connection-status () (cons transmit--connection-ready transmit--connecting))
(defun transmit-current-server ()    (transmit--get-selected-server))
(defun transmit-current-remote ()    (transmit--get-selected-remote))

(provide 'transmit)
;;; transmit.el ends here
