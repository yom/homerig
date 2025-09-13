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
readonly DISPLAY_ID="${DISPLAY_ID:-:0}"
readonly USER_HOME="${USER_HOME:-/home/$(logname 2>/dev/null || echo ${USER:-yom})}"
readonly AUDIO_SERVER="${AUDIO_SERVER:-127.0.0.1}"
readonly AUDIO_CARD="${AUDIO_CARD:-alsa_card.pci-0000_00_1f.3}"

# Display configuration constants
readonly PRIMARY_DISPLAY="${PRIMARY_DISPLAY:-eDP-1}"
readonly DISPLAY_POSITION="${DISPLAY_POSITION:-above}"  # above, right, left, below
readonly DISPLAY_ROTATION="${DISPLAY_ROTATION:-left}"   # left, right, inverted, normal

# Window rescue configuration
readonly WINDOW_RESCUE_MARGIN="${WINDOW_RESCUE_MARGIN:-20}"      # Margin from screen edges
readonly WINDOW_CASCADE_OFFSET="${WINDOW_CASCADE_OFFSET:-30}"    # Offset between rescued windows
readonly WINDOW_BASE_POSITION="${WINDOW_BASE_POSITION:-50}"      # Base position for first rescued window

# Logging configuration
readonly LOG_LEVEL="${LOG_LEVEL:-INFO}"  # DEBUG, INFO, WARN, ERROR
readonly LOG_FORMAT="${LOG_FORMAT:-timestamp}"  # timestamp, simple
readonly USE_JOURNALD="${USE_JOURNALD:-true}"  # Enable journald logging

# Window rescue area configuration
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

# === LOGGING FUNCTIONS ===

# Convenience functions
log_debug() { log "DEBUG" "$@"; }
log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# === ERROR HANDLING FUNCTIONS ===

# Exit with error message and cleanup
die() {
    local exit_code=${2:-1}
    log_error "$1"
    cleanup_and_exit "$exit_code"
}

# Retry function with exponential backoff
retry() {
    local max_attempts="$1"
    local delay="$2"
    local description="$3"
    shift 3

    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        log_debug "Attempt $attempt/$max_attempts: $description"

        if "$@"; then
            log_debug "$description succeeded on attempt $attempt"
            return 0
        fi

        if [[ $attempt -eq $max_attempts ]]; then
            log_error "$description failed after $max_attempts attempts"
            return 1
        fi

        log_warn "$description failed (attempt $attempt/$max_attempts), retrying in ${delay}s..."
        sleep "$delay"
        delay=$((delay * 2))  # Exponential backoff
        ((attempt++))
    done
}

# Safe command execution with error handling
safe_run() {
    local description="$1"
    shift

    log_debug "Executing: $description"
    if ! "$@"; then
        log_error "Failed to execute: $description"
        return 1
    fi
    log_debug "Successfully executed: $description"
    return 0
}

# Cleanup function called on exit
cleanup_and_exit() {
    local exit_code=${1:-0}

    # Cleanup lock if we have it
    if [[ -n "$LOCKFILE" && -f "$LOCKFILE" ]]; then
        flock -u 200 2>/dev/null || true
        rm -f "$LOCKFILE" 2>/dev/null || true
    fi

    exit "$exit_code"
}

# === USER CONTEXT & PERMISSION HELPERS ===
is_running_as_root_for_user() {
    [[ "$(whoami)" == "root" && -n "$X_USER" && "$X_USER" != "root" ]]
}

run_as_x_user() {
    if is_running_as_root_for_user; then
        su - "$X_USER" -c "DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY $(printf '%q ' "$@")" 2>/dev/null
    else
        "$@" 2>/dev/null
    fi
}

