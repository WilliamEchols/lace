# LACE - Local AI Companion for Emacs

LACE provides a seamless interface to interact with local AI models directly within Emacs.

## Features

- Real-time streaming chat interface with AI models
- Support for multiple Ollama models
- Simple, distraction-free chat buffer
- Evil-mode compatibility
- Minimal dependencies (just built-in Emacs packages)

## Installation

### Prerequisites

1. Emacs 26.1 or later
2. [Ollama](https://ollama.ai/) installed and running locally

### Manual Installation

Clone this repository:

```bash
git clone https://github.com/williamechols/lace.git
```

Add the following to your Emacs configuration file (e.g., `~/.emacs` or `~/.emacs.d/init.el`):

```elisp
(add-to-list 'load-path "path/to/lace")
(require 'lace)
```

## Usage

1. Start Ollama on your system
2. `M-x lace-start-chat` to open the chat interface
3. Type your message and press `RET` to send
4. Use `M-x lace-select-model` to switch between different Ollama models

## Commands

- `lace-start-chat`: Start a new chat session
- `lace-select-model`: Choose an Ollama model
- `lace-reset-chat`: Reset the chat buffer
- `lace-verify-ollama`: Check if Ollama is accessible

## Customization

```elisp
;; Change the default model
(setq lace--current-model "codellama:latest")

;; Customize the chat buffer display function
(setq lace-chat-display-function #'switch-to-buffer-other-window)
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the GPL-3.0 License - see the [LICENSE](LICENSE) file for details.
