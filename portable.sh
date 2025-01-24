#!/bin/bash

function pecho() {
	if [[ $1 =~ debug ]] && [[ ${PORTABLE_LOGGING} = "debug" ]]; then
		echo "[Debug] $2"
	elif [[ $1 =~ info ]] && [[ ${PORTABLE_LOGGING} = "info" ]] || [[ ${PORTABLE_LOGGING} = "debug" ]]; then
		echo "[Info] $2"
	elif [[ $1 =~ warn ]]; then
		echo "[Warn] $2"
	elif [[ $1 =~ crit ]]; then
		echo "[Critical] $2"
	fi
}

if [[ ${_portalConfig} ]] && [[ "${_portableConfig}" ]]; then
	pecho crit "No portable config specified!"
	exit 1
fi

if [ ${_portalConfig} ]; then
	export _portableConfig="${_portalConfig}"
	pecho warn "Using legacy configuration variable!"
fi

if [ -f "${_portableConfig}" ]; then
	pecho \
		info \
		"Configuration specified as absolute path: ${_portableConfig}"
	source "${_portableConfig}"
else
	if [[ -f "/usr/lib/portable/info/${_portableConfig}/config" ]]; then
		pecho \
			info \
			"Configuration specified as global name /usr/lib/portable/info/${_portableConfig}/config"
		source "/usr/lib/portable/info/${_portableConfig}/config"
		export _portableConfig="/usr/lib/portable/info/${_portableConfig}/config"
	elif [[ -f "$(pwd)/${_portableConfig}" ]]; then
		pecho \
			info \
			"Configuration specified as relative path ${_portableConfig}"
		source "$(pwd)/${_portableConfig}"
		export _portableConfig="$(pwd)/${_portableConfig}"
	else
		pecho \
			crit \
			"Specified config cannot be found!"
		exit 1
	fi
fi

busName="${appID}"
busDir="${XDG_RUNTIME_DIR}/app/${busName}"
busDirAy="${XDG_RUNTIME_DIR}/app/${busName}-a11y"
unitName="${friendlyName}"
proxyName="${friendlyName}-dbus"

function sourceXDG() {
	if [[ ! ${XDG_CONFIG_HOME} ]]; then
		export XDG_CONFIG_HOME="${HOME}"/.config
		pecho info "Guessing XDG Config Home @ ${XDG_CONFIG_HOME}"
	else
		source "${XDG_CONFIG_HOME}"/user-dirs.dirs
		pecho info "XDG Config Home defined @ ${XDG_CONFIG_HOME}"
	fi
	if [[ ! ${XDG_DATA_HOME} ]]; then
		export XDG_DATA_HOME="${HOME}"/.local/share
	fi
	export XDG_DOCUMENTS_DIR="$(xdg-user-dir DOCUMENTS)"
}

function manageDirs() {
	createWrapIfNotExist "${XDG_DATA_HOME}"/${stateDirectory}
	rm -r "${XDG_DATA_HOME}/${stateDirectory}/Shared"
	mkdir -p "${XDG_DATA_HOME}/${stateDirectory}/Shared"
	ln -sfr \
		"${XDG_DATA_HOME}/${stateDirectory}/Shared" \
		"${XDG_DATA_HOME}/${stateDirectory}/共享文件"
}

function genXAuth() {
	if [ ${waylandOnly} = "true" ]; then
		touch "${XDG_DATA_HOME}/${stateDirectory}/.XAuthority"
		return $?
	fi
	pecho debug "Processing X Server security restriction..."
	rm "${XDG_DATA_HOME}/${stateDirectory}/.XAuthority"
	touch "${XDG_DATA_HOME}/${stateDirectory}/.XAuthority"
	pecho debug "Detecting display as ${DISPLAY}"
	if [[ $(xauth list ${DISPLAY} | head -n 1) =~ "$(hostnamectl --static)/unix: " ]]; then
		pecho warn "Adding new display..."
		export authHash="$(xxd -p -l 16 /dev/urandom)"
		xauth \
			add \
			"${DISPLAY}" \
			. \
			"${authHash}"
		xauth -f \
			"${XDG_DATA_HOME}/${stateDirectory}/.XAuthority" \
			add $(xauth list ${DISPLAY} | head -n 1)
	else
		xauth -f \
			"${XDG_DATA_HOME}/${stateDirectory}/.XAuthority" \
			add $(xauth list ${DISPLAY} | head -n 1)
	fi
	if [ ! -f "${HOME}/.XAuthority"  ] && [ -z "${XAUTHORITY}" ]; then
		pecho warn "Could not determine XAuthority file path"
		xhost +localhost
	fi
	xauth \
		-f "${XDG_DATA_HOME}/${stateDirectory}/.XAuthority" \
		list >/dev/null
	if [ $? = 0 ]; then
		return 0
	else
		pecho warn "Turning off X access control for localhost"
		xauth +localhost
	fi
}

