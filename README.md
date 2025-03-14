# LACE - Local AI Companion for Emacs

LACE provides an interface to interact with local AI models directly in Emacs.

> **⚠️ Early Development Notice**
>
> This project is in early development and actively evolving. Features may be incomplete, and breaking changes are likely to occur between versions. While the core functionality is usable, please be aware that APIs, commands, and behaviors may change significantly.
>
> Feel free to try it out and provide feedback.

## Features

- Real-time streaming chat interface with AI models
- Automatic Ollama server management
- Support for multiple Ollama models
- Evil-mode compatibility
- Minimal dependencies (just built-in Emacs packages and Ollama)
- Context-aware change suggestions with accept/reject functionality
- Sidebar chat interface for file-specific discussions

## Installation

### Prerequisites

1. Emacs 26.1 or later
2. [Ollama](https://ollama.ai/) and desired model(s) installed on your system

### Manual Installation

Clone this repository:

```bash
git clone https://github.com/williamechols/lace.git
```

Add the following to your Emacs configuration (e.g., `~/.emacs` or `~/.emacs.d/init.el`):

```elisp
(add-to-list 'load-path "path/to/lace")
(require 'lace)
```

## Usage

### Quick Start

1. `M-x lace-start-chat` to open the chat interface
2. Type your message and press `RET` to send
3. Use `M-x lace-select-model` to switch between different Ollama models

### Server Management

LACE automatically manages the Ollama server:
- Starts the server automatically when needed
- `M-x lace-start-server` to manually start the server
- `M-x lace-stop-server` to stop the server
- `M-x lace-verify-ollama` to check server status

### Available Commands

Chat Commands:
- `lace-start-chat` - Start a new chat session
- `lace-select-model` - Choose an Ollama model
- `lace-reset-chat` - Reset the chat buffer
- `RET` or `C-c C-c` - Send message

### Context-Aware Suggestions

LACE can analyze your code and suggest improvements:

1. Set context:
   - `M-x lace-set-file-context` to select specific files
   - `M-x lace-set-directory-context` to include all relevant files in a directory
   
2. Get suggestions:
   - Ask for code improvements in the chat
   - Review suggestions with accept/reject buttons
   - Use `C-c C-a` to accept changes
   - Use `C-c C-r` to reject changes
   
3. Manage context:
   - `M-x lace-clear-context` to clear the current context

### Sidebar Chat Interface

LACE provides a convenient sidebar chat interface for discussing specific files:

- `C-c l s` to toggle the sidebar
- Each sidebar chat maintains its own context based on the buffer it was opened from
- The sidebar automatically loads the current file as context
- Multiple sidebars can be open for different files

## Customization

Use `M-x customize-group RET lace RET` or add to your init file:

```elisp
;; Path to Ollama executable (if not in PATH)
(setq lace-ollama-executable "/path/to/ollama")

;; Disable automatic server management
(setq lace-auto-start-server nil)

;; Use a different Ollama server
(setq lace-ollama-host "http://other-host:11434")

;; Change default model
(setq lace--current-model "codellama:latest")

;; Customize chat buffer display
(setq lace-chat-display-function #'switch-to-buffer-other-window)

;; Maximum size for context files (in bytes)
(setq lace-max-context-size 2000000)  ; 2MB

;; File types to include in directory context
(setq lace-context-file-types '(".el" ".js" ".py"))

;; Adjust sidebar width (in columns)
(setq lace-sidebar-width 60)

;; Customize suggestion keybindings
(setq lace-suggestion-accept-key "C-c C-a")
(setq lace-suggestion-reject-key "C-c C-r")
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Known Issues

- In the sidebar, after the first suggestion, the buttons show up and work fine. If I then send a following response, the buttons do not show up for this message and there is no "You: " in the buffer to indicate where to start the next response. I don't think we are properly handling multiple user messages in the same LACE Sidebar chat.
- Need to update the context to include updated file content when using the sidebar. (If I accept a change or make my own changes, then I ask another question, the model does not have the updated file content.)
- Only show Accept Change or Reject Change buttons if there are changes to accept or reject.
- Are before, after, and <<<CODE>>> blocks all necessary? Would it be more reliable and easier to use an alternative structure?

## Roadmap

- Multiple file context in sidebar.
- Make the suggestion interface more robust.
- Visualize diff in original buffer when accepting/rejecting changes.

## License

This project is licensed under the GPL-3.0 License - see the [LICENSE](LICENSE) file for details.
