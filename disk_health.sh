#!/bin/bash
# disk_health.sh — decide whether a disk is actually failing, and say why.
#
#   sudo ./tools/disk_health.sh /dev/sdd
#   sudo ./tools/disk_health.sh                      # every disk smartctl sees
#   sudo ./tools/disk_health.sh --all --state /var/lib/disk-health.state
#   sudo ./tools/disk_health.sh -d sat /dev/sdd       # USB bridge that lies about its type
#
# LibreNMS over SNMP: one extend per disk, because an extend returns one string
# and one exit status.
#
#   # /etc/snmp/snmpd.conf
#   extend disk_sdd /usr/bin/sudo /usr/local/bin/disk_health.sh --snmp /dev/sdd
#
#   # /etc/sudoers.d/disk-health (snmpd usually runs as Debian-snmp)
#   Debian-snmp ALL = NOPASSWD: /usr/local/bin/disk_health.sh
#
# --snmp prints exactly one line and otherwise behaves like a Nagios plugin:
# OK/WARNING/CRITICAL/UNKNOWN, perfdata after a "|". net-snmp exposes the exit
# status as nsExtendResult."disk_sdd" (0/1/2/3) — alert on that OID; the text
# goes to nsExtendOutput1Line for humans. Add
# --state /var/lib/disk-health/sdd.state and every poll reports what grew since
# the previous one. The graphs themselves come from LibreNMS's own SMART
# application, which caches smartctl output from cron for exactly the reason
# this script needs a wake-up read: a sleeping disk must not stall a poller.
#
# `smartctl -H` on its own is not enough. The overall assessment only flips to
# FAILED when a *pre-fail* attribute crosses its threshold, so a drive happily
# reports PASSED while it is sitting on hundreds of sectors it can no longer
# read. This is the shape of that trap:
#
#     SMART overall-health self-assessment test result: PASSED
#       5 Reallocated_Sector_Ct   100  100  036   0
#     197 Current_Pending_Sector  095  095  000   424
#     198 Offline_Uncorrectable   095  095  000   424
#
# The real evidence is the attribute table (197/198/187/5, plus whether any
# pre-fail value is at or below its threshold), the drive's error log, the
# self-test log, and the kernel's I/O errors. Counters alone cannot separate
# "one bad sector ten years ago" from "dying": --state remembers them between
# runs, so a second run shows what grew.
#
# Exit codes: 0 healthy, 1 marginal, 2 failing, 3 nothing could be checked.
set -euo pipefail

PROG=$(basename "$0")
SMARTCTL=${SMARTCTL:-smartctl}
TEMP_WARN=${DISK_TEMP_WARN:-50}
TEMP_FAIL=${DISK_TEMP_FAIL:-60}
STATE=
QUIET=0
DTYPE=
ALL=0
SNMP=0
USE_DMESG=auto

usage() {
	cat <<EOF
usage: $PROG [options] [device...]

  -a, --all            check every device reported by smartctl --scan (default
                       when no device is given)
  -d, --device TYPE    pass -d TYPE to smartctl (sat, scsi, nvme, auto, ...)
  -s, --state FILE     remember the counters in FILE and flag anything that grew
  -q, --quiet          only print devices that have warnings or failures
      --temp-warn N    temperature that counts as a warning (default $TEMP_WARN C)
      --temp-fail N    temperature that counts as a failure (default $TEMP_FAIL C)
      --dmesg          look for I/O errors in the kernel ring buffer (default:
                       on when it is readable)
      --no-dmesg       do not look at the kernel log
      --snmp           one device, one line, no colour, no auto-sudo: the shape
                       an snmpd "extend" needs (see the comment at the top)
  -h, --help

exit: 0 healthy, 1 marginal, 2 failing, 3 nothing could be checked
EOF
	exit 0
}

# snmpd captures stdout and the exit status only, so an extend-mode failure
# has to be a normal one-line answer, not a message on stderr.
die() {
	if [ "$SNMP" = 1 ]; then
		printf 'SMART UNKNOWN - %s\n' "$*"
	else
		printf '%s: %s\n' "$PROG" "$*" >&2
	fi
	exit 3
}

# Keep the invocation intact: the sudo re-exec below must replay what the
# operator actually asked for, not what is left after option parsing.
ORIG_ARGS=("$@")

