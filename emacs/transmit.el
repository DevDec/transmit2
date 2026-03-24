;;; transmit.el --- SFTP file transfer plugin for Emacs -*- lexical-binding: t -*-

;; Author: Port of transmit2 (https://github.com/DevDec/transmit2)
;; Version: 2.0.0
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
;; Quick start in init.el:
;;
;;   (add-to-list 'load-path "~/projects/transmit2.nvim/emacs/")
;;   (require 'transmit)
;;   (setq transmit-binary-path "~/projects/transmit2.nvim/bin/transmit-linux")
;;   (transmit-setup "~/transmit_sftp/config.json")
;;
;; Commands:
;;   M-x transmit-select-server     - Pick server + remote for current project
;;   M-x transmit-upload-file       - Upload current buffer's file
;;   M-x transmit-remove-file       - Remove current buffer's file from remote
;;   M-x transmit-watch-directory   - Watch project root for changes and auto-upload
;;   M-x transmit-stop-watching     - Stop all file watchers
;;   M-x transmit-disconnect        - Close SFTP connection
;;   M-x transmit-show-queue        - Show the upload queue buffer
;;   M-x transmit-show-queue-popup  - Show floating queue popup (also: click modeline)
;;   M-x transmit-clear-queue       - Clear pending queue items
;;   M-x transmit-show-log          - Show the debug log buffer
;;   M-x transmit-status            - Show connection/queue summary

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
  "Path to the JSON file recording per-project server selections."
  :type 'file :group 'transmit)

(defcustom transmit-binary-path nil
  "Explicit path to the transmit binary.
When nil the binary is found automatically."
  :type '(choice (const :tag "Auto-detect" nil) file)
  :group 'transmit)

(defcustom transmit-queue-popup-height 12
  "Height in lines of the queue popup window."
  :type 'integer :group 'transmit)


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
(defvar transmit--modeline-timer nil)
;; Cached active server/remote — updated on selection, shown in all buffers
(defvar transmit--active-server nil)
(defvar transmit--active-remote nil)
;; Debounce table: tracks recently-queued files to prevent double-queueing
(defvar transmit--recent-uploads (make-hash-table :test 'equal))


;;;; ---- Project Root ---------------------------------------------------------

(defun transmit--project-root (&optional dir)
  "Return the project root for DIR (or `default-directory').
Uses projectile if available, falls back to `default-directory'."
  (let ((d (expand-file-name (or dir default-directory))))
    (or
     ;; projectile
     (and (fboundp 'projectile-project-root)
          (let ((root (ignore-errors (projectile-project-root d))))
            (and root (not (string= root "")) (expand-file-name root))))
     ;; built-in project.el
     (and (fboundp 'project-current)
          (let ((proj (ignore-errors (project-current nil d))))
            (and proj (expand-file-name (project-root proj)))))
     ;; git root fallback
     (let ((git (locate-dominating-file d ".git")))
       (and git (expand-file-name git)))
     ;; last resort
     d)))


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

(defun transmit--working-dir-has-selection-p (&optional dir)
  "Return non-nil if the project containing DIR has a server selection."
  (let* ((root  (transmit--project-root dir))
         (data  (transmit--read-data))
         (entry (and data (gethash root data))))
    (and entry (gethash "remote" entry))))

(defun transmit--get-selected-server (&optional dir)
  "Return the server name selected for the project containing DIR, or nil."
  (let* ((root  (transmit--project-root dir))
         (data  (transmit--read-data))
         (entry (and data (gethash root data))))
    (and entry (gethash "server_name" entry))))

(defun transmit--get-selected-remote (&optional dir)
  "Return the remote name selected for the project containing DIR, or nil."
  (let* ((root  (transmit--project-root dir))
         (data  (transmit--read-data))
         (entry (and data (gethash root data))))
    (and entry (gethash "remote" entry))))

(defun transmit--get-server-config (&optional dir)
  "Return the server config hash-table for the server selected in DIR's project."
  (let ((server (transmit--get-selected-server dir)))
    (and server (gethash server transmit--server-config))))

(defun transmit--update-selection (server-name remote &optional dir)
  "Record that the project containing DIR uses SERVER-NAME / REMOTE.
Pass \"none\" to clear."
  (let* ((root (transmit--project-root dir))
         (data (or (transmit--read-data) (make-hash-table :test 'equal))))
    (if (string= server-name "none")
        (progn
          (remhash root data)
          ;; Clear last-used if it was this server
          (when (string= transmit--active-server server-name)
            (setq transmit--active-server nil
                  transmit--active-remote nil))
          ;; Update last-used to another project's server if one exists
          (let ((any (transmit--find-any-selection data)))
            (when any
              (setq transmit--active-server (car any)
                    transmit--active-remote  (cdr any)))))
      (let ((entry (or (gethash root data) (make-hash-table :test 'equal))))
        (puthash "server_name" server-name entry)
        (puthash "remote"      remote      entry)
        (puthash root entry data))
      ;; Always cache the most recently selected server globally
      (setq transmit--active-server server-name
            transmit--active-remote remote))
    (transmit--write-data data)
    (transmit--modeline-refresh)))

(defun transmit--find-any-selection (data)
  "Return (server . remote) for any project in DATA, or nil."
  (let (result)
    (maphash (lambda (k v)
               (unless (or (string-prefix-p "__" k) result)
                 (let ((s (gethash "server_name" v))
                       (r (gethash "remote" v)))
                   (when (and s r) (setq result (cons s r))))))
             data)
    result))


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
    (let ((file (expand-file-name filename)))
      ;; Deduplication: handle existing queue entries for this file
      (let ((existing (cl-find-if (lambda (i)
                                    (string= (plist-get i :filename) file))
                                  transmit--queue)))
        (when existing
          (cond
           ;; Already has an upload queued — skip adding anything new
           ((string= (plist-get existing :type) "upload")
            (transmit--log 1 (format "Skipping duplicate queue entry for %s" file))
            (cl-return-from transmit--enqueue nil))
           ;; Has a remove queued and we're adding an upload — upgrade to upload
           ((and (string= (plist-get existing :type) "remove")
                 (string= type "upload"))
            (transmit--log 1 (format "Upgrading remove→upload for %s" file))
            (plist-put existing :type "upload")
            (cl-return-from transmit--enqueue (plist-get existing :id)))
           ;; Has a remove queued and we're adding another remove — skip
           ((string= type "remove")
            (cl-return-from transmit--enqueue nil)))))
      ;; Not in queue — add it
      (let ((id transmit--next-queue-id))
        (cl-incf transmit--next-queue-id)
        (setq transmit--queue
              (nconc transmit--queue
                     (list (list :id id
                                 :type type
                                 :filename file
                                 :working-dir working-dir
                                 :processing nil))))
        (transmit--log 1 (format "Queued [%d]: %s %s" id type file))
        (transmit--modeline-refresh)
        (transmit--ensure-connection #'transmit--process-next)
        id))))

(defun transmit--queue-head ()
  "Return the first queue item, or nil."
  (car transmit--queue))

(defun transmit--dequeue ()
  "Remove the first queue item."
  (setq transmit--queue (cdr transmit--queue))
  (transmit--modeline-refresh))

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
            (setq transmit--keepalive-timer nil)
            (transmit--modeline-refresh)))))

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
            (setq transmit--auth-timeout-timer nil)
            (transmit--modeline-refresh)))))

(defun transmit--stop-auth-timeout ()
  "Cancel the authentication watchdog timer."
  (when transmit--auth-timeout-timer
    (cancel-timer transmit--auth-timeout-timer)
    (setq transmit--auth-timeout-timer nil)))

(defun transmit--start-modeline-timer ()
  "Start a repeating timer to refresh the modeline during uploads."
  (unless transmit--modeline-timer
    (setq transmit--modeline-timer
          (run-with-timer 0.5 0.5 #'transmit--watchdog))))

(defun transmit--watchdog ()
  "Refresh modeline and unstick queue if process has died."
  (force-mode-line-update t)
  ;; If head item is stuck processing but process is dead, unstick and retry
  (let ((head (transmit--queue-head)))
    (when (and head
               (plist-get head :processing)
               (not (and transmit--process
                         (process-live-p transmit--process))))
      (transmit--log 2 "Watchdog: unsticking stalled queue item")
      (plist-put head :processing nil)
      (setq transmit--connection-ready nil
            transmit--connecting       nil)
      (transmit--ensure-connection #'transmit--process-next))))

(defun transmit--stop-modeline-timer ()
  "Stop the modeline refresh timer."
  (when transmit--modeline-timer
    (cancel-timer transmit--modeline-timer)
    (setq transmit--modeline-timer nil)))


;;;; ---- Modeline -------------------------------------------------------------

(defvar transmit--modeline-segment-form '(:eval (transmit--modeline-segment))
  "Form evaluated by doom-modeline/mode-line to render the transmit segment.")

(defun transmit--modeline-segment ()
  "Compute and return the transmit modeline string live."
  (let* ((progress  (transmit-get-progress))
         (file      (plist-get progress :file))
         (pct       (or (plist-get progress :percent) 0))
         (queue-len (length transmit--queue))
         (map       (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'transmit-show-queue-popup)
    (define-key map [mode-line mouse-3] #'transmit-show-queue-popup)
    (propertize
     (concat
      " ⇪ "
      (if transmit--active-server
          (propertize
           (format "%s→%s" transmit--active-server transmit--active-remote)
           'face (if transmit--connection-ready
                     '(:foreground "#88c0d0" :weight bold)
                   '(:foreground "#616e88")))
        (propertize "no server" 'face '(:foreground "#4c566a")))
      (when file
        (concat
         " "
         (propertize (transmit--modeline-progress-bar pct 10)
                     'face '(:foreground "#a3be8c"))
         (propertize (format " %d%%" pct)
                     'face '(:foreground "#a3be8c" :weight bold))))
      (when (and (> queue-len 0) (not file))
        (propertize (format " [%d]" queue-len)
                    'face '(:foreground "#ebcb8b")))
      " ")
     'mouse-face 'mode-line-highlight
     'local-map  map
     'help-echo  (if transmit--active-server
                     (format "SFTP: %s → %s | %d queued\nClick to show queue"
                             transmit--active-server
                             transmit--active-remote
                             queue-len)
                   "SFTP: no server selected\nClick to configure"))))

(defun transmit--modeline-refresh ()
  "Force modeline to redisplay."
  (force-mode-line-update t))

(defun transmit--modeline-progress-bar (pct width)
  "Return a progress bar string of WIDTH chars at PCT percent."
  (let* ((filled (round (* pct (/ width 100.0))))
         (empty  (- width filled)))
    (concat "["
            (make-string filled ?█)
            (make-string empty ?░)
            "]")))

(defvar transmit--modeline-segment-form '(:eval (transmit--modeline-segment))
  "Form evaluated by the mode-line to render the transmit segment.")

(defun transmit--setup-modeline ()
  "Add transmit segment to the modeline (idempotent)."
  (when (fboundp 'doom-modeline-def-segment)
    (eval
     '(doom-modeline-def-segment transmit
        "SFTP status and upload progress."
        (transmit--modeline-segment))))
  ;; Wrap in (t ...) to match doom-modeline's misc-info format
  (let ((entry '(t (:eval (transmit--modeline-segment)))))
    (unless (member entry global-mode-string)
      (add-to-list 'global-mode-string entry t))))


;;;; ---- Queue Popup ----------------------------------------------------------

(defun transmit-show-queue-popup (&optional _event)
  "Show a scrollable popup buffer listing the current upload queue."
  (interactive)
  (let* ((buf  (get-buffer-create "*transmit-queue*"))
         (win  (get-buffer-window buf)))
    ;; If already visible, just focus it
    (if win
        (select-window win)
      (with-current-buffer buf
        (transmit--render-queue-buffer))
      (let ((win (display-buffer
                  buf
                  `(display-buffer-at-bottom
                    . ((window-height . ,transmit-queue-popup-height)
                       (preserve-size . (nil . t)))))))
        (when win
          (select-window win))))
    ;; Set up auto-refresh inside the popup
    (with-current-buffer buf
      (setq-local revert-buffer-function
                  (lambda (_ignore-auto _noconfirm)
                    (transmit--render-queue-buffer)))
      ;; q closes the popup
      (local-set-key (kbd "q")
                     (lambda ()
                       (interactive)
                       (quit-window t)))
      ;; g refreshes
      (local-set-key (kbd "g")
                     (lambda ()
                       (interactive)
                       (transmit--render-queue-buffer))))))

