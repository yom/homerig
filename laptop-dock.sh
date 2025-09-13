#!/bin/bash
#
# laptop-dock.sh - Automatic display and audio configuration for laptop docking
#
# DESCRIPTION:
#   Automatically configures external displays and audio when docking/undocking
#   a laptop. Supports multiple monitor configurations and audio switching.
#
# USAGE:
#   laptop-dock.sh [-i] [-h]
#
# OPTIONS:
#   -i    Invert display positioning (swap above/right configurations)
#   -h    Show help message
#
# DEPENDENCIES:
#   - xrandr: Display configuration
#   - pactl: Audio control (PipeWire/PulseAudio)
#   - Window manager (wmaker assumed)

# Configuration constants
readonly LOCKFILE="/var/lock/laptop-dock.lock"
readonly SWAPFILE="/tmp/laptop-dock.swap"
readonly LOGFILE="/tmp/laptop-dock.log"
readonly LOCK_TIMEOUT_MIN=1
readonly DISPLAY_ID=":0"
readonly USER_HOME="/home/yom"
readonly AUDIO_SERVER="127.0.0.1"
readonly AUDIO_CARD="alsa_card.pci-0000_00_1f.3"

# Logging configuration
readonly LOG_LEVEL="${LOG_LEVEL:-INFO}"  # DEBUG, INFO, WARN, ERROR
readonly LOG_FORMAT="${LOG_FORMAT:-timestamp}"  # timestamp, simple
readonly USE_JOURNALD="${USE_JOURNALD:-true}"  # Enable journald logging

# Check if systemd-cat is available
SYSTEMD_CAT_AVAILABLE=false
if command -v systemd-cat >/dev/null 2>&1; then
    SYSTEMD_CAT_AVAILABLE=true
fi

SWAP_SCR=0

# Redirect stdout/stderr to log file while preserving original
exec 3>&1 4>&2 >>"$LOGFILE" 2>&1

# Enhanced logging function with journald support
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Skip if log level is below configured level
    case "$LOG_LEVEL" in
        "ERROR") [[ "$level" != "ERROR" ]] && return ;;
        "WARN")  [[ "$level" =~ ^(DEBUG|INFO)$ ]] && return ;;
        "INFO")  [[ "$level" == "DEBUG" ]] && return ;;
        "DEBUG") ;;
    esac
    
    # Format message
    local formatted_msg
    if [[ "$LOG_FORMAT" == "timestamp" ]]; then
        formatted_msg="[$timestamp] [$level] $message"
    else
        formatted_msg="[$level] $message"
    fi
    
    # Output to log (stdout is already redirected to logfile)
    echo "$formatted_msg"
    
    # Also send to journald if enabled and available
    if [[ "$USE_JOURNALD" == "true" && "$SYSTEMD_CAT_AVAILABLE" == "true" ]]; then
        # Map our log levels to journald priorities
        local priority
        case "$level" in
            "ERROR") priority="err" ;;
            "WARN")  priority="warning" ;;
            "INFO")  priority="info" ;;
            "DEBUG") priority="debug" ;;
            *) priority="info" ;;
        esac
        
        echo "$message" | systemd-cat -t "laptop-dock" -p "$priority"
    fi
}

# Convenience functions
log_debug() { log "DEBUG" "$@"; }
log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

function run_using_same_user() {
    local progname="$1"
    shift
    local cmd="$*"

    log_debug "Getting user for process: $progname"
    local username=$(ps -p $(pidof -s "$progname" 2>/dev/null) -o ruser= 2>/dev/null)
    
    if [[ -z "$username" ]]; then
        log_error "Could not find process: $progname"
        return 1
    fi
    
    log_debug "Running command as user '$username': $cmd"
    if [[ "$username" = "$(whoami)" ]]; then
        eval "$cmd" 2>/dev/null
    else
        su - "$username" -c "$cmd" 2>/dev/null
    fi
}

function rescue_windows() {
    log_debug "Checking for orphaned windows on disconnected displays"
    
    # Get current screen dimensions
    local screen_info=$(xrandr -q 2>/dev/null | grep "^Screen 0:" | grep -o "current [0-9]* x [0-9]*" | awk '{print $2, $4}')
    local screen_width=$(echo $screen_info | awk '{print $1}')
    local screen_height=$(echo $screen_info | awk '{print $2}')
    
    if [[ -z "$screen_width" || -z "$screen_height" ]]; then
        log_warn "Could not determine screen dimensions for window rescue"
        return 1
    fi
    
    log_debug "Screen dimensions: ${screen_width}x${screen_height}"
    
    # Use wmctrl to find and move orphaned windows
    if command -v wmctrl >/dev/null 2>&1; then
        local moved_count=0
        while IFS=' ' read -r wid desktop x y width height hostname title; do
            # Skip if window coordinates are within screen bounds
            if [[ $x -ge 0 && $y -ge 0 && $x -lt $screen_width && $y -lt $screen_height ]]; then
                continue
            fi
            
            # Move window to visible area (top-left with some padding)
            local new_x=$((50 + (moved_count * 30)))
            local new_y=$((50 + (moved_count * 30)))
            
            # Ensure new position is within bounds
            if [[ $new_x -gt $((screen_width - 200)) ]]; then new_x=50; fi
            if [[ $new_y -gt $((screen_height - 200)) ]]; then new_y=50; fi
            
            wmctrl -i -r "$wid" -e "0,$new_x,$new_y,-1,-1" 2>/dev/null
            log_info "Moved window '$title' from off-screen position to ${new_x},${new_y}"
            ((moved_count++))
            
        done < <(wmctrl -lG 2>/dev/null | grep -v "^0x.*-1 ")
        
        if [[ $moved_count -gt 0 ]]; then
            log_info "Rescued $moved_count orphaned window(s)"
        fi
    else
        log_warn "wmctrl not available - cannot rescue orphaned windows"
        log_info "Install wmctrl for automatic window management: sudo apt install wmctrl"
    fi
}

