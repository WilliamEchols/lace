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

;; LACE provides a seamless interface to interact with local AI models
;; through Ollama directly within Emacs.
;;
;; Features:
;; - Real-time streaming chat interface
;; - Support for multiple models
;; - Simple, distraction-free buffer
;; - Evil-mode compatibility
;;
;; Usage:
;; M-x lace-start-chat to begin a chat session
;; M-x lace-select-model to choose a different model

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
                               (lace--handle-stream-error (plist-get status :error)))
                           (if-let ((proc (get-buffer-process (current-buffer))))
                               (progn
                                 (lace--log "Got process: %S" proc)
                                 (set-process-sentinel proc #'lace--stream-sentinel)
                                 (set-process-filter proc #'lace--stream-filter)
                                 (process-put proc 'response-buffer response-buffer))
                             (lace--log "Error: No process found for buffer"))))))
      (error (lace--log "Error setting up stream: %S" err)))))

(defun lace-send-message ()
  "Send the current line to the AI model."
  (interactive)
  (let* ((message (buffer-substring-no-properties
                   (line-beginning-position)
                   (line-end-position)))
         (request-data (json-encode
                       `((model . ,lace--current-model)
                         (prompt . ,message)
                         (stream . t)))))
    
    ;; Insert newline after current line
    (end-of-line)
    (insert "\n")
    
    ;; Insert assistant prefix and set response marker
    (goto-char (point-max))
    (insert "Assistant: ")
    (setq-local lace--response-marker (point-marker))
    
    ;; Debug output
    (lace--log "Sending message: %s" message)
    
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
  ;; (lace--log "Received data: %S" string)
  (let ((chat-buffer (process-get proc 'chat-buffer)))
    (with-current-buffer (process-buffer proc)
      (goto-char (point-max))
      (insert string)
      
      ;; Skip HTTP headers on first chunk
      (goto-char (point-min))
      (when (looking-at "HTTP/.*\n\\(.\\|\n\\)*\n\n")
        (lace--log "Skipping HTTP headers")
        (delete-region (point-min) (match-end 0)))
      
      ;; Process complete JSON objects
      (goto-char (point-min))
      (while (re-search-forward "^{.*}$" nil t)
        (let* ((json-string (match-string 0))
               (json-object-type 'plist)
               (json-array-type 'list))
          ;; (lace--log "Processing JSON: %s" json-string)
          (condition-case err
              (let* ((response (json-read-from-string json-string))
                     (token (plist-get response :response))
                     (done (plist-get response :done)))
                (when token
                  (lace--log "Inserting token: %S" token)
                  (with-current-buffer chat-buffer
                    (save-excursion
                      (goto-char (marker-position lace--response-marker))
                      (insert token)
                      (set-marker lace--response-marker (point))
                      (redisplay t))))  ; Force display update
                ;; Only add "You: " prompt when done is true
                (when (eq done t)  ; explicitly check for t
                  (lace--log "Response complete")
                  (with-current-buffer chat-buffer
                    (save-excursion
                      (goto-char (point-max))
                      (insert "\n\nYou: ")))))
            (error
             (lace--log "Error processing JSON: %S" err)))))
      
      ;; Clear processed text
      (delete-region (point-min) (point)))))

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
                      content)
              'read-only t))

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
  (let ((buf (lace--setup-chat-buffer)))
    (switch-to-buffer buf)
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

(provide 'lace)

;;; lace.el ends here
