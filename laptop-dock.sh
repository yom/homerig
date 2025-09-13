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

# Window rescue configuration
readonly MIN_VISIBLE_RATIO="${MIN_VISIBLE_RATIO:-0.3}"  # Minimum ratio of window area that must be visible (0.0-1.0)
readonly MAX_WINDOW_RATIO="${MAX_WINDOW_RATIO:-0.9}"    # Maximum ratio of screen area a rescued window can occupy (0.0-1.0)

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

function get_external_displays_info() {
    # Get detailed info about external displays (connected, not primary)
    # Returns: display_name:status:resolution:rotation
    echo "$XRANDR_OUTPUT" | \
        grep ' connected' | \
        grep -v 'primary' | \
        while read -r line; do
            local display=$(echo "$line" | awk '{print $1}')
            local resolution=$(echo "$line" | grep -o '[0-9]\+x[0-9]\+' | head -1)
            local rotation=$(echo "$line" | grep -o '\(left\|right\|inverted\|normal\)' | head -1)

            # Check if display is active (has resolution configured)
            if [[ -n "$resolution" ]]; then
                echo "$display:active:$resolution:${rotation:-normal}"
            else
                echo "$display:inactive::normal"
            fi
        done
}

function get_active_external_displays() {
    # Get list of external displays that are currently active/configured
    get_external_displays_info | grep ':active:' | cut -d: -f1
}

function get_external_display_rotation() {
    # Get rotation state of a specific external display
    local display="$1"
    get_external_displays_info | grep "^$display:" | cut -d: -f4
}

function run_xrandr_cmd() {
    # Execute xrandr command with proper user context
    local xrandr_args="$1"
    local cmd="/usr/bin/xrandr --display $DISPLAY $xrandr_args"

    log_debug "Running xrandr command: $cmd"

    if [[ "$(whoami)" == "root" && -n "$X_USER" && "$X_USER" != "root" ]]; then
        su - "$X_USER" -c "DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY $cmd" 2>/dev/null || {
            log_warn "xrandr command failed: $cmd"
            return 1
        }
    else
        eval "$cmd" || {
            log_warn "xrandr command failed: $cmd"
            return 1
        }
    fi
}

