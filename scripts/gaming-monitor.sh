#!/bin/bash
#
# Gaming Process Monitor - Phase 3
# Automatically detects game launch and applies optimizations
# Usage: gaming-monitor.sh [start|stop|status]
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSFS_GAMEMODE="/sys/kernel/gamemode"
LOG_FILE="/var/log/gaming-monitor.log"

# Gaming app patterns
GAME_PATTERNS=(
	"com.tencent.ig"         # PUBG Mobile
	"com.pubg.krmobile"      # PUBG: Battlegrounds
	"com.pubg.imobile"       # BGMI
	"com.tencent.tmgp"       # Tencent Gaming Platform
)

# Performance core mask (SM8250: cores 6,7 = Gold cluster)
PERF_CORES="6,7"
ALL_CORES="0-7"

# CPU governor
PERF_GOVERNOR="performance"
NORMAL_GOVERNOR="schedutil"

log_msg() {
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
	echo "$*"
}

# Enable game mode optimizations
enable_game_mode() {
	local pid=$1
	local app=$2

	log_msg "=== GAME MODE ENABLED ==="
	log_msg "PID: $pid, App: $app"

	# Set CPU governor to performance
	for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
		echo "$PERF_GOVERNOR" > "$cpu" 2>/dev/null
	done
	log_msg "CPU Governor: $PERF_GOVERNOR"

	# Set CPU boost
	echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null
	log_msg "CPU Boost: Enabled"

	# Set process affinity to performance cores (if available)
	if command -v taskset &> /dev/null; then
		taskset -p -c "$PERF_CORES" "$pid" 2>/dev/null || true
		log_msg "Thread Affinity: $PERF_CORES"
	fi

	# Increase process priority
	if command -v renice &> /dev/null; then
		renice -n -10 -p "$pid" 2>/dev/null || true
		log_msg "Process Priority: -10"
	fi

	# Apply sysctl gaming profiles
	if [ -f "$SCRIPT_DIR/sysctl.d/99-gaming-performance.conf" ]; then
		sysctl -p "$SCRIPT_DIR/sysctl.d/99-gaming-performance.conf" > /dev/null 2>&1
		log_msg "Applied: 99-gaming-performance.conf"
	fi

	if [ -f "$SCRIPT_DIR/sysctl.d/98-gaming-scheduler.conf" ]; then
		sysctl -p "$SCRIPT_DIR/sysctl.d/98-gaming-scheduler.conf" > /dev/null 2>&1
		log_msg "Applied: 98-gaming-scheduler.conf"
	fi

	# Set I/O scheduler to Kyber
	for device in /sys/block/*/queue/scheduler; do
		if [ -w "$device" ]; then
			echo "kyber" > "$device" 2>/dev/null || true
		fi
	done
	log_msg "I/O Scheduler: kyber"

	# Increase dirty page thresholds for better I/O
	sysctl -w vm.dirty_ratio=10 > /dev/null 2>&1
	sysctl -w vm.dirty_background_ratio=5 > /dev/null 2>&1
	log_msg "Dirty page tuning: applied"

	log_msg "Game mode optimizations active"
}

# Disable game mode (restore normal settings)
disable_game_mode() {
	log_msg "=== GAME MODE DISABLED ==="

	# Restore default CPU governor
	for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
		echo "$NORMAL_GOVERNOR" > "$cpu" 2>/dev/null
	done
	log_msg "CPU Governor: $NORMAL_GOVERNOR"

	# Reset I/O scheduler
	for device in /sys/block/*/queue/scheduler; do
		if [ -w "$device" ]; then
			echo "kyber" > "$device" 2>/dev/null || true
		fi
	done

	log_msg "Game mode disabled, normal settings restored"
}

# Check if a process is a game
is_game_process() {
	local comm=$1
	for pattern in "${GAME_PATTERNS[@]}"; do
		if [[ "$comm" == *"$pattern"* ]]; then
			return 0
		fi
	done
	return 1
}

# Monitor process creation
monitor_games() {
	log_msg "Gaming monitor started (PID: $$)"

	# Use fanotify or inotify to watch process creation
	# For now, use polling method
	while true; do
		# Check running processes
		for pid in $(pgrep -f "render\|game\|pubg\|bgmi" 2>/dev/null); do
			if [ -r "/proc/$pid/comm" ]; then
				comm=$(cat "/proc/$pid/comm" 2>/dev/null)
				if is_game_process "$comm"; then
					# Check if this PID is not yet optimized
					if [ ! -f "/tmp/game_optimized_$pid" ]; then
						enable_game_mode "$pid" "$comm"
						touch "/tmp/game_optimized_$pid"
					fi
				fi
			fi
		done

		# Clean up stale optimization flags
		for pidfile in /tmp/game_optimized_*; do
			pid=${pidfile##*_}
			if ! kill -0 "$pid" 2>/dev/null; then
				rm -f "$pidfile"
				disable_game_mode
			fi
		done

		sleep 2
	done
}

# Show current status
show_status() {
	echo "=== Gaming Monitor Status ==="
	echo "Monitor running: $(pgrep -f 'gaming-monitor.sh' > /dev/null && echo 'Yes' || echo 'No')"
	echo "Game mode kernel module: $([ -d "$SYSFS_GAMEMODE" ] && echo 'Loaded' || echo 'Not loaded')"

	if [ -d "$SYSFS_GAMEMODE" ]; then
		echo "Game mode enabled: $(cat $SYSFS_GAMEMODE/enabled 2>/dev/null || echo 'N/A')"
	fi

	echo ""
	echo "Active game processes:"
	for pid in $(pgrep -f "render\|game\|pubg\|bgmi" 2>/dev/null); do
		comm=$(cat "/proc/$pid/comm" 2>/dev/null)
		is_game_process "$comm" && echo "  $pid: $comm"
	done
}

case "${1:-status}" in
	start)
		monitor_games &
		echo "Gaming monitor started (PID: $!)"
		;;
	stop)
		pkill -f "gaming-monitor.sh"
		disable_game_mode
		echo "Gaming monitor stopped"
		;;
	status)
		show_status
		;;
	*)
		echo "Usage: $0 {start|stop|status}"
		exit 1
		;;
esac
