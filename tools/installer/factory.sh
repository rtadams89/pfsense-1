#!/bin/sh

export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin

does_if_exist() {
	local _if="$1"

	[ -z "${_if}" ] \
		&& return 1

	ifconfig ${_if} >/dev/null 2>&1
	return $?
}

get_if_mac() {
	local _if="$1"
	local _if_mac="000000000000"

	if does_if_exist ${_if}; then
		_if_mac=$(ifconfig ${_if} \
			| awk '/ether/ {gsub(/:/, "", $2); print $2}')
	fi

	echo "${_if_mac}"
}

upgrade_netgate_coreboot() {
	local _roms_dir=/usr/local/share/pfSense-pkg-Netgate_Coreboot_Upgrade/roms

	# No roms found in this installation media, aborting
	[ -d /mnt/${_roms_dir} ] \
	    || return 0

	local _adi_flash_util=/usr/local/sbin/adi_flash_util

	# Upgrade utility is not available
	[ -f /mnt/${_adi_flash_util} ] \
	    || return 0

	local _product=$(/bin/kenv -q smbios.system.product 2>/dev/null)
	local _coreboot_model=""

	case "${_product}" in
		RCC-VE)
			_coreboot_model="RCCVE"
			;;
		DFFv2)
			_coreboot_model="DFF2"
			;;
		RCC)
			_coreboot_model="RCC"
			;;
		*)
			# Unsupported model
			return 0
			;;
	esac

	# Look for available rom for this model
	local _avail_rom=$(cd /mnt/${_roms_dir} && \
	    ls -1 ADI_${_coreboot_model}-*.rom 2>/dev/null | tail -n 1)

	[ -f "/mnt/${_roms_dir}/${_avail_rom}" ] \
	    || return 0

	# Get available version
	local _avail_version=$(echo "${_avail_rom}" | \
	    sed "s/^ADI_${_coreboot_model}-//; s/-.*//")

	# Check current model and version
	local _cur_model=$(/bin/kenv -q smbios.bios.version 2>/dev/null | \
	    sed 's/^ADI_//; s/-.*//')
	local _cur_version=$(/bin/kenv -q smbios.bios.version 2>/dev/null | \
	    sed "s/^ADI_${_cur_model}-//; s/-.*//")

	# Models don't match, leave it alone
	[ "${_coreboot_model}" != "${_cur_model}" ] \
	    && return 0

	# Installed version is the latest, nothing to be done here
	[ "${_avail_version}" = "${_cur_version}" ] \
	    && return 0

	# Upgrade coreboot
	echo "===> Upgrading Netgate Coreboot"
	mkdir -p /mnt/dev
	mount -t devfs devfs /mnt/dev
	chroot /mnt ${_adi_flash_util} -u ${_roms_dir}/${_avail_rom}
	local _rc=$?
	umount -f /mnt/dev
	return ${_rc}
}

get_cur_model() {
	local _cur_model=""

	local _product=$(/bin/kenv -q smbios.system.product 2>/dev/null)
	local _planar_product=$(/bin/kenv -q smbios.planar.product 2>/dev/null)
	local _hw_model=$(sysctl -b hw.model)
	local _hw_ncpu=$(sysctl -n hw.ncpu)

	case "${_product}" in
		RCC-VE)
			if ! ifconfig igb4 >/dev/null 2>&1; then
				_cur_model="SG-2440"
			elif echo $_hw_model | grep -q C2558; then
				_cur_model="SG-4860"
			elif echo $_hw_model | grep -q C2758; then
				_cur_model="SG-8860"
			else
				_cur_model="RCC-VE"
			fi
			;;
		RCC)
			_cur_model="XG-2758"
			;;
		DFFv2)
			_cur_model="SG-2220"
			;;
		FW7541)
			_cur_model="FW7541"
			;;
		APU)
			_cur_model="APU"
			;;
		SYS-5018A-FTN4|A1SAi)
			_cur_model="C2758"
			;;
		SYS-5018D-FN4T)
			_cur_model="XG-1540"
			;;
		"Minnowboard Turbot D0 PLATFORM")
			case "${_hw_ncpu}" in
				4)
					_cur_model="SG-2340"
					;;
				2)
					_cur_model="SG-2320"
					;;
			esac
			;;
	esac

	if [ "${_planar_product}" = 'X10SDV-8C-TLN4F+' ]; then
		_cur_model="XG-1537"
	fi

	echo "$_cur_model"
}