(defun transmit--render-queue-buffer ()
  "Render the queue contents into the current buffer."
  (let ((inhibit-read-only t)
        (pos (point)))
    (erase-buffer)
    (insert (propertize "⇪ Transmit Upload Queue\n" 'face '(:weight bold :height 1.1)))
    (insert (propertize (make-string 50 ?─) 'face '(:foreground "#4c566a")))
    (insert "\n")
    ;; Connection status
    (let ((server (transmit--get-selected-server))
          (remote (transmit--get-selected-remote)))
      (if server
          (insert (format "  Server : %s → %s  [%s]\n"
                          (propertize server 'face '(:foreground "#88c0d0" :weight bold))
                          (propertize (or remote "?") 'face '(:foreground "#88c0d0"))
                          (cond (transmit--connection-ready
                                 (propertize "connected" 'face '(:foreground "#a3be8c")))
                                (transmit--connecting
                                 (propertize "connecting…" 'face '(:foreground "#ebcb8b")))
                                (t (propertize "disconnected" 'face '(:foreground "#bf616a"))))))
        (insert (propertize "  No server selected for this project\n"
                            'face '(:foreground "#616e88")))))
    (insert "\n")
    ;; Current upload progress
    (let* ((progress (transmit-get-progress))
           (file     (plist-get progress :file))
           (pct      (or (plist-get progress :percent) 0)))
      (when file
        (insert (propertize "  Uploading now:\n" 'face '(:foreground "#ebcb8b")))
        (insert (format "  %s\n" (propertize (file-name-nondirectory file)
                                             'face '(:foreground "#eceff4"))))
        (insert (format "  %s %d%%\n\n"
                        (propertize (transmit--modeline-progress-bar pct 30)
                                    'face '(:foreground "#a3be8c"))
                        pct))))
    ;; Queue
    (let ((pending (cl-remove-if (lambda (i) (plist-get i :processing)) transmit--queue)))
      (if (null pending)
          (insert (propertize "  Queue is empty.\n" 'face '(:foreground "#616e88")))
        (insert (propertize (format "  Queued (%d):\n" (length pending))
                            'face '(:foreground "#ebcb8b")))
        (cl-loop for item in pending
                 for i from 1
                 do (insert
                     (format "  %2d. [%s] %s\n"
                             i
                             (propertize (plist-get item :type) 'face '(:foreground "#81a1c1"))
                             (propertize (file-name-nondirectory (plist-get item :filename))
                                         'face '(:foreground "#d8dee9")))))))
    (insert "\n")
    (insert (propertize "  q: close  g: refresh\n" 'face '(:foreground "#4c566a")))
    (goto-char (min pos (point-max)))))