function waylandDisplay() {
	if [ ${XDG_SESSION_TYPE} = x11 ]; then
		pecho debug "Skipped wayland detection"
		wayDisplayBind="/$(uuidgen)/$(uuidgen)"
		return 0
	fi
	if [ -z ${WAYLAND_DISPLAY} ]; then
		pecho debug "WAYLAND_DISPLAY not set, defaulting to wayland-0"
		wayDisplayBind="${XDG_RUNTIME_DIR}/wayland-0"
	fi
	if [ -f "${WAYLAND_DISPLAY}" ]; then
		pecho debug "Wayland display is specified as an absolute path"
		export wayDisplayBind="${WAYLAND_DISPLAY}"
	elif [[ "${WAYLAND_DISPLAY}" =~ 'wayland-' ]]; then
		pecho debug "Detected Wayland display as ${WAYLAND_DISPLAY}"
		export wayDisplayBind="${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}"
	fi
}

function createWrapIfNotExist() {
	if [ -d "$@" ]; then
		return 0
	else
		mkdir -p "$@"
	fi
}

function inputMethod() {
	if [[ ${waylandOnly} = true ]]; then
		export QT_IM_MODULE=wayland
		export GTK_IM_MODULE=wayland
		IBUS_USE_PORTAL=1
	fi
	if [[ ${XMODIFIERS} =~ fcitx ]] || [[ ${QT_IM_MODULE} =~ fcitx ]] || [[ ${GTK_IM_MODULE} =~ fcitx ]]; then
		export QT_IM_MODULE=fcitx
		export GTK_IM_MODULE=fcitx
	elif [[ ${XMODIFIERS} =~ ibus ]] || [[ ${QT_IM_MODULE} =~ ibus ]] || [[ ${GTK_IM_MODULE} =~ ibus ]]; then
		export QT_IM_MODULE=ibus
		export GTK_IM_MODULE=ibus
		IBUS_USE_PORTAL=1
	elif [[ ${XMODIFIERS} =~ gcin ]]; then
		export QT_IM_MODULE=ibus
		export GTK_IM_MODULE=gcin
		export LC_CTYPE=zh_TW.UTF-8
	else
		pecho warn 'Input Method potentially broken! Please set $XMODIFIERS properly'
		# Guess the true IM based on running processes
		runningProcess=$(ps -U $(whoami))
		if [[ ${runningProcess} =~ "ibus-daemon" ]]; then
			pecho warn "Guessing Input Method as iBus"
			export QT_IM_MODULE=ibus
			export GTK_IM_MODULE=ibus
			export XMODIFIERS=@im=ibus
		elif [[ ${runningProcess} =~ "fcitx" ]]; then
			pecho warn "Guessing Input Method as Fcitx"
			export QT_IM_MODULE=fcitx
			export GTK_IM_MODULE=fcitx
			export XMODIFIERS=@im=fcitx
		fi
	fi
}

function importEnv() {
	inputMethod
	genXAuth
	cat "${_portableConfig}" >"${XDG_DATA_HOME}/${stateDirectory}/portable-generated.env"
	printf "\n\n" >>"${XDG_DATA_HOME}/${stateDirectory}/portable-generated.env"
	printf "\n\n" >>"${XDG_DATA_HOME}/${stateDirectory}/portable-generated.env"
	if [ -e "${XDG_DATA_HOME}"/${stateDirectory}/portable.env ]; then
		pecho info "${XDG_DATA_HOME}/${stateDirectory}/portable.env exists"
	else
		touch "${XDG_DATA_HOME}"/${stateDirectory}/portable.env
	fi
	if [ -s "${XDG_DATA_HOME}"/${stateDirectory}/portable.env ]; then
		cat "${XDG_DATA_HOME}"/${stateDirectory}/portable.env >>"${XDG_DATA_HOME}/${stateDirectory}/portable-generated.env"
	else
		echo "# Envs" >>"${XDG_DATA_HOME}"/${stateDirectory}/portable.env
		echo "isPortableEnvPresent=1" >>"${XDG_DATA_HOME}"/${stateDirectory}/portable.env
	fi
	PW_V4L2_LD_PRELOAD="/usr/lib/pipewire-0.3/v4l2/libpw-v4l2.so"
	if [ "${LD_PRELOAD}" = "" ]; then
		export LD_PRELOAD="$PW_V4L2_LD_PRELOAD"
	else
		export LD_PRELOAD="${LD_PRELOAD} ${PW_V4L2_LD_PRELOAD}"
	fi
	addEnv "LD_PRELOAD=${LD_PRELOAD}"
	addEnv 'GDK_DEBUG=portals'
	addEnv 'GTK_USE_PORTAL=1'
	addEnv 'QT_AUTO_SCREEN_SCALE_FACTOR=1'
	addEnv "GTK_IM_MODULE=${GTK_IM_MODULE}"
	addEnv "QT_IM_MODULE=${QT_IM_MODULE}"
	addEnv "QT_ENABLE_HIGHDPI_SCALING=1"
	addEnv "PATH=/sandbox:${PATH}"
	addEnv "DISPLAY=${DISPLAY}"
	addEnv "QT_SCALE_FACTOR=${QT_SCALE_FACTOR}"
}