DEVICES=()
while [ $# -gt 0 ]; do
	case "$1" in
	-a | --all) ALL=1 ;;
	-d | --device) DTYPE=${2:-}; [ -n "$DTYPE" ] || die "-d needs a type"; shift ;;
	-s | --state) STATE=${2:-}; [ -n "$STATE" ] || die "-s needs a file"; shift ;;
	-q | --quiet) QUIET=1 ;;
	--temp-warn) TEMP_WARN=${2:-}; [ -n "$TEMP_WARN" ] || die "--temp-warn needs a number"; shift ;;
	--temp-fail) TEMP_FAIL=${2:-}; [ -n "$TEMP_FAIL" ] || die "--temp-fail needs a number"; shift ;;
	--dmesg) USE_DMESG=yes ;;
	--no-dmesg) USE_DMESG=no ;;
	--snmp) SNMP=1 ;;
	-h | --help) usage ;;
	--) shift; DEVICES+=("$@"); break ;;
	-*) die "unknown option: $1 (try --help)" ;;
	*) DEVICES+=("$1") ;;
	esac
	shift
done

[ "${#DEVICES[@]}" -gt 0 ] || ALL=1

if [ "$SNMP" = 1 ]; then
	# An extend is one string and one status; aggregating disks would hide
	# which one is dying.
	if [ "$ALL" = 1 ] || [ "${#DEVICES[@]}" -ne 1 ]; then
		die "--snmp needs exactly one device, e.g. --snmp /dev/sda"
	fi
fi

# /usr/sbin is not on a normal user PATH on Debian, and the sudo re-exec below
# happens after this check.
if ! command -v "$SMARTCTL" >/dev/null 2>&1 && [ "$SMARTCTL" = smartctl ]; then
	for p in /usr/sbin/smartctl /sbin/smartctl /usr/local/sbin/smartctl; do
		if [ -x "$p" ]; then
			SMARTCTL=$p
			break
		fi
	done
fi
command -v "$SMARTCTL" >/dev/null 2>&1 || die "smartctl not found (apt install smartmontools)"

# smartctl needs raw device access. Re-exec once instead of printing an error
# the operator has to retype. Under snmpd there is no tty and no password to
# type: the sudoers rule in the header is the supported way in.
if [ "$SNMP" = 0 ] && [ "$(id -u)" -ne 0 ] && [ -z "${DISK_HEALTH_NO_SUDO:-}" ]; then
	if command -v sudo >/dev/null 2>&1; then
		echo "$PROG: re-running under sudo (smartctl needs raw device access)" >&2
		exec sudo --preserve-env=SMARTCTL,NO_COLOR,DISK_TEMP_WARN,DISK_TEMP_FAIL,DISK_HEALTH_NO_SUDO -- "$0" "${ORIG_ARGS[@]}"
	fi
	die "run as root: smartctl needs raw device access"
fi

