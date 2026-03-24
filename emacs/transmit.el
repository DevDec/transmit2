;;; init.el --- Emacs configuration for Neovim users
;;; A full-featured IDE config with Evil, LSP, Treesitter, Magit, and more.

;;; ============================================================
;;; SECTION 1: BOOTSTRAP — straight.el + use-package
;;; ============================================================

;; Silence native-comp warnings
(setq native-comp-async-report-warnings-errors nil)
(setq byte-compile-warnings '(not obsolete))

;; Don't recurse into submodules when cloning — some repos have broken submodule refs
(setq straight-vc-git-default-clone-depth 1)
(setq straight-vc-git-submodule-recurse nil)

;; Bootstrap straight.el (replaces package.el with reproducible installs)
(defvar bootstrap-version)
(let ((bootstrap-file
       (expand-file-name
        "straight/repos/straight.el/bootstrap.el"
        (or (bound-and-true-p straight-base-dir)
            user-emacs-directory)))
      (bootstrap-version 7))
  (unless (file-exists-p bootstrap-file)
    (with-current-buffer
        (url-retrieve-synchronously
         "https://raw.githubusercontent.com/radian-software/straight.el/develop/install.el"
         'silent 'inhibit-cookies)
      (goto-char (point-max))
      (eval-print-last-sexp)))
  (load bootstrap-file nil 'nomessage))

;; Install use-package via straight and make it the default
(straight-use-package 'use-package)
(setq straight-use-package-by-default t)
(setq use-package-always-demand t) ; eager load unless :defer t is specified


;;; ============================================================
;;; SECTION 2: CORE EMACS SETTINGS
;;; ============================================================

(use-package emacs
  :straight nil
  :config
  ;; Disable file locking — avoids lock file prompts in single-user setups
  (setq create-lockfiles nil)

  ;; Clean UI
  (menu-bar-mode -1)
  (tool-bar-mode -1)
  (scroll-bar-mode -1)
  (setq inhibit-startup-screen t)
  (setq initial-scratch-message nil)

  ;; Sane defaults
  (setq-default
   tab-width 4
   indent-tabs-mode t          ; use tabs, not spaces
   fill-column 100)

  ;; Relative line numbers (like Neovim)
  (global-display-line-numbers-mode t)
  (setq display-line-numbers-type 'relative)

  ;; Syntax highlighting everywhere
  (global-font-lock-mode t)

  ;; Highlight current line
  (global-hl-line-mode t)

  ;; Show matching parens
  (show-paren-mode t)
  (setq show-paren-delay 0)

  ;; Smoother scrolling
  (setq scroll-margin 8
        scroll-conservatively 101
        scroll-preserve-screen-position t)

  ;; Keep backup/auto-save files out of the way
  (setq backup-directory-alist `(("." . ,(expand-file-name "backups" user-emacs-directory)))
        auto-save-file-name-transforms `((".*" ,(expand-file-name "auto-saves/" user-emacs-directory) t)))
  (make-directory (expand-file-name "auto-saves" user-emacs-directory) t)

  ;; UTF-8 everywhere
  (set-language-environment "UTF-8")
  (prefer-coding-system 'utf-8)

  ;; Font — change "JetBrains Mono" to any font you have installed
  (set-face-attribute 'default nil :family "JetBrains Mono" :height 140)
  (set-face-attribute 'fixed-pitch nil :family "JetBrains Mono" :height 140))


;;; ============================================================
;;; SECTION 3: THEME
;;; ============================================================

(use-package doom-themes
  :config
  (load-theme 'doom-nord t))


;;; ============================================================
;;; SECTION 4: EVIL MODE (Vim keybindings)
;;; ============================================================

(use-package evil
  :init
  ;; Required before evil loads
  (setq evil-want-integration t)
  (setq evil-want-keybinding nil)  ; evil-collection handles this
  (setq evil-want-C-u-scroll t)    ; C-u scrolls up like Vim
  (setq evil-want-C-i-jump t)
  (setq evil-undo-system 'undo-redo) ; Use Emacs 28+ undo-redo
  (setq evil-respect-visual-line-mode t)
  :config
  (evil-mode 1)
  ;; Make C-g act like <Escape>
  (define-key evil-insert-state-map (kbd "C-g") 'evil-normal-state)
  ;; Keep visual selection after indenting
  (define-key evil-visual-state-map (kbd ">") (kbd ">gv"))
  (define-key evil-visual-state-map (kbd "<") (kbd "<gv")))

;; Evil bindings for many built-in and popular modes
(use-package evil-collection
  :after evil
  :config
  (evil-collection-init))

;; Surround operator: ys, cs, ds like vim-surround
(use-package evil-surround
  :after evil
  :config
  (global-evil-surround-mode 1))

;; Commentary: gc operator like vim-commentary
(use-package evil-commentary
  :after evil
  :config
  (evil-commentary-mode))

;; Text objects: ii, ai, iI etc.
(use-package evil-indent-plus
  :after evil
  :config
  (evil-indent-plus-default-bindings))


;;; ============================================================
;;; SECTION 5: GENERAL.EL — Leader key & keybindings
;;; ============================================================

(use-package general
  :config
  (general-evil-setup t)

  ;; SPC as leader (like Neovim/LazyVim/Doom)
  (general-create-definer leader-key
    :states '(normal visual emacs)
    :keymaps 'override
    :prefix "SPC")

  ;; Local leader: SPC m (for mode-specific bindings)
  (general-create-definer local-leader-key
    :states '(normal visual emacs)
    :keymaps 'override
    :prefix "SPC m")

  (leader-key
    ;; Top-level
    "SPC" '(execute-extended-command :wk "M-x")
    ";"   '(eval-expression :wk "Eval expression")
    "u"   '(universal-argument :wk "Universal arg")
    "q"   '(:ignore t :wk "quit")
    "qq"  '(save-buffers-kill-terminal :wk "Quit Emacs")
    "qr"  '(restart-emacs :wk "Restart Emacs")

    ;; Buffers
    "b"   '(:ignore t :wk "buffer")
    "bb"  '(consult-buffer :wk "Switch buffer")
    "bd"  '(kill-current-buffer :wk "Delete buffer")
    "bn"  '(next-buffer :wk "Next buffer")
    "bp"  '(previous-buffer :wk "Prev buffer")
    "bs"  '(save-buffer :wk "Save buffer")
    "bS"  '(save-some-buffers :wk "Save all buffers")

    ;; Files
    "f"   '(:ignore t :wk "file")
    "ff"  '(find-file :wk "Find file")
    "fr"  '(consult-recent-file :wk "Recent files")
    "fs"  '(save-buffer :wk "Save file")

    ;; Windows
    "w"   '(:ignore t :wk "window")
    "ww"  '(other-window :wk "Other window")
    "wd"  '(delete-window :wk "Delete window")
    "wo"  '(delete-other-windows :wk "Delete other windows")
    "ws"  '(split-window-below :wk "Split horizontal")
    "wv"  '(split-window-right :wk "Split vertical")
    "wh"  '(windmove-left :wk "Focus left")
    "wl"  '(windmove-right :wk "Focus right")
    "wk"  '(windmove-up :wk "Focus up")
    "wj"  '(windmove-down :wk "Focus down")

    ;; Project (Projectile)
    "p"   '(:ignore t :wk "project")
    "pp"  '(projectile-switch-project :wk "Switch project")
    "pf"  '(projectile-find-file :wk "Find file in project")
    "pr"  '(projectile-recentf :wk "Recent project files")
    "pk"  '(projectile-kill-buffers :wk "Kill project buffers")
    "pa"  '(projectile-add-known-project :wk "Add project")

    ;; Search
    "s"   '(:ignore t :wk "search")
    "ss"  '(consult-line :wk "Search in buffer")
    "sS"  '(consult-line-multi :wk "Search all buffers")
    "sp"  '(consult-ripgrep :wk "Ripgrep in project")
    "sP"  '(projectile-ripgrep :wk "Ripgrep (projectile)")
    "sf"  '(consult-find :wk "Find file by name")
    "si"  '(consult-imenu :wk "Imenu (symbols)")
    "sI"  '(consult-imenu-multi :wk "Imenu all buffers")
    "sd"  '(deadgrep :wk "Deadgrep (interactive rg)")

    ;; Find & Replace across project
    "r"   '(:ignore t :wk "replace")
    "rr"  '(anzu-query-replace :wk "Replace in buffer")
    "rR"  '(anzu-query-replace-regexp :wk "Regexp replace in buffer")
    "rp"  '(projectile-replace :wk "Replace in project")
    "rP"  '(projectile-replace-regexp :wk "Regexp replace in project")

    ;; LSP
    "l"   '(:ignore t :wk "lsp")
    "la"  '(lsp-execute-code-action :wk "Code action")
    "ld"  '(lsp-find-definition :wk "Find definition")
    "lD"  '(lsp-find-references :wk "Find references")
    "li"  '(lsp-find-implementation :wk "Find implementation")
    "lt"  '(lsp-find-type-definition :wk "Find type")
    "lh"  '(lsp-ui-doc-glance :wk "Hover docs")
    "lr"  '(lsp-rename :wk "Rename symbol")
    "ls"  '(consult-lsp-symbols :wk "Workspace symbols")
    "lf"  '(lsp-format-buffer :wk "Format buffer")
    "lF"  '(lsp-format-region :wk "Format region")
    "lx"  '(lsp-workspace-restart :wk "Restart LSP")
    "lX"  '(lsp-workspace-shutdown :wk "Shutdown LSP")
    "le"  '(lsp-ui-flycheck-list :wk "Errors list")
    "lj"  '(lsp-ui-peek-find-definitions :wk "Peek definition")
    "lk"  '(lsp-ui-peek-find-references :wk "Peek references")

    ;; Diagnostics
    "e"   '(:ignore t :wk "errors")
    "en"  '(flymake-goto-next-error :wk "Next error")
    "ep"  '(flymake-goto-prev-error :wk "Prev error")
    "el"  '(consult-flymake :wk "List errors")

    ;; Git (Magit)
    "g"   '(:ignore t :wk "git")
    "gg"  '(magit-status :wk "Magit status")
    "gb"  '(magit-blame :wk "Blame")
    "gl"  '(magit-log-current :wk "Log")
    "gL"  '(magit-log-all :wk "Log all")
    "gc"  '(magit-commit :wk "Commit")
    "gC"  '(magit-clone :wk "Clone")
    "gd"  '(magit-diff :wk "Diff")
    "gD"  '(magit-diff-buffer-file :wk "Diff file")
    "gf"  '(magit-fetch :wk "Fetch")
    "gF"  '(magit-pull :wk "Pull")
    "gp"  '(magit-push :wk "Push")
    "gs"  '(magit-stage-file :wk "Stage file")
    "gS"  '(magit-stage-modified :wk "Stage all modified")
    "gt"  '(git-timemachine :wk "Git timemachine")
    "ghr" '(diff-hl-revert-hunk :wk "Revert hunk")
    "ghn" '(diff-hl-next-hunk :wk "Next hunk")
    "ghp" '(diff-hl-previous-hunk :wk "Prev hunk")
    "ghd" '(diff-hl-diff-goto-hunk :wk "Diff hunk")

    ;; Multicursor
    "c"   '(:ignore t :wk "cursor")
    "cn"  '(evil-mc-make-and-goto-next-match :wk "Add cursor next match")
    "cp"  '(evil-mc-make-and-goto-prev-match :wk "Add cursor prev match")
    "ca"  '(evil-mc-make-all-cursors :wk "Add cursors all matches")
    "cq"  '(evil-mc-undo-all-cursors :wk "Remove all cursors")
    "cs"  '(evil-mc-skip-and-goto-next-match :wk "Skip & next match")

    ;; Jump (avy)
    "j"   '(:ignore t :wk "jump")
    "jj"  '(avy-goto-char-timer :wk "Jump to char")
    "jl"  '(avy-goto-line :wk "Jump to line")
    "jw"  '(avy-goto-word-0 :wk "Jump to word")
    "js"  '(avy-goto-symbol-1 :wk "Jump to symbol")

    ;; Open (terminals, popups etc.)
    "o"   '(:ignore t :wk "open")
    "ot"  '(vterm-toggle :wk "Toggle terminal")
    "oT"  '(vterm :wk "New terminal")
    "op"  '(popper-toggle :wk "Toggle popup")
    "oP"  '(popper-cycle :wk "Cycle popups")
    "of"  '(treemacs :wk "File tree")

    ;; Workspaces (perspective)
    "TAB"   '(:ignore t :wk "workspace")
    "TAB TAB" '(persp-switch :wk "Switch/create workspace")
    "TAB n"   '(persp-next :wk "Next workspace")
    "TAB p"   '(persp-prev :wk "Prev workspace")
    "TAB d"   '(persp-kill :wk "Delete workspace")
    "TAB r"   '(persp-rename :wk "Rename workspace")
    "TAB N"   '(my/new-workspace :wk "New named workspace")
    "TAB 1"   '((lambda () (interactive) (persp-switch-by-number 1)) :wk "Workspace 1")
    "TAB 2"   '((lambda () (interactive) (persp-switch-by-number 2)) :wk "Workspace 2")
    "TAB 3"   '((lambda () (interactive) (persp-switch-by-number 3)) :wk "Workspace 3")
    "TAB 4"   '((lambda () (interactive) (persp-switch-by-number 4)) :wk "Workspace 4")
    "TAB 5"   '((lambda () (interactive) (persp-switch-by-number 5)) :wk "Workspace 5")

    ;; Transmit SFTP
    "T"   '(:ignore t :wk "transmit/sftp")
    "Ts"  '(transmit-select-server :wk "Select server")
    "Tu"  '(transmit-upload-file :wk "Upload file")
    "Td"  '(transmit-remove-file :wk "Remove remote file")
    "Tw"  '(transmit-watch-directory :wk "Watch project")
    "TW"  '(transmit-stop-watching :wk "Stop watching")
    "Tq"  '(transmit-show-queue-popup :wk "Show queue")
    "Tc"  '(transmit-clear-queue :wk "Clear queue")
    "Tl"  '(transmit-show-log :wk "Show log")
    "Tx"  '(transmit-disconnect :wk "Disconnect")
    "T?"  '(transmit-status :wk "Status")
    "tl"  '(display-line-numbers-mode :wk "Line numbers")
    "tw"  '(whitespace-mode :wk "Whitespace")
    "ts"  '(flyspell-mode :wk "Spell check")
    "ti"  '(lsp-ui-imenu :wk "LSP imenu sidebar")
    "tf"  '(treemacs :wk "File tree")
    "tz"  '(olivetti-mode :wk "Zen / focus mode")
    "tS"  '(string-inflection-all-cycle :wk "Cycle case (camel/snake/etc)")))


;;; ============================================================
;;; SECTION 6: WHICH-KEY — keybinding discovery
;;; ============================================================

(use-package which-key
  :config
  (which-key-mode)
  (setq which-key-idle-delay 0.3
        which-key-min-display-lines 5))


;;; ============================================================
;;; SECTION 7: COMPLETION — Vertico + Orderless + Marginalia + Consult
;;; ============================================================

;; Vertical completion UI (like fzf popup)
(use-package vertico
  :config
  (vertico-mode)
  (setq vertico-count 15
        vertico-cycle t))

;; Fuzzy/flex matching
(use-package orderless
  :config
  (setq completion-styles '(orderless basic)
        completion-category-overrides
        '((file (styles basic partial-completion))
          ;; Use basic + initials for LSP so orderless doesn't interfere
          (lsp-capf (styles basic initials)))))

;; Rich annotations in minibuffer
(use-package marginalia
  :config
  (marginalia-mode))

;; Practical completion commands (consult-ripgrep, consult-line, etc.)
(use-package consult
  :defer t
  :bind
  (:map evil-normal-state-map
        ("g/" . consult-line))
  :config
  (setq consult-async-min-input 2))

;; Embark for contextual actions on completions
(use-package embark
  :defer t)

(use-package embark-consult
  :after (embark consult)
  :hook (embark-collect-mode . consult-preview-at-point-mode))

;; LSP symbol search via consult
(use-package consult-lsp
  :after (consult lsp-mode)
  :defer t)

;; Corfu: in-buffer completion popup (like nvim-cmp)
(use-package corfu
  :hook
  (lsp-managed-mode . corfu-mode)  ; enable in any LSP buffer
  :config
  (setq corfu-auto t
        corfu-auto-delay 0.3
        corfu-auto-prefix 2
        corfu-cycle t
        corfu-quit-no-match 'separator
        corfu-on-exact-match nil)
  (global-corfu-mode)
  (define-key corfu-map (kbd "TAB") 'corfu-next)
  (define-key corfu-map (kbd "<backtab>") 'corfu-previous)
  (define-key corfu-map (kbd "RET") 'corfu-insert))

;; Completion-at-point extensions (gives more sources to corfu)
(use-package cape
  :config
  (add-to-list 'completion-at-point-functions #'cape-file)
  (add-to-list 'completion-at-point-functions #'cape-dabbrev)
  (advice-add #'lsp-completion-at-point :around #'cape-wrap-nonexclusive)
  ;; lsp-request-while-no-input cancels completion requests when you type.
  ;; Override it to use a normal blocking request instead.
  (with-eval-after-load 'lsp-mode
    (advice-add #'lsp-request-while-no-input
                :override #'lsp-request)))


;;; ============================================================
;;; SECTION 8: YASNIPPET
;;; ============================================================

(use-package yasnippet
  :config
  (yas-global-mode 1))

(use-package yasnippet-snippets
  :after yasnippet)


;;; ============================================================
;;; SECTION 9: TREESITTER
;;; ============================================================

;; treesit-auto: installs grammars and maps major modes automatically
(use-package treesit-auto
  :config
  (setq treesit-auto-install 'prompt) ; asks before installing grammars
  (global-treesit-auto-mode))

;; Structural navigation with evil text objects
(use-package evil-textobj-tree-sitter
  :after (evil treesit-auto)
  :config
  ;; in/around function
  (define-key evil-outer-text-objects-map "f"
    (evil-textobj-tree-sitter-get-textobj "function.outer"))
  (define-key evil-inner-text-objects-map "f"
    (evil-textobj-tree-sitter-get-textobj "function.inner"))
  ;; in/around class
  (define-key evil-outer-text-objects-map "c"
    (evil-textobj-tree-sitter-get-textobj "class.outer"))
  (define-key evil-inner-text-objects-map "c"
    (evil-textobj-tree-sitter-get-textobj "class.inner"))
  ;; in/around parameter/argument
  (define-key evil-outer-text-objects-map "a"
    (evil-textobj-tree-sitter-get-textobj "parameter.outer"))
  (define-key evil-inner-text-objects-map "a"
    (evil-textobj-tree-sitter-get-textobj "parameter.inner")))


;;; ============================================================
;;; SECTION 9: LSP-MODE
;;; ============================================================

(use-package lsp-mode
  :hook
  ((lsp-mode . lsp-enable-which-key-integration)
   (lsp-managed-mode . (lambda ()
                          ;; Ensure lsp capf is first in the list
                          (setq-local completion-at-point-functions
                                      (list #'lsp-completion-at-point)))))
  :init
  (setq lsp-keymap-prefix "C-c l") ; backup prefix (SPC l is the main one)
  :config
  (setq lsp-idle-delay 0.2
        lsp-log-io nil
        lsp-completion-provider :none
        lsp-completion-enable t
        lsp-enable-snippet t          ; yasnippet is now installed
        lsp-headerline-breadcrumb-enable t
        lsp-headerline-breadcrumb-segments '(project file symbols)
        lsp-signature-auto-activate t
        lsp-signature-render-documentation nil
        lsp-eldoc-enable-hover t
        lsp-inlay-hint-enable t
        lsp-enable-symbol-highlighting t
        lsp-semantic-tokens-enable t))

;; UI enhancements: sideline diagnostics, peek windows, doc popups
(use-package lsp-ui
  :after lsp-mode
  :config
  (setq lsp-ui-doc-enable t
        lsp-ui-doc-position 'at-point
        lsp-ui-doc-delay 0.5
        lsp-ui-doc-show-with-cursor nil ; show with SPC l h instead
        lsp-ui-sideline-enable t
        lsp-ui-sideline-show-diagnostics t
        lsp-ui-sideline-show-hover nil
        lsp-ui-sideline-show-code-actions t
        lsp-ui-peek-enable t
        lsp-ui-peek-always-show t))


;;; ============================================================
;;; SECTION 10: LANGUAGE SUPPORT
;;; ============================================================

;; --- PHP ---
(use-package php-mode
  :mode "\\.php\\'")

;; --- JavaScript / TypeScript / TSX ---
;; These are handled by built-in js-ts-mode, typescript-ts-mode, tsx-ts-mode
;; (shipped with Emacs 29+). We just set up file associations here.
(add-to-list 'auto-mode-alist '("\\.js\\'"   . js-ts-mode))
(add-to-list 'auto-mode-alist '("\\.jsx\\'"  . js-ts-mode))
(add-to-list 'auto-mode-alist '("\\.ts\\'"   . typescript-ts-mode))
(add-to-list 'auto-mode-alist '("\\.tsx\\'"  . tsx-ts-mode))
(add-to-list 'auto-mode-alist '("\\.mjs\\'"  . js-ts-mode))
(add-to-list 'auto-mode-alist '("\\.cjs\\'"  . js-ts-mode))

;; --- CSS / SCSS ---
(add-to-list 'auto-mode-alist '("\\.css\\'"  . css-ts-mode))
(add-to-list 'auto-mode-alist '("\\.scss\\'" . css-ts-mode))

;; Tell vscode-css-language-server to validate SCSS properly
(with-eval-after-load 'lsp-mode
  (setq lsp-css-validate t
        lsp-css-lint-unknown-properties "ignore")
  ;; Register SCSS with the CSS language server
  (add-to-list 'lsp-language-id-configuration '(css-ts-mode . "scss"))
  ;; Disable emmet-ls for CSS/SCSS — emmet-mode handles expansions natively
  ;; and emmet-ls snippets drown out real css-ls completions
  (add-to-list 'lsp-disabled-clients '(css-ts-mode . emmet-ls)))

;; --- HTML / Templates ---
;; web-mode handles embedded languages (PHP+HTML, template engines, etc.)
(use-package web-mode
  :mode
  (("\\.html?\\'"    . web-mode)
   ("\\.phtml\\'"   . web-mode)
   ("\\.twig\\'"    . web-mode)
   ("\\.blade\\.php\\'" . web-mode)
   ("\\.ejs\\'"     . web-mode)
   ("\\.hbs\\'"     . web-mode))
  :config
  (setq web-mode-markup-indent-offset 2
        web-mode-css-indent-offset 2
        web-mode-code-indent-offset 2
        web-mode-enable-auto-pairing t
        web-mode-enable-auto-closing t
        web-mode-enable-current-element-highlight t
        web-mode-enable-css-colorization t))

;; --- Emmet (fast HTML/CSS expansion, like VSCode Emmet) ---
(use-package emmet-mode
  :hook
  ((web-mode     . emmet-mode)
   (css-ts-mode  . emmet-mode)
   (html-mode    . emmet-mode))
  :config
  (setq emmet-expand-jsx-className? t))

;; --- JSON ---
(use-package json-mode
  :mode "\\.json\\'")

;; --- YAML ---
(use-package yaml-mode
  :mode "\\.ya?ml\\'")

;; Prettier via apheleia (configured in Section 31) handles formatting.
;; prettier-js is NOT used — apheleia is async and won't move your cursor.


;;; ============================================================
;;; SECTION 11: STATUS BAR — doom-modeline
;;; ============================================================

(use-package doom-modeline
  :config
  (doom-modeline-mode 1)
  (setq doom-modeline-height 28
        doom-modeline-bar-width 4
        doom-modeline-icon t                  ; needs nerd-icons fonts
        doom-modeline-major-mode-icon t
        doom-modeline-buffer-state-icon t
        doom-modeline-lsp t                   ; show LSP status
        doom-modeline-github nil              ; set t if you want GitHub notifs
        doom-modeline-minor-modes nil
        doom-modeline-enable-word-count nil
        doom-modeline-buffer-encoding t
        doom-modeline-vcs-max-length 20))

;; Required for icons in doom-modeline (run M-x nerd-icons-install-fonts once)
(use-package nerd-icons)


;;; ============================================================
;;; SECTION 12: MAGIT & GIT
;;; ============================================================

(use-package magit
  :defer t
  :config
  (setq magit-display-buffer-function #'magit-display-buffer-same-window-except-diff-v1
        magit-log-auto-more t))

;; Inline diff highlights in the gutter (like gitsigns.nvim)
(use-package diff-hl
  :hook
  ((prog-mode . diff-hl-mode)
   (magit-pre-refresh  . diff-hl-magit-pre-refresh)
   (magit-post-refresh . diff-hl-magit-post-refresh))
  :config
  (diff-hl-flydiff-mode)
  ;; Navigate hunks in normal mode
  (evil-define-key 'normal 'global
    (kbd "]h") 'diff-hl-next-hunk
    (kbd "[h") 'diff-hl-previous-hunk))

;; Walk through git history of a file
(use-package git-timemachine
  :defer t
  :hook (git-timemachine-mode . evil-normalize-keymaps)
  :config
  ;; Make evil keys work in timemachine buffers
  (evil-define-key 'normal git-timemachine-mode-map
    (kbd "n") 'git-timemachine-show-next-revision
    (kbd "p") 'git-timemachine-show-previous-revision
    (kbd "q") 'git-timemachine-quit
    (kbd "b") 'git-timemachine-blame))


;;; ============================================================
;;; SECTION 13: PROJECTILE — project management
;;; ============================================================

(use-package projectile
  :config
  (projectile-mode +1)
  (setq projectile-completion-system 'auto   ; uses vertico automatically
        projectile-enable-caching t
        projectile-indexing-method 'alien)   ; uses fd/git for speed
  ;; C-p as a secondary shortcut (vim muscle memory)
  (define-key evil-normal-state-map (kbd "C-p") 'projectile-find-file))


;;; ============================================================
;;; SECTION 14: SEARCH — Ripgrep + Deadgrep
;;; ============================================================

;; consult-ripgrep handles project-wide search (SPC s p)
;; deadgrep gives an interactive ripgrep buffer (SPC s d)
(use-package deadgrep
  :defer t)

;; wgrep: edit grep/deadgrep results directly and apply to files
;; This is how you do find-and-replace across the whole project:
;;   1. SPC s p  → consult-ripgrep  OR  SPC s d → deadgrep
;;   2. Press e  in the results buffer to enter wgrep-mode
;;   3. Edit the matches in the buffer like normal text
;;   4. C-c C-c  to apply all changes to files on disk
;;   5. C-c C-k  to abort
(use-package wgrep
  :config
  (setq wgrep-auto-save-buffer t))

;; anzu: shows replacement count and preview in query-replace (SPC r r)
(use-package anzu
  :config
  (global-anzu-mode +1)
  ;; Use SPC r a instead of % so evil's matchit % is preserved
  (evil-define-key 'normal 'global
    (kbd "SPC r a") 'anzu-query-replace-at-cursor-thing))


;;; ============================================================
;;; SECTION 15: MULTICURSOR — evil-mc
;;; ============================================================

;; evil-mc works with visual selection and g-prefixed commands.
;;
;; Quick reference (in normal/visual mode):
;;   gzm  — make cursors at all matches of word under cursor
;;   gzn  — make cursor + goto next match
;;   gzp  — make cursor + goto prev match
;;   gzA  — make cursor at end of every selected line
;;   gzI  — make cursor at start of every selected line
;;   gzu  — undo all cursors
;;
;; SPC c * shortcuts are also configured via leader keys above.

(use-package evil-mc
  :after evil
  :config
  (global-evil-mc-mode 1)
  (setq evil-mc-cursor-current-evil-cursor 'bar)
  ;; Escape always quits all cursors
  (evil-define-key 'normal evil-mc-key-map
    (kbd "<escape>") 'evil-mc-undo-all-cursors)
  (evil-define-key '(normal visual) evil-mc-key-map
    (kbd "gzu") 'evil-mc-undo-all-cursors))


;;; ============================================================
;;; SECTION 16: FILE TREE — Treemacs
;;; ============================================================

(use-package treemacs
  :defer t
  :config
  (setq treemacs-width 30
        treemacs-follow-after-init t
        treemacs-is-never-other-window nil)
  (treemacs-follow-mode t)
  (treemacs-filewatch-mode t)
  (treemacs-git-mode 'deferred))

(use-package treemacs-evil
  :after (treemacs evil))

(use-package treemacs-projectile
  :after (treemacs projectile))

(use-package treemacs-nerd-icons
  :after treemacs)


;;; ============================================================
;;; SECTION 17: SMARTPARENS / AUTOPAIRS
;;; ============================================================

(use-package smartparens
  :hook (prog-mode . smartparens-mode)
  :config
  (require 'smartparens-config))


;;; ============================================================
;;; SECTION 18: INDENTATION GUIDES
;;; ============================================================

(use-package indent-bars
  :straight (indent-bars :type git :host github :repo "jdtsmith/indent-bars")
  :hook (prog-mode . indent-bars-mode)
  :config
  (setq indent-bars-treesit-support t
        indent-bars-width-frac 0.2
        indent-bars-pad-frac 0.1))


;;; ============================================================
;;; SECTION 19: RAINBOW DELIMITERS
;;; ============================================================

(use-package rainbow-delimiters
  :hook (prog-mode . rainbow-delimiters-mode))


;;; ============================================================
;;; SECTION 20: RESTART-EMACS
;;; ============================================================

(use-package restart-emacs
  :defer t)


;;; ============================================================
;;; SECTION 21: ADDITIONAL EVIL KEYBINDINGS (non-leader)
;;; ============================================================

(with-eval-after-load 'evil
  ;; Window navigation with C-h/j/k/l in normal mode
  (define-key evil-normal-state-map (kbd "C-h") 'windmove-left)
  (define-key evil-normal-state-map (kbd "C-j") 'windmove-down)
  (define-key evil-normal-state-map (kbd "C-k") 'windmove-up)
  (define-key evil-normal-state-map (kbd "C-l") 'windmove-right)

  ;; Diagnostic navigation (like ]e [e)
  (evil-define-key 'normal 'global
    (kbd "]e") 'flymake-goto-next-error
    (kbd "[e") 'flymake-goto-prev-error
    (kbd "]d") 'lsp-ui-peek-jump-forward
    (kbd "[d") 'lsp-ui-peek-jump-backward
    ;; LSP hover on K (like Neovim)
    (kbd "K")  'lsp-ui-doc-glance
    ;; gd → definition, gr → references, gi → implementation
    (kbd "gd") 'lsp-find-definition
    (kbd "gr") 'lsp-find-references
    (kbd "gi") 'lsp-find-implementation
    (kbd "gt") 'lsp-find-type-definition
    ;; Leader-less renames
    (kbd "g r") 'lsp-rename))


;;; ============================================================
;;; SECTION 22: AVY — jump anywhere on screen
;;; ============================================================

;; avy lets you jump anywhere visible in 2-3 keystrokes.
;; Equivalent to flash.nvim / leap.nvim.
;;
;; Usage:
;;   SPC j j  → type 1-2 chars, then the hint letter to jump there
;;   SPC j l  → jump to a line
;;   SPC j w  → jump to any word start
;;   gs       → avy-goto-char-timer in normal mode (fastest muscle memory)

(use-package avy
  :config
  (setq avy-timeout-seconds 0.3
        avy-style 'at-full  ; show hints overlaid on text
        avy-background t)   ; dim rest of buffer during hint
  ;; gs as a fast normal-mode shortcut (like flash.nvim)
  (evil-define-key 'normal 'global
    (kbd "gs") 'avy-goto-char-timer
    (kbd "gS") 'avy-goto-line))


;;; ============================================================
;;; SECTION 23: VTERM — proper terminal
;;; ============================================================

;; vterm is a full libvterm-backed terminal, not a toy.
;; Requires libvterm on your system:
;;   brew install libvterm cmake    (macOS)
;;   apt install libvterm-dev cmake (Linux)

(use-package vterm
  :defer t
  :config
  (setq vterm-max-scrollback 10000
        vterm-kill-buffer-on-exit t))

;; vterm-toggle: toggle a persistent terminal with one key
(use-package vterm-toggle
  :after vterm
  :config
  (setq vterm-toggle-fullscreen-p nil)
  ;; Open terminal at the bottom, respecting popper
  (setq vterm-toggle-scope 'project)
  (add-to-list 'display-buffer-alist
               '((lambda (buf _) (with-current-buffer buf (equal major-mode 'vterm-mode)))
                 (display-buffer-reuse-window display-buffer-at-bottom)
                 (reusable-frames . visible)
                 (window-height . 0.3))))


;;; ============================================================
;;; SECTION 24: POPPER — tame popup windows
;;; ============================================================

;; popper groups transient/popup buffers (terminal, help, errors,
;; compilation) so they don't clobber your layout.
;;
;; SPC o p  → toggle the last popup
;; SPC o P  → cycle through popups
;; Popups open at the bottom at 30% height and can be dismissed instantly.

(use-package popper
  :config
  (setq popper-reference-buffers
        '("\\*Messages\\*"
          "\\*Warnings\\*"
          "\\*Compile-Log\\*"
          "\\*Backtrace\\*"
          "\\*helpful"
          "\\*lsp-help\\*"
          "\\*lsp-diagnostics\\*"
          flymake-diagnostics-buffer-mode
          help-mode
          compilation-mode
          vterm-mode
          deadgrep-mode
          "\\*deadgrep"
          "\\*ripgrep-search\\*"))
  (setq popper-window-height 0.3)
  (popper-mode +1)
  (popper-echo-mode +1)  ; show popup indicator in modeline
  ;; Integrate with evil so q closes popups
  (evil-define-key 'normal popper-mode-map
    (kbd "q") 'popper-toggle))


;;; ============================================================
;;; SECTION 25: PERSPECTIVE — named workspaces
;;; ============================================================

;; perspective.el gives you named workspaces, each with their own
;; isolated buffer list. Think tmux windows but inside Emacs.
;;
;; Workflow:
;;   SPC TAB TAB  → create/switch workspace (type a name)
;;   SPC TAB n/p  → cycle workspaces
;;   SPC TAB d    → kill current workspace
;;   SPC TAB 1-5  → jump to workspace by number
;;
;; Tip: create one workspace per project:
;;   1. SPC TAB TAB → name it "my-project"
;;   2. SPC p p     → switch to the project inside it
;;   All buffers for that project stay scoped to that workspace.

(use-package perspective
  :init
  (setq persp-mode-prefix-key (kbd "C-c M-p"))
  :config
  (persp-mode))

(defun my/new-workspace (name)
  "Create and switch to a new named workspace."
  (interactive "sWorkspace name: ")
  (persp-switch name))

;; Add perspective's buffer source to consult after both are loaded.
;; We avoid touching consult--source-buffer internals entirely.
(add-hook 'emacs-startup-hook
          (lambda ()
            (when (and (featurep 'consult) (featurep 'perspective))
              (add-to-list 'consult-buffer-sources 'persp-consult-source))))

;; Tie projectile projects to perspective workspaces automatically
(use-package persp-projectile
  :after (perspective projectile)
  :config
  ;; SPC p p now creates/switches a matching perspective
  (define-key projectile-mode-map (kbd "C-c p") 'projectile-command-map))


;;; ============================================================
;;; SECTION 26: HELPFUL — better help buffers
;;; ============================================================

;; helpful replaces describe-function / describe-variable etc. with
;; much richer buffers that show source code, examples, and references.

(use-package helpful
  :config
  (setq counsel-describe-function-function #'helpful-callable
        counsel-describe-variable-function #'helpful-variable)
  ;; Replace built-in help commands
  (global-set-key (kbd "C-h f") #'helpful-callable)
  (global-set-key (kbd "C-h v") #'helpful-variable)
  (global-set-key (kbd "C-h k") #'helpful-key)
  (global-set-key (kbd "C-h x") #'helpful-command)
  ;; Make K in normal mode use helpful for elisp buffers
  (evil-define-key 'normal emacs-lisp-mode-map
    (kbd "K") 'helpful-at-point))


;;; ============================================================
;;; SECTION 27: HL-TODO — highlight TODO/FIXME/HACK in comments
;;; ============================================================

(use-package hl-todo
  :hook (prog-mode . hl-todo-mode)
  :config
  (setq hl-todo-keyword-faces
        '(("TODO"   . "#FFD700")
          ("FIXME"  . "#FF4500")
          ("HACK"   . "#FF8C00")
          ("NOTE"   . "#00CED1")
          ("WARN"   . "#FF4500")
          ("REVIEW" . "#DA70D6")
          ("DEPRECATED" . "#808080")))
  ;; Navigate between TODOs
  (evil-define-key 'normal 'global
    (kbd "]t") 'hl-todo-next
    (kbd "[t") 'hl-todo-previous))


;;; ============================================================
;;; SECTION 28: STRING-INFLECTION — cycle word case
;;; ============================================================

;; Cycle a word through camelCase → snake_case → UPPER_SNAKE → kebab-case
;; SPC t S  → cycle (configured in leader keys above)
;; Also available as a text operator below

(use-package string-inflection
  :defer t)


;;; ============================================================
;;; SECTION 29: EVIL-LION — alignment operator
;;; ============================================================

;; gl<motion><char>  → align region left on <char>
;; gL<motion><char>  → align region right on <char>
;; Example: select lines with foo = 1 / bar = 22 / baz = 333
;;          gl=  aligns them all on =

(use-package evil-lion
  :after evil
  :config
  (evil-lion-mode))


;;; ============================================================
;;; SECTION 30: OLIVETTI — focused writing / reading mode
;;; ============================================================

;; Centres the buffer with comfortable margins.
;; Great for reading long files or writing docs.
;; SPC t z  → toggle (configured in leader keys above)

(use-package olivetti
  :defer t
  :config
  (setq olivetti-body-width 100))


;;; ============================================================
;;; SECTION 31: WEB / JS EXTRAS
;;; ============================================================



;; Run npm scripts from Emacs  (SPC m n in js/ts buffers)
(use-package npm-mode
  :hook ((js-ts-mode typescript-ts-mode tsx-ts-mode) . npm-mode))

;; .env file syntax highlighting
(use-package dotenv-mode
  :mode "\\.env\\.?.*\\'")

;; apheleia: async formatting — replaces prettier-js for async format-on-save
;; Doesn't move your cursor or flash the buffer when saving.
(use-package apheleia
  :config
  ;; Tell prettier to use tabs
  (setf (alist-get 'prettier apheleia-formatters)
        '("prettier" "--use-tabs" "true" "--tab-width" "4" file))
  (apheleia-global-mode +1))


;;; ============================================================
;;; SECTION 33: MARKDOWN & MERMAID
;;; ============================================================

;; markdown-mode: syntax highlighting and structure editing
(use-package markdown-mode
  :mode
  (("\\.md\\'"       . markdown-mode)
   ("\\.markdown\\'" . markdown-mode)
   ("README\\.md\\'" . gfm-mode))
  :hook
  (markdown-mode . font-lock-mode)
  (gfm-mode      . font-lock-mode)
  :config
  (setq markdown-fontify-code-blocks-natively t
        markdown-header-scaling t
        markdown-enable-math t
        markdown-enable-wiki-links t
        markdown-italic-underscore t
        markdown-asymmetric-header t)
  ;; Ensure font-lock is fully enabled for markdown
  (add-hook 'markdown-mode-hook #'(lambda () (font-lock-flush) (font-lock-ensure))))

;; grip-mode: live GitHub-flavoured markdown preview in your browser.
;; Uses GitHub's own renderer via the grip CLI so it looks exactly
;; like it will on GitHub, including mermaid diagrams.
;;
;; Requires:
;;   pip install grip
;;   (optionally) set a GitHub token to avoid rate limits:
;;     M-x customize-variable grip-github-user / grip-github-password
;;
;; Usage:
;;   SPC m g  → start grip preview (opens browser tab, live-reloads on save)
;;   SPC m G  → stop grip
(use-package grip-mode
  :defer t
  :config
  (setq grip-preview-use-webkit nil))  ; set t if you want in-Emacs webkit window

;; markdown-mermaid: renders mermaid diagrams inline inside Emacs
;; by piping fenced ```mermaid blocks through mmdc and showing the
;; result as an inline image in the buffer.
;;
;; Requires:
;;   npm i -g @mermaid-js/mermaid-cli
(use-package markdown-mermaid
  :straight (:host github :repo "pasunboneleve/markdown-mermaid")
  :after markdown-mode)

(local-leader-key
  :keymaps '(markdown-mode-map gfm-mode-map)
  "m"  '(my/markdown-mermaid-preview-right :wk "Preview mermaid diagram"))

(defun my/markdown-mermaid-preview-right ()
  "Preview mermaid diagram in a vertical split to the right."
  (interactive)
  (let ((display-buffer-alist
         '((".*"
            (display-buffer-reuse-window display-buffer-in-side-window)
            (side . right)
            (window-width . 0.4)))))
    (markdown-mermaid-preview)))


;;; ============================================================
;;; SECTION 34: PERFORMANCE TUNING
;;; ============================================================

;; Increase GC threshold during startup, restore after
(setq gc-cons-threshold (* 128 1024 1024))  ; 128MB during use
(add-hook 'emacs-startup-hook
          (lambda () (setq gc-cons-threshold (* 16 1024 1024)))) ; 16MB after

;; Increase read process output for LSP
(setq read-process-output-max (* 4 1024 1024)) ; 4MB

;; Don't re-render the entire screen on every keypress
(setq redisplay-dont-pause t)


;;; ============================================================
;;; SECTION 36: TRANSMIT — SFTP file transfer
;;; ============================================================

;; Loaded directly from the transmit2 GitHub repo via straight.el.
;; transmit.el lives under emacs/transmit.el in the repo.
;;
;; Update these paths to match your setup before uncommenting:
;; (setq transmit-binary-path "~/projects/transmit2.nvim/bin/transmit-linux")
;; (transmit-setup "~/transmit_sftp/config.json")

(use-package transmit
  :straight (:host github
             :repo "DevDec/transmit2"
             :files ("emacs/transmit.el")
             :nonrecursive t)
  :config
  (setq transmit-binary-path
        (expand-file-name "straight/repos/transmit2/bin/transmit-linux"
                          user-emacs-directory))
  (transmit-setup "~/transmit_sftp/config.json"))
;;; ============================================================

;; Install the server:
;;   npm i -g twig-language-server
;;
;; If you prefer Twiggy (more actively maintained but must be built
;; from source):
;;   git clone https://github.com/moetelo/twiggy && cd twiggy
;;   npm install -g pnpm && pnpm install && pnpm build
;;   then change the :new-connection cmd below to the built binary path

(with-eval-after-load 'lsp-mode
  (add-to-list 'lsp-language-id-configuration '(web-mode . "twig"))
  (lsp-register-client
   (make-lsp-client
    :new-connection (lsp-stdio-connection "twig-language-server")
    :activation-fn (lsp-activate-on "twig")
    :server-id 'twig-ls)))

(add-hook 'web-mode-hook
          (lambda ()
            (when (and buffer-file-name
                       (string= (file-name-extension buffer-file-name) "twig"))
              (lsp))))
;;; ============================================================

;; Registered here at the end so php-mode, lsp-mode, web-mode etc.
;; are all guaranteed to be loaded before these hooks are added.
(add-hook 'php-mode-hook           #'lsp)
(add-hook 'php-ts-mode-hook        #'lsp)
(add-hook 'js-ts-mode-hook         #'lsp)
(add-hook 'typescript-ts-mode-hook #'lsp)
(add-hook 'tsx-ts-mode-hook        #'lsp)
(add-hook 'css-ts-mode-hook        #'lsp)
(add-hook 'html-mode-hook          #'lsp)


;;; ============================================================
;;; FIRST-TIME SETUP INSTRUCTIONS (run once, then remove/ignore)
;;; ============================================================

;; After Emacs loads for the first time:
;;
;; 1. Install icon fonts (required for doom-modeline):
;;      M-x nerd-icons-install-fonts  RET
;;
;; 2. Install Treesitter grammars (will prompt per grammar):
;;      M-x treesit-auto-install-all  RET
;;
;; 3. Install language servers (put these in your PATH):
;;      npm i -g intelephense                    ← PHP
;;      npm i -g typescript typescript-language-server  ← JS/TS
;;      npm i -g vscode-langservers-extracted     ← CSS/HTML/JSON
;;
;; 4. Install system tools:
;;      brew install ripgrep fd cmake libvterm    ← macOS
;;      apt install ripgrep fd-find cmake libvterm-dev  ← Linux
;;        (libvterm + cmake are required for vterm)
;;
;; 5. Install prettier for apheleia formatting:
;;      npm i -g prettier
;;
;; 6. Install mermaid CLI and grip for markdown rendering:
;;      npm i -g @mermaid-js/mermaid-cli
;;      pip install grip
;;
;; 7. Install Twig language server:
;;      npm i -g twig-language-server


;;; init.el ends here