function getChildPid() {
	cGroup=$(systemctl --user show "${unitName}" -p ControlGroup | cut -c '14-')
	for childPid in $(pgrep --cgroup "${cGroup}"); do
		pecho debug "Trying PID ${childPid}"
		cmdlineArg=$(cat /proc/${childPid}/cmdline | tr '\000' ' ')
		if [[ ${cmdlineArg} =~ '/usr/bin/bwrap' ]]; then
			pecho debug "Detected bwrap"
		else
			if [[ "${cmdlineArg}" =~ "${launchTarget}" ]]; then
				export childPid=${childPid}
				return 0
			fi
		fi
	done
}

function enterSandbox() {
	if [ ! $(systemctl --user is-active ${unitName}.service) = active ]; then
		pecho crit "Application not running"
		exit 1
	fi
	pecho debug "Starting program in sandbox: $@"
	getChildPid
	if [ -z ${childPid} ]; then
		pecho crit "Failed to determine child PID"
		exit 1
	fi
	pecho debug "procps-ng returned child ${childPid}"
	systemd-run -P \
		-p Slice="portable-${unitName}.slice" \
		-p BindsTo="${proxyName}.service" \
		-u "${unitName}-subprocess-$(uuidgen)" \
		-p EnvironmentFile="${XDG_DATA_HOME}/${stateDirectory}/portable-generated.env" \
		-p Environment=XAUTHORITY="${HOME}/.XAuthority" \
		-p DevicePolicy=strict \
		-p NoNewPrivileges=yes \
		-p KeyringMode=private \
		--user \
		-- nsenter \
			--user \
			--user-parent \
			--preserve-credentials \
			-t ${childPid} \
		nsenter \
			--mount \
			--uts \
			--ipc \
			--user \
			-t ${childPid} \
			--preserve-credentials \
			$@
	return $?
}

