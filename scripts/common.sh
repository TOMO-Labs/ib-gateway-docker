#!/bin/bash
# shellcheck disable=SC1091

apply_settings() {
	# apply env variables into IBC and gateway config files
	if [ "$CUSTOM_CONFIG" != "yes" ]; then
		echo ".> Appling settings to IBC's config.ini"

		file_env 'TWS_PASSWORD'
		# replace env variables
		envsubst <"${IBC_INI_TMPL}" >"${IBC_INI}"
		unset_env 'TWS_PASSWORD'
		# set config.ini readable by user only
		chmod 600 "${IBC_INI}"

		# where are settings stored
		if [ -n "$TWS_SETTINGS_PATH" ]; then
			echo ".> Settings directory set to: $TWS_SETTINGS_PATH"
			_JTS_PATH=$TWS_SETTINGS_PATH
			if [ ! -d "$TWS_SETTINGS_PATH" ]; then
				# if TWS_SETTINGS_PATH does not exists, create it
				echo ".> Creating directory: $TWS_SETTINGS_PATH"
				mkdir "$TWS_SETTINGS_PATH"
			fi
		else
			echo ".> Settings directory NOT set, defaulting to: $TWS_PATH"
			_JTS_PATH=$TWS_PATH
		fi
		# only if jts.ini does not exists
		if [ ! -f "$_JTS_PATH/$TWS_INI" ]; then
			echo ".> Setting timezone in ${_JTS_PATH}/${TWS_INI}"
			envsubst <"${TWS_PATH}/${TWS_INI_TMPL}" >"${_JTS_PATH}/${TWS_INI}"
		else
			echo ".> File jts.ini already exists, not setting timezone"
		fi
	else
		echo ".> Using CUSTOM_CONFIG, (value:${CUSTOM_CONFIG})"
	fi
}

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		printf >&2 'error: both %s and %s are set (but are exclusive)\n' "$var" "$fileVar"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(<"${!fileVar}")"
	fi
	export "$var"="$val"
	#unset "$fileVar"
}

# usage: unset_env VAR
#	ie: unset_env 'XYZ_DB_PASSWORD'
unset_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	if [ "${!fileVar:-}" ]; then
		unset "$var"
	fi
}

run_scripts() {
	# run start up scripts
	_start_scripts=$1
	if [ ! -d "$_start_scripts" ]; then
		echo "> No start scripts defined on $_start_scripts"
		return 0
	fi
	echo "> Running start up scripts on $_start_scripts"

	for _f in "${_start_scripts}"/*.sh; do
		echo "> Running $_f"
		[ -f "$_f" ] && bash "$_f" || echo "File $_f not found."
	done

}

set_ports() {
	# set ports for API

	# ibgateway ports
	if [ "$TRADING_MODE" = "paper" ]; then
		# paper ibgateway ports
		API_PORT=4002
		export API_PORT
	elif [ "$TRADING_MODE" = "live" ]; then
		# live ibgateway ports
		API_PORT=4001
		export API_PORT
	else
		# invalid option
		echo ".> Invalid TRADING_MODE: $TRADING_MODE"
		exit 1
	fi
	echo ".> API_PORT set to: ${API_PORT}"

}

set_java_heap() {
	# set java heap size in vm options
	if [ -n "${JAVA_HEAP_SIZE}" ]; then
		_vmpath="${TWS_PATH}/ibgateway/${IB_GATEWAY_VERSION}"
		_string="s/-Xmx768m/-Xmx${JAVA_HEAP_SIZE}m/g"
		sed -i "${_string}" "${_vmpath}/ibgateway.vmoptions"
		echo ".> Java heap size set to ${JAVA_HEAP_SIZE}m"
	else
		echo ".> Usign default Java heap size 768m."
	fi
}

port_forwarding() {
	echo ".> Starting Port Forwarding."
	# validate API port
	if [ -z "${API_PORT}" ]; then
		echo ".> API_PORT not set, port: ${API_PORT}"
		exit 1
	fi

	# Start HAProxy for port forwarding
	echo ".> Starting HAProxy"
	start_haproxy
}

start_haproxy() {
	# Check if HAProxy is already running
	if pgrep -x haproxy >/dev/null; then
		echo ".> HAProxy already active. Not starting a new one"
		return 0
	fi

	# Start HAProxy in background
	echo ".> Starting HAProxy"
	"${SCRIPT_PATH}/run_haproxy.sh" &

	# Wait briefly and verify it started
	sleep 2
	if pgrep -x haproxy >/dev/null; then
		echo ".> HAProxy started successfully"
	else
		echo ".> WARNING: HAProxy may have failed to start"
	fi
}