function determine_action() {
    # Determine what action to take based on current display state
    # Returns: extend|rotate|unrotate|cleanup

    local connected_external=($(echo "$XRANDR_OUTPUT" | grep ' connected' | grep -v 'primary' | cut -d' ' -f1))
    local active_external=($(get_active_external_displays))

    # Check previous state to detect if external displays were unplugged
    local previous_state=$(load_previous_state)
    local had_external_before=false

    # Parse previous state to see if we had active external displays
    if [[ -n "$previous_state" ]]; then
        # Look for connected external displays in previous state
        while IFS= read -r line; do
            if [[ "$line" =~ ^[^:]+:connected$ ]] && [[ "$line" != "eDP-1:connected" ]]; then
                had_external_before=true
                break
            fi
        done <<< "$previous_state"
    fi

    log_debug "Connected external displays: ${connected_external[*]}"
    log_debug "Active external displays: ${active_external[*]}"
    log_debug "Had external displays before: $had_external_before"

    if [[ ${#connected_external[@]} -eq 0 ]]; then
        # No external displays connected
        if [[ "$had_external_before" == "true" ]]; then
            # But we had external displays before - cleanup needed
            log_debug "Action determined: cleanup (external displays were unplugged)"
            echo "cleanup"
        else
            # Nothing to do
            log_debug "Action determined: none (no external displays)"
            echo "none"
        fi
    elif [[ ${#active_external[@]} -eq 0 ]]; then
        # External displays connected but not active - extend desktop
        log_debug "Action determined: extend (external displays connected but not active)"
        echo "extend"
    else
        # External displays are active - check rotation state
        local first_active="${active_external[0]}"
        local current_rotation=$(get_external_display_rotation "$first_active")

        log_debug "First active display: $first_active, rotation: $current_rotation"

        if [[ "$current_rotation" == "normal" ]]; then
            # Currently normal - rotate it
            log_debug "Action determined: rotate (display is active and normal)"
            echo "rotate"
        else
            # Currently rotated - unrotate it
            log_debug "Action determined: unrotate (display is active and rotated)"
            echo "unrotate"
        fi
    fi
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
            # Calculate visible area ratio to determine if window is orphaned
            local visible_left=$((x > 0 ? x : 0))
            local visible_top=$((y > 0 ? y : 0))
            local visible_right=$(((x + width) < screen_width ? (x + width) : screen_width))
            local visible_bottom=$(((y + height) < screen_height ? (y + height) : screen_height))

            # Calculate visible dimensions (ensure non-negative)
            local visible_width=$((visible_right > visible_left ? (visible_right - visible_left) : 0))
            local visible_height=$((visible_bottom > visible_top ? (visible_bottom - visible_top) : 0))

            # Calculate areas
            local visible_area=$((visible_width * visible_height))
            local total_area=$((width * height))

            # Skip if window has sufficient visible area (avoid division by zero)
            if [[ $total_area -gt 0 ]]; then
                # Use integer arithmetic: visible_area * 1000 >= total_area * (MIN_VISIBLE_RATIO * 1000)
                local min_visible_area_scaled=$(echo "$total_area * $MIN_VISIBLE_RATIO * 1000" | bc -l | cut -d. -f1)
                local visible_area_scaled=$((visible_area * 1000))

                if [[ $visible_area_scaled -ge $min_visible_area_scaled ]]; then
                    log_debug "Window '$title' has sufficient visible area (${visible_area}/${total_area}), skipping"
                    continue
                fi

                log_debug "Window '$title' is orphaned with visible ratio $(echo "scale=2; $visible_area / $total_area" | bc -l) (threshold: $MIN_VISIBLE_RATIO)"
            else
                log_debug "Window '$title' has zero area, considering as orphaned"
            fi

            # Calculate target position with padding
            local new_x=$((50 + (moved_count * 30)))
            local new_y=$((50 + (moved_count * 30)))

            # Check if window needs resizing (too large for current screen)
            local max_width=$(echo "$screen_width * $MAX_WINDOW_RATIO" | bc -l | cut -d. -f1)
            local max_height=$(echo "$screen_height * $MAX_WINDOW_RATIO" | bc -l | cut -d. -f1)
            local new_width=$width
            local new_height=$height

            if [[ $width -gt $max_width || $height -gt $max_height ]]; then
                # Calculate scaling factors for both dimensions
                local scale_x_scaled=$((max_width * 1000 / width))  # Scale factor * 1000
                local scale_y_scaled=$((max_height * 1000 / height))

                # Use the smaller scale factor to preserve aspect ratio
                local scale_factor_scaled
                if [[ $scale_x_scaled -lt $scale_y_scaled ]]; then
                    scale_factor_scaled=$scale_x_scaled
                else
                    scale_factor_scaled=$scale_y_scaled
                fi

                # Apply scaling (divide by 1000 to get back to normal scale)
                new_width=$((width * scale_factor_scaled / 1000))
                new_height=$((height * scale_factor_scaled / 1000))

                log_debug "Resizing oversized window '$title' from ${width}x${height} to ${new_width}x${new_height}"
            fi

            # Ensure new position accounts for the (possibly resized) window dimensions
            if [[ $((new_x + new_width)) -gt $screen_width ]]; then
                new_x=$((screen_width - new_width - 20))
                if [[ $new_x -lt 0 ]]; then new_x=10; fi
            fi
            if [[ $((new_y + new_height)) -gt $screen_height ]]; then
                new_y=$((screen_height - new_height - 20))
                if [[ $new_y -lt 0 ]]; then new_y=10; fi
            fi

            # Move and optionally resize window
            wmctrl -i -r "$wid" -e "0,$new_x,$new_y,$new_width,$new_height" 2>/dev/null
            if [[ $new_width -ne $width || $new_height -ne $height ]]; then
                log_debug "Rescued and resized window '$title' to position ${new_x},${new_y} size ${new_width}x${new_height}"
            else
                log_debug "Rescued window '$title' to position ${new_x},${new_y}"
            fi
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

# Determine what action to take based on current display state
ACTION=$(determine_action)
log_info "Determined action: $ACTION"

case "$ACTION" in
    "none")
        log_debug "No action needed, exiting"
        exit 0
        ;;
    "extend")
        # External displays connected but not active - extend desktop
        connected_external=($(echo "$XRANDR_OUTPUT" | grep ' connected' | grep -v 'primary' | cut -d' ' -f1))

        log_info "Extending desktop to ${#connected_external[@]} external display(s): ${connected_external[*]}"

        # Turn off any disconnected displays first
        for display in $(echo "$XRANDR_OUTPUT" | grep 'disconnected' | cut -d' ' -f1); do
            run_xrandr_cmd "--output $display --off"
        done

        # Configure each connected external display with normal rotation
        for display in "${connected_external[@]}"; do
            run_xrandr_cmd "--output $display --auto --set audio on --above eDP-1 --rotate normal"
        done
        ;;
    "rotate")
        # External displays are active with normal rotation - rotate them
        active_external=($(get_active_external_displays))

        log_info "Rotating ${#active_external[@]} active external display(s): ${active_external[*]}"

        for display in "${active_external[@]}"; do
            run_xrandr_cmd "--output $display --rotate left"
        done
        ;;
    "unrotate")
        # External displays are active and rotated - unrotate them
        active_external=($(get_active_external_displays))

        log_info "Unrotating ${#active_external[@]} active external display(s): ${active_external[*]}"

        for display in "${active_external[@]}"; do
            run_xrandr_cmd "--output $display --rotate normal"
        done
        ;;
    "cleanup")
        # External displays were unplugged - turn them off and rescue windows
        log_info "Cleaning up unplugged external displays and resetting to primary display"

        # Turn off all disconnected displays and reset primary display
        run_xrandr_cmd "--output eDP-1 --primary --auto"

        for display in $(echo "$XRANDR_OUTPUT" | grep 'disconnected' | cut -d' ' -f1); do
            run_xrandr_cmd "--output $display --off"
        done

        # Wait for X11 to finish repositioning windows after display changes
        sleep 2

        # Rescue orphaned windows that may be off-screen after display reset
        log_debug "Rescuing windows after display cleanup"
        if [[ "$(whoami)" == "root" && -n "$X_USER" && "$X_USER" != "root" ]]; then
            su - "$X_USER" -c "DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY $(declare -f rescue_windows); rescue_windows" 2>/dev/null
        else
            rescue_windows
        fi
        ;;
esac


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