function execApp() {
	waylandDisplay
	importEnv
	deviceBinding
	mkdir -p "${XDG_DATA_HOME}"/"${stateDirectory}"/.config
	if [ ! ${bwBindPar} ]; then
		bwBindPar="/$(uuidgen)"
	else
		pecho warn "bwBindPar is ${bwBindPar}"
	fi
	systemd-run \
	--user \
	${sdOption} \
	-u "${unitName}" \
	-p BindsTo="${proxyName}.service" \
	-p Description="Portable Sandbox for ${appID}" \
	-p Documentation="https://github.com/Kraftland/portable" \
	-p Slice="portable-${unitName}.slice" \
	-p ExitType=cgroup \
	-p OOMPolicy=stop \
	-p KillMode=control-group \
	-p LimitCORE=0 \
	-p CPUAccounting=yes \
	-p StartupCPUWeight=idle \
	-p StartupIOWeight=1 \
	-p MemoryHigh=90% \
	-p ManagedOOMSwap=kill \
	-p ManagedOOMMemoryPressure=kill \
	-p IPAccounting=yes \
	-p EnvironmentFile="${XDG_DATA_HOME}/${stateDirectory}/portable-generated.env" \
	-p SystemCallFilter=~@clock \
	-p SystemCallFilter=~@cpu-emulation \
	-p SystemCallFilter=~@debug \
	-p SystemCallFilter=~@module \
	-p SystemCallFilter=~@obsolete \
	-p SystemCallFilter=~@resources \
	-p SystemCallFilter=~@raw-io \
	-p SystemCallFilter=~@reboot \
	-p SystemCallFilter=~@swap \
	-p SystemCallErrorNumber=EPERM \
	-p PrivateIPC=yes \
	-p ProtectClock=yes \
	-p CapabilityBoundingSet= \
	-p ProtectKernelModules=yes \
	-p RestrictSUIDSGID=yes \
	-p LockPersonality=yes \
	-p RestrictRealtime=yes \
	-p ProtectSystem=strict \
	-p ProtectProc=invisible \
	-p ProcSubset=pid \
	-p ProtectHome=no \
	-p PrivateUsers=yes \
	-p UMask=077 \
	-p DevicePolicy=strict \
	-p NoNewPrivileges=yes \
	-p ProtectControlGroups=yes \
	-p PrivateMounts=yes \
	-p KeyringMode=private \
	-p TimeoutStopSec=20s \
	-p BindReadOnlyPaths=/usr/bin/true:/usr/bin/lsblk \
	-p Environment=XAUTHORITY="${HOME}/.XAuthority" \
	-- \
	bwrap --new-session \
		--unshare-cgroup-try \
		--unshare-ipc \
		--unshare-uts \
		--unshare-pid \
		--unshare-user \
		--ro-bind "${XDG_DATA_HOME}/${stateDirectory}"/flatpak-info \
			/.flatpak-info \
		--tmpfs /tmp \
  		--bind-try /tmp/.X11-unix /tmp/.X11-unix \
    		--bind-try /tmp/.XIM-unix /tmp/.XIM-unix \
		--dev /dev \
		--dev-bind /dev/dri /dev/dri \
		${bwInputArg} \
		${bwSwitchableGraphicsArg} \
		--tmpfs /sys \
		--bind /sys/module/ /sys/module/ \
		--ro-bind /sys/dev/char /sys/dev/char \
		--ro-bind /sys/devices /sys/devices \
		--tmpfs /sys/devices/virtual/dmi \
		--dir /sandbox \
		--ro-bind /usr/lib/portable/open \
			/sandbox/chromium \
		--ro-bind /usr/lib/portable/open \
			/sandbox/firefox \
		--ro-bind /usr/lib/portable/open \
			/sandbox/dde-file-manager \
		--ro-bind /usr/lib/portable/open \
			/sandbox/xdg-open \
		--ro-bind /usr/lib/portable/open \
			/sandbox/open \
		--ro-bind /usr/lib/portable/open \
			/sandbox/nautilus \
		--ro-bind /usr/lib/portable/open \
			/sandbox/dolphin \
		--ro-bind /usr/lib/portable/mimeapps.list \
			"${XDG_DATA_HOME}/${stateDirectory}/.config/mimeapps.list" \
		--proc /proc \
		--ro-bind-try /dev/null /proc/uptime \
		--ro-bind-try /dev/null /proc/modules \
		--ro-bind-try /dev/null /proc/cmdline \
		--ro-bind-try /dev/null /proc/diskstats \
		--ro-bind-try /dev/null /proc/devices \
		--ro-bind-try /dev/null /proc/config.gz \
		--ro-bind-try /dev/null /proc/version \
		--tmpfs /proc/1 \
		--bind-try /dev/null /proc/meminfo \
		--bind-try /dev/null /proc/cpuinfo \
		--bind /usr /usr \
		--tmpfs /usr/share/applications \
		--ro-bind /etc /etc \
		--symlink /usr/lib /lib \
		--symlink /usr/lib /lib64 \
		--ro-bind-try /bin /bin \
		--ro-bind-try /sbin /sbin \
		--ro-bind-try /opt /opt \
		--bind "${busDir}" "${XDG_RUNTIME_DIR}" \
		--bind "${busDirAy}" "${XDG_RUNTIME_DIR}/at-spi" \
		--dir /run/host \
		--ro-bind "${XDG_DATA_HOME}/${stateDirectory}"/flatpak-info \
			"${XDG_RUNTIME_DIR}/.flatpak-info" \
		--ro-bind-try "${XDG_RUNTIME_DIR}/pulse" \
			"${XDG_RUNTIME_DIR}/pulse" \
		${pipewireBinding} \
		--bind "${XDG_RUNTIME_DIR}/doc/by-app/${appID}" \
			"${XDG_RUNTIME_DIR}"/doc \
		--ro-bind /dev/null \
			"${XDG_RUNTIME_DIR}"/.flatpak/"${instanceId}-private/run-environ" \
		--bind "${XDG_DATA_HOME}/${stateDirectory}" "${HOME}" \
		--ro-bind-try "${XDG_DATA_HOME}"/icons \
			"${XDG_DATA_HOME}"/icons \
		--ro-bind-try "${XDG_CONFIG_HOME}"/gtk-4.0 \
			"${XDG_CONFIG_HOME}"/gtk-4.0 \
		--ro-bind-try "${XDG_CONFIG_HOME}"/gtk-3.0 \
			"${XDG_CONFIG_HOME}"/gtk-3.0 \
		--ro-bind-try "${wayDisplayBind}" \
				"${wayDisplayBind}" \
		--ro-bind /usr/lib/portable/user-dirs.dirs \
			"${XDG_CONFIG_HOME}"/user-dirs.dirs \
		--ro-bind-try "${XDG_CONFIG_HOME}"/fontconfig \
			"${XDG_CONFIG_HOME}"/fontconfig \
		--ro-bind-try "${XDG_DATA_HOME}/fonts" \
			"${XDG_DATA_HOME}/fonts" \
		--ro-bind-try "/run/systemd/resolve/stub-resolv.conf" \
			"/run/systemd/resolve/stub-resolv.conf" \
		--dir "${XDG_DATA_HOME}/${stateDirectory}/Documents" \
		--bind "${XDG_DATA_HOME}/${stateDirectory}" \
			"${XDG_DATA_HOME}/${stateDirectory}" \
		--tmpfs "${XDG_DATA_HOME}/${stateDirectory}"/options \
		--ro-bind-try /dev/null \
			"${XDG_DATA_HOME}/${stateDirectory}"/portable.env \
		--bind-try "${bwBindPar}" "${bwBindPar}" \
		${bwCamPar} \
		--setenv XDG_DOCUMENTS_DIR "$HOME/Documents" \
		--setenv XDG_DATA_HOME "${XDG_DATA_HOME}" \
		-- \
			${launchTarget}
}

function execAppExist() {
	export sdOption="-P"
	export unitName="${unitName}-subprocess-$(uuidgen)"
	execApp
	status=$?
	export unitName="$@"
	return ${status}
}

function shareFile() {
	if [[ ${trashAppUnsafe} = 1 ]]; then
		zenity \
			--error \
			--title "Sandbox disabled" \
			--text "Feature is intended for sandbox users"
		pecho crit "Sandbox is disabled"
		exit 1
	fi
	fileList=$(zenity --file-selection --multiple | tail -n 1)
	IFS='|' read -r -a filePaths <<< "${fileList}"
	for filePath in "${filePaths[@]}"; do
		pecho info "User selected path: ${filePath}"
		cp -a \
			"${filePath}" \
			"${XDG_DATA_HOME}/${stateDirectory}/Shared"
	done
	exit 0
}

