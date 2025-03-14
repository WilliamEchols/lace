;;; lace.el --- Local AI Companion for Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2024 William Echols

;; Author: William Echols <williamechols@berkeley.edu>
;; Version: 0.1.0
;; Package-Requires: ((emacs "26.1"))
;; Keywords: ai, tools, local
;; URL: https://github.com/williamechols/lace

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; LACE (Local AI Companion for Emacs) provides an interface to interact
;; with local AI models directly in Emacs.
;;
;; Features:
;; - Real-time streaming chat interface
;; - Automatic Ollama server management
;; - Support for multiple models
;; - Simple, distraction-free buffer
;; - Evil-mode compatibility
;;
;; Basic Usage:
;; M-x lace-start-chat to begin a chat session
;; M-x lace-select-model to choose a different model
;;
;; For detailed documentation, customization options, and examples,
;; see https://github.com/williamechols/lace

;;; Code:

(require 'json)
(require 'url)

(when (version< emacs-version "26.1")
  (error "LACE requires Emacs 26.1 or later"))

(defgroup lace nil
  "Local AI Companion using ollama."
  :group 'tools
  :prefix "lace-")

(defcustom lace-ollama-host "http://localhost:11434"
  "Host URL for ollama API."
  :type 'string
  :group 'lace)

(defcustom lace-ollama-executable "ollama"
  "Path to the ollama executable."
  :type 'string
  :group 'lace)

(defcustom lace-auto-start-server t
  "Whether to automatically start the Ollama server when needed."
  :type 'boolean
  :group 'lace)

(defcustom lace-max-context-size 1000000
  "Maximum size in bytes for context files to prevent memory issues."
  :type 'integer
  :group 'lace)

(defcustom lace-context-file-types
  '(".el" ".js" ".py" ".cpp" ".hpp" ".c" ".h" ".java" ".go" ".rs" ".md" ".txt")
  "File extensions to include when gathering directory context."
  :type '(repeat string)
  :group 'lace)

(defvar lace--current-model "qwen2.5:latest"
  "Currently selected ollama model.")

(defvar lace--chat-buffer-name "*LACE Chat*"
  "Name of the LACE chat buffer.")

(defvar lace--chat-history nil
  "History of the current chat conversation.")

(defcustom lace-chat-display-function #'display-buffer
  "Function used to display the chat buffer."
  :type 'function
  :group 'lace)

(defvar-local lace--chat-input-start nil
  "Marker for start of input area in chat buffer.")

(defvar-local lace--chat-input-end nil
  "Marker for end of input area in chat buffer.")

(defvar-local lace--current-response-point nil
  "Marker for current response insertion point.")

(defvar-local lace--awaiting-response nil
  "Non-nil when waiting for a response from the model.")

(defvar-local lace--response-marker nil
  "Marker for where to insert streamed response.")

(defvar lace--server-process nil
  "Process object for the Ollama server.")

(defvar lace--current-context nil
  "Plist containing current context information.
Structure: (:files [list of files] :content [concatenated content])")

(defvar-local lace--buffer-context nil
  "Context information specific to this chat buffer.")

(defcustom lace-sidebar-width 60
  "Width of the LACE sidebar chat window."
  :type 'integer
  :group 'lace)

(defvar-local lace--suggestion-markers nil
  "Markers for suggested code changes in the associated buffer.")

(defvar lace-suggestion-delimiters '("<<<CODE>>>" "</CODE>>>")
  "Delimiters for code suggestions in chat responses.")

(defvar lace-suggestion-accept-key "C-c C-a"
  "Keybinding to accept a code suggestion.")

(defvar lace-suggestion-reject-key "C-c C-r"
  "Keybinding to reject a code suggestion.")

(defun lace--log (format-string &rest args)
  "Log a message to *Messages* with FORMAT-STRING and ARGS."
  (let ((message-log-max t))
    (apply #'message (concat "[LACE] " format-string) args)))

(defun lace--update-mode-line ()
  "Update the mode line to show the current state."
  (setq mode-line-process
        (when lace--awaiting-response
          '(:propertize " [Thinking...]" face warning)))
  (force-mode-line-update))

(defun lace--flash-mode-line ()
  "Briefly flash the mode line."
  (let ((flash-time 0.1))
    (invert-face 'mode-line)
    (run-with-timer flash-time nil #'invert-face 'mode-line)))

(defun lace--ensure-input-area-writable ()
  "Ensure the input area is writable."
  (when (and (markerp lace--chat-input-start)
             (markerp lace--chat-input-end)
             (marker-position lace--chat-input-start)
             (marker-position lace--chat-input-end))
    (let ((inhibit-read-only t))
      ;; Remove any read-only properties in input area
      (remove-text-properties (marker-position lace--chat-input-start)
                            (marker-position lace--chat-input-end)
                            '(read-only nil front-sticky nil rear-nonsticky nil))
      ;; Explicitly make input area writable
      (put-text-property (marker-position lace--chat-input-start)
                        (marker-position lace--chat-input-end)
                        'read-only nil))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; API Calls

(defun lace--make-api-call (endpoint data callback &optional method)
  "Make API call to Ollama ENDPOINT with DATA and process the result with CALLBACK.
Optional METHOD defaults to POST."
  (lace--ensure-server)
  (let* ((url-request-method (or method "POST"))
         (url-request-extra-headers '(("Content-Type" . "application/json")))
         (url-request-data (when data
                            (encode-coding-string (json-encode data) 'utf-8)))
         (url (concat lace-ollama-host endpoint)))
    ;; url-retrieve-synchronously only takes 1-2 arguments in older Emacs versions
    (let ((response-buffer (url-retrieve-synchronously url)))
      (when response-buffer
        (with-current-buffer response-buffer
          (funcall callback nil))
        (kill-buffer response-buffer)))))

(defun lace-list-models (callback)
  "Get list of available models and process with CALLBACK."
  (lace--make-api-call "/api/tags"
                       nil
                       (lambda (status)
                         (unless status
                           (lace--handle-api-response callback)))
                       "GET"))

(defun lace--handle-api-response (callback)
  "Handle API response and pass result to CALLBACK."
  (goto-char (point-min))
  (unless (search-forward "\n\n" nil t)
    (error "Invalid response format"))
  (let ((json-object-type 'plist)
        (json-array-type 'list))
    (condition-case err
        (let ((response (json-read)))
          (funcall callback response))
      (error
       (message "JSON parsing error: %s" (error-message-string err))))))

(defun lace--generate-chat (prompt callback)
  "Send PROMPT to the current model and process response with CALLBACK."
  (let ((data `((model . ,lace--current-model)
                (prompt . ,prompt)
                (stream . nil))))
    (lace--make-api-call "/api/generate"
                         data
                         (lambda (status)
                           (unless status
                             (lace--handle-api-response callback))))))

(defun lace--generate-chat-streaming (prompt)
  "Send PROMPT to the current model and stream the response."
  (lace--log "Setting up streaming request...")
  (let* ((url-request-method "POST")
         (url-request-extra-headers '(("Content-Type" . "application/json")))
         (request-data `((model . ,lace--current-model)
                        (prompt . ,prompt)
                        (stream . t)))
         (url-request-data (encode-coding-string (json-encode request-data) 'utf-8))
         (url (concat lace-ollama-host "/api/generate"))
         (response-buffer (generate-new-buffer " *lace-response*")))
    (lace--log "Streaming request to %s" url)
    (lace--log "Request data: %S" request-data)
    (condition-case err
        (progn
          (lace--log "Initiating URL retrieve...")
          (url-retrieve url
                       (lambda (status)
                         (lace--log "URL retrieve callback with status: %S" status)
                         (if (plist-get status :error)
                             (progn
                               (lace--log "Error in URL retrieve: %S" (plist-get status :error))
                           (if-let ((proc (get-buffer-process (current-buffer))))
                               (progn
                                 (lace--log "Got process: %S" proc)
                                 (set-process-sentinel proc #'lace--stream-sentinel)
                                 (set-process-filter proc #'lace--stream-filter)
                                 (process-put proc 'response-buffer response-buffer))
                             (lace--log "Error: No process found for buffer"))))))
      (error (lace--log "Error setting up stream: %S" err))))))

(defun lace-send-message ()
  "Send the current line to the AI model."
  (interactive)
  (lace--ensure-server)
  (let* ((message (buffer-substring-no-properties
                   (line-beginning-position)
                   (line-end-position)))
         ;; Use buffer-local context if available, otherwise global
         (context (or lace--buffer-context lace--current-context))
         (context-str (when context
                       (lace--format-context-prompt)))
         (full-prompt (if context-str
                         (concat "Context:\n" context-str "\n\nUser message: " message)
                       message))
         (request-data (json-encode
                       `((model . ,lace--current-model)
                         (prompt . ,full-prompt)
                         (stream . t)))))
    
    ;; Insert newline after current line
    (end-of-line)
    (insert "\n")
    
    ;; Insert assistant prefix and set response marker
    (goto-char (point-max))
    (insert "Assistant: ")
    (setq-local lace--response-marker (point-marker))
    
    ;; Debug output
    (lace--log "Sending message with context: %s" (if context-str "yes" "no"))
    
    ;; Make network request using open-network-stream
    (let* ((response-buffer (generate-new-buffer " *lace-response*"))
           (proc (condition-case err
                    (open-network-stream
                     "lace-stream" response-buffer
                     "localhost" 11434
                     :type 'plain
                     :coding 'no-conversion)
                  (error
                   (lace--log "Network error: %S" err)
                   nil))))
      (if (not proc)
          (progn
            (lace--log "Failed to create network connection")
            (insert "\nError: Could not connect to Ollama. Is it running?\n"))
        ;; Store chat buffer reference
        (process-put proc 'chat-buffer (current-buffer))
        
        ;; Set up process handlers
        (set-process-filter proc #'lace--stream-filter)
        (set-process-sentinel proc #'lace--stream-sentinel)
        
        ;; Construct HTTP request
        (let ((http-request
               (format "POST /api/generate HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s"
                      (length request-data)
                      request-data)))
          ;; Debug output
          (lace--log "Sending HTTP request:\n%s" http-request)
          
          ;; Send request
          (process-send-string proc http-request)
          (lace--log "Request sent, waiting for response..."))))))

(defun lace--stream-filter (proc string)
  "Process streaming STRING from PROC."
  (let ((chat-buffer (process-get proc 'chat-buffer)))
    (with-current-buffer (process-buffer proc)
      (goto-char (point-max))
      (insert string)
      
      ;; Improved HTTP header handling
      (goto-char (point-min))
      (when (search-forward "\r\n\r\n" nil t)
        (delete-region (point-min) (point))
        (lace--log "Removed HTTP headers"))
      
      ;; Process complete JSON lines
      (goto-char (point-min))
      (while (re-search-forward "^\\([^[:cntrl:]]+\\)\n" nil t)
        (let* ((json-line (match-string 1))
               (json-object-type 'plist)
               (json-array-type 'list))
          (delete-region (point-min) (point))
          (unless (string-blank-p json-line)
            (condition-case err
                (let* ((response (json-read-from-string json-line))
                       (token (plist-get response :response))
                       (done (plist-get response :done)))
                  (when token
                    (with-current-buffer chat-buffer
                      (save-excursion
                        (goto-char (marker-position lace--response-marker))
                        (insert token)
                        (set-marker lace--response-marker (point))
                        (redisplay t))))
                  (when done
                    (with-current-buffer chat-buffer
                      (setq-local lace--awaiting-response nil)
                      (unless (get-text-property (point-min) 'response-finalized)
                        (lace--finalize-suggestion)
                        (save-excursion
                          (goto-char (point-max))
                          (insert "\n\nYou: ")
                          (put-text-property (point-min) (point-max) 
                                           'response-finalized t))))))
              (error 
               (lace--log "Error processing JSON: %s" (error-message-string err))))))))))

(defun lace--stream-sentinel (proc event)
  "Handle PROC EVENT for streaming."
  (when (string-match "\\(finished\\|deleted\\|connection broken\\)" event)
    (let ((response-buffer (process-buffer proc)))
      (when response-buffer
        (kill-buffer response-buffer)))))

(defun lace--format-message (role content)
  "Format a chat message with ROLE and CONTENT."
  (propertize (format "%s: %s\n" 
                      (propertize (capitalize role) 'face 'bold)
              'read-only t)))

(defun lace--insert-message (role content)
  "Insert a message with ROLE and CONTENT into the chat buffer."
  (with-current-buffer (get-buffer-create lace--chat-buffer-name)
    (let ((inhibit-read-only t))
      ;; Save current input
      (let ((input (buffer-substring-no-properties 
                    (marker-position lace--chat-input-start)
                    (marker-position lace--chat-input-end))))
        ;; Insert the message before the input area
        (save-excursion
          (goto-char lace--chat-input-start)
          (forward-line -2) ; Move before separator
          (insert (lace--format-message role content)))
        ;; Update response point for assistant messages
        (when (string= role "assistant")
          (save-excursion
            (goto-char lace--chat-input-start)
            (forward-line -2)
            (set-marker lace--current-response-point (point))))
        ;; Restore input
        (delete-region lace--chat-input-start lace--chat-input-end)
        (goto-char lace--chat-input-start)
        (insert input)))
    ;; Ensure input area remains writable
    (lace--ensure-input-area-writable)
    ;; Debug marker positions after insertion
    (lace--debug-markers)
    (push `((role . ,role) (content . ,content)) lace--chat-history)))

(defun lace--setup-chat-buffer ()
  "Create and set up the chat buffer."
  (let ((buf (get-buffer-create lace--chat-buffer-name)))
    (with-current-buffer buf
      (erase-buffer)
      ;; Simple keymap for RET
      (use-local-map (make-sparse-keymap))
      (local-set-key (kbd "RET") 'lace-send-message)
      ;; Make it writable
      (setq buffer-read-only nil))
    buf))

(defvar lace-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") 'lace-send-message)
    (define-key map (kbd "C-c C-c") 'lace-send-message)
    map)
  "Keymap for LACE chat mode.")

(define-derived-mode lace-chat-mode text-mode "LACE Chat"
  "Major mode for LACE chat interface."
  ;; Set up keymap
  (use-local-map lace-chat-mode-map)
  ;; Evil mode setup
  (when (bound-and-true-p evil-mode)
    (evil-set-initial-state 'lace-chat-mode 'insert))
  ;; Buffer local settings
  (setq-local scroll-conservatively 101)
  (setq-local scroll-margin 0)
  (setq-local scroll-preserve-screen-position t)
  ;; No auto-fill
  (auto-fill-mode -1))

(defun lace--verify-chat-mode ()
  "Verify that the chat mode is properly set up."
  (lace--log "Current major mode: %s" major-mode)
  (lace--log "Current local keymap: %s" (current-local-map))
  (lace--log "RET binding: %s" (key-binding (kbd "RET")))
  (lace--log "C-c C-c binding: %s" (key-binding (kbd "C-c C-c"))))

(defun lace--verify-keymap ()
  "Verify that the LACE chat keymap is properly set up."
  (interactive)
  (lace--log "Current keymap: %S" (current-local-map))
  (lace--log "RET binding: %S" (key-binding (kbd "RET")))
  (lace--log "C-c C-c binding: %S" (key-binding (kbd "C-c C-c"))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; User Commands

(defun lace-select-model ()
  "Interactively select an Ollama model to use."
  (interactive)
  (lace--ensure-server)
  (lace-list-models
   (lambda (response)
     (let* ((models (mapcar (lambda (model) (plist-get model :name))
                           (plist-get response :models)))
            (selected (completing-read "Select model: " models)))
       (setq lace--current-model selected)
       (message "Selected model: %s" selected)))))

(defun lace-start-chat ()
  "Start a new chat session."
  (interactive)
  (lace--ensure-server)
  (let ((buf (lace--setup-chat-buffer)))
    (switch-to-buffer buf)
    (lace-chat-mode)
    (insert "You: ")
    (message "Chat started. Type your message and press RET to send.")))

(defun lace--handle-stream-error (error)
  "Handle streaming ERROR and clean up."
  (lace--log "Handling stream error: %S" error)
  (with-current-buffer lace--chat-buffer-name
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char lace--current-response-point)
        (insert (propertize "\nError: Failed to get response from model\n" 
                           'face 'error))))
    (setq lace--awaiting-response nil)
    (lace--update-mode-line)))

(defun lace--ensure-insert-state ()
  "Ensure we're in insert state if using evil-mode."
  (when (and (bound-and-true-p evil-mode)
             (eq evil-state 'normal))
    (evil-insert-state)))

(defun lace--highlight-input-area ()
  "Add visual indication of the input area."
  (let ((input-overlay (make-overlay lace--chat-input-start lace--chat-input-end)))
    (overlay-put input-overlay 'face '(:background "#303030"))))

(defun lace--debug-markers ()
  "Print debug information about marker positions."
  (interactive)
  (lace--log "=== Marker Debug ===")
  (lace--log "Input start: %S at %d" 
             lace--chat-input-start 
             (marker-position lace--chat-input-start))
  (lace--log "Input end: %S at %d" 
             lace--chat-input-end 
             (marker-position lace--chat-input-end))
  (lace--log "Current point: %d" (point))
  (lace--log "Buffer content between markers: '%s'"
             (buffer-substring-no-properties 
              (marker-position lace--chat-input-start)
              (marker-position lace--chat-input-end))))

(defun lace-verify-load ()
  "Verify that LACE package is properly loaded."
  (interactive)
  (if (featurep 'lace)
      (if (commandp 'lace-start-chat)
          (message "LACE package is properly loaded. You can use M-x lace-start-chat")
        (message "LACE package loaded but commands not defined"))
    (message "LACE package not loaded")))

(defun lace-reset-chat ()
  "Reset the chat buffer to its initial state."
  (interactive)
  (when (get-buffer lace--chat-buffer-name)
    (kill-buffer lace--chat-buffer-name))
  (lace-start-chat))

(defun lace-verify-ollama ()
  "Check if Ollama is running and accessible."
  (interactive)
  (condition-case err
      (let ((proc (open-network-stream
                   "lace-test" nil
                   "localhost" 11434
                   :type 'plain
                   :coding 'no-conversion)))
        (delete-process proc)
        (message "Ollama is running and accessible"))
    (error
     (message "Cannot connect to Ollama: %s" (error-message-string err)))))

(defun lace--ensure-server ()
  "Ensure the Ollama server is running, starting it if necessary and configured."
  (unless (lace--server-running-p)
    (if lace-auto-start-server
        (lace-start-server)
      (user-error "Ollama server is not running. Use M-x lace-start-server or start manually"))))

(defun lace--server-running-p ()
  "Check if the Ollama server is running."
  (or (and lace--server-process
           (process-live-p lace--server-process))
      (condition-case nil
          (progn
            (let ((proc (open-network-stream
                        "lace-test" nil
                        "localhost" 11434
                        :type 'plain
                        :coding 'no-conversion)))
              (delete-process proc)
              t))
        (error nil))))

(defun lace-start-server ()
  "Start the Ollama server process."
  (interactive)
  (if (lace--server-running-p)
      (message "Ollama server is already running")
    (let ((process-environment
           ;; Ensure PATH is inherited for finding ollama executable
           (cons (concat "PATH=" (getenv "PATH")) process-environment)))
      (condition-case err
          (progn
            (setq lace--server-process
                  (make-process
                   :name "ollama-server"
                   :buffer "*ollama-server*"
                   :command (list lace-ollama-executable "serve")
                   :sentinel #'lace--server-sentinel))
            (message "Started Ollama server")
            ;; Wait briefly to ensure server is ready
            (sleep-for 1))
        (error
         (user-error "Failed to start Ollama server: %s" (error-message-string err)))))))

(defun lace-stop-server ()
  "Stop the Ollama server process."
  (interactive)
  (when (and lace--server-process
             (process-live-p lace--server-process))
    (delete-process lace--server-process)
    (setq lace--server-process nil)
    (message "Stopped Ollama server")))

(defun lace--server-sentinel (process event)
  "Monitor PROCESS for EVENT changes."
  (when (memq (process-status process) '(exit signal))
    (setq lace--server-process nil)
    (message "Ollama server process ended: %s" (string-trim event))))

(defun lace-set-file-context (file)
  "Set FILE as the current context for AI suggestions."
  (interactive "fSelect file for context: ")
  (setq lace--current-context nil)
  (setq lace--pending-changes nil)
  (let ((content-list nil)
        (total-size 0))
    (when (and (file-readable-p file)
               (not (file-directory-p file))
               (let ((ext (file-name-extension file)))
                 (member (concat "." ext) lace-context-file-types)))
      (let ((size (file-attribute-size (file-attributes file))))
        (when (< total-size lace-max-context-size)
          (push (cons file (with-temp-buffer
                           (insert-file-contents file)
                           (buffer-string)))
                content-list)
          (setq total-size (+ total-size size)))))
    (setq lace--current-context
          `(:files ,(mapcar #'car content-list)
            :content ,(mapcar #'cdr content-list)))
    (message "Context set with %d files (%.2fMB)"
             (length (plist-get lace--current-context :files))
             (/ total-size 1024.0 1024.0))))

(defun lace-set-directory-context (dir)
  "Set all relevant files in DIR as context for AI suggestions."
  (interactive "DDirectory: ")
  (setq lace--current-context nil)
  (setq lace--pending-changes nil)
  (let ((files (directory-files-recursively
                dir
                (regexp-opt lace-context-file-types)))
        (content-list nil)
        (total-size 0))
    (dolist (file files)
      (when (and (file-readable-p file)
                 (not (file-directory-p file)))
        (let ((size (file-attribute-size (file-attributes file))))
          (when (< (+ total-size size) lace-max-context-size)
            (push (cons file (with-temp-buffer
                             (insert-file-contents file)
                             (buffer-string)))
                  content-list)
            (setq total-size (+ total-size size))))))
    (setq lace--current-context
          `(:files ,(mapcar #'car content-list)
            :content ,(mapcar #'cdr content-list)))
    (message "Context set with %d files (%.2fMB)"
             (length (plist-get lace--current-context :files))
             (/ total-size 1024.0 1024.0))))

(defun lace-clear-context ()
  "Clear the current context."
  (interactive)
  (setq lace--current-context nil)
  (setq lace--pending-changes nil)
  (message "Context cleared"))

(defun lace--format-context-prompt ()
  "Format the current context for inclusion in prompts."
  (when lace--current-context
    (let ((files (plist-get lace--current-context :files))
          (contents (plist-get lace--current-context :content)))
      (concat "IMPORTANT: When suggesting code changes, use this exact format:\n"
              "FILE: <filename>\n"
              "BEFORE:\n```\n<existing code>\n```\n"
              "AFTER:\n```\n<modified code>\n```\n"
              "Wrap all code blocks with " (car lace-suggestion-delimiters) " and " (cadr lace-suggestion-delimiters) "\n\n"
              "Current file context:\n"
              "----------------\n"
              (mapconcat
               (lambda (file-and-content)
                 (format "=== %s ===\n%s\n"
                         (file-relative-name (car file-and-content))
                         (cdr file-and-content)))
               (cl-mapcar #'cons files contents)
               "\n")))))

(defun lace-send-sidebar-message ()
  "Send message in sidebar chat."
  (interactive)
  (let* ((message (buffer-substring-no-properties
                   (line-beginning-position)
                   (line-end-position)))
         (context lace--buffer-context)
         (context-str (when context
                       (lace--format-context-prompt)))
         (full-prompt (if context-str
                         (concat "Context:\n" context-str "\n\nUser message: " message)
                       message)))
    (let ((lace--current-context context))
      (lace-send-message))))

(define-derived-mode lace-sidebar-mode lace-chat-mode "LACE Sidebar"
  "Major mode for LACE sidebar chat interface."
  (setq-local window-size-fixed 'width)
  (setq-local lace--chat-buffer-name (buffer-name))
  (setq-local lace--current-context lace--buffer-context)
  (setq-local lace--suggestion-markers nil)
  (define-key lace-sidebar-mode-map (kbd lace-suggestion-accept-key) #'lace-accept-suggestion)
  (define-key lace-sidebar-mode-map (kbd lace-suggestion-reject-key) #'lace-reject-suggestion)
  (define-key lace-sidebar-mode-map (kbd "RET") #'lace-send-sidebar-message)
  (define-key lace-sidebar-mode-map (kbd "C-c C-c") #'lace-send-sidebar-message))

(defun lace-toggle-sidebar ()
  "Toggle the LACE sidebar chat for the current buffer."
  (interactive)
  (let* ((current-file (buffer-file-name))
         (chat-buffer-name (format "*LACE Chat: %s*" 
                                 (if current-file 
                                     (file-name-nondirectory current-file)
                                   (buffer-name))))
         (chat-buffer (get-buffer chat-buffer-name)))
    (if (and chat-buffer 
             (get-buffer-window chat-buffer))
        ;; If sidebar exists, close it
        (delete-window (get-buffer-window chat-buffer))
      ;; Create or show sidebar
      (let ((chat-buffer (or chat-buffer 
                            (generate-new-buffer chat-buffer-name))))
        (with-current-buffer chat-buffer
          (unless (eq major-mode 'lace-sidebar-mode)
            (lace-sidebar-mode)
            ;; Set context for this chat buffer
            (let ((file-content (with-temp-buffer
                                 (insert-file-contents current-file)
                                 (buffer-string))))
              (setq-local lace--buffer-context 
                         (when current-file
                           `(:files (,current-file)
                             :content (,file-content)))))
            (insert "You: ")))
        ;; Display sidebar
        (display-buffer-in-side-window
         chat-buffer
         `((side . right)
           (window-width . ,lace-sidebar-width)))))))

;; Add global key binding for toggling sidebar
(global-set-key (kbd "C-c l s") #'lace-toggle-sidebar)

(defun lace--detect-suggestion (chat-buffer)
  "Detect code suggestions in CHAT-BUFFER and prepare for application."
  (with-current-buffer chat-buffer
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward 
             (format "%s\\(.*?\\)%s" 
                     (regexp-quote (car lace-suggestion-delimiters))
                     (regexp-quote (cadr lace-suggestion-delimiters))) 
             nil t)
        (let ((start (match-beginning 1))
              (end (match-end 1)))
          (put-text-property start end 'face 'diff-added)
          (put-text-property start end 'lace-suggestion t))))))

(defun lace--finalize-suggestion ()
  "Finalize suggestion detection and add action buttons."
  (when (not (get-text-property (point-min) 'lace-suggestion-finalized))
    (save-excursion
      (goto-char (point-max))
      (insert "\n\n")
      (insert-button "Accept Change" 
                     'action (lambda (_) (lace-accept-suggestion))
                     'face 'button)
      (insert " | ")
      (insert-button "Reject Change" 
                     'action (lambda (_) (lace-reject-suggestion))
                     'face 'button)
      (put-text-property (point-min) (point-max) 'lace-suggestion-finalized t)
      (setq-local lace--awaiting-response nil)
      (lace--update-mode-line))))

(defun lace-accept-suggestion ()
  "Accept the current code suggestion and apply it to the original buffer."
  (interactive)
  (lace--log "Attempting to accept suggestion...")
  (let* ((chat-buffer (current-buffer))
         (suggestion (lace--extract-suggestion)))
    (lace--log "Extracted suggestion: %S" suggestion)
    (when suggestion
      ;; Find the file mentioned in the suggestion
      (save-excursion
        (goto-char (point-min))
        (when (re-search-forward "FILE:[ \t]*\\(.*?\\)[ \t]*[\n\r]" nil t)
          (let* ((filename (match-string 1))
                 (file-buffer (find-buffer-visiting filename))
                 (content (car suggestion))
                 (replacement (cdr suggestion)))
            ;; If buffer not found, try to find the file relative to the project root
            (unless file-buffer
              (setq file-buffer 
                    (find-file-noselect 
                     (expand-file-name filename (project-root (project-current))))))
            
            (if file-buffer
                (with-current-buffer file-buffer
                  (save-excursion
                    (goto-char (point-min))
                    (let ((case-fold-search nil))
                      (lace--log "Searching for content in %s: %S" filename content)
                      (if (search-forward content nil t)
                          (let ((start (match-beginning 0))
                                (end (match-end 0)))
                            (lace--log "Found match at %d-%d" start end)
                            (delete-region start end)
                            (insert replacement)
                            (lace--log "Replacement complete")
                            (message "Change accepted and applied successfully."))
                        (lace--log "No matches found for suggestion in %s" filename)
                        (message "Could not find the text to replace in %s" filename)))))
              (message "Could not find or open file: %s" filename))))))))

(defun lace-reject-suggestion ()
  "Reject the current code suggestion."
  (interactive)
  (let ((inhibit-read-only t))
    (delete-region (point-min) (point-max))
    (message "Change rejected.")))

(defun lace--extract-suggestion ()
  "Extract code suggestion from chat buffer."
  (save-excursion
    (goto-char (point-min))
    (let* ((header-regex "FILE:[ \t]*\\(.*?\\)[ \t]*[\n\r]+BEFORE:[ \t]*[\n\r]+")
           (before-regex "```[^\n\r]*[\n\r]+\\([^`]*?\\)[\n\r]+```")
           (after-regex "[\n\r]+AFTER:[ \t]*[\n\r]+```[^\n\r]*[\n\r]+\\([^`]*?\\)[\n\r]+```"))
      (lace--log "=== Buffer Content ===")
      (lace--log "%s" (buffer-substring-no-properties (point-min) (point-max)))
      (lace--log "=== Matching Pattern ===")
      (lace--log "Header: %s" header-regex)
      (lace--log "Before: %s" before-regex)
      (lace--log "After: %s" after-regex)
      
      ;; Try to match the structured format
      (when (re-search-forward (concat header-regex before-regex after-regex) nil t)
        (let ((file (match-string 1))
              (before (string-trim (match-string 2)))
              (after (string-trim (match-string 3))))
          (lace--log "Match groups: [%s][%s][%s]" file before after)
          (cons before after))))))

(provide 'lace)

;;; lace.el ends here