;; Auto-refresh the queue buffer whenever the queue changes
(defun transmit--maybe-refresh-queue-buffer ()
  "If the queue popup is visible, refresh it."
  (when-let ((buf (get-buffer "*transmit-queue*")))
    (when (get-buffer-window buf)
      (with-current-buffer buf
        (transmit--render-queue-buffer)))))


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
               (root     (transmit--project-root cwd))
               (entry    (and data (gethash root data)))
               (rname    (and entry (gethash "remote" entry)))
               (remotes  (and cfg (gethash "remotes" cfg)))
               (rbase    (and remotes rname (gethash rname remotes))))
          (unless (and cfg rbase)
            (transmit--log 4 (format "No remote configured for %s" cwd) t)
            (transmit--dequeue)
            (cl-return-from transmit--process-next nil))
          (let* ((relative    (file-relative-name filename root))
                 (remote-path (concat rbase "/" relative))
                 (cmd (cl-case (intern (plist-get item :type))
                        (upload (format "upload %s %s\n" filename remote-path))
                        (remove (format "remove %s\n"    remote-path)))))
            (when cmd
              (plist-put item :processing t)
              (transmit--start-modeline-timer)
              (transmit--log 1 (format "Sending: %s" (string-trim cmd)))
              (process-send-string transmit--process cmd))))))))


