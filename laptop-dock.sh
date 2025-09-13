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
readonly LOGFILE="/tmp/laptop-dock-$(whoami).log"
readonly STATEFILE="/tmp/laptop-dock-state-$(whoami).txt"
readonly LOCK_TIMEOUT_SEC=5
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


# Redirect stdout/stderr to log file while preserving original
# Create log file with proper permissions
touch "$LOGFILE" 2>/dev/null || {
    echo "Warning: Cannot create log file $LOGFILE, using /dev/null" >&2
    LOGFILE="/dev/null"
}
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

function cache_xrandr_output() {
    # Call xrandr once and cache globally - handles both root and non-root contexts
    if [[ "$(whoami)" == "root" && -n "$X_USER" && "$X_USER" != "root" ]]; then
        XRANDR_OUTPUT=$(su - "$X_USER" -c "DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY xrandr -q" 2>/dev/null)
    else
        XRANDR_OUTPUT=$(xrandr -q 2>/dev/null)
    fi

    if [[ -z "$XRANDR_OUTPUT" ]]; then
        log_error "Failed to get xrandr output"
        return 1
    fi

    log_debug "Cached xrandr output successfully"
    return 0
}

function get_display_state() {
    # Get current connected displays state using cached xrandr output
    echo "$XRANDR_OUTPUT" | \
        grep -E ' (connected|disconnected)' | \
        awk '{print $1 ":" $2}' | sort
}

function get_statefile_path() {
    # Get the right state file path based on context
    if [[ "$(whoami)" == "root" && -n "$X_USER" && "$X_USER" != "root" ]]; then
        echo "/tmp/laptop-dock-state-${X_USER}.txt"
    else
        echo "$STATEFILE"
    fi
}

function save_current_state() {
    # Simple: always write as the X11 user
    local current_state="$1"
    local statefile=$(get_statefile_path)

    # Always write as the user (even when script runs as root)
    if [[ "$(whoami)" == "root" && -n "$X_USER" && "$X_USER" != "root" ]]; then
        su - "$X_USER" -c "echo '$current_state' > '$statefile'" 2>/dev/null || {
            log_error "Failed to write state file as user $X_USER: $statefile"
            return 1
        }
    else
        echo "$current_state" > "$statefile" 2>/dev/null || {
            log_error "Failed to write state file: $statefile"
            return 1
        }
    fi

    log_debug "Saved state to $statefile"
}

function load_previous_state() {
    # Simple: read file contents, empty if doesn't exist
    local statefile=$(get_statefile_path)

    if [[ -f "$statefile" ]]; then
        cat "$statefile" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

function check_and_handle_state_change() {
    # Use already cached xrandr output
    local current_state=$(get_display_state)
    local previous_state=$(load_previous_state)

    log_debug "Current: '$current_state'"
    log_debug "Previous: '$previous_state'"

    if [[ "$current_state" != "$previous_state" ]]; then
        log_debug "Display state changed, proceeding with configuration"

        # Always save current state
        save_current_state "$current_state"

        return 0  # State changed - do something
    else
        log_debug "Display state unchanged, exiting early"
        return 1  # No change - exit
    fi
}

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

    # Get current screen dimensions using xdpyinfo (more reliable than xrandr)
    local screen_info=$(xdpyinfo 2>/dev/null | grep dimensions | awk '{print $2}' | cut -d'x' -f1,2)
    local screen_width=$(echo $screen_info | cut -d'x' -f1)
    local screen_height=$(echo $screen_info | cut -d'x' -f2)

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
            log_debug "Moved window '$title' from off-screen position to ${new_x},${new_y}"
            ((moved_count++))

        done < <(wmctrl -lG 2>/dev/null | grep -v "^0x.*-1 ")

        if [[ $moved_count -gt 0 ]]; then
            log_debug "Rescued $moved_count orphaned window(s)"
        fi
    else
        log_warn "wmctrl not available - cannot rescue orphaned windows"
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
        log_debug "HDMI audio available, switching to HDMI output"
        run_using_same_user pipewire-pulse /usr/bin/pactl set-card-profile "$AUDIO_CARD" output:hdmi-stereo
    else
        log_debug "HDMI audio not available, using analog output"
        run_using_same_user pipewire-pulse /usr/bin/pactl set-card-profile "$AUDIO_CARD" output:analog-stereo+input:analog-stereo
    fi
}


# Atomic lock with cooldown to prevent rapid successive executions
# Use flock-style locking with a short cooldown period
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    log_debug "Script already running or in cooldown, exiting"
    exit 0
fi