function addEnv() {
	echo "$@" >>"${XDG_DATA_HOME}/${stateDirectory}/portable-generated.env"
}

function deviceBinding() {
	if [[ ${gameMode} = true ]]; then
		bwSwitchableGraphicsArg=""
		pecho debug "Binding all GPUs in Game Mode"
		ls /dev/nvidia* 2>/dev/null 1>/dev/null
		lsStatus=$?
		if [ "${lsStatus}" = 0 ]; then
			pecho debug "Binding NVIDIA GPUs"
			for _card in $(ls /dev/nvidia*); do
				if [ -e ${_card} ]; then
					bwSwitchableGraphicsArg="${bwSwitchableGraphicsArg} --dev-bind ${_card} ${_card}"
				fi
			done
			pecho debug "Specifying environment variables for dGPU utilization"
			addEnv '__NV_PRIME_RENDER_OFFLOAD=1'
			addEnv '__VK_LAYER_NV_optimus=NVIDIA_only'
			addEnv '__GLX_VENDOR_LIBRARY_NAME=nvidia'
			addEnv 'VK_LOADER_DRIVERS_SELECT=nvidia_icd.json'
		fi
	else
		pecho debug "Detecting GPU..."
		bwSwitchableGraphicsArg=""
		videoMod=$(lsmod)
		if [ $(ls /dev/dri/renderD* -la | wc -l) = 1 ] && [[ ${videoMod} =~ nvidia ]]; then
			pecho info "Using single NVIDIA GPU"
			for _card in $(ls /dev/nvidia*); do
				if [ -e ${_card} ]; then
					bwSwitchableGraphicsArg="${bwSwitchableGraphicsArg} --dev-bind ${_card} ${_card}"
				fi
			done
		elif [[ ${videoMod} =~ i915 ]] || [[ ${videoMod} =~ xe ]] || [[ ${videoMod} =~ amdgpu ]]; then
			pecho debug "Not using NVIDIA GPU"
			bwSwitchableGraphicsArg=""
		elif [[ ${videoMod} =~ nvidia ]]; then
			pecho debug "Using NVIDIA GPU"
			for _card in $(ls /dev/nvidia*); do
				if [ -e ${_card} ]; then
					bwSwitchableGraphicsArg="${bwSwitchableGraphicsArg} --dev-bind ${_card} ${_card}"
				fi
			done
		fi
	fi
	pecho debug "Generated GPU bind parameter: ${bwSwitchableGraphicsArg}"
	bwCamPar=""
	if [[ ${bindCameras} = "true" ]]; then
		pecho debug "Detecting Camera..."
		for camera in $(ls /dev/video*); do
			if [ -e ${camera} ]; then
				bwCamPar="${bwCamPar} --dev-bind ${camera} ${camera}"
			fi
		done
	fi
	pecho debug "Generated Camera bind parameter: ${bwCamPar}"
	if [[ ${bindInputDevices} = "true" ]]; then
		bwInputArg="--dev-bind-try /dev/input /dev/input --dev-bind-try /dev/uinput /dev/uinput"
		ls /dev/hidraw* 2>/dev/null 1>/dev/null
		lsStatus=$?
		if [ "${lsStatus}" = 0 ]; then
			for _device in $(ls /dev/hidraw*); do
				if [ -e ${_card} ]; then
					bwInputArg="${bwInputArg} --dev-bind ${_device} ${_device}"
				fi
			done
		fi
		pecho warn "Detected input preference as expose, setting arg: ${bwInputArg}"
	else
		bwInputArg=""
		pecho debug "Not exposing input devices"
	fi
	if [[ ${bindPipewire} = "true" ]]; then
		pipewireBinding="--ro-bind-try ${XDG_RUNTIME_DIR}/pipewire-0 ${XDG_RUNTIME_DIR}/pipewire-0"
	fi
}

function warnMulRunning() {
	id=$(dbus-send \
		--bus=unix:path="${busDir}/bus" \
		--dest=org.kde.StatusNotifierWatcher \
		--type=method_call \
		--print-reply=literal /StatusNotifierWatcher \
		org.freedesktop.DBus.Properties.Get \
		string:org.kde.StatusNotifierWatcher \
		string:RegisteredStatusNotifierItems | grep -oP 'org.kde.StatusNotifierItem-\d+-\d+')
	pecho debug "Unique ID: ${id}"
	dbus-send \
		--print-reply \
		--session \
		--dest=${id} \
		--type=method_call \
		/StatusNotifierItem \
		org.kde.StatusNotifierItem.Activate \
		int32:114514 \
		int32:1919810
	if [[ $? = 0 ]]; then
		exit 0
	fi
	source "${_portableConfig}"
	execAppExist "${unitName}"
	if [[ $? = 0 ]]; then
		exit 0
	fi
	if [[ "${LANG}" =~ 'zh_CN' ]]; then
		zenity --title "程序未响应" --icon=utilities-system-monitor-symbolic --default-cancel --question --text="是否结束正在运行的进程?"
	else
		zenity --title "Application is not responding" --icon=utilities-system-monitor-symbolic --default-cancel --question --text="Do you wish to terminate the running session?"
	fi
	if [ $? = 0 ]; then
		systemctl --user stop "portable-${unitName}.slice"
	else
		pecho crit "User denied session termination"
		exit $?
	fi
}