# Try to read serial
machine_arch=$(uname -p)
unset is_adi
unset is_turbot
case "${machine_arch}" in
	amd64)
		serial=$(kenv smbios.system.serial)
		product=$(kenv -q smbios.system.product)
		case "${product}" in
			RCC-VE|DFFv2|RCC)
				is_adi=1
				;;
			"Minnowboard Turbot D0 PLATFORM")
				serial=$(ifconfig igb0 | \
					sed -n '/hwaddr / { s,^.*hwaddr *,,; s,:,,g; p; }')
				is_turbot=1
				;;
		esac
		;;
	armv6)
		dd if=/dev/icee0 of=/tmp/serial.bin bs=1 count=12 skip=16
		serial=$(hexdump -C /tmp/serial.bin | \
			sed '1!d; s,\.*\|$,,; s,^.*\|,,')
		;;
	*)
		echo "Unsupported platform"
		exit 1
esac

# XXX is it really necessary?
if [ "${serial}" = "123456789" ]; then
	serial=""
fi

unset selected_model
cur_model=$(get_cur_model)

if [ -n "${is_adi}" ]; then
	case "${cur_model}" in
		SG-2220|SG-2440|XG-2758)
			selected_model="${cur_model}"
			;;
		SG-4860|SG-8860)
			models="\
				\"${cur_model}\" \"${cur_model}\" \
				\"${cur_model}-1U\" \"${cur_model}-1U\" \
			"
			;;
		*)
			selected_model="Default"
	esac
elif [ "${machine_arch}" != "armv6" ]; then
	case "${cur_model}" in
		C2758|APU|SG-2320|SG-2340)
			selected_model="${cur_model}"
			;;
		XG-1540)
			models="\
			\"XG-1540\" \"XG-1540\" \
			\"XG-1541\" \"XG-1541\" \
			"
			;;
		*)
			selected_model="Default"
	esac
else
	selected_model="SG-1000"
fi

if [ -z "${selected_model}" ]; then
	exec 3>&1
	selected_model=$(echo $models | xargs dialog \
		--backtitle "pfSense installer" \
		--title "Hardware model" \
		--menu "Select corresponding hardware model" \
		0 0 0 2>&1 1>&3) || exit 1
	exec 3>&-
fi

if [ "${machine_arch}" != "armv6" ]; then
	if [ -n "${is_turbot}" ]; then
		echo 'console="vidconsole"' > /tmp/loader.conf.pfSense
	else
		echo 'boot_serial="YES"' > /tmp/loader.conf.pfSense
		if [ -n "${is_adi}" ]; then
			echo "-S115200 -h" > /tmp/boot.config
			echo 'console="comconsole"' >> /tmp/loader.conf.pfSense
			echo 'comconsole_port="0x2F8"' >> /tmp/loader.conf.pfSense
			echo 'hint.uart.0.flags="0x00"' >> /tmp/loader.conf.pfSense
			echo 'hint.uart.1.flags="0x10"' >> /tmp/loader.conf.pfSense
			echo 'kern.cam.boot_delay="10000"' >> /tmp/loader.conf.local.pfSense
		else
			echo "-S115200 -D" > /tmp/boot.config
			echo 'boot_multicons="YES"' >> /tmp/loader.conf.pfSense
			echo 'console="comconsole,vidconsole"' >> /tmp/loader.conf.pfSense
		fi
		echo 'comconsole_speed="115200"' >> /tmp/loader.conf.pfSense
	fi
	echo 'kern.ipc.nmbclusters="1000000"' >> /tmp/loader.conf.pfSense
	echo 'kern.ipc.nmbjumbop="524288"' >> /tmp/loader.conf.pfSense
	echo 'kern.ipc.nmbjumbo9="524288"' >> /tmp/loader.conf.pfSense
	echo 'hw.usb.no_pf="1"' >> /tmp/loader.conf.pfSense