# Clean up stale locks (older than 2 minutes)
if [[ -f "$LOCKFILE" ]]; then
    if find "$LOCKFILE" -cmin +2 2>/dev/null | grep -q .; then
        log_debug "Cleaned up stale lock file"
        rm -f "$LOCKFILE"
        exec 200>"$LOCKFILE"
        flock -n 200 || exit 0
    fi
fi

# Set up cleanup trap to maintain lock briefly after completion
cleanup_lock() {
    # Keep lock for 2 seconds after completion (reduced due to state tracking)
    sleep 2
    flock -u 200
    rm -f "$LOCKFILE"
}
trap cleanup_lock EXIT


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
        log_debug "Detected X11 session for user: $X_USER"
        export DISPLAY="$DISPLAY_ID"
        export XAUTHORITY="/home/$X_USER/.Xauthority"
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

# Parse command line options (keep -i for backward compatibility but ignore it)
while getopts ":ih" opt; do
  case ${opt} in
    i )
      # Ignore -i option for backward compatibility
      log_debug "Option -i ignored (deprecated)"
      ;;
    h )
      echo "Usage: laptop-dock.sh [-h]"
      echo "Options:"
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

# Cache xrandr output once for the entire script
if ! cache_xrandr_output; then
    log_error "Failed to get display information, exiting"
    exit 1
fi

# Check if display state has actually changed
if ! check_and_handle_state_change; then
    exit 0  # No change detected, exit early
fi

# Use cached xrandr output
xrandr_tmp=$(mktemp)
echo "$XRANDR_OUTPUT" > "$xrandr_tmp"

# Find disconnected displays to turn off
off_screens=""
disconnected_displays=()
for display in $(grep 'disconnected' "$xrandr_tmp" | cut -d' ' -f1); do
    off_screens="$off_screens --output $display --off"
    disconnected_displays+=("$display")
done

if [[ ${#disconnected_displays[@]} -gt 0 ]]; then
    log_info "Turning off ${#disconnected_displays[@]} disconnected display(s): ${disconnected_displays[*]}"
fi
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

# Lock is already acquired above with flock

# Build xrandr command
cmd="/usr/bin/xrandr --display $DISPLAY"
for i in "${!SCR[@]}"; do
    cmd="$cmd --output ${SCR[$i]} $DEF_OPTS ${POS[$i]} --rotate ${ROT[$i]}"
    log_debug "Display ${SCR[$i]}: position=${POS[$i]}, rotation=${ROT[$i]}"
done
cmd="$cmd $off_screens"

log_debug "xrandr command: $cmd"

# Smart xrandr commands: separate connect/disconnect logic
if [[ ${#SCR[@]} -gt 0 ]]; then
    # Configure connected external displays (one command per display)
    for i in "${!SCR[@]}"; do
        connect_cmd="/usr/bin/xrandr --display $DISPLAY --output ${SCR[$i]} $DEF_OPTS ${POS[$i]} --rotate ${ROT[$i]}"
        log_debug "Configuring connected display: $connect_cmd"

        if [[ "$(whoami)" == "root" && -n "$X_USER" && "$X_USER" != "root" ]]; then
            su - "$X_USER" -c "DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY $connect_cmd" 2>/dev/null || log_warn "connect command failed for ${SCR[$i]}"
        else
            eval "$connect_cmd" || log_warn "connect command failed for ${SCR[$i]}"
        fi
    done
else
    # Turn off disconnected displays when no external displays are connected
    if [[ -n "$off_screens" ]]; then
        disconnect_cmd="/usr/bin/xrandr --display $DISPLAY $off_screens"
        log_debug "Turning off disconnected displays: $disconnect_cmd"

        if [[ "$(whoami)" == "root" && -n "$X_USER" && "$X_USER" != "root" ]]; then
            su - "$X_USER" -c "DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY $disconnect_cmd" 2>/dev/null || log_warn "disconnect command failed"
        else
            eval "$disconnect_cmd" || log_warn "disconnect command failed"
        fi
    fi
fi

# If no external displays are connected, rescue orphaned windows
if [[ ${#SCR[@]} -eq 0 ]]; then
    log_debug "No external displays connected, will rescue orphaned windows after delay"

    # Wait for X11 to finish repositioning windows after display change
    sleep 1

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
    kill -USR1 "$WMAKER_PID" && log_debug "WindowMaker restart signal sent to PID $WMAKER_PID" || log_warn "Failed to send WindowMaker restart signal to PID $WMAKER_PID"
else
    log_warn "WindowMaker main process not found, skipping restart signal"
fi

# Brief delay after WindowMaker restart (reduced due to state tracking preventing spurious runs)
log_debug "Waiting for WindowMaker restart to complete"
sleep 1

# Configure audio and other settings
switch_audio


log_debug "Script completed successfully"

# Lock cleanup is handled by EXIT trap