;;;; ---- Process: output filter -----------------------------------------------

(defun transmit--send (proc text)
  "Send TEXT to PROC and log it at DEBUG level."
  (transmit--log 1 (format "> %s" (string-trim text)))
  (process-send-string proc text))

(defun transmit--check-prompt (proc cfg)
  "Check the incomplete accumulation buffer for handshake prompts and respond."
  (let ((buf transmit--process-buf)
        (creds (and cfg (gethash "credentials" cfg))))
    (cond
     ((and (string= transmit--phase transmit--phase-init)
           (string-match-p "Enter SSH hostname" buf))
      (transmit--send proc (concat (gethash "host" creds) "\n"))
      (setq transmit--phase transmit--phase-username)
      (setq transmit--process-buf ""))

     ((and (string= transmit--phase transmit--phase-username)
           (string-match-p "Enter SSH username" buf))
      (transmit--send proc (concat (gethash "username" creds) "\n"))
      (setq transmit--phase transmit--phase-auth-method)
      (setq transmit--process-buf ""))

     ((and (string= transmit--phase transmit--phase-auth-method)
           (string-match-p "Authentication method" buf))
      (let ((auth-type (or (gethash "auth_type" creds) "key")))
        (transmit--send proc (concat auth-type "\n"))
        (setq transmit--phase
              (if (string= auth-type "password")
                  transmit--phase-password
                transmit--phase-key))
        (setq transmit--process-buf "")))

     ((and (string= transmit--phase transmit--phase-password)
           (string-match-p "Enter password" buf))
      (transmit--send proc (concat (gethash "password" creds) "\n"))
      (setq transmit--phase transmit--phase-ready)
      (setq transmit--process-buf ""))

     ((and (string= transmit--phase transmit--phase-key)
           (string-match-p "Enter path to private key" buf))
      (transmit--send proc (concat (expand-file-name (gethash "identity_file" creds)) "\n"))
      (setq transmit--phase transmit--phase-ready)
      (setq transmit--process-buf "")))))