function generateFlatpakInfo() {
	pecho debug "Installing flatpak-info..."
	install /usr/lib/portable/flatpak-info \
		"${XDG_DATA_HOME}/${stateDirectory}"/flatpak-info
	pecho debug "Generating flatpak-info..."
	export instanceId=$(head -c 4 /dev/urandom | xxd -p | tr -d '\n' | awk '{print strtonum("0x"$1)}')
	sed -i "s|placeHolderAppName|${appID}|g" \
		"${XDG_DATA_HOME}/${stateDirectory}"/flatpak-info
	sed -i "s|placeholderInstanceId|${instanceId}|g" \
		"${XDG_DATA_HOME}/${stateDirectory}"/flatpak-info
	sed -i "s|placeholderPath|${XDG_DATA_HOME}/${stateDirectory}|g" \
		"${XDG_DATA_HOME}/${stateDirectory}"/flatpak-info

	mkdir -p "${XDG_RUNTIME_DIR}/.flatpak/${instanceId}"
	install /usr/lib/portable/bwrapinfo.json \
		"${XDG_RUNTIME_DIR}/.flatpak/${instanceId}/bwrapinfo.json"
	install "${XDG_DATA_HOME}/${stateDirectory}"/flatpak-info \
		"${XDG_RUNTIME_DIR}/.flatpak/${instanceId}/info"

}