COLOUR=0
if [ "$SNMP" = 0 ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then COLOUR=1; fi
paint() {
	local c=$1
	shift
	if [ "$COLOUR" = 1 ]; then printf '\033[%sm%s\033[0m' "$c" "$*"; else printf '%s' "$*"; fi
}
FAIL_C=31
WARN_C=33
NOTE_C=36
OK_C=32
BOLD=1

TOTAL_FAILS=0
TOTAL_WARNS=0
TOTAL_ERRORS=0
CHECKED=0
HAS_ATA=0

BODY=""
FAIL_REASONS=()
WARN_REASONS=()
DEV_FAILS=0
DEV_WARNS=0
SNMP_EXIT=0

add_fail() {
	DEV_FAILS=$((DEV_FAILS + 1))
	FAIL_REASONS+=("$*")
	BODY+="  $(paint "$FAIL_C" FAIL)  $*"$'\n'
}
add_warn() {
	DEV_WARNS=$((DEV_WARNS + 1))
	WARN_REASONS+=("$*")
	BODY+="  $(paint "$WARN_C" WARN)  $*"$'\n'
}
add_note() { BODY+="  $(paint "$NOTE_C" NOTE)  $*"$'\n'; }

# --- state: previous counters, so growth can be reported ---------------------

declare -A PREV=()
NEW_ROWS=()

load_state() {
	[ -n "$STATE" ] || return 0
	[ -r "$STATE" ] || return 0
	local dev id raw
	while read -r dev id raw; do
		[ -n "${dev:-}" ] && [ -n "${id:-}" ] && [ -n "${raw:-}" ] || continue
		PREV["$dev|$id"]=$raw
	done <"$STATE"
}

save_state() {
	[ -n "$STATE" ] || return 0
	[ "${#NEW_ROWS[@]}" -gt 0 ] || return 0
	local dir tmp
	dir=$(dirname "$STATE")
	[ -d "$dir" ] || mkdir -p "$dir"
	tmp=$(mktemp "${STATE}.XXXXXX")
	printf '%s\n' "${NEW_ROWS[@]}" >"$tmp"
	if [ -r "$STATE" ]; then
		# Keep rows for devices that were not part of this run.
		awk 'NR == FNR { seen[$1] = 1; print; next } !($1 in seen)' "$tmp" "$STATE" >"${tmp}.merged"
		mv "${tmp}.merged" "$STATE"
		rm -f "$tmp"
	else
		mv "$tmp" "$STATE"
	fi
}

# --- text helpers -----------------------------------------------------------

# get_field NAME TEXT — value of a "Name: value" line (NVMe health log).
# head(1) closing the pipe early must not trip pipefail/set -e.
get_field() {
	printf '%s\n' "$2" | sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" | head -1 |
		sed -e 's/[[:space:]]*$//' -e 's/%$//' || true
}

get_info() { # label from the -i section
	printf '%s\n' "$OUT" | sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" | head -1 |
		sed -e 's/[[:space:]]*$//' || true
}

# kernel_errors DEV — kernel-log lines that look like failed I/O on DEV. A drive
# can fail reads while SMART still reports fine, and when SMART cannot be read
# at all this is the only evidence left.
#
# Discard/TRIM failures are dropped: a USB bridge that does not forward the
# command answers "critical target error" on every discard without losing a
# single byte of data, so counting them would nag about a healthy disk forever.
# Reads and writes are the ones that mean data.
kernel_errors() {
	[ "$USE_DMESG" != no ] || return 0
	local base=${1##*/}
	dmesg 2>/dev/null |
		grep -iE '(I/O error|medium error|unrecovered read error|critical (medium|target) error)' |
		grep -v 'op 0x3:(DISCARD)' |
		grep -E "(^|[^[:alnum:]])${base}([^[:alnum:]]|$)" || true
}

# --- device checks ----------------------------------------------------------

check_device() {
	local dev="$1" dtype="$2"
	local -A RAW=() VAL=() THRESH=() WHEN=() NAME=() SEEN=()
	local out rc=0 line f id raw val temp
	local model serial size health

	# smartctl --scan answers "-d scsi" for anything it cannot classify, and
	# forcing that on a SATA disk hands back "SMART support is: Unavailable"
	# instead of the ATA attribute table. Auto-detection tries SAT first, so
	# drop that one guess; the specific types (sat, nvme, megaraid,N, 3ware,N)
	# are worth keeping.
	if [ "$dtype" = scsi ]; then dtype=""; fi

	OUT=""
	BODY=""
	FAIL_REASONS=()
	WARN_REASONS=()
	DEV_FAILS=0
	DEV_WARNS=0

	local args=(-a)
	[ -n "$dtype" ] && args+=(-d "$dtype")
	# The exit code is a bitmask and a failed command is not fatal: parse
	# whatever came back and only give up if nothing usable did.
	OUT=$("$SMARTCTL" "${args[@]}" "$dev" 2>&1) || rc=$?
	# A spun-down USB enclosure answers before the platter is up; give it one
	# more chance instead of reporting a healthy disk as unreadable. A single
	# read is what makes these bridges wake the drive.
	if [ "$rc" -ne 0 ] && printf '%s' "$OUT" | grep -q 'will be ready soon'; then
		timeout 20 dd if="$dev" of=/dev/null bs=512 count=1 status=none 2>/dev/null || true
		sleep 3
		rc=0
		OUT=$("$SMARTCTL" "${args[@]}" "$dev" 2>&1) || rc=$?
	fi
	# Another stale guess: if the answer has no attribute table, no NVMe
	# health log and no SCSI health line, let smartctl detect the type itself
	# before calling the disk unreadable.
	if [ -n "$dtype" ] &&
		! printf '%s' "$OUT" | grep -qE 'ID# *ATTRIBUTE_NAME|^[[:space:]]*Critical Warning:|^[[:space:]]*Media and Data Integrity Errors|^SMART Health Status'; then
		rc=0
		OUT=$("$SMARTCTL" -a "$dev" 2>&1) || rc=$?
	fi
	out=$OUT

	model=$(get_info "Device Model")
	[ -n "$model" ] || model=$(get_info "Model Number")
	[ -n "$model" ] || model=$(get_info "Model Family")
	[ -n "$model" ] || model=$(get_info "Product")
	serial=$(get_info "Serial Number")
	[ -n "$serial" ] || serial=$(get_info "Serial number")
	size=$(printf '%s\n' "$out" | sed -n 's/.*\[\([0-9.]* [A-Z]*\)\].*/\1/p' | head -1 || true)

	# Parse the ATA attribute table. Columns are ID NAME FLAG VALUE WORST
	# THRESH TYPE UPDATED WHEN_FAILED RAW..., and RAW may be "29 (4 26 29)".
	local table
	table=$(printf '%s\n' "$out" | sed -n '/^ID# *ATTRIBUTE_NAME/,/^$/p')
	while IFS= read -r line; do
		read -ra f <<<"$line"
		[ "${#f[@]}" -ge 9 ] || continue
		[[ ${f[0]} =~ ^[0-9]+$ ]] || continue
		[[ ${f[2]} == 0x* ]] || continue
		id=${f[0]}
		NAME[$id]=${f[1]}
		VAL[$id]=${f[3]}
		THRESH[$id]=${f[5]}
		WHEN[$id]=${f[8]}
		raw=${f[9]:-0}
		RAW[$id]=${raw%%,*}
	done <<<"$table"

	nvme_field() { get_field "$1" "$out"; }

	# SAS/SCSI disks have no attribute table: health, grown defects and
	# temperature are what they expose.
	local scsi_health grown scsi_temp
	scsi_health=$(printf '%s\n' "$out" | sed -n 's/^SMART Health Status:[[:space:]]*//p' | head -1 || true)
	grown=$(printf '%s\n' "$out" | sed -n 's/^Elements in grown defect list:[[:space:]]*//p' | head -1 || true)
	scsi_temp=$(printf '%s\n' "$out" | sed -n 's/^Current Drive Temperature:[[:space:]]*\([0-9][0-9]*\) C.*/\1/p' | head -1 || true)

	if [ "${#NAME[@]}" -eq 0 ] && [ -z "$(nvme_field 'Critical Warning')" ] &&
		[ -z "$(nvme_field 'Media and Data Integrity Errors')" ] && [ -z "$scsi_health" ]; then
		local kern n=0
		kern=$(kernel_errors "$dev")
		if [ -n "$kern" ]; then n=$(printf '%s\n' "$kern" | wc -l); fi
		if [ "$n" -gt 0 ]; then
			# smartctl cannot reach the drive and the kernel is already
			# logging failed reads: that is a broken device path, not a
			# gap in the tooling, and it deserves a louder answer than
			# UNKNOWN.
			CHECKED=$((CHECKED + 1))
			TOTAL_FAILS=$((TOTAL_FAILS + 1))
			SNMP_EXIT=2
			if [ "$SNMP" = 1 ]; then
				printf 'SMART CRITICAL - %s: no SMART data (smartctl exit %s), %s I/O error(s) in the kernel log\n' \
					"$dev" "$rc" "$n"
				return 0
			fi
			printf '%s  %s\n' "$(paint "$BOLD" "$dev")" "${model:-unknown model}"
			printf '  %s  %s\n' "$(paint "$FAIL_C" "FAIL")" \
				"no SMART data (smartctl exit $rc) and $n I/O error(s) in the kernel log — the device path is failing"
			printf '        e.g. %s\n' "$(printf '%s\n' "$kern" | tail -1 | cut -c1-150)"
			printf '  => %s\n' "$(paint "$FAIL_C" "FAILING — copy the data off now, then replace it")"
			printf '     SMART is unreachable, so suspect the cable, the enclosure and its power before the platter.\n\n'
			return 0
		fi

		TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
		if [ "$SNMP" = 1 ]; then
			SNMP_EXIT=3
			printf 'SMART UNKNOWN - %s: no SMART data (smartctl exit %s); try -d sat\n' "$dev" "$rc"
			return 0
		fi
		printf '%s  %s\n' "$(paint "$BOLD" "$dev")" "${model:-unknown model}"
		printf '  %s  %s\n' "$(paint "$FAIL_C" "ERROR")" "no SMART data (smartctl exit $rc)"
		printf '%s\n' "$out" | sed -n '1,8p' | sed 's/^/    /'
		if printf '%s' "$out" | grep -q 'SMART support is:[[:space:]]*Unavailable'; then
			printf '  %s  %s\n' "$(paint "$NOTE_C" "NOTE")" \
				"the device reports it has no SMART capability; a USB/RAID bridge may need -d sat, -d scsi or -d megaraid,N"
		else
			printf '  %s  %s\n' "$(paint "$NOTE_C" "NOTE")" \
				"if this is a USB bridge or RAID member, retry with -d sat / -d scsi"
		fi
		return 0
	fi

	# Overall health is a floor, not a verdict. SCSI reports it elsewhere.
	health=$(printf '%s\n' "$out" | sed -n 's/^SMART overall-health self-assessment test result: //p' | head -1 || true)
	if [ -n "$health" ]; then
		case "$health" in
		FAILED*) add_fail "SMART self-assessment says FAILED — the drive has crossed a pre-fail threshold" ;;
		PASSED*) add_note "SMART self-assessment says PASSED (necessary, not sufficient)" ;;
		*) add_warn "SMART self-assessment: $health" ;;
		esac
	elif [ -z "$scsi_health" ]; then
		add_warn "SMART self-assessment not reported"
	fi

	raw_num() {
		local v=${RAW[$1]:-}
		v=${v%% *}
		[[ $v =~ ^[0-9]+$ ]] || v=0
		printf '%s' "$v"
	}

	# Seagate packs three 16-bit words into the raw value of 188; the low
	# word is the timeout count that matters.
	norm_raw() {
		local n
		n=$(raw_num "$1")
		if [ "$1" = 188 ] && [ "$n" -gt 65535 ]; then n=$((n & 0xffff)); fi
		printf '%s' "$n"
	}

	check_counter() { # id severity description
		local aid=$1 sev=$2 why=$3 n msg
		n=$(norm_raw "$aid")
		[ "$n" -gt 0 ] || return 0
		[ -z "${SEEN[$aid]:-}" ] || return 0
		SEEN[$aid]=1
		local prev=${PREV["$dev|$aid"]:-} label="${NAME[$aid]:-attribute $aid}"
		if [ -n "$prev" ] && [ "$n" -gt "$prev" ]; then
			# Growth is the decisive signal: a count that was quiet last
			# run and is not now means the drive is losing ground. Keep
			# it before the dash so the one-line SNMP answer carries it.
			sev=FAIL
			msg="$label grew from $prev to $n since last run"
		elif [ -n "$prev" ] && [ "$n" -lt "$prev" ]; then
			msg="$label = $n (was $prev last run)"
		else
			msg="$label = $n"
		fi
		if [ "$sev" = FAIL ]; then
			add_fail "$msg — $why"
		else
			add_warn "$msg — $why"
		fi
	}

	check_counter 5 WARN "sectors the drive already gave up on"
	check_counter 197 FAIL "sectors it cannot read right now; it retries them on every pass"
	check_counter 198 FAIL "sectors that failed an offline read"
	check_counter 187 FAIL "uncorrectable errors reported to the host"
	check_counter 184 FAIL "errors inside the drive's data path"
	check_counter 10 FAIL "the spindle needed a retry to start"
	check_counter 183 WARN "bad blocks found at run time"
	check_counter 199 WARN "link errors — usually the cable or controller, not the platter"
	check_counter 188 WARN "commands timed out"

	# Any attribute that has crossed its own threshold is decisive, even if
	# the overall assessment still says PASSED.
	# 190/194 are handled by the temperature check below, where the raw value
	# is what we care about.
	SEEN[190]=1
	SEEN[194]=1
	for id in $(printf '%s\n' "${!NAME[@]}" | sort -n); do
		[ -z "${SEEN[$id]:-}" ] || continue
		local th=${THRESH[$id]:-0}
		val=${VAL[$id]:-0}
		[ "$th" -gt 0 ] || continue
		if [ "$val" -le "$th" ]; then
			add_fail "${NAME[$id]} ($id) value $val is at or below its threshold $th"
		elif [ "${WHEN[$id]:--}" != "-" ]; then
			add_warn "${NAME[$id]} ($id) crossed its threshold in the past (worst ${VAL[$id]})"
		fi
	done

	# Temperature, from 194 or 190 (first token of the raw value).
	for id in 194 190; do
		temp=$(raw_num "$id")
		[ "$temp" -gt 0 ] && [ "$temp" -lt 200 ] || continue
		if [ "$temp" -ge "$TEMP_FAIL" ]; then
			add_fail "running at ${temp}C — above ${TEMP_FAIL}C, the drive is throttling or cooking"
		elif [ "$temp" -ge "$TEMP_WARN" ]; then
			add_warn "running at ${temp}C (warn at ${TEMP_WARN}C)"
		fi
		break
	done

	# SCSI/SAS disks carry their whole health story in three lines.
	if [ -n "$scsi_health" ]; then
		case "$scsi_health" in
		OK) add_note "SCSI health status OK" ;;
		*) add_fail "SCSI health status: $scsi_health" ;;
		esac
		if [ -n "$grown" ] && [ "$grown" -gt 0 ] 2>/dev/null; then
			add_warn "$grown element(s) in the grown defect list — SCSI's reallocated sectors"
		fi
		if [ -n "$scsi_temp" ] && [ "$scsi_temp" -gt 0 ] && [ "$scsi_temp" -lt 200 ]; then
			if [ "$scsi_temp" -ge "$TEMP_FAIL" ]; then
				add_fail "running at ${scsi_temp}C — above ${TEMP_FAIL}C"
			elif [ "$scsi_temp" -ge "$TEMP_WARN" ]; then
				add_warn "running at ${scsi_temp}C (warn at ${TEMP_WARN}C)"
			fi
		fi
	fi

	# Vendor "marginal attributes" note from -H. The block ends at the next
	# blank line — after it comes the full attribute table, which is not
	# marginal merely by being listed.
	local marginal
	marginal=$(printf '%s\n' "$out" | sed -n '/marginal Attributes/,/^$/p' |
		grep -E '^[[:space:]]*[0-9]+[[:space:]]' | head -3 || true)
	if [ -n "$marginal" ]; then
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			read -ra f <<<"$line"
			add_warn "vendor flags ${f[1]:-attribute} (${f[0]:-?}) as marginal — it hit its threshold in the past"
		done <<<"$marginal"
	fi

	# Drive error log.
	local ata_errors
	ata_errors=$(printf '%s\n' "$out" | sed -n 's/^ATA Error Count:[[:space:]]*//p' | head -1 || true)
	if [ -n "$ata_errors" ] && [ "$ata_errors" -gt 0 ] 2>/dev/null; then
		add_warn "$ata_errors ATA errors in the drive's log (smartctl -l error $dev)"
	fi

	# Self-test log. NVMe keeps no such log, so only ask ATA drives.
	local selftest ran broken
	selftest=$(printf '%s\n' "$out" | sed -n '/^SMART Self-test log/,$p')
	ran=$(printf '%s\n' "$selftest" | grep -cE '^#[[:space:]]*[0-9]+' || true)
	broken=$(printf '%s\n' "$selftest" |
		grep -Ei '^#[[:space:]]*[0-9]+.*(read failure|write failure|servo|electronics|fatal|completed:[[:space:]]*unknown)' |
		head -1 || true)
	if [ -n "$broken" ]; then
		add_fail "a self-test ended badly: $(printf '%s' "$broken" | sed 's/^[[:space:]]*//;s/[[:space:]]\+/ /g')"
	elif [ "${#NAME[@]}" -gt 0 ] && [ "${ran:-0}" -eq 0 ]; then
		add_note "no self-test has ever run (smartctl -t short $dev)"
	fi

	# NVMe exposes a different health log.
	local cw spare spare_thresh used media errs ntemp
	cw=$(nvme_field 'Critical Warning')
	if [ -n "$cw" ]; then
		case "$cw" in
		0x00 | 0x0 | 0) ;;
		*) add_fail "NVMe critical warning $cw — the controller has flagged a problem" ;;
		esac
		ntemp=$(nvme_field 'Temperature')
		ntemp=${ntemp%% *}
		if [ -n "$ntemp" ] && [ "$ntemp" -ge 70 ] 2>/dev/null; then
			add_warn "NVMe running at ${ntemp}C — it starts throttling around 70C"
		fi
		spare=$(nvme_field 'Available Spare')
		spare_thresh=$(nvme_field 'Available Spare Threshold')
		used=$(nvme_field 'Percentage Used')
		media=$(nvme_field 'Media and Data Integrity Errors')
		errs=$(nvme_field 'Error Information Log Entries')
		if [ -n "$spare" ] && [ -n "$spare_thresh" ] && [ "$spare" -lt "$spare_thresh" ] 2>/dev/null; then
			add_fail "NVMe spare blocks down to ${spare}% (threshold ${spare_thresh}%)"
		fi
		if [ -n "$media" ] && [ "$media" -gt 0 ] 2>/dev/null; then
			add_fail "NVMe reports $media media/data-integrity errors"
		fi
		if [ -n "$used" ] && [ "$used" -ge 90 ] 2>/dev/null; then
			add_warn "NVMe rated endurance ${used}% used — replace before it runs out"
		elif [ -n "$used" ] && [ "$used" -ge 80 ] 2>/dev/null; then
			add_note "NVMe rated endurance ${used}% used"
		fi
		if [ -n "$errs" ] && [ "$errs" -gt 0 ] 2>/dev/null; then
			add_warn "$errs entries in the NVMe error log"
		fi
	fi

	# Kernel view: a drive can fail reads without SMART noticing yet.
	local kern
	kern=$(kernel_errors "$dev")
	if [ -n "$kern" ]; then
		add_warn "$(printf '%s\n' "$kern" | wc -l) I/O error(s) in the kernel log for ${dev##*/}, e.g.: $(printf '%s\n' "$kern" | tail -1 | cut -c1-140)"
	fi

	# Remember this run's counters for the next one. Only the counters that
	# mean something are kept — a state file of every attribute is noise.
	if [ -n "$STATE" ]; then
		for id in 5 10 183 184 187 188 197 198 199 194; do
			[ -n "${RAW[$id]:-}" ] || continue
			NEW_ROWS+=("$dev $id $(norm_raw "$id")")
		done
	fi

	CHECKED=$((CHECKED + 1))
	TOTAL_FAILS=$((TOTAL_FAILS + DEV_FAILS))
	TOTAL_WARNS=$((TOTAL_WARNS + DEV_WARNS))
	if [ "${#NAME[@]}" -gt 0 ]; then HAS_ATA=1; fi

	# snmpd "extend" answer: one line, a state word, the reasons that fit and
	# perfdata after the bar. net-snmp turns the exit status into
	# nsExtendResult, so the code matters as much as the text.
	if [ "$SNMP" = 1 ]; then
		local state=OK code=0 parts="" r nf=0 nw=0
		local base=${dev##*/} perf="" temp=""
		base=${base//[^A-Za-z0-9_]/_}
		if [ "$DEV_FAILS" -gt 0 ]; then
			state=CRITICAL
			code=2
		elif [ "$DEV_WARNS" -gt 0 ]; then
			state=WARNING
			code=1
		fi
		for r in "${FAIL_REASONS[@]}"; do
			[ "$nf" -lt 3 ] || break
			parts=${parts:+$parts, }${r%% — *}
			nf=$((nf + 1))
		done
		if [ "$nf" -lt 3 ]; then
			for r in "${WARN_REASONS[@]}"; do
				[ "$nw" -lt 2 ] || break
				parts=${parts:+$parts, }${r%% — *}
				nw=$((nw + 1))
			done
		fi
		if [ -n "${RAW[197]:-}" ]; then perf+=" ${base}_pending=$(norm_raw 197)"; fi
		if [ -n "${RAW[198]:-}" ]; then perf+=" ${base}_uncorrectable=$(norm_raw 198)"; fi
		if [ -n "${RAW[5]:-}" ]; then perf+=" ${base}_reallocated=$(norm_raw 5)"; fi
		temp=$(norm_raw 194)
		[ "$temp" -gt 0 ] || temp=$(norm_raw 190)
		if [ "$temp" -eq 0 ]; then temp=${scsi_temp:-0}; fi
		if [ "$temp" -gt 0 ]; then perf+=" ${base}_temp=$temp"; fi
		if [ -n "${grown:-}" ]; then perf+=" ${base}_grown_defects=$grown"; fi
		if [ -n "${spare:-}" ]; then perf+=" ${base}_spare=$spare"; fi
		if [ -n "${used:-}" ]; then perf+=" ${base}_used=$used"; fi
		if [ -n "${media:-}" ]; then perf+=" ${base}_media_errors=$media"; fi

		local line="SMART $state - $dev" text="" suffix="" room
		if [ -n "$parts" ]; then text=": $parts"; fi
		if [ -n "$perf" ]; then suffix=" |$perf"; fi
		# nsExtendOutput1Line is 255 octets: trim the prose, never the
		# numbers, so the perfdata survives a long list of reasons.
		room=$((250 - ${#line} - ${#suffix}))
		if [ "$room" -le 8 ]; then
			text=""
		elif [ "${#text}" -gt "$room" ]; then
			text="${text:0:$((room - 3))}..."
		fi
		line="${line}${text}${suffix}"
		printf '%s\n' "${line:0:250}"
		SNMP_EXIT=$code
		return 0
	fi

	if [ "$QUIET" = 1 ] && [ "$DEV_FAILS" -eq 0 ] && [ "$DEV_WARNS" -eq 0 ]; then
		return 0
	fi

	local ident="$model"
	if [ -n "$serial" ]; then ident="$ident, SN $serial"; fi
	if [ -n "$size" ]; then ident="$ident, $size"; fi
	printf '%s  %s\n' "$(paint "$BOLD" "$dev")" "$ident"
	printf '%s' "$BODY"
	if [ "$DEV_FAILS" -gt 0 ]; then
		printf '  => %s\n' "$(paint "$FAIL_C" "FAILING — copy the data off now, then replace it")"
		if [ "${#NAME[@]}" -gt 0 ]; then
			printf '     A long self-test or a full surface scan can finish a drive like this off.\n'
		fi
	elif [ "$DEV_WARNS" -gt 0 ]; then
		printf '  => %s\n' "$(paint "$WARN_C" "MARGINAL — nothing fatal yet, keep an eye on it")"
	else
		printf '  => %s\n' "$(paint "$OK_C" "healthy")"
	fi
	printf '\n'
}

# --- main -------------------------------------------------------------------

# smartctl --scan also tells us the right -d type for USB bridges.
declare -a SCAN_DEV=()
declare -a SCAN_TYPE=()
if [ "$ALL" = 1 ]; then
	while read -r dev flag type _; do
		[ -n "$dev" ] || continue
		SCAN_DEV+=("$dev")
		if [ "$flag" = "-d" ]; then SCAN_TYPE+=("$type"); else SCAN_TYPE+=(""); fi
	done < <("$SMARTCTL" --scan 2>/dev/null || true)
fi

load_state

if [ "$ALL" = 1 ]; then
	if [ "${#SCAN_DEV[@]}" -eq 0 ] && [ "${#DEVICES[@]}" -eq 0 ]; then
		die "smartctl --scan found no devices"
	fi
	for i in "${!SCAN_DEV[@]}"; do
		check_device "${SCAN_DEV[$i]}" "${SCAN_TYPE[$i]}"
	done
fi

# Explicit devices are checked as well, so "--all /dev/sdz" is not silently
# reduced to just the scan.
if [ "${#DEVICES[@]}" -gt 0 ]; then
	for dev in "${DEVICES[@]}"; do
		check_device "$dev" "$DTYPE"
	done
fi

save_state

# The extend answer and its status were printed by check_device.
if [ "$SNMP" = 1 ]; then
	exit "$SNMP_EXIT"
fi

if [ "$CHECKED" -eq 0 ]; then
	die "no device could be checked"
fi

if [ "$TOTAL_FAILS" -gt 0 ]; then
	printf '%s: %d device(s) checked, %d failure(s), %d warning(s)\n' \
		"$(paint "$FAIL_C" "FAIL")" "$CHECKED" "$TOTAL_FAILS" "$TOTAL_WARNS"
	[ -n "$STATE" ] || [ "$HAS_ATA" = 0 ] ||
		printf 'hint: re-run with --state FILE to catch counters that keep growing\n'
	exit 2
elif [ "$TOTAL_ERRORS" -gt 0 ]; then
	printf '%s: %d device(s) checked, %d could not be read\n' \
		"$(paint "$NOTE_C" "INCOMPLETE")" "$CHECKED" "$TOTAL_ERRORS"
	exit 3
elif [ "$TOTAL_WARNS" -gt 0 ]; then
	printf '%s: %d device(s) checked, %d warning(s)\n' \
		"$(paint "$WARN_C" "WARN")" "$CHECKED" "$TOTAL_WARNS"
	exit 1
fi

printf '%s: %d device(s) checked, all healthy\n' "$(paint "$OK_C" "OK")" "$CHECKED"
exit 0