function switch_audio() {
    log_debug "Configuring audio output"
    
    # Use the X_USER detected earlier, or try to find audio user session
    local audio_user="$X_USER"
    if [[ -z "$audio_user" || "$audio_user" == "root" ]]; then
        audio_user=$(ps -eo user,comm 2>/dev/null | grep -E '(pipewire|pulseaudio)' | head -1 | awk '{print $1}')
    fi
    
    if [[ -z "$audio_user" || "$audio_user" == "root" ]]; then
        log_warn "No active user session found for audio configuration"
        return 1
    fi
    
    log_debug "Configuring audio for user: $audio_user"
    
    # Use pactl without server specification to use user's default
    local out=$(run_using_same_user pipewire-pulse /usr/bin/pactl list cards 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        log_warn "Failed to connect to audio server, skipping audio configuration"
        return 1
    fi
    
    local hdmi_avail=$(echo "$out" | grep 'output:hdmi-stereo:' | grep 'available: yes')
    
    if [[ -n "$hdmi_avail" ]]; then
        log_info "HDMI audio available, switching to HDMI output"
        run_using_same_user pipewire-pulse /usr/bin/pactl set-card-profile "$AUDIO_CARD" output:hdmi-stereo
    else
        log_info "HDMI audio not available, using analog output"
        run_using_same_user pipewire-pulse /usr/bin/pactl set-card-profile "$AUDIO_CARD" output:analog-stereo+input:analog-stereo
    fi
}


# Check for existing lock file
if [[ -f "$LOCKFILE" ]]; then
    if find "$LOCKFILE" -cmin +$LOCK_TIMEOUT_MIN 2>/dev/null | grep -q .; then
        log_warn "Removing stale lock file older than $LOCK_TIMEOUT_MIN minute(s)"
        rm -f "$LOCKFILE"
    else
        log_info "Script already running, exiting"
        exit 0
    fi
fi

# Check swap file state
if [[ -f "$SWAPFILE" ]]; then
    SWAP_SCR=1
    log_debug "Swap file found, display inversion enabled"
fi

# Set up X11 environment for udev context
if [[ "$(whoami)" == "root" ]]; then
    # Running from udev as root, need to find the user session
    # Try multiple methods to find the X11 user
    X_USER=""
    
    # Method 1: Check who owns the X server process
    X_USER=$(ps -eo user,comm 2>/dev/null | grep -E '(Xorg|X)$' | head -1 | awk '{print $1}' 2>/dev/null)
    
    # Method 2: Check for active loginctl sessions if method 1 fails
    if [[ -z "$X_USER" || "$X_USER" == "root" ]]; then
        X_USER=$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' | grep -v root | head -1 2>/dev/null)
    fi
    
    # Method 3: Fallback to checking process ownership of common desktop processes
    if [[ -z "$X_USER" ]]; then
        X_USER=$(ps -eo user,comm 2>/dev/null | grep -E '(gnome-session|kde|xfce|wmaker)' | head -1 | awk '{print $1}' 2>/dev/null)
    fi
    
    # Method 4: Final fallback - use the user who owns /tmp/.X11-unix/X0
    if [[ -z "$X_USER" && -S /tmp/.X11-unix/X0 ]]; then
        X_USER=$(stat -c %U /tmp/.X11-unix/X0 2>/dev/null)
    fi
    
    if [[ -n "$X_USER" && "$X_USER" != "root" ]]; then
        export DISPLAY="$DISPLAY_ID"
        export XAUTHORITY="/home/$X_USER/.Xauthority"
        log_info "Detected X11 session for user: $X_USER"
    else
        # Set default values even if no user detected
        export DISPLAY="$DISPLAY_ID"
        export XAUTHORITY="$USER_HOME/.Xauthority"
        log_warn "No active X11 session found, using default values"
    fi
else
    export DISPLAY="$DISPLAY_ID"
    export XAUTHORITY="$USER_HOME/.Xauthority"
    X_USER=$(whoami)
fi
log_debug "Environment set: DISPLAY=$DISPLAY, XAUTHORITY=$XAUTHORITY, USER=$X_USER"

# Parse command line options
while getopts ":ih" opt; do
  case ${opt} in
    i )
      SWAP_SCR=$(( 1 - SWAP_SCR ))
      if [[ -f "$SWAPFILE" ]]; then
          rm -f "$SWAPFILE"
          log_info "Display inversion disabled"
      else
          touch "$SWAPFILE"
          log_info "Display inversion enabled"
      fi
      ;;
    h )
      echo "Usage: laptop-dock.sh [-i] [-h]"
      echo "Options:"
      echo "    -i    Invert display positioning"
      echo "    -h    Show this help message"
      echo
      exit 0
      ;;
    \? )
      log_error "Invalid option: $OPTARG"
      exit 1
      ;;
    : )
      log_error "Invalid option: $OPTARG requires an argument"
      exit 1
      ;;
  esac
