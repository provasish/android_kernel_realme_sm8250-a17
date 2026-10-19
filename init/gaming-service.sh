#!/system/bin/sh
#
# Gaming Service - Init Script for Android
# Starts gaming monitor on boot
# Place in: /system/etc/init.d/99-gaming or use init.rc
#

### BEGIN INIT INFO
# Provides:          gaming-monitor
# Required-Start:    $all
# Required-Stop:
# Default-Start:     2 3 4 5
# Default-Stop:
# Description:       SM8250 Gaming Performance Monitor
### END INIT INFO

SERVICE_NAME="gaming-monitor"
SERVICE_SCRIPT="/data/adb/service.d/gaming-monitor.sh"
SERVICE_PID_FILE="/data/gaming-monitor.pid"

start_service() {
	if [ -f "$SERVICE_SCRIPT" ]; then
		echo "Starting $SERVICE_NAME..."

		# Start the monitoring daemon
		nohup "$SERVICE_SCRIPT" start > /data/gaming-monitor.log 2>&1 &
		echo $! > "$SERVICE_PID_FILE"

		echo "$SERVICE_NAME started (PID: $(cat $SERVICE_PID_FILE))"
	else
		echo "Error: $SERVICE_SCRIPT not found"
		return 1
	fi
}

stop_service() {
	echo "Stopping $SERVICE_NAME..."

	if [ -f "$SERVICE_PID_FILE" ]; then
		PID=$(cat "$SERVICE_PID_FILE")
		kill "$PID" 2>/dev/null
		rm -f "$SERVICE_PID_FILE"
	fi

	# Kill any remaining instances
	pkill -f "gaming-monitor.sh" 2>/dev/null || true

	echo "$SERVICE_NAME stopped"
}

restart_service() {
	stop_service
	sleep 1
	start_service
}

status_service() {
	if [ -f "$SERVICE_PID_FILE" ]; then
		PID=$(cat "$SERVICE_PID_FILE")
		if kill -0 "$PID" 2>/dev/null; then
			echo "$SERVICE_NAME is running (PID: $PID)"
			return 0
		fi
	fi

	echo "$SERVICE_NAME is not running"
	return 1
}

case "${1:-start}" in
	start)
		start_service
		;;
	stop)
		stop_service
		;;
	restart)
		restart_service
		;;
	status)
		status_service
		;;
	*)
		echo "Usage: $0 {start|stop|restart|status}"
		exit 1
		;;
esac

exit 0