(defun transmit--handle-line (line)
  "Handle a complete newline-terminated LINE from the binary."
  (transmit--log 1 (format "< %s" line))
  (cond
   ((and (string= transmit--phase transmit--phase-ready)
         (string-match-p "Connected to" line))
    (setq transmit--phase           transmit--phase-active
          transmit--connecting      nil
          transmit--connection-ready t)
    (transmit--stop-auth-timeout)
    (transmit--log 2 "SFTP connection established" t)
    (transmit--modeline-refresh)
    (when transmit--pending-callback
      (let ((cb transmit--pending-callback))
        (setq transmit--pending-callback nil)
        (funcall cb))))

   ((and (string= transmit--phase transmit--phase-active)
         (string-match "^PROGRESS|\\(.*\\)|\\([0-9]+\\)$" line))
    (let ((file (match-string 1 line))
          (pct  (string-to-number (match-string 2 line))))
      (when (and file (>= pct 0) (<= pct 100))
        (setq transmit--current-progress (list :file file :percent pct))
        (transmit--modeline-refresh)
        (transmit--maybe-refresh-queue-buffer))))

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
        (transmit--maybe-refresh-queue-buffer)
        ;; Always try to process next regardless of queue length check
        (if transmit--queue
            (run-at-time 0.05 nil #'transmit--process-next)
          (transmit--stop-modeline-timer)
          (transmit--modeline-refresh)
          (message "Transmit: All transfers complete")))))))