fi

if [ ! -f /tmp/buildroom ]; then
	exit 0
fi

# Make sure coreboot is in the last version
if ! upgrade_netgate_coreboot; then
	echo "Error while upgrading Netgate Coreboot"
	exit 1
fi

# Get WAN mac address
unset wan_if
case "${selected_model}" in
	APU)
		wan_if="re1"
		;;
	XG-154*)
		if does_if_exist igb2; then
			wan_if="igb4"
		elif does_if_exist cxl0; then
			wan_if="cxl0"
		else
			wan_if="ix0"
		fi
		;;
	XG-2758)
		if does_if_exist igb7; then
			wan_if="igb4"
		else
			wan_if="igb0"
		fi
		;;
	SG-4860*|SG-8860*)
		wan_if="igb1"
		;;
	SG-1000)
		wan_if="cpsw0"
		;;
	*)
		wan_if="igb0"
		;;
esac

wan_mac=$(get_if_mac ${wan_if})

if [ "${selected_model}" != "SG-1000" ]; then
	# Get WLAN mac address
	wlan_devices=$(sysctl -n net.wlan.devices)
	if [ -n "${wlan_devices}" ]; then
		if ! does_if_exist wlan0; then
			wlan_dev=$(echo "${wlan_devices}" | awk '{ print $1 }')
			ifconfig create wlan0 wlandev ${wlan_dev} >/dev/null 2>&1
		fi
	fi
fi

wlan_mac=$(get_if_mac wlan0)

if [ "${selected_model}" = "SG-1000" ]; then
	image_default_url="http://factory-logger.pfmechanics.com/pfSense-netgate-sg-1000-latest.img.gz"
	image_url=$(kenv -q ufw.install.image.url)
	image_url=${image_url:-${image_default_url}}

	fetch -o - "${image_url}" \
		| gunzip \
		| dd of=/dev/mmcsd0 bs=1m
	if [ $? -ne 0 ]; then
		echo "Error: Anything went wrong when tried to dd image to eMMC"
		exit 1
	fi

	# Get / ufsid
	UFSID=$(glabel status -s mmcsd0s2a 2>/dev/null \
		| head -n 1 | cut -d' ' -f1)

	if [ -z "${UFSID}" ]; then
		echo "Error obtaining UFSID"
		exit 1
	fi

	if ! mount /dev/${UFSID} /mnt; then
		echo "Error mounting pfSense partition"
		exit 1
	fi
	trap "umount /mnt; return" 1 2 15 EXIT

	# Found available label for EMMCBOOT
	idx=0
	while [ -e "/dev/label/EMMCBOOT${idx}" ]; do
		idx=$((idx+1))
	done
	EMMCBOOT_LABEL="EMMCBOOT${idx}"

	if ! glabel label ${EMMCBOOT_LABEL} /dev/mmcsd0s1; then
		echo "Error setting EMMCBOOT label"
		exit 1
	fi

	sed -i '' \
		-e "/[[:blank:]]\/boot\/msdos[[:blank:]]/ s,^/dev/[^[:blank:]]*,/dev/label/${EMMCBOOT_LABEL}," \
		-e "/[[:blank:]]\/[[:blank:]]/ s,^/dev/[^[:blank:]]*,/dev/${UFSID}," \
		/mnt/etc/fstab

	# Enable the factory post installation automatic halt
	touch /mnt/root/factory_boot
