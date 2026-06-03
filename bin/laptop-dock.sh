#!/bin/bash

# Early help option parsing (before any setup or logging)
for arg in "$@"; do
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
        echo "Usage: laptop-dock.sh [-h]"
        echo "Options:"
        echo "    -h    Show this help message"
        echo
        exit 0
    fi
done

#
# laptop-dock.sh - Automatic display and audio configuration for laptop docking
#
# DESCRIPTION:
#   Automatically configures external displays and audio when docking/undocking
#   a laptop. Supports multiple monitor configurations and audio switching.
#
# USAGE:
#   laptop-dock.sh [-h]
#
# OPTIONS:
#   -h    Show help message
#
# DEPENDENCIES:
#   - xrandr: Display configuration
#   - pactl: Audio control (PipeWire/PulseAudio)
#   - Window manager (wmaker assumed)

# Configuration constants
readonly LOCKFILE="/tmp/laptop-dock-$(whoami).lock"
readonly LOGFILE="/tmp/laptop-dock-$(whoami).log"
readonly USER_HOME="${HOME:-/home/$(whoami)}"
readonly PRIMARY_DISPLAY="${PRIMARY_DISPLAY:-eDP-1}"
readonly AUDIO_CARD="${AUDIO_CARD:-}"


# Runtime configuration
readonly LOG_LEVEL="${LOG_LEVEL:-INFO}"
readonly DRY_RUN="${DRY_RUN:-false}"



# Redirect stdout/stderr to log file while preserving original
# Create log file with proper permissions
touch "$LOGFILE" 2>/dev/null || {
    echo "Warning: Cannot create log file $LOGFILE, using /dev/null" >&2
    LOGFILE="/dev/null"
}
exec 3>&1 4>&2 >>"$LOGFILE" 2>&1

# Simple logging function
log() {
    local level="$1"
    shift
    local message="$*"

    # Skip if log level is below configured level
    case "$LOG_LEVEL" in
        "ERROR") [[ "$level" != "ERROR" ]] && return ;;
        "WARN")  [[ "$level" =~ ^(DEBUG|INFO)$ ]] && return ;;
        "INFO")  [[ "$level" == "DEBUG" ]] && return ;;
        "DEBUG") ;;
    esac

    # Format message with timestamp
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local formatted_msg="[$timestamp] [$level] $message"

    # Output to log (stdout is already redirected to logfile)
    echo "$formatted_msg"
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
    [[ -n "$1" ]] || { echo "ERROR: die() called without error message" >&2; exit 1; }
    local exit_code=${2:-1}

    # Validate exit code
    if [[ ! "$exit_code" =~ ^[0-9]+$ ]] || [[ "$exit_code" -lt 0 ]] || [[ "$exit_code" -gt 255 ]]; then
        echo "ERROR: Invalid exit code '$exit_code', using 1" >&2
        exit_code=1
    fi

    log_error "$1"
    cleanup_and_exit "$exit_code"
}


# Cleanup function called on exit
cleanup_and_exit() {
    local exit_code=${1:-0}

    # Validate exit code
    if [[ ! "$exit_code" =~ ^[0-9]+$ ]] || [[ "$exit_code" -lt 0 ]] || [[ "$exit_code" -gt 255 ]]; then
        echo "ERROR: Invalid exit code '$exit_code', using 0" >&2
        exit_code=0
    fi

    # Cleanup resources
    # Close file descriptors
    exec 3>&- 4>&- 2>/dev/null || true

    # Cleanup lock if we have it
    if [[ -n "$LOCKFILE" && -f "$LOCKFILE" ]]; then
        flock -u 200 2>/dev/null || true
        exec 200>&- 2>/dev/null || true
        rm -f "$LOCKFILE" 2>/dev/null || true
    fi

    exit "$exit_code"
}

# === USER CONTEXT & PERMISSION HELPERS ===
is_running_as_root_for_user() {
    [[ "$(whoami)" == "root" && -n "$X_USER" && "$X_USER" != "root" ]]
}

run_as_x_user() {
    # Validate inputs
    [[ -n "$1" ]] || { log_error "run_as_x_user: No command provided"; return 1; }

    if is_running_as_root_for_user; then
        # Validate X_USER to prevent injection
        if [[ ! "$X_USER" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            log_error "run_as_x_user: Invalid X_USER format: $X_USER"
            return 1
        fi

        # Validate DISPLAY format
        if [[ ! "$DISPLAY" =~ ^:[0-9]+(\.[0-9]+)?$ ]]; then
            log_error "run_as_x_user: Invalid DISPLAY format: $DISPLAY"
            return 1
        fi

        # Use arrays to prevent injection
        local env_vars=(
            "DISPLAY=$DISPLAY"
            "XAUTHORITY=$XAUTHORITY"
        )
        local cmd_array=("$@")

        # Build command safely using printf %q
        local safe_cmd="$(printf '%q ' "${env_vars[@]}") $(printf '%q ' "${cmd_array[@]}")"
        su - "$X_USER" -c "$safe_cmd" 2>/dev/null
    else
        "$@" 2>/dev/null
    fi
}

# Run command as the same user that owns a specific process
run_as_process_user() {
    local process_name="$1"
    shift

    # Validate inputs
    [[ -n "$process_name" ]] || { log_error "run_as_process_user: No process name provided"; return 1; }
    [[ -n "$1" ]] || { log_error "run_as_process_user: No command provided"; return 1; }

    # Validate process name format to prevent injection
    if [[ ! "$process_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "run_as_process_user: Invalid process name format: $process_name"
        return 1
    fi

    log_debug "Getting user for process: $process_name"
    local pid
    if ! pid=$(pidof -s "$process_name" 2>/dev/null); then
        log_error "run_as_process_user: Could not find process: $process_name"
        return 1
    fi

    local username
    if ! username=$(ps -p "$pid" -o ruser= 2>/dev/null); then
        log_error "run_as_process_user: Could not get user for process: $process_name (PID: $pid)"
        return 1
    fi

    # Validate username format
    if [[ ! "$username" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "run_as_process_user: Invalid username format: $username"
        return 1
    fi

    log_debug "Running command as user '$username': $*"
    if [[ "$username" = "$(whoami)" ]]; then
        "$@" 2>/dev/null
    else
        # Use printf %q for safe quoting
        local safe_cmd
        safe_cmd=$(printf '%q ' "$@")
        su - "$username" -c "$safe_cmd" 2>/dev/null
    fi
}

# Dependency validation function
check_dependencies() {
    local missing=()
    local required_commands=(
        "xrandr:Display configuration (x11-xserver-utils)"
        "xdpyinfo:Display information (x11-utils)"
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
        log_error "cache_xrandr_output: Failed to get xrandr output"
        return 1
    fi

    log_debug "Cached xrandr output successfully"
    return 0
}

get_display_state() {
    # Get current connected displays state using cached xrandr output
    echo "$XRANDR_OUTPUT" | \
        grep -E " (connected|disconnected)" | \
        awk '{print $1 ":" $2}' | sort
}

get_external_displays_info() {
    # Get detailed info about external displays (connected, not primary)
    # Returns: display_name:status:resolution:rotation
    echo "$XRANDR_OUTPUT" | \
        grep " connected" | \
        grep -v "primary" | \
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
    [[ -n "$display" ]] || { log_error "get_external_display_rotation: No display name provided"; return 1; }

    get_external_displays_info | grep "^$display:" | cut -d: -f4
}

run_xrandr_cmd() {
    # Execute xrandr command with proper user context with retry
    local xrandr_args="$1"
    [[ -n "$xrandr_args" ]] || { log_error "run_xrandr_cmd: No arguments provided"; return 1; }

    # Validate DISPLAY format to prevent injection
    [[ "$DISPLAY" =~ ^:[0-9]+(\.[0-9]+)?$ ]] || {
        log_error "run_xrandr_cmd: Invalid DISPLAY format: $DISPLAY"
        return 1
    }

    # Build command safely using printf %q for argument quoting
    local cmd="/usr/bin/xrandr --display $(printf '%q' "$DISPLAY") $xrandr_args"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would execute: $cmd"
        return 0
    fi

    log_debug "Running xrandr command: $cmd"

    # Use retry for xrandr commands as they can be flaky during display transitions
    local attempt=1
    local delay=1

    while [[ $attempt -le 3 ]]; do
        log_debug "Attempt $attempt/3: xrandr command: $xrandr_args"

        if run_as_x_user bash -c "/usr/bin/xrandr --display $(printf '%q' "$DISPLAY") $xrandr_args"; then
            log_debug "xrandr command succeeded on attempt $attempt"
            return 0
        fi

        if [[ $attempt -eq 3 ]]; then
            log_error "run_xrandr_cmd: Command failed after 3 attempts"
            return 1
        fi

        log_warn "xrandr command failed (attempt $attempt/3), retrying in ${delay}s..."
        sleep "$delay"
        delay=$((delay * 2))
        ((attempt++))
    done
}

determine_action() {
    # Determine what action to take based on current display state
    # Returns: extend|rotate|unrotate|cleanup

    local connected_external
    readarray -t connected_external < <(echo "$XRANDR_OUTPUT" | grep " connected" | grep -v "primary" | cut -d' ' -f1)

    local active_external
    readarray -t active_external < <(get_active_external_displays)

    log_debug "Connected external displays: ${connected_external[*]}"
    log_debug "Active external displays: ${active_external[*]}"

    local action
    if [[ ${#connected_external[@]} -eq 0 ]]; then
        # No external displays connected - run cleanup/window rescue
        log_debug "Action determined: cleanup (no external displays, rescue any orphaned windows)"
        action="cleanup"
    elif [[ ${#active_external[@]} -eq 0 ]]; then
        # External displays connected but not active - extend desktop (no rotation)
        log_debug "Action determined: extend (external displays connected but not active)"
        action="extend"
    else
        # External displays are active - check rotation state to toggle
        local first_active="${active_external[0]}"
        local current_rotation
        current_rotation=$(get_external_display_rotation "$first_active")

        # Handle edge case where rotation detection fails
        if [[ -z "$current_rotation" ]]; then
            log_warn "Could not determine rotation for display $first_active, defaulting to normal"
            current_rotation="normal"
        fi

        log_debug "First active display: $first_active, rotation: $current_rotation"

        if [[ "$current_rotation" == "normal" ]]; then
            # Currently normal - rotate it
            log_debug "Action determined: rotate (display is active and normal)"
            action="rotate"
        else
            # Currently rotated - unrotate it
            log_debug "Action determined: unrotate (display is active and rotated)"
            action="unrotate"
        fi
    fi

    # Return clean action result without any contamination
    echo "$action" >&3
}

get_action() {
    # Wrapper function to get clean action result
    determine_action 3>&1 >/dev/null
}



# === WINDOW MANAGEMENT FUNCTIONS ===

# Wait for window positions to stabilize after display changes
wait_for_window_stabilization() {
    local max_wait_seconds=${1:-5}

    # Validate timeout parameter
    if [[ ! "$max_wait_seconds" =~ ^[0-9]+$ ]] || [[ "$max_wait_seconds" -lt 1 ]] || [[ "$max_wait_seconds" -gt 30 ]]; then
        log_error "wait_for_window_stabilization: Invalid timeout '$max_wait_seconds' (must be 1-30 seconds)"
        return 1
    fi

    # Simple wait - just give X11 some time to finish moving windows
    if command -v wmctrl >/dev/null 2>&1; then
        log_debug "Waiting ${max_wait_seconds}s for window positions to stabilize"
        sleep "$max_wait_seconds"
    else
        log_debug "wmctrl not available - using shorter wait"
        sleep 2
    fi
}


# Simple window rescue function - just move obviously off-screen windows
simple_window_rescue() {
    # Check if required tools are available
    if ! command -v xdpyinfo >/dev/null 2>&1 || ! command -v wmctrl >/dev/null 2>&1; then
        log_debug "Window rescue tools not available, skipping"
        return 0
    fi

    # Get screen dimensions
    local screen_info
    if ! screen_info=$(xdpyinfo 2>&1 | grep dimensions | awk '{print $2}' | cut -d'x' -f1,2); then
        log_debug "Could not get screen dimensions, skipping window rescue"
        return 0
    fi

    local screen_width screen_height
    screen_width=$(echo "$screen_info" | cut -d'x' -f1)
    screen_height=$(echo "$screen_info" | cut -d'x' -f2)

    if [[ -z "$screen_width" || -z "$screen_height" || "$screen_width" -le 0 || "$screen_height" -le 0 ]]; then
        log_debug "Invalid screen dimensions, skipping window rescue"
        return 0
    fi

    log_debug "Rescuing off-screen windows (screen: ${screen_width}x${screen_height})"

    # Simple rescue: move any window that's completely off-screen to top-left
    local moved_count=0
    local rescue_x=50
    local rescue_y=50

    while IFS=' ' read -r wid desktop x y width height hostname title; do
        # Skip if window has invalid dimensions
        [[ "$width" -gt 0 && "$height" -gt 0 ]] || continue

        # Check if window is completely off-screen (simple check)
        if [[ "$x" -ge "$screen_width" || "$y" -ge "$screen_height" || $((x + width)) -le 0 || $((y + height)) -le 0 ]]; then
            # Reset cascade when it would go off-screen
            local cascade_x=$((moved_count * 30))
            local cascade_y=$((moved_count * 30))

            # If cascade would exceed screen bounds, reset to base position
            if [[ $((rescue_x + cascade_x + width)) -gt "$screen_width" ]] || [[ $((rescue_y + cascade_y + height)) -gt "$screen_height" ]]; then
                cascade_x=0
                cascade_y=0
                moved_count=0  # Reset counter
            fi

            local new_x=$((rescue_x + cascade_x))
            local new_y=$((rescue_y + cascade_y))

            # Final bounds check to ensure window fits on screen
            if [[ $((new_x + width)) -gt "$screen_width" ]]; then
                new_x=$((screen_width - width - 20))
            fi
            if [[ $((new_y + height)) -gt "$screen_height" ]]; then
                new_y=$((screen_height - height - 20))
            fi

            # Ensure minimum position
            [[ "$new_x" -lt 10 ]] && new_x=10
            [[ "$new_y" -lt 10 ]] && new_y=10

            wmctrl -i -r "$wid" -e "0,$new_x,$new_y,$width,$height" 2>/dev/null && {
                log_debug "Rescued window '$title' from ($x,$y) to ($new_x,$new_y)"
                ((moved_count++))
            }
        fi
    done < <(wmctrl -lG 2>/dev/null | grep -v "^0x.*-1 ")

    [[ "$moved_count" -gt 0 ]] && log_debug "Rescued $moved_count window(s)"
}

# Run window rescue with proper user context
run_window_rescue() {
    if is_running_as_root_for_user; then
        # Validate environment variables before using them
        [[ "$DISPLAY" =~ ^:[0-9]+(\.[0-9]+)?$ ]] || {
            log_error "run_window_rescue: Invalid DISPLAY format: $DISPLAY"
            return 1
        }

        # Run as user with validated environment
        local env_cmd="DISPLAY=$(printf '%q' "$DISPLAY") XAUTHORITY=$(printf '%q' "$XAUTHORITY")"
        local rescue_cmd="$(declare -f simple_window_rescue log_debug); simple_window_rescue"

        su - "$X_USER" -c "$env_cmd $rescue_cmd" 2>/dev/null
    else
        simple_window_rescue
    fi
}

# === AUDIO MANAGEMENT FUNCTIONS ===

# Detect audio user session
detect_audio_user() {
    local audio_user="$X_USER"
    if [[ -z "$audio_user" || "$audio_user" == "root" ]]; then
        audio_user=$(ps -eo user,comm 2>/dev/null | grep -E '(pipewire|pulseaudio)' | head -1 | awk '{print $1}')
    fi

    if [[ -z "$audio_user" || "$audio_user" == "root" ]]; then
        return 1
    fi

    echo "$audio_user"
}

# Check if HDMI audio is available
is_hdmi_audio_available() {
    local card_info="$1"
    [[ -n "$card_info" ]] || { log_error "is_hdmi_audio_available: No card info provided"; return 1; }

    echo "$card_info" | grep "output:hdmi-stereo:" | grep -q "available: yes"
}

switch_audio() {
    log_debug "Configuring audio output"

    if [[ -z "$AUDIO_CARD" ]]; then
        log_warn "switch_audio: AUDIO_CARD not set in ~/.config/dotfiles/local.env, skipping audio configuration"
        return 0
    fi

    local audio_user
    if ! audio_user=$(detect_audio_user); then
        log_warn "switch_audio: No active user session found for audio configuration"
        return 1
    fi

    log_debug "Configuring audio for user: $audio_user"

    # Use pactl without server specification to use user's default
    local card_info
    if ! card_info=$(run_as_process_user pipewire-pulse /usr/bin/pactl list cards 2>&1); then
        log_warn "switch_audio: Failed to connect to audio server, skipping audio configuration"
        return 1
    fi

    if is_hdmi_audio_available "$card_info"; then
        log_debug "HDMI audio available, switching to HDMI output"
        run_as_process_user pipewire-pulse /usr/bin/pactl set-card-profile "$AUDIO_CARD" output:hdmi-stereo
    else
        log_debug "HDMI audio not available, using analog output"
        run_as_process_user pipewire-pulse /usr/bin/pactl set-card-profile "$AUDIO_CARD" output:analog-stereo+input:analog-stereo
    fi
}

# === ACTION HANDLERS ===

# Common post-action handler: wait for windows to stabilize and rescue orphaned ones
finalize_display_change() {
    local action_description="$1"
    local timeout_seconds="$2"

    [[ -n "$action_description" ]] || { log_error "finalize_display_change: No action description provided"; return 1; }
    [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || { log_error "finalize_display_change: Invalid timeout '$timeout_seconds'"; return 1; }

    # Wait for window positions to stabilize after display changes
    wait_for_window_stabilization "$timeout_seconds"

    # Rescue orphaned windows that may be off-screen
    log_debug "Rescuing windows after $action_description"
    run_window_rescue
}

handle_extend_action() {
    # External displays connected but not active - extend desktop
    local connected_external
    readarray -t connected_external < <(echo "$XRANDR_OUTPUT" | grep " connected" | grep -v "primary" | cut -d' ' -f1)

    log_info "Extending desktop to ${#connected_external[@]} external display(s): ${connected_external[*]}"

    # Store original display state for rollback
    local original_state
    original_state=$(get_display_state)

    # Turn off any disconnected displays first
    for display in $(echo "$XRANDR_OUTPUT" | grep "disconnected" | cut -d' ' -f1); do
        if ! run_xrandr_cmd "--output $display --off"; then
            log_error "Failed to turn off disconnected display $display, continuing..."
        fi
    done

    # Configure each connected external display with normal rotation
    local failed_displays=()
    for display in "${connected_external[@]}"; do
        if ! run_xrandr_cmd "--output $display --auto --above $PRIMARY_DISPLAY --rotate normal"; then
            log_error "Failed to configure display $display"
            failed_displays+=("$display")
        fi
    done

    # If any display configuration failed, attempt recovery
    if [[ ${#failed_displays[@]} -gt 0 ]]; then
        log_warn "Display configuration failed for: ${failed_displays[*]}"
        log_info "Attempting to restore primary display configuration"
        run_xrandr_cmd "--output $PRIMARY_DISPLAY --primary --auto" || {
            log_error "Critical: Failed to restore primary display configuration"
            return 1
        }
    fi

    finalize_display_change "display extension" 5
}

handle_rotate_action() {
    # External displays are active with normal rotation - rotate them
    local active_external
    readarray -t active_external < <(get_active_external_displays)

    log_info "Rotating ${#active_external[@]} active external display(s): ${active_external[*]}"

    # Store original rotation states for rollback
    local -A original_rotations
    for display in "${active_external[@]}"; do
        original_rotations["$display"]=$(get_external_display_rotation "$display")
    done

    local failed_displays=()
    for display in "${active_external[@]}"; do
        if ! run_xrandr_cmd "--output $display --rotate left"; then
            log_error "Failed to rotate display $display"
            failed_displays+=("$display")
        fi
    done

    # If rotation failed, attempt to restore original rotations
    if [[ ${#failed_displays[@]} -gt 0 ]]; then
        log_warn "Rotation failed for displays: ${failed_displays[*]}"
        for display in "${failed_displays[@]}"; do
            local orig_rotation="${original_rotations[$display]:-normal}"
            log_info "Restoring original rotation '$orig_rotation' for display $display"
            run_xrandr_cmd "--output $display --rotate $orig_rotation" || \
                log_error "Failed to restore rotation for $display"
        done
    fi

    finalize_display_change "display rotation" 5
}

handle_unrotate_action() {
    # External displays are active and rotated - unrotate them
    local active_external
    readarray -t active_external < <(get_active_external_displays)

    log_info "Unrotating ${#active_external[@]} active external display(s): ${active_external[*]}"

    for display in "${active_external[@]}"; do
        run_xrandr_cmd "--output $display --rotate normal"
    done

    finalize_display_change "display unrotation" 5
}

handle_cleanup_action() {
    # External displays were unplugged - turn them off and rescue windows
    log_info "Cleaning up unplugged external displays and resetting to primary display"

    # Turn off all disconnected displays and reset primary display
    run_xrandr_cmd "--output $PRIMARY_DISPLAY --primary --auto"

    for display in $(echo "$XRANDR_OUTPUT" | grep "disconnected" | cut -d' ' -f1); do
        run_xrandr_cmd "--output $display --off"
    done

    finalize_display_change "display cleanup" 5
}

# === MAIN EXECUTION FLOW ===

# Simple file locking to prevent concurrent executions
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    log_debug "Script already running, exiting"
    exit 0
fi

# Set up cleanup trap
trap 'cleanup_and_exit $?' EXIT INT TERM


# Set up X11 environment for udev context
if [[ "$(whoami)" == "root" ]]; then
    # Running from udev as root, need to find the user session
    # Method 1: Check who owns the X server process
    X_USER=$(ps -eo user,comm 2>/dev/null | grep -E '(Xorg|X)$' | head -1 | awk '{print $1}' 2>/dev/null)

    # Method 2: Fallback - use the user who owns /tmp/.X11-unix/X0
    if [[ -z "$X_USER" || "$X_USER" == "root" ]] && [[ -S /tmp/.X11-unix/X0 ]]; then
        X_USER=$(stat -c %U /tmp/.X11-unix/X0 2>/dev/null)
    fi

    if [[ -n "$X_USER" && "$X_USER" != "root" ]]; then
        log_debug "Detected X11 session for user: $X_USER"
        export DISPLAY=":0"
        export XAUTHORITY="/home/$X_USER/.Xauthority"
    else
        # Set default values if no user detected
        export DISPLAY=":0"
        export XAUTHORITY="$USER_HOME/.Xauthority"
        log_warn "No active X11 session found, using default values"
    fi
else
    export DISPLAY=":0"
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
      die "Invalid option: $OPTARG"
      ;;
    : )
      die "Invalid option: $OPTARG requires an argument"
      ;;
  esac
done
shift $((OPTIND -1))

# Check dependencies before proceeding
check_dependencies

# Cache xrandr output once for the entire script
cache_xrandr_output || die "Failed to get display information"

# Determine what action to take based on current display state
action=$(get_action)
log_info "Determined action: $action"

# Validate action to prevent crashes
if [[ ! "$action" =~ ^(extend|rotate|unrotate|cleanup)$ ]]; then
    log_error "Invalid action '$action' returned by determine_action(), defaulting to cleanup"
    action="cleanup"
fi

case "$action" in
    "extend")
        handle_extend_action
        ;;
    "rotate")
        handle_rotate_action
        ;;
    "unrotate")
        handle_unrotate_action
        ;;
    "cleanup")
        handle_cleanup_action
        ;;
    *)
        log_warn "Unknown action '$action', defaulting to cleanup"
        handle_cleanup_action
        ;;
esac


# Restart WindowMaker to detect display changes
log_debug "Restarting WindowMaker to refresh display configuration"
# Find the correct WindowMaker process (the one with --for-real argument)
WMAKER_PID=$(pgrep -f "wmaker.*--for-real" 2>/dev/null | head -1)
if [[ -n "$WMAKER_PID" && "$WMAKER_PID" =~ ^[0-9]+$ ]]; then
    if kill -USR1 "$WMAKER_PID" 2>/dev/null; then
        log_debug "WindowMaker restart signal sent to PID $WMAKER_PID"
    else
        log_warn "Failed to send WindowMaker restart signal to PID $WMAKER_PID"
    fi
else
    log_warn "WindowMaker main process not found, skipping restart signal"
fi

# Brief delay after WindowMaker restart
log_debug "Waiting for WindowMaker restart to complete"
sleep 2

# Configure audio and other settings
switch_audio

# No state saving needed - script logic is stateless

log_debug "Script completed successfully"

# Lock cleanup is handled by EXIT trap
