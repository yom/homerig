# ~/.bashrc: executed by bash(1) for non-login shells.
# see /usr/share/doc/bash/examples/startup-files (in the package bash-doc)
# for examples

# =============================================================================
# 1. CORE SHELL SETUP
# =============================================================================
# Essential shell initialization and behavior configuration.
# This section ensures proper shell environment and basic options.

# Interactive shell check - exit early for non-interactive shells
# Non-interactive shells (like scripts) will exit here to avoid loading
# unnecessary configurations that could interfere with automation.
# The $- variable contains current shell options; 'i' indicates interactive mode.
case $- in
    *i*) ;;      # Interactive shell - continue loading bashrc
      *) return;; # Non-interactive shell - exit immediately
esac

# Automatically update terminal size variables after each command
# This ensures LINES and COLUMNS variables stay accurate when terminal is resized
shopt -s checkwinsize

# =============================================================================
# 2. ENVIRONMENT VARIABLES
# =============================================================================
# Configure environment variables for development tools and system behavior.
# This includes PATH setup and tool-specific configurations.

# PATH Configuration
# ==================
# Configure the PATH environment variable to include various binary directories.
# PATH determines where the shell looks for executable commands.

# Add system admin directories to PATH (for system utilities like fdisk, etc.)
export PATH="/sbin:/usr/sbin:${PATH}"

# Add personal binary directory if it exists
# This is typically used for user-installed scripts and binaries
[ -d /home/yom/bin ] && export PATH="/home/yom/bin:${PATH}"

# Add Go binary directory if it exists
# Go installs binaries here when using 'go install'
[ -d /home/yom/go/bin ] && export PATH="/home/yom/go/bin:${PATH}"

# Add local Python/pip binary directory if it exists
# Python packages installed with --user flag place binaries here
if [ -d /home/yom/.local/bin ] ; then
    export PATH="/home/yom/.local/bin:${PATH}"
fi

# Development Environment Variables
# =================================

# Set Go workspace directory for Go development
export GOPATH=~/go

# Tool Configuration Variables
# =============================

# Configure less pager to interpret ANSI color sequences
# -R flag allows less to display colored output properly
export LESS='-R'

# Set up lessfilter for enhanced file viewing in less
# This allows less to display syntax highlighting and formatted content
export LESSOPEN='|~/.lessfilter %s'

# =============================================================================
# 3. HISTORY MANAGEMENT
# =============================================================================
# Configure how bash handles command history for better usability and privacy.

# Control what gets saved to history:
# - ignoreboth = ignore duplicate lines AND lines starting with space
# - This prevents cluttering history with repeated commands and allows
#   hiding sensitive commands by prefixing them with a space
HISTCONTROL=ignoreboth

# Append new history to the history file instead of overwriting it
# This prevents losing history when multiple bash sessions are open
shopt -s histappend

# Set history size limits:
# HISTSIZE: number of commands to remember in current session (1000)
# HISTFILESIZE: maximum lines in the history file (2000)
# This prevents the history file from growing indefinitely
HISTSIZE=1000
HISTFILESIZE=2000

# =============================================================================
# 4. TERMINAL & DISPLAY
# =============================================================================
# Configure terminal capabilities, color support, and display utilities.

# Set up lesspipe for better handling of non-text files in less/more
# This allows viewing compressed files, images, etc. directly with less
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# Enable colored output for ls command
if [ -x /usr/bin/dircolors ]; then
    # Load custom color scheme if available, otherwise use default
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
fi

# Powerline Configuration
# ========================
# Set up powerline for enhanced prompt with git integration and visual styling

# Start powerline daemon if not already running (use system binary)
/usr/bin/powerline-daemon -q

# Source the powerline bash bindings
POWERLINE_BASH_CONTINUATION=1
POWERLINE_BASH_SELECT=1
source /usr/share/powerline/bindings/bash/powerline.sh

# =============================================================================
# 5. VERSION CONTROL INTEGRATION
# =============================================================================
# Git integration is handled automatically by powerline, which provides:
# - Current branch display
# - Dirty/clean status indicators
# - Ahead/behind commit counts
# - Stash status
# - Untracked files indication
#
# Additional git-prompt settings (optional - powerline has its own git integration)
# These may still be used by other tools or custom scripts