# Dependency validation function
check_dependencies() {
    local missing=()
    local required_commands=(
        "xrandr:Display configuration (x11-xserver-utils)"
        "xdpyinfo:Display information (x11-utils)"
        "bc:Calculator for arithmetic (bc)"
    )
    local optional_commands=(
        "wmctrl:Window management for rescue feature (wmctrl)"
        "pactl:Audio switching (pulseaudio-utils)"
        "systemd-cat:Journald logging (systemd)"
    )

    # Check required dependencies
    for cmd_info in "${required_commands[@]}"; do
        local cmd="${cmd_info%%:*}"
        local desc="${cmd_info#*:}"
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd ($desc)")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        printf '%s\n' "${missing[@]}" | sed 's/^/  - /' >&2
        die "Missing required dependencies listed above"
    fi

    # Check optional dependencies and warn
    local optional_missing=()
    for cmd_info in "${optional_commands[@]}"; do
        local cmd="${cmd_info%%:*}"
        local desc="${cmd_info#*:}"
        if ! command -v "$cmd" >/dev/null 2>&1; then
            optional_missing+=("$cmd ($desc)")
        fi
    done

    if [[ ${#optional_missing[@]} -gt 0 ]]; then
        log_warn "Optional dependencies missing (some features may be disabled):"
        for dep in "${optional_missing[@]}"; do
            log_warn "  - $dep"
        done
    fi

    log_debug "Dependency check completed successfully"
    return 0
}

# === DISPLAY MANAGEMENT FUNCTIONS ===

cache_xrandr_output() {
    # Call xrandr once and cache globally - handles both root and non-root contexts
    XRANDR_OUTPUT=$(run_as_x_user xrandr -q)

    if [[ -z "$XRANDR_OUTPUT" ]]; then
        log_error "Failed to get xrandr output"
        return 1
    fi

    log_debug "Cached xrandr output successfully"
    return 0
}

get_display_state() {
    # Get current connected displays state using cached xrandr output
    echo "$XRANDR_OUTPUT" | \
        grep -E ' (connected|disconnected)' | \
        awk '{print $1 ":" $2}' | sort
}

get_external_displays_info() {
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

get_active_external_displays() {
    # Get list of external displays that are currently active/configured
    get_external_displays_info | grep ':active:' | cut -d: -f1
}

get_external_display_rotation() {
    # Get rotation state of a specific external display
    local display="$1"
    get_external_displays_info | grep "^$display:" | cut -d: -f4
}

run_xrandr_cmd() {
    # Execute xrandr command with proper user context with retry
    local xrandr_args="$1"
    local cmd="/usr/bin/xrandr --display $DISPLAY $xrandr_args"

    log_debug "Running xrandr command: $cmd"

    # Use retry for xrandr commands as they can be flaky during display transitions
    local attempt=1
    local max_attempts=3
    local delay=1

    while [[ $attempt -le $max_attempts ]]; do
        log_debug "Attempt $attempt/$max_attempts: xrandr command: $xrandr_args"

        if run_as_x_user bash -c "$cmd"; then
            log_debug "xrandr command succeeded on attempt $attempt"
            return 0
        fi

        if [[ $attempt -eq $max_attempts ]]; then
            log_error "xrandr command failed after $max_attempts attempts"
            return 1
        fi

        log_warn "xrandr command failed (attempt $attempt/$max_attempts), retrying in ${delay}s..."
        sleep "$delay"
        delay=$((delay * 2))
        ((attempt++))
    done
}

determine_action() {
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
            if [[ "$line" =~ ^[^:]+:connected$ ]] && [[ "$line" != "$PRIMARY_DISPLAY:connected" ]]; then
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

# === STATE MANAGEMENT FUNCTIONS ===

get_statefile_path() {
    # Get the right state file path based on context
    if [[ "$(whoami)" == "root" && -n "$X_USER" && "$X_USER" != "root" ]]; then
        echo "/tmp/laptop-dock-state-${X_USER}.txt"
    else
        echo "$STATEFILE"
    fi
}

save_current_state() {
    # Simple: always write as the X11 user
    local current_state="$1"
    local statefile=$(get_statefile_path)

    # Always write as the user (even when script runs as root)
    run_as_x_user bash -c "echo '$current_state' > '$statefile'" || {
        log_error "Failed to write state file: $statefile"
        return 1
    }

    log_debug "Saved state to $statefile"
}

load_previous_state() {
    # Simple: read file contents, empty if doesn't exist
    local statefile=$(get_statefile_path)

    if [[ -f "$statefile" ]]; then
        cat "$statefile" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

run_using_same_user() {
    local progname="$1"
    shift

    log_debug "Getting user for process: $progname"
    local username=$(ps -p $(pidof -s "$progname" 2>/dev/null) -o ruser= 2>/dev/null)

    if [[ -z "$username" ]]; then
        log_error "Could not find process: $progname"
        return 1
    fi

    log_debug "Running command as user '$username': $*"
    if [[ "$username" = "$(whoami)" ]]; then
        "$@" 2>/dev/null
    else
        su - "$username" -c "$(printf '%q ' "$@")" 2>/dev/null
    fi
}

# === WINDOW MANAGEMENT FUNCTIONS ===

# Window rescue helper functions
calculate_visible_area() {
    local x=$1 y=$2 width=$3 height=$4 screen_width=$5 screen_height=$6

    # Calculate intersection rectangle
    local visible_left=$((x > 0 ? x : 0))
    local visible_top=$((y > 0 ? y : 0))
    local visible_right=$(((x + width) < screen_width ? (x + width) : screen_width))
    local visible_bottom=$(((y + height) < screen_height ? (y + height) : screen_height))

    # Calculate visible dimensions (ensure non-negative)
    local visible_width=$((visible_right > visible_left ? (visible_right - visible_left) : 0))
    local visible_height=$((visible_bottom > visible_top ? (visible_bottom - visible_top) : 0))

    # Return visible area
    echo $((visible_width * visible_height))
}

is_window_orphaned() {
    local x=$1 y=$2 width=$3 height=$4 screen_width=$5 screen_height=$6 title="$7"

    local total_area=$((width * height))
    [[ $total_area -eq 0 ]] && { log_debug "Window '$title' has zero area, considering as orphaned"; return 0; }

    local visible_area=$(calculate_visible_area "$x" "$y" "$width" "$height" "$screen_width" "$screen_height")

    # Use integer arithmetic: visible_area * 1000 >= total_area * (MIN_VISIBLE_RATIO * 1000)
    local min_visible_area_scaled=$(echo "$total_area * $MIN_VISIBLE_RATIO * 1000" | bc -l | cut -d. -f1)
    local visible_area_scaled=$((visible_area * 1000))

    if [[ $visible_area_scaled -ge $min_visible_area_scaled ]]; then
        log_debug "Window '$title' has sufficient visible area (${visible_area}/${total_area}), skipping"
        return 1  # Not orphaned
    fi

    log_debug "Window '$title' is orphaned with visible ratio $(echo "scale=2; $visible_area / $total_area" | bc -l) (threshold: $MIN_VISIBLE_RATIO)"
    return 0  # Is orphaned
}

calculate_new_window_size() {
    local width=$1 height=$2 screen_width=$3 screen_height=$4

    local max_width=$(echo "$screen_width * $MAX_WINDOW_RATIO" | bc -l | cut -d. -f1)
    local max_height=$(echo "$screen_height * $MAX_WINDOW_RATIO" | bc -l | cut -d. -f1)

    if [[ $width -le $max_width && $height -le $max_height ]]; then
        echo "$width $height"  # No resizing needed
        return 0
    fi

    # Calculate scaling factors for both dimensions
    local scale_x_scaled=$((max_width * 1000 / width))
    local scale_y_scaled=$((max_height * 1000 / height))

    # Use the smaller scale factor to preserve aspect ratio
    local scale_factor_scaled
    if [[ $scale_x_scaled -lt $scale_y_scaled ]]; then
        scale_factor_scaled=$scale_x_scaled
    else
        scale_factor_scaled=$scale_y_scaled
    fi

    # Apply scaling (divide by 1000 to get back to normal scale)
    local new_width=$((width * scale_factor_scaled / 1000))
    local new_height=$((height * scale_factor_scaled / 1000))

    echo "$new_width $new_height"
}

position_rescued_window() {
    local new_width=$1 new_height=$2 screen_width=$3 screen_height=$4 moved_count=$5

    # Calculate target position with padding
    local new_x=$((WINDOW_BASE_POSITION + (moved_count * WINDOW_CASCADE_OFFSET)))
    local new_y=$((WINDOW_BASE_POSITION + (moved_count * WINDOW_CASCADE_OFFSET)))

    # Ensure new position accounts for the window dimensions
    if [[ $((new_x + new_width)) -gt $screen_width ]]; then
        new_x=$((screen_width - new_width - WINDOW_RESCUE_MARGIN))
        if [[ $new_x -lt 0 ]]; then new_x=10; fi
    fi
    if [[ $((new_y + new_height)) -gt $screen_height ]]; then
        new_y=$((screen_height - new_height - WINDOW_RESCUE_MARGIN))
        if [[ $new_y -lt 0 ]]; then new_y=10; fi
    fi

    echo "$new_x $new_y"
}

rescue_windows() {
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
            # Check if window is orphaned
            if ! is_window_orphaned "$x" "$y" "$width" "$height" "$screen_width" "$screen_height" "$title"; then
                continue
            fi

            # Calculate new window size (may be resized to fit screen)
            local new_size=($(calculate_new_window_size "$width" "$height" "$screen_width" "$screen_height"))
            local new_width=${new_size[0]}
            local new_height=${new_size[1]}

            if [[ $new_width -ne $width || $new_height -ne $height ]]; then
                log_debug "Resizing oversized window '$title' from ${width}x${height} to ${new_width}x${new_height}"
            fi

            # Calculate position for rescued window
            local new_position=($(position_rescued_window "$new_width" "$new_height" "$screen_width" "$screen_height" "$moved_count"))
            local new_x=${new_position[0]}
            local new_y=${new_position[1]}

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

# === AUDIO MANAGEMENT FUNCTIONS ===

switch_audio() {
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

# === ACTION HANDLERS ===

handle_extend_action() {
    # External displays connected but not active - extend desktop
    local connected_external=($(echo "$XRANDR_OUTPUT" | grep ' connected' | grep -v 'primary' | cut -d' ' -f1))

    log_info "Extending desktop to ${#connected_external[@]} external display(s): ${connected_external[*]}"

    # Turn off any disconnected displays first
    for display in $(echo "$XRANDR_OUTPUT" | grep 'disconnected' | cut -d' ' -f1); do
        run_xrandr_cmd "--output $display --off"
    done

    # Configure each connected external display with normal rotation
    for display in "${connected_external[@]}"; do
        run_xrandr_cmd "--output $display --auto --set audio on --$DISPLAY_POSITION $PRIMARY_DISPLAY --rotate normal"
    done
}

handle_rotate_action() {
    # External displays are active with normal rotation - rotate them
    local active_external=($(get_active_external_displays))

    log_info "Rotating ${#active_external[@]} active external display(s): ${active_external[*]}"

    for display in "${active_external[@]}"; do
        run_xrandr_cmd "--output $display --rotate $DISPLAY_ROTATION"
    done
}

handle_unrotate_action() {
    # External displays are active and rotated - unrotate them
    local active_external=($(get_active_external_displays))

    log_info "Unrotating ${#active_external[@]} active external display(s): ${active_external[*]}"

    for display in "${active_external[@]}"; do
        run_xrandr_cmd "--output $display --rotate normal"
    done
}

handle_cleanup_action() {
    # External displays were unplugged - turn them off and rescue windows
    log_info "Cleaning up unplugged external displays and resetting to primary display"

    # Turn off all disconnected displays and reset primary display
    run_xrandr_cmd "--output $PRIMARY_DISPLAY --primary --auto"

    for display in $(echo "$XRANDR_OUTPUT" | grep 'disconnected' | cut -d' ' -f1); do
        run_xrandr_cmd "--output $display --off"
    done

    # Wait for X11 to finish repositioning windows after display changes
    sleep 2

    # Rescue orphaned windows that may be off-screen after display reset
    log_debug "Rescuing windows after display cleanup"
    if is_running_as_root_for_user; then
        su - "$X_USER" -c "DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY $(declare -f rescue_windows); rescue_windows" 2>/dev/null
    else
        rescue_windows
    fi
}

# === MAIN EXECUTION FLOW ===

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

# Set up cleanup trap
trap 'cleanup_and_exit $?' EXIT INT TERM


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

# Check dependencies before proceeding
check_dependencies

# Cache xrandr output once for the entire script
cache_xrandr_output || die "Failed to get display information"

# Determine what action to take based on current display state
ACTION=$(determine_action)
log_info "Determined action: $ACTION"

case "$ACTION" in
    "none")
        log_debug "No action needed, exiting"
        exit 0
        ;;
    "extend")
        handle_extend_action
        # Wait for X11 to complete display configuration changes before WindowMaker restart
        sleep 1
        ;;
    "rotate")
        handle_rotate_action
        ;;
    "unrotate")
        handle_unrotate_action
        ;;
    "cleanup")
        handle_cleanup_action
        # Wait for X11 to complete display configuration changes before WindowMaker restart
        sleep 1
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