(defun transmit--filter (proc string)
  "Accumulate output STRING from PROC and drive the state machine."
  (setq transmit--process-buf (concat transmit--process-buf string))
  (let ((cfg (transmit--get-server-config)))
    (unless (string= transmit--phase transmit--phase-active)
      (transmit--check-prompt proc cfg))
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
  (transmit--stop-modeline-timer)
  (transmit--modeline-refresh)
  (unless transmit--is-exiting
    (transmit--log 3 "SFTP connection lost, reconnecting..." t)
    ;; Unmark all processing items so they get retried on reconnect
    (dolist (item transmit--queue)
      (plist-put item :processing nil))
    (transmit--ensure-connection #'transmit--process-next)))


;;;; ---- Connection lifecycle -------------------------------------------------

(defun transmit--ensure-connection (&optional callback)
  "Ensure an SFTP connection is live, then call CALLBACK."
  (cl-block transmit--ensure-connection
    (cond
     ((and transmit--process transmit--connection-ready)
      (when callback (funcall callback))
      (transmit--reset-keepalive))

     (transmit--connecting
      (when callback
        (let ((prev transmit--pending-callback))
          (setq transmit--pending-callback
                (if prev
                    (lambda () (funcall prev) (funcall callback))
                  callback)))))

     (t
      (let ((cfg (transmit--get-server-config)))
        (unless cfg
          (transmit--log 4 "No SFTP server configured for current project" t)
          (cl-return-from transmit--ensure-connection nil))
        (let ((binary (transmit--binary-path)))
          (unless binary
            (cl-return-from transmit--ensure-connection nil))
          (setq transmit--connecting       t
                transmit--phase            transmit--phase-init
                transmit--process-buf      ""
                transmit--pending-callback callback)
          (transmit--start-auth-timeout)
          (transmit--modeline-refresh)
          (transmit--log 2
            (format "Connecting to %s..."
                    (gethash "host" (gethash "credentials" cfg))) t)
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
  "Handle filenotify EVENT.
Also starts watching newly-created directories automatically."
  (let* ((action (nth 1 event))
         (file   (nth 2 event)))
    (when (and file (not (transmit--excluded-p file)))
      (cond
       ;; Newly created: if it's a directory, start watching it too
       ((eq action 'created)
        (if (file-directory-p file)
            ;; New directory — add watchers for it and its children
            (let ((root (transmit--find-watch-root file)))
              (when root
                (let* ((tbl   (gethash root transmit--watchers))
                       (subdirs (transmit--list-subdirs file)))
                  (dolist (dir subdirs)
                    (unless (or (transmit--excluded-p dir) (gethash dir tbl))
                      (condition-case err
                          (puthash dir
                                   (file-notify-add-watch
                                    dir '(change) #'transmit--watch-callback)
                                   tbl)
                        (error (transmit--log 3 (format "Could not watch %s: %s"
                                                        dir err)))))))))
          ;; New regular file — upload it
          (when (file-regular-p file)
            (let ((root (transmit--find-watch-root file)))
              (when root (transmit--enqueue "upload" file root))))))

       ((eq action 'deleted)
        ;; Skip remove if file was recently saved — magit discard deletes then
        ;; rewrites the file, the subsequent 'created' event handles the upload
        (unless (transmit--recently-uploaded-p file)
          (let ((root (transmit--find-watch-root file)))
            (when root (transmit--enqueue "remove" file root)))))

       ((eq action 'changed)
        (when (and (file-regular-p file)
                   (not (transmit--excluded-p file))
                   (not (transmit--recently-uploaded-p file)))
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
    (let* ((f    (or file (buffer-file-name)))
           (root (transmit--project-root (or working-dir default-directory))))
      (unless f
        (message "Transmit: buffer has no associated file")
        (cl-return-from transmit--upload nil))
      (unless (file-regular-p f)
        (message "Transmit: not a regular file: %s" f)
        (cl-return-from transmit--upload nil))
      (unless (transmit--working-dir-has-selection-p root)
        (message "Transmit: no server configured for project %s" root)
        (cl-return-from transmit--upload nil))
      (transmit--enqueue "upload" (expand-file-name f) root))))

(defun transmit--remove (file &optional working-dir)
  "Queue FILE for remote removal.  Returns queue-item ID or nil."
  (cl-block transmit--remove
    (let* ((f    (or file (buffer-file-name)))
           (root (transmit--project-root (or working-dir default-directory))))
      (unless f
        (message "Transmit: buffer has no associated file")
        (cl-return-from transmit--remove nil))
      (unless (transmit--working-dir-has-selection-p root)
        (message "Transmit: no server configured for project %s" root)
        (cl-return-from transmit--remove nil))
      (transmit--enqueue "remove" (expand-file-name f) root))))


;;;; ---- Auto-upload on save --------------------------------------------------

(defvar-local transmit--save-in-progress nil
  "Buffer-local flag to prevent re-entrant after-save-hook calls.")

(defun transmit--debounce-file (file)
  "Mark FILE as recently uploaded for 2 seconds to suppress watcher dupes."
  (puthash file t transmit--recent-uploads)
  (run-at-time 2.0 nil (lambda () (remhash file transmit--recent-uploads))))

(defun transmit--recently-uploaded-p (file)
  "Return non-nil if FILE was uploaded in the last 2 seconds."
  (gethash file transmit--recent-uploads))

(defun transmit--after-save-hook ()
  "Upload the saved buffer if its project has a server selected."
  (when (and buffer-file-name
             (not transmit--save-in-progress)
             (transmit--working-dir-has-selection-p
              (transmit--project-root default-directory)))
    (setq transmit--save-in-progress t)
    (unwind-protect
        (let ((file (expand-file-name buffer-file-name))
              (root (transmit--project-root default-directory)))
          (unless (cl-some (lambda (item)
                             (string= (plist-get item :filename) file))
                           transmit--queue)
            (transmit--debounce-file file)
            (transmit--enqueue "upload" file root)))
      (setq transmit--save-in-progress nil))))


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
  (transmit--setup-modeline)
  ;; Install auto-upload hook globally
  (transmit--install-auto-upload)
  ;; When a file is opened, update modeline and start watching if project has a server
  (add-hook 'find-file-hook #'transmit--maybe-watch-project)
  ;; Start with clean state — modeline shows "no server" until a project is opened
  (setq transmit--active-server nil
        transmit--active-remote nil)
  (transmit--modeline-refresh))

(defun transmit--maybe-watch-project ()
  "When a file is opened, update the active server for the modeline
and start watching the project if it has a server selected."
  (when buffer-file-name
    (let* ((root   (transmit--project-root default-directory))
           (server (transmit--get-selected-server root))
           (remote (transmit--get-selected-remote root)))
      (when server
        ;; Update modeline to show this project's server
        (setq transmit--active-server server
              transmit--active-remote remote)
        (transmit--modeline-refresh)
        ;; Start watching if not already watched
        (unless (gethash root transmit--watchers)
          (transmit--log 2 (format "Starting watch for project: %s" root))
          (transmit--watch-dir root))))))

(defun transmit--on-kill-emacs ()
  "Clean up on Emacs exit."
  (setq transmit--is-exiting t)
  (transmit--stop-watching)
  (transmit--stop-modeline-timer)
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


;;;; ---- Magit integration ----------------------------------------------------

(defun transmit--magit-post-refresh ()
  "After a magit refresh, unstick any stalled queue items and retry."
  (when transmit--queue
    ;; If the head item is marked processing but the process is dead,
    ;; it's stuck — unmark it so it gets retried
    (let ((head (transmit--queue-head)))
      (when (and head
                 (plist-get head :processing)
                 (not (and transmit--process
                           (process-live-p transmit--process))))
        (transmit--log 2 "Unsticking stalled queue item after magit refresh")
        (plist-put head :processing nil)))
    ;; Re-attempt processing
    (transmit--ensure-connection #'transmit--process-next)))

(with-eval-after-load 'magit
  (add-hook 'magit-post-refresh-hook #'transmit--magit-post-refresh))

;;;###autoload
(defun transmit-select-server ()
  "Interactively pick a server and remote for the current project.
The selection is remembered per project root and persisted to disk."
  (interactive)
  (let ((servers (transmit--server-names))
        (root    (transmit--project-root)))
    (unless servers (user-error "Transmit: no servers configured"))
    (let* ((current-server (transmit--get-selected-server))
           (current-remote (transmit--get-selected-remote))
           (choice (completing-read
                    (format "Transmit server for %s [current: %s]: "
                            (abbreviate-file-name root)
                            (if current-server
                                (format "%s→%s" current-server current-remote)
                              "none"))
                    (cons "none" servers) nil t)))
      (if (string= choice "none")
          (progn
            (transmit--update-selection "none" nil)
            (message "Transmit: cleared server selection for %s"
                     (abbreviate-file-name root)))
        (let ((remotes (transmit--remote-names choice)))
          (unless remotes
            (user-error "Transmit: no remotes defined for server '%s'" choice))
          (let ((remote (completing-read
                         (format "Remote for %s: " choice) remotes nil t)))
            (transmit--update-selection choice remote)
            (message "Transmit: project %s → %s / %s"
                     (abbreviate-file-name root) choice remote)
            ;; Install auto-upload hook for this project
            (transmit--install-auto-upload)
            (let ((cfg (gethash choice transmit--server-config)))
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
  "Watch the project root (or DIR) for changes and auto-upload.
Newly created files and directories are automatically watched."
  (interactive)
  (let* ((root (transmit--project-root dir))
         (cfg  (transmit--get-server-config root)))
    (unless cfg (user-error "Transmit: no server configured for project %s" root))
    (transmit--watch-dir root)))

;;;###autoload
(defun transmit-stop-watching (&optional dir)
  "Stop watching DIR's project, or all directories if DIR is nil."
  (interactive)
  (let* ((root (and dir (transmit--project-root dir)))
         (n    (transmit--stop-watching root)))
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
  "Display the upload queue in a dedicated buffer."
  (interactive)
  (transmit-show-queue-popup))

;;;###autoload
(defun transmit-clear-queue ()
  "Remove all pending (non-active) items from the queue."
  (interactive)
  (let ((before (length transmit--queue)))
    (setq transmit--queue
          (cl-remove-if-not (lambda (i) (plist-get i :processing))
                            transmit--queue))
    (let ((n (- before (length transmit--queue))))
      (transmit--modeline-refresh)
      (transmit--maybe-refresh-queue-buffer)
      (message "Transmit: cleared %d item%s" n (if (= n 1) "" "s")))))

;;;###autoload
(defun transmit-upload-modified ()
  "Upload all git-modified files in the current project.
Fetches the list of modified/added/untracked files via git and queues
them all for upload."
  (interactive)
  (let* ((root (transmit--project-root))
         (cfg  (transmit--get-server-config root)))
    (unless cfg
      (user-error "Transmit: no server configured for project %s" root))
    (let* ((output (shell-command-to-string
                    (format "git -C %s status --porcelain"
                            (shell-quote-argument root))))
           (lines  (split-string output "\n" t))
           (files  (cl-loop for line in lines
                            ;; git status --porcelain format: XY filename
                            ;; Handle renames: "R old -> new"
                            for parts = (split-string (string-trim line))
                            for status = (car parts)
                            for file = (car (last parts))
                            collect (cons status (expand-file-name file root)))))
      (if (null files)
          (message "Transmit: no modified files found in %s"
                   (abbreviate-file-name root))
        (let ((count 0))
          (dolist (pair files)
            (let ((status (car pair))
                  (file   (cdr pair)))
              (cond
               ;; Deleted — queue a remove on the remote
               ((string-match-p "^D" status)
                (transmit--enqueue "remove" file root)
                (cl-incf count))
               ;; Modified/added/renamed — queue an upload
               ((file-regular-p file)
                (transmit--debounce-file file)
                (transmit--enqueue "upload" file root)
                (cl-incf count)))))
          (message "Transmit: queued %d file%s (%d deleted)"
                   count
                   (if (= count 1) "" "s")
                   (cl-count-if (lambda (p) (string-match-p "^D" (car p)))
                                files)))))))

;;;###autoload
(defun transmit-retry ()
  "Unstick and reprocess the queue without clearing it.
Use this when uploads have stalled but you want to keep queued files."
  (interactive)
  ;; Unmark all processing items so they get retried
  (dolist (item transmit--queue)
    (plist-put item :processing nil))
  ;; Kill stale process if dead
  (when (and transmit--process
             (not (process-live-p transmit--process)))
    (delete-process transmit--process)
    (setq transmit--process nil))
  ;; Reset connection flags so ensure-connection starts fresh
  (setq transmit--connecting       nil
        transmit--connection-ready nil
        transmit--process-buf      "")
  (transmit--stop-auth-timeout)
  (transmit--modeline-refresh)
  (if transmit--queue
      (progn
        (transmit--ensure-connection #'transmit--process-next)
        (message "Transmit: retrying %d queued item%s"
                 (length transmit--queue)
                 (if (= (length transmit--queue) 1) "" "s")))
    (message "Transmit: queue is empty")))

;;;###autoload
(defun transmit-reset ()
  "Fully reset transmit state — clears queue, kills process, resets all flags.
Use this when the queue is stuck or the process is in a bad state."
  (interactive)
  ;; Kill the process hard
  (when transmit--process
    (condition-case nil (delete-process transmit--process) (error nil))
    (setq transmit--process nil))
  ;; Cancel all timers
  (transmit--stop-modeline-timer)
  (transmit--stop-auth-timeout)
  (when transmit--keepalive-timer
    (cancel-timer transmit--keepalive-timer)
    (setq transmit--keepalive-timer nil))
  ;; Reset all state
  (setq transmit--queue              '()
        transmit--phase              transmit--phase-init
        transmit--connecting         nil
        transmit--connection-ready   nil
        transmit--pending-callback   nil
        transmit--process-buf        ""
        transmit--current-progress   (list :file nil :percent nil))
  (transmit--modeline-refresh)
  (transmit--maybe-refresh-queue-buffer)
  (message "Transmit: reset complete — queue cleared, connection closed"))

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
          (transmit--modeline-refresh)
          (transmit--maybe-refresh-queue-buffer)
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
  (message "Transmit: project=%s  server=%s → %s  status=%s  queue=%d"
           (abbreviate-file-name (transmit--project-root))
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