# Show unstaged (*) and staged (+) changes in the prompt
export GIT_PS1_SHOWDIRTYSTATE=1

# Show if there are stashed changes ($) in the prompt
export GIT_PS1_SHOWSTASHSTATE=1

# Show if there are untracked files (%) in the prompt
export GIT_PS1_SHOWUNTRACKEDFILES=1

# Show relationship between HEAD and upstream branch
export GIT_PS1_SHOWUPSTREAM=verbose

# Use branch names instead of commit hashes when possible
export GIT_PS1_DESCRIBE_STYLE=branch

# =============================================================================
# 6. PROMPT CUSTOMIZATION
# =============================================================================
# Powerline provides the enhanced prompt with the following features:
# - Colorized segments showing user, hostname, current directory
# - Git branch and status integration
# - Return code indication for failed commands  
# - Virtual environment display (Python, etc.)
# - Customizable themes and segments
#
# Powerline configuration files are located in:
# - System: /usr/share/powerline/config_files/
# - User: ~/.config/powerline/ (create this for custom configs)
#
# To customize powerline themes and segments, copy the system configs to
# your user directory and modify them:
# mkdir -p ~/.config/powerline
# cp -r /usr/share/powerline/config_files/* ~/.config/powerline/

# Legacy prompt functions (kept for reference, not used with powerline)
# function _usr_prompt () {
#     [[ $EUID == 0 ]] \
#     && echo -en "\[\e[0;31m\]" \
#     || echo -en "\[\e[0;34m\]"
# }
#
# function _git_prompt () {
#     GITSTATUS=$(__git_ps1 %s)
#     [ "x$GITSTATUS" == "x" ] \
#     || echo -en "\[\e[1m\][\[\e[0;34m\]${GITSTATUS}\[\e[1m\]]\[\e[m\]"
# }

# =============================================================================
# 7. ALIASES & SHORTCUTS
# =============================================================================
# Configure command aliases and shortcuts for improved productivity.

# Enable colored ls by default
alias ls='ls --color=auto'

# Load custom aliases from separate file if it exists
# This allows keeping personal aliases organized in ~/.bash_aliases
if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi

# =============================================================================
# 8. COMPLETION SYSTEMS
# =============================================================================
# Enable advanced bash completion features for enhanced command-line experience.

# Enable advanced bash completion features
# This provides tab completion for commands, options, filenames, etc.
# Only load if not in POSIX mode (which disables bash extensions)
if ! shopt -oq posix; then
  # Try modern bash-completion location first
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  # Fall back to older location if needed
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

# =============================================================================
# 9. SECURITY & CREDENTIALS
# =============================================================================
# Security-related configurations and credential handling guidance.

# AWS Credentials Configuration
# =============================
# SECURITY WARNING: Never store credentials directly in shell configuration files.
# 
# Recommended secure credential storage methods:
# 1. AWS CLI configuration: Run 'aws configure' to set up credentials securely
# 2. AWS credentials file: Store in ~/.aws/credentials with proper permissions (600)
# 3. Environment variables: Export AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY
# 4. IAM roles: Use IAM roles for EC2 instances (recommended for cloud environments)
# 5. AWS SSO: Use 'aws sso configure' for organizations using AWS SSO
#
# Example secure setup:
#   aws configure
#   # or
#   export AWS_ACCESS_KEY_ID="your-access-key"
#   export AWS_SECRET_ACCESS_KEY="your-secret-key"
#   export AWS_DEFAULT_REGION="your-preferred-region"

# =============================================================================
# 10. CUSTOM FUNCTIONS & UTILITIES
# =============================================================================
# User-defined functions and utilities for enhanced shell functionality.
# Add your custom functions and utilities here.

# Example utility functions can be added here:
# function myfunction() {
#     # Your custom function code
# }

# Load additional custom functions from external files if they exist
# if [ -f ~/.bash_functions ]; then
#     . ~/.bash_functions
# fi
# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