else
	support_types=$(fetch -o - http://prodtrack.netgate.com/listspt 2>/dev/null)
	if [ -z "${support_types}" ]; then
		echo "Error: Unable to get the list of support plans"
		exit 1
	fi

	OIFS="${IFS}"
	IFS="
"

	unset support_menu
	for item in ${support_types}; do
		code=$(echo "${item}" | cut -d',' -f1)
		desc=$(echo "${item}" | sed 's/^[^,]*,//')
		support_menu="${support_menu}${support_menu:+ }\"${code}\" \"${desc}\""
	done

	IFS="${OIFS}"

	if [ -n "${support_menu}" ]; then
		exec 3>&1
		support_type=$(echo $support_menu | xargs dialog \
			--backtitle "pfSense installer" \
			--title "Support type" \
			--menu "Select corresponding support type" \
			0 0 0 2>&1 1>&3) || exit 1
		exec 3>&-
	fi
fi

if [ -f /tmp/custom ]; then
	custom_url="http://factory-logger.pfmechanics.com/${custom}-install.sh"

	if ! fetch -o /tmp/custom.sh ${custom_url}; then
		echo "Error downloading custom script from ${custom_url}"
		exit 1
	fi

	if ! /bin/sh /tmp/custom.sh; then
		echo "Error executing custom script from ${custom_url}"
		exit 1
	fi

	if [ -f /tmp/custom_order ]; then
		order=$(cat /tmp/custom_order)
	fi
fi

default_serial="${serial}"
serial_size=0
sticker=1
# Serial is empty, let operator edit it
if [ -z "${default_serial}" ]; then
	serial_size=16
fi
while [ "${selected_model}" != "SG-1000" ]; do
	exec 3>&1
	col=30
	factory_raw_data=$(dialog --nocancel \
		--backtitle "pfSense installer" \
		--title "Register Serial Number" \
		--form "Enter system information" 0 0 0 \
		"Model" 1 0 "${selected_model}" 1 $col 0 0 \
		"Serial" 2 0 "${default_serial}" 2 $col ${serial_size} ${serial_size} \
		"Order Number" 3 0 "" 3 $col 16 0 \
		"Print sticker (0/1)" 4 0 "${sticker}" 4 $col 2 1 \
		2>&1 1>&3)
	exec 3>&-

	factory_data=$(echo "$factory_raw_data" \
		| sed 's,#,,g' \
		| paste -d'#' -s -)

	if [ ${serial_size} -eq 0 ]; then
		set_vars=$(echo "$factory_data" | \
			awk '
			BEGIN { FS="#" }
			{
				print "order=\""$1"\""
				print "sticker=\""$2"\"";
			}')
	else
		set_vars=$(echo "$factory_data" | \
			awk '
			BEGIN { FS="#" }
			{
				print "serial=\""$1"\"";
				print "order=\""$2"\""
				print "sticker=\""$3"\"";
			}')
	fi

	eval "${set_vars}"

	if [ "${sticker}" != "0" ]; then
		sticker=1
	fi

	if [ -n "${serial}" -a -n "${order}" ]; then
		break
	fi

	dialog --backtitle "pfSense installer" --title "Error" \
		--msgbox \
		"Serial and Order Number are mandatory" \
		0 0
done

release_ver="UNKNOWN"
if [ -f /mnt/etc/version ]; then
	release_ver=$(cat /mnt/etc/version)
fi

if [ -f /mnt/etc/version.patch ]; then
	release_patch=$(cat /mnt/etc/version.patch)
	if [ -n "${release_patch}" -a "${release_patch}" != "0" ]; then
		release_ver="${release_ver}-p${release_patch}"
	fi
fi

umount /mnt
sync; sync; sync
trap "-" 1 2 15 EXIT

# Calculate the "Unique ID" for support and tracking purposes
UID=$(/usr/sbin/gnid)

postreq="model=${selected_model}&serial=${serial}&release=${release_ver}"
postreq="${postreq}&wan_mac=${wan_mac}&print=${sticker}"
postreq="${postreq}&uniqueid=${UID}"

if [ -n "${order}" ]; then
	postreq="${postreq}&order=${order}"
fi

if [ "${selected_model}" != "SG-1000" ]; then
	postreq="${postreq}&wlan_mac=${wlan_mac}"
fi

if [ -n "${support_type}" ]; then
	postreq="${postreq}&support=${support_type}"
fi

postreq="${postreq}&submit=Submit"

# ProdTrack
fetch -o /dev/null "http://prodtrack.netgate.com/builder?${postreq}" >/dev/null 2>&1

exit $?