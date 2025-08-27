# ~/.bashrc: executed by bash(1) for non-login shells.
# see /usr/share/doc/bash/examples/startup-files (in the package bash-doc)
# for examples

# =============================================================================
# INTERACTIVE SHELL CHECK
# =============================================================================
# This section ensures the bashrc only runs for interactive shells.
# Non-interactive shells (like scripts) will exit here to avoid loading
# unnecessary configurations that could interfere with automation.
# The $- variable contains current shell options; 'i' indicates interactive mode.
case $- in
    *i*) ;;      # Interactive shell - continue loading bashrc
      *) return;; # Non-interactive shell - exit immediately
esac

# =============================================================================
# PATH CONFIGURATION
# =============================================================================
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

# =============================================================================
# BASH HISTORY CONFIGURATION
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
# SHELL OPTIONS AND UTILITIES
# =============================================================================
# Configure various shell behaviors and integrate useful utilities.

# Automatically update terminal size variables after each command
# This ensures LINES and COLUMNS variables stay accurate when terminal is resized
shopt -s checkwinsize


# Set up lesspipe for better handling of non-text files in less/more
# This allows viewing compressed files, images, etc. directly with less
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# =============================================================================
# GIT PROMPT CONFIGURATION
# =============================================================================
# Configure git-prompt to show detailed repository status in the shell prompt.
# These settings control what information is displayed about the current git repo.

# Show unstaged (*) and staged (+) changes in the prompt
export GIT_PS1_SHOWDIRTYSTATE=1

# Show if there are stashed changes ($) in the prompt
export GIT_PS1_SHOWSTASHSTATE=1

# Show if there are untracked files (%) in the prompt
export GIT_PS1_SHOWUNTRACKEDFILES=1

# Show relationship between HEAD and upstream branch
# 'verbose' shows ahead/behind counts (e.g., ↑3↓1)
export GIT_PS1_SHOWUPSTREAM=verbose

# Use branch names instead of commit hashes when possible
export GIT_PS1_DESCRIBE_STYLE=branch

# Enable colored hints in the git prompt (requires proper prompt setup)
export GIT_PS1_SHOWCOLORHINTS=1

# Load the git-prompt script that provides the __git_ps1 function
source /etc/bash_completion.d/git-prompt

# =============================================================================
# CUSTOM PROMPT FUNCTIONS
# =============================================================================
# These functions create colorized prompt components for a custom bash prompt.

# Function to set user color based on privileges
# Returns red color for root user, blue for regular users
function _usr_prompt () {
    [[ $EUID == 0 ]] \
    && echo -en "\[\e[0;31m\]" \  # Red for root (EUID=0)
    || echo -en "\[\e[0;34m\]"    # Blue for regular users
}

# Function to display git status in the prompt
# Shows current branch and status indicators in brackets with formatting
function _git_prompt () {
    GITSTATUS=$(__git_ps1 %s)     # Get git status from git-prompt
    [ "x$GITSTATUS" == "x" ] \    # Check if we're in a git repository
    || echo -en "\[\e[1m\][\[\e[0;34m\]${GITSTATUS}\[\e[1m\]]\[\e[m\]"  # Format: [branch*+%]
}

# =============================================================================
# TERMINAL AND POWERLINE SETUP
# =============================================================================
# Configuration for advanced terminal features and powerline prompt styling.

# Function to update prompt and terminal settings
function _update_ps1() {
    # Force terminal type to support 256 colors for better display
    export TERM="screen-256color"
    
    # Enable powerline features for better prompt continuation and selection
    POWERLINE_BASH_CONTINUATION=1  # Better multiline command prompts
    POWERLINE_BASH_SELECT=1        # Enhanced selection highlighting
}

# Conditionally set up the prompt update function
# Only activate if not in basic linux terminal and not already configured
if [[ $TERM != linux && ! $PROMPT_COMMAND =~ _update_ps1 ]]; then
    PROMPT_COMMAND="_update_ps1; $PROMPT_COMMAND"
fi

# =============================================================================
# ALIASES AND COMPLETION SETUP
# =============================================================================
# Configure colored output and load shell completion features.

# Enable colored output for ls command
if [ -x /usr/bin/dircolors ]; then
    # Load custom color scheme if available, otherwise use default
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    # Set ls to use colors automatically
    alias ls='ls --color=auto'
fi

# Load custom aliases from separate file if it exists
# This allows keeping personal aliases organized in ~/.bash_aliases
if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi

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
# ENVIRONMENT VARIABLES
# =============================================================================
# Set up various environment variables for development tools and utilities.

# AWS credentials should be configured using 'aws configure' or ~/.aws/credentials
# (Previously contained hardcoded credentials - now removed for security)

# Set Go workspace directory for Go development
export GOPATH=~/go

# Configure less pager to interpret ANSI color sequences
# -R flag allows less to display colored output properly
export LESS='-R'

# Set up lessfilter for enhanced file viewing in less
# This allows less to display syntax highlighting and formatted content
export LESSOPEN='|~/.lessfilter %s'