function dbusProxy() {
	generateFlatpakInfo
	if [[ $(systemctl --user is-failed ${proxyName}.service) = failed ]]; then
		pecho warn "D-Bus proxy failed last time"
		systemctl --user reset-failed ${proxyName}.service
	fi
	if [[ $(systemctl --user is-failed ${proxyName}-a11y.service) = failed ]]; then
		pecho warn "D-Bus a11y proxy failed last time"
		systemctl --user reset-failed ${proxyName}-a11y.service
	fi
	mkdir "${busDir}" -p
	mkdir -p "${busDirAy}" -p
	pecho info "Starting D-Bus Proxy @ ${busDir}..."
	if [[ ${PORTABLE_LOGGING} = "debug" ]]; then
		proxyArg="--log"
	fi
	mkdir -p "${XDG_RUNTIME_DIR}/doc/by-app/${appID}"
	systemd-run \
		--user \
		-p Slice="portable-${unitName}.slice" \
		-u ${proxyName} \
		-p RestartMode=direct \
		-p ExecStopPost="rm ${XDG_RUNTIME_DIR}/.flatpak/${instanceId} -r" \
		-p ExecStopPost="rm -r ${busDir}" \
		-- bwrap \
			--symlink /usr/lib64 /lib64 \
			--ro-bind /usr/lib /usr/lib \
			--ro-bind /usr/lib64 /usr/lib64 \
			--ro-bind /usr/bin /usr/bin \
			--ro-bind-try /usr/share /usr/share \
			--bind "${XDG_RUNTIME_DIR}" "${XDG_RUNTIME_DIR}" \
			--ro-bind "${XDG_DATA_HOME}/${stateDirectory}"/flatpak-info \
				"${XDG_RUNTIME_DIR}/.flatpak-info" \
			--ro-bind "${XDG_DATA_HOME}/${stateDirectory}"/flatpak-info \
				/.flatpak-info \
			-- /usr/bin/xdg-dbus-proxy \
			"${DBUS_SESSION_BUS_ADDRESS}" \
			"${busDir}/bus" \
			${proxyArg} \
			--filter \
			--own=org.kde.StatusNotifierItem-2-1 \
			--own=com.belmoussaoui.ashpd.demo \
			--own=com.steampowered.* \
			--own="${appID}" \
			--talk=org.freedesktop.Notifications \
			--call=org.freedesktop.Notifications.*=* \
			--see=org.a11y.Bus \
			--call=org.a11y.Bus=org.a11y.Bus.GetAddress@/org/a11y/bus \
			--call=org.a11y.Bus=org.freedesktop.DBus.Properties.Get@/org/a11y/bus \
			--see=org.freedesktop.portal.Flatpak \
			--see=org.freedesktop.portal.Request \
			--call=org.freedesktop.portal.Flatpak=org.freedesktop.DBus.Peer.Ping \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.DBus.Properties.GetAll \
			--call=org.freedesktop.portal.Flatpak=*@/org/freedesktop/portal/Flatpak \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.Settings.ReadAll \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.Email.ComposeEmail \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.ScreenCast \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.ScreenCast.* \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.Account.GetUserInformation \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.Camera.* \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.Camera \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.RemoteDesktop.* \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.RemoteDesktop \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.Settings.Read \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.Request \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.Documents.* \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.Documents \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.FileChooser.* \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.FileChooser \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.FileTransfer.* \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.FileTransfer \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.Notification.* \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.Notification \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.Print.* \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.Print \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.OpenURI.* \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.OpenURI \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.Fcitx.* \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.Fcitx \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.IBus.* \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.IBus \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.IBus \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.Secret \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.Secret.RetrieveSecret \
			--call=org.freedesktop.portal.Desktop=org.freedesktop.DBus.Properties.Get@/org/freedesktop/portal/desktop \
			--talk=org.freedesktop.portal.Documents \
			--call=org.freedesktop.portal.Documents=* \
			--talk=org.freedesktop.portal.FileTransfer \
			--call=org.freedesktop.portal.FileTransfer=* \
			--talk=org.freedesktop.portal.FileTransfer.* \
			--call=org.freedesktop.portal.FileTransfer.*=* \
			--talk=org.freedesktop.portal.Notification \
			--call=org.freedesktop.portal.Notification=* \
			--talk=org.freedesktop.portal.Print \
			--call=org.freedesktop.portal.Print=* \
			--talk=org.freedesktop.FileManager1 \
			--call=org.freedesktop.FileManager1=* \
			--talk=org.kde.StatusNotifierWatcher \
			--call=org.kde.StatusNotifierWatcher=* \
			--talk=org.freedesktop.portal.OpenURI \
			--call=org.freedesktop.portal.OpenURI=* \
			--talk=org.freedesktop.portal.OpenURI.OpenURI \
			--call=org.freedesktop.portal.OpenURI.OpenURI=* \
			--talk=org.freedesktop.portal.OpenURI.OpenFile \
			--call=org.freedesktop.portal.OpenURI.OpenFile=* \
			--talk=org.freedesktop.portal.Fcitx \
			--call=org.freedesktop.portal.Fcitx=* \
			--talk=org.freedesktop.portal.Fcitx.* \
			--call=org.freedesktop.portal.Fcitx.*=* \
			--talk=org.freedesktop.portal.IBus \
			--call=org.freedesktop.portal.IBus=* \
			--talk=org.freedesktop.portal.IBus.* \
			--call=org.freedesktop.portal.IBus.*=* \
			--call=org.freedesktop.portal.Request=* \
			--own="${busName}" \
			--broadcast=org.freedesktop.portal.*=@/org/freedesktop/portal/*
	if [ ! -S ${XDG_RUNTIME_DIR}/at-spi/bus ]; then
		pecho warn "No at-spi bus detected!"
		touch "${busDirAy}/bus"
		return 0
	fi
	systemd-run \
		--user \
		-p Slice="portable-${unitName}.slice" \
		-u ${proxyName}-a11y \
		-p RestartMode=direct \
		-p BindsTo="${proxyName}.service" \
		-p ExecStopPost="rm -r ${busDirAy}" \
		-- bwrap \
			--symlink /usr/lib64 /lib64 \
			--ro-bind /usr/lib /usr/lib \
			--ro-bind /usr/lib64 /usr/lib64 \
			--ro-bind /usr/bin /usr/bin \
			--ro-bind-try /usr/share /usr/share \
			--bind "${XDG_RUNTIME_DIR}" "${XDG_RUNTIME_DIR}" \
			--ro-bind "${XDG_DATA_HOME}/${stateDirectory}"/flatpak-info \
				"${XDG_RUNTIME_DIR}/.flatpak-info" \
			--ro-bind "${XDG_DATA_HOME}/${stateDirectory}"/flatpak-info \
				/.flatpak-info \
			-- /usr/bin/xdg-dbus-proxy \
			unix:path="${XDG_RUNTIME_DIR}/at-spi/bus" \
			"${busDirAy}/bus" \
			--filter \
			--sloppy-names \
			--call=org.a11y.atspi.Registry=org.a11y.atspi.Socket.Embed@/org/a11y/atspi/accessible/root \
			--call=org.a11y.atspi.Registry=org.a11y.atspi.Socket.Unembed@/org/a11y/atspi/accessible/root \
			--call=org.a11y.atspi.Registry=org.a11y.atspi.Registry.GetRegisteredEvents@/org/a11y/atspi/registry \
			--call=org.a11y.atspi.Registry=org.a11y.atspi.DeviceEventController.GetKeystrokeListeners@/org/a11y/atspi/registry/deviceeventcontroller \
			--call=org.a11y.atspi.Registry=org.a11y.atspi.DeviceEventController.GetDeviceEventListeners@/org/a11y/atspi/registry/deviceeventcontroller \
			--call=org.a11y.atspi.Registry=org.a11y.atspi.DeviceEventController.NotifyListenersSync@/org/a11y/atspi/registry/deviceeventcontroller \
			--call=org.a11y.atspi.Registry=org.a11y.atspi.DeviceEventController.NotifyListenersAsync@/org/a11y/atspi/registry/deviceeventcontroller


}

function execAppUnsafe() {
	importEnv
	source "${XDG_DATA_HOME}/${stateDirectory}/portable-generated.env"
	pecho info "GTK_IM_MODULE is ${GTK_IM_MODULE}"
	pecho info "QT_IM_MODULE is ${QT_IM_MODULE}"
	systemd-run --user \
		-p Slice="portable-${unitName}.slice" \
                -p Environment=QT_AUTO_SCREEN_SCALE_FACTOR="${QT_AUTO_SCREEN_SCALE_FACTOR}" \
                -p Environment=QT_ENABLE_HIGHDPI_SCALING="${QT_ENABLE_HIGHDPI_SCALING}" \
                -p EnvironmentFile="${XDG_DATA_HOME}/${stateDirectory}/portable-generated.env" \
		-u ${unitName} \
		--tty \
		${launchTarget}
}

function questionFirstLaunch() {
	if [ ! -f "${XDG_DATA_HOME}"/${stateDirectory}/options/sandbox ]; then
		if [[ "${LANG}" =~ 'zh_CN' ]]; then
			/usr/bin/zenity \
				--default-cancel \
				--title "初次启动" \
				--icon=security-medium-symbolic \
				--question \
				--text="允许程序读取 / 修改所有个人数据?"
		else
			/usr/bin/zenity --default-cancel \
				--title "Welcome" \
				--icon=security-medium-symbolic \
				--question \
				--text="Do you wish this Application to access and modify all of your data?"
		fi
		if [[ $? = 0 ]]; then
			export trashAppUnsafe=1
			if [[ "${LANG}" =~ 'zh_CN' ]]; then
				zenity --error --title "沙盒已禁用" --icon=security-low-symbolic --text "用户数据不再被保护"
			else
				zenity --error --title "Sandbox disabled" --icon=security-low-symbolic --text "User data is potentially compromised"
			fi
		else
			pecho warn "Request canceled by user"
			mkdir -p "${XDG_DATA_HOME}"/${stateDirectory}/options
			touch "${XDG_DATA_HOME}"/${stateDirectory}/options/sandbox
			return 0
		fi
		mkdir -p "${XDG_DATA_HOME}"/${stateDirectory}/options
		echo disableSandbox >>"${XDG_DATA_HOME}"/${stateDirectory}/options/sandbox
	fi
	if [[ $(cat "${XDG_DATA_HOME}"/${stateDirectory}/options/sandbox) =~ "disableSandbox" ]]; then
		export trashAppUnsafe=1
	fi
}

function launch() {
	if [[ $(systemctl --user is-failed ${unitName}.service) = failed ]]; then
		pecho warn "${appID} failed last time"
		systemctl --user reset-failed ${unitName}.service
	fi
	if [[ $(systemctl --user is-active ${unitName}.service) = active ]]; then
		warnMulRunning ${unitName}.service
	fi
	if [[ $@ =~ "--actions" ]] && [[ $@ =~ "debug-shell" ]]; then
		launchTarget="/usr/bin/bash"
	fi
	export sdOption="-P"
	if [[ ${trashAppUnsafe} = 1 ]]; then
		pecho warn "Launching ${appID} (unsafe)..."
		execAppUnsafe
	else
		dbusProxy
		pecho info "Launching ${appID}..."
		passPid &
		execApp
	fi
}

function passPid() {
	pecho debug "Waiting for application start"
	while [[ $(systemctl --user show ${unitName} -p ExecMainPID) = "ExecMainPID=0" ]]; do
		sleep 0.1s
	done
	getChildPid
	echo "${childPid}" >"${XDG_DATA_HOME}/${stateDirectory}/mainPid"
	sed -i \
		"s|placeholderChildPid|$(systemctl --user show ${proxyName} -p MainPID | cut -c '9-')|g" \
		"${XDG_RUNTIME_DIR}/.flatpak/${instanceId}/bwrapinfo.json"

	sed -i \
		"s|placeholderMntId|$(readlink /proc/${childPid}/ns/mnt | sed 's/[^0-9]//g')|g" \
		"${XDG_RUNTIME_DIR}/.flatpak/${instanceId}/bwrapinfo.json"
	sed -i \
		"s|placeholderPidId|$(readlink /proc/${childPid}/ns/pid | sed 's/[^0-9]//g')|g" \
		"${XDG_RUNTIME_DIR}/.flatpak/${instanceId}/bwrapinfo.json"
	install "${XDG_DATA_HOME}/${stateDirectory}/mainPid" \
		"${XDG_RUNTIME_DIR}/.flatpak/${instanceId}/pid"
}

function stopApp() {
	systemctl --user stop "portable-${unitName}.slice"
}

function cmdlineDispatcher() {
	if [[ $@ =~ "f5aaebc6-0014-4d30-beba-72bce57e0650" ]] && [[ $@ =~ "--actions" ]]; then
		rm -f \
			"${XDG_DATA_HOME}"/${stateDirectory}/options/sandbox
		rm -r "${XDG_DATA_HOME}"/flatpak/db
		questionFirstLaunch
	fi
	if [[ $@ =~ "--actions" ]] && [[ $@ =~ "opendir" ]]; then
		/usr/lib/flatpak-xdg-utils/xdg-open "${XDG_DATA_HOME}"/${stateDirectory}
		exit $?
	fi
	if [[ $@ =~ "--actions" ]] && [[ $@ =~ "inspect" ]]; then
		enterSandbox /usr/bin/bash
		exit $?
	fi
	if [[ $@ =~ "--actions" ]] && [[ $@ =~ "share-files" ]]; then
		shareFile
	fi
}

if [[ $@ = "--actions quit" ]]; then
	stopApp "portable-${unitName}.slice"
	exit $?
fi

sourceXDG
questionFirstLaunch
manageDirs
cmdlineDispatcher $@
launch $@