done
shift $((OPTIND -1))

# Get display information
xrandr_tmp=$(mktemp)

# Run xrandr with proper user context if we're running as root
if [[ "$(whoami)" == "root" && -n "$X_USER" && "$X_USER" != "root" ]]; then
    log_debug "Running xrandr as user $X_USER"
    su - "$X_USER" -c "DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY xrandr -q" > "$xrandr_tmp" 2>/dev/null
else
    xrandr -q > "$xrandr_tmp" 2>/dev/null
fi

# Find disconnected displays to turn off
off_screens=""
for display in $(grep 'disconnected' "$xrandr_tmp" | cut -d' ' -f1); do
    off_screens="$off_screens --output $display --off"
done
log_debug "Disconnected displays to turn off:$off_screens"

# Find connected external displays (excluding primary)
declare -a SCR POS ROT
connected_displays=$(grep ' connected' "$xrandr_tmp" | grep -v 'primary' | cut -d' ' -f1)
SCR=( $connected_displays )
if [[ ${#SCR[@]} -gt 0 ]]; then
    log_info "Found ${#SCR[@]} external display(s): ${SCR[*]}"
else
    log_debug "No external displays connected"
fi
log_debug "Raw connected displays: $(grep ' connected' "$xrandr_tmp")"
log_debug "After filtering primary: $(grep ' connected' "$xrandr_tmp" | grep -v 'primary')"

# Set display positioning and rotation based on swap state
POS=( "--above eDP-1" "--right-of eDP-1" )
ROT=("normal" "left")
if [[ $SWAP_SCR -eq 1 ]]; then
    POS=( "--right-of eDP-1" "--above eDP-1" )
    ROT=("left" "normal")
    log_debug "Using swapped display configuration"
else
    log_debug "Using default display configuration"
fi

rm -f "$xrandr_tmp"

# Set default display options
readonly DEF_OPTS="--auto --set audio on"

touch "$LOCKFILE"

# Build xrandr command
cmd="/usr/bin/xrandr --display $DISPLAY"
for i in "${!SCR[@]}"; do
    cmd="$cmd --output ${SCR[$i]} $DEF_OPTS ${POS[$i]} --rotate ${ROT[$i]}"
    log_debug "Display ${SCR[$i]}: position=${POS[$i]}, rotation=${ROT[$i]}"
done
cmd="$cmd $off_screens"

log_debug "xrandr command: $cmd"

# Execute the xrandr command with proper user context
if [[ "$(whoami)" == "root" && -n "$X_USER" && "$X_USER" != "root" ]]; then
    log_debug "Executing xrandr as user $X_USER"
    su - "$X_USER" -c "DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY $cmd" 2>/dev/null || log_warn "xrandr command failed"
else
    eval "$cmd" || log_warn "xrandr command failed"
fi

# If no external displays are connected, rescue orphaned windows
if [[ ${#SCR[@]} -eq 0 ]]; then
    if [[ "$(whoami)" == "root" && -n "$X_USER" && "$X_USER" != "root" ]]; then
        su - "$X_USER" -c "DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY $(declare -f rescue_windows); rescue_windows" 2>/dev/null
    else
        rescue_windows
    fi
fi


# Restart WindowMaker to detect display changes
log_debug "Restarting WindowMaker to refresh display configuration"
WMAKER_PID=$(pgrep -f "wmaker --for-real" | head -1)
if [[ -n "$WMAKER_PID" ]]; then
    kill -USR1 "$WMAKER_PID" && log_info "WindowMaker restart signal sent to PID $WMAKER_PID" || log_warn "Failed to send WindowMaker restart signal to PID $WMAKER_PID"
else
    log_warn "WindowMaker main process not found, skipping restart signal"
fi

# Configure audio and other settings
switch_audio

# Use the X_USER detected earlier
if [[ -n "$X_USER" && "$X_USER" != "root" ]]; then
    log_debug "Applying X11 settings for user: $X_USER"
    su - "$X_USER" -c "DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY xset b off" 2>/dev/null || log_warn "Failed to disable bell"
    su - "$X_USER" -c "DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY /usr/bin/setxkbmap -rules evdev -model evdev -layout us -variant altgr-intl" 2>/dev/null || log_warn "Failed to set keyboard layout"
else
    log_warn "No X11 session user found, skipping additional settings"
fi

rm -f "$LOCKFILE"
