#!/bin/sh
# tune.sh -- apply/undo low-noise system tuning for CPU time
# profiling (perf, etc). POSIX sh only, no bashisms. Run as root.
#
# Usage:
#   tune.sh [cpu]     dedicate the physical core owning logical
#                           CPU <cpu> (auto-picked if omitted): offline
#                           its SMT sibling(s), shield it from the
#                           scheduler, steer IRQs off it, lock
#                           frequency, disable ASLR/THP/swap.
#   tune.sh --reset   undo everything above.
#   tune.sh --check   report current state, change nothing.
#   tune.sh --hold [cpu]
#                           tune, then stay in the foreground until
#                           Ctrl-C (or SIGTERM), and undo on the way out.
#                           Profile from a second terminal.
#
# Ctrl-C always undoes a partially applied run. --hold extends that to
# the whole session, so the tuning cannot outlive the terminal by
# accident; without it the tuning persists until --reset.
#
# Every step is verified by reading back what was written. A step that
# does not take effect aborts the run and rolls everything back, rather
# than reporting success over a system that is not actually tuned.
#
# Depends only on util-linux, systemd and coreutils -- no Python, no
# pipx, no out-of-distro packages.
#
# Assumes /sys/devices/system/cpu/present is a contiguous range "0-N".
# Kernel cmdline isolation (isolcpus=, nohz_full=, rcu_nocbs=) is not
# set here -- it needs a reboot. Put it in a separate GRUB entry.

set -eu

STATE=/run/tune.state
ARMED=0

# perf sampling ceiling to install while tuned. The kernel lowers this
# on its own if sampling overruns its time budget, so it is set high
# deliberately and restored on reset.
SAMPLE_RATE=100000

die() {
	echo "tune: error: $1" >&2
	exit 1
}

# die with a copy-pasteable remedy: the command goes on its own line,
# flush left, with nothing else on it.
die_cmd() {
	echo "tune: error: $1" >&2
	echo "" >&2
	echo "fix it with:" >&2
	echo "" >&2
	echo "$2" >&2
	echo "" >&2
	if [ $# -ge 3 ]; then
		echo "$3" >&2
		echo "" >&2
	fi
	exit 1
}

note() {
	echo "tune: $1" >&2
}

have() {
	command -v "$1" >/dev/null 2>&1
}

on_exit() {
	rc=$?
	if [ "$rc" -ne 0 ] && [ "$ARMED" = 1 ]; then
		# leaving --hold on Ctrl-C/SIGTERM is the intended way out, not
		# a failure, so say so rather than crying abort
		case "${HOLD:-0}:$rc" in
		1:130 | 1:143) echo "tune: restoring system" >&2 ;;
		*) echo "tune: aborting, rolling back" >&2 ;;
		esac
		ARMED=0
		if do_reset; then
			echo "tune: system restored" >&2
		else
			echo "tune: rollback FAILED -- run: sudo $0 --reset" >&2
		fi
	fi
	exit "$rc"
}

cpu_max() {
	r=$(cat /sys/devices/system/cpu/present)
	echo "${r#*-}"
}

expand_cpulist() {
	oldifs=$IFS
	IFS=,
	set -- $1
	IFS=$oldifs
	for tok in "$@"; do
		case $tok in
		*-*)
			n=${tok%-*}
			hi=${tok#*-}
			while [ "$n" -le "$hi" ]; do
				echo "$n"
				n=$((n + 1))
			done
			;;
		*) echo "$tok" ;;
		esac
	done
}

# /proc/irq/default_smp_affinity takes a hex bitmask (there is no _list
# variant of that file), as comma-separated 32-bit words, most
# significant first.
cpulist_to_mask() {
	hi=$2
	w=$((hi / 32))
	out=""
	while [ "$w" -ge 0 ]; do
		val=0
		for c in $(expand_cpulist "$1"); do
			if [ $((c / 32)) -eq "$w" ]; then
				val=$((val | (1 << (c % 32))))
			fi
		done
		word=$(printf '%08x' "$val")
		if [ -z "$out" ]; then
			out=$word
		else
			out="$out,$word"
		fi
		w=$((w - 1))
	done
	echo "$out"
}

# compare two cpulists by content, so "0,1,2,4" matches "0-2,4"
cpulist_norm() {
	expand_cpulist "$1" | sort -n | tr '\n' ' '
}

thp_current() {
	sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled
}

swap_kb() {
	awk 'NR>1 {s+=$3} END {print s+0}' /proc/swaps
}

# write a value, then read it back and confirm it stuck
set_verify() {
	path=$1
	want=$2
	echo "$want" > "$path" 2>/dev/null || die "cannot write $path (wanted $want)"
	got=$(cat "$path")
	[ "$got" = "$want" ] || die "$path reads back as '$got', expected '$want'"
}

preflight() {
	[ "$(id -u)" = 0 ] || die "must run as root"

	for c in systemctl awk sed sort tr; do
		have "$c" || die "missing required command: $c"
	done

	if ! have rfkill; then
		die_cmd "rfkill is not installed (needed to disable radios)" \
			"sudo apt install rfkill"
	fi

	if [ ! -d /sys/fs/cgroup/system.slice ]; then
		die "no cgroup v2 unified hierarchy at /sys/fs/cgroup -- shielding needs it"
	fi
	if ! grep -qw cpuset /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
		die_cmd "the cpuset cgroup controller is not enabled, so systemd cannot shield a CPU" \
			"cat /sys/fs/cgroup/cgroup.controllers" \
			"That lists the controllers actually available. If cpuset is
missing from it, this kernel or boot configuration cannot do cgroup
CPU shielding at all."
	fi

	# On a laptop, running on battery lets the firmware drop the CPU
	# clock when the charge gets low, which silently changes the
	# cycles-to-wall-time mapping mid-measurement.
	ac=0
	for f in /sys/class/power_supply/*/online; do
		[ -r "$f" ] || continue
		if [ "$(cat "$f")" = 1 ]; then
			ac=1
		fi
	done
	if [ "$ac" = 0 ]; then
		die "no AC adapter detected -- plug in the power cable; on battery the CPU clock can drop mid-run"
	fi

	# intel_pstate and nohz_full are incompatible: with nohz_full the
	# CPU frequency goes unstable under intel_pstate.
	# https://bugzilla.redhat.com/show_bug.cgi?id=1378529
	if [ -d /sys/devices/system/cpu/intel_pstate ]; then
		nhf=$(cat /sys/devices/system/cpu/nohz_full 2>/dev/null || echo "")
		case "$nhf" in
		"" | "(null)") ;;
		*) die "nohz_full=$nhf is active together with the intel_pstate driver; that combination makes the CPU frequency unstable (RH bug 1378529). Drop nohz_full= or boot with intel_pstate=disable." ;;
		esac
	fi

	[ -r /sys/devices/system/cpu/present ] || die "cannot read /sys/devices/system/cpu/present"
	[ -r /sys/kernel/mm/transparent_hugepage/enabled ] ||
		die "cannot read transparent_hugepage/enabled"
}

report() {
	max=$(cpu_max)
	echo "CPUs present:        0-$max"
	off=""
	i=0
	while [ "$i" -le "$max" ]; do
		f="/sys/devices/system/cpu/cpu$i/online"
		if [ -f "$f" ] && [ "$(cat "$f")" = 0 ]; then
			off="$off $i"
		fi
		i=$((i + 1))
	done
	echo "CPUs offline:       ${off:- none}"
	echo "governor (cpu0):     $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
	echo "no_turbo:            $(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo n/a)"
	echo "cpufreq boost:       $(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo n/a)"
	echo "cpu0 freq floor/ceil: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 2>/dev/null || echo n/a) / $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo n/a)"
	echo "on AC power:         $(cat /sys/class/power_supply/A*/online 2>/dev/null | head -1 || echo n/a)"
	echo "ASLR:                $(cat /proc/sys/kernel/randomize_va_space)"
	echo "THP:                 $(thp_current)"
	echo "swap in use (KiB):   $(swap_kb)"
	echo "perf sample rate:    $(cat /proc/sys/kernel/perf_event_max_sample_rate 2>/dev/null || echo n/a)"
	echo "system.slice cpus:   $(cat /sys/fs/cgroup/system.slice/cpuset.cpus.effective 2>/dev/null || echo n/a)"
	echo "user.slice cpus:     $(cat /sys/fs/cgroup/user.slice/cpuset.cpus.effective 2>/dev/null || echo n/a)"
	echo "tuning state file:   $([ -f "$STATE" ] && echo present || echo absent)"
}

do_reset() {
	max=$(cpu_max)

	i=0
	while [ "$i" -le "$max" ]; do
		f="/sys/devices/system/cpu/cpu$i/online"
		if [ -f "$f" ] && [ "$(cat "$f")" = 0 ]; then
			echo 1 > "$f" || note "warning: could not bring cpu $i back online"
		fi
		i=$((i + 1))
	done

	if [ -f "$STATE" ]; then
		. "$STATE"
		if [ "$governor" != unknown ]; then
			for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
				if [ -w "$f" ]; then
					echo "$governor" > "$f" 2>/dev/null || true
				fi
			done
		fi
		if [ "$turbo" != unknown ]; then
			echo "$turbo" > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
		fi
		if [ "${boost:-unknown}" != unknown ]; then
			echo "$boost" > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
		fi
		echo "$aslr" > /proc/sys/kernel/randomize_va_space 2>/dev/null || true
		if [ "$samplerate" != unknown ]; then
			echo "$samplerate" > /proc/sys/kernel/perf_event_max_sample_rate 2>/dev/null || true
		fi
		if [ -n "$thp" ]; then
			echo "$thp" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
		fi
		rm -f "$STATE"
	fi

	for d in /sys/devices/system/cpu/cpu*/cpufreq; do
		if [ -w "$d/scaling_min_freq" ] && [ -r "$d/cpuinfo_min_freq" ]; then
			cat "$d/cpuinfo_min_freq" > "$d/scaling_min_freq" 2>/dev/null || true
		fi
	done
	if [ -n "${defaffinity:-}" ] && [ "${defaffinity:-unknown}" != unknown ]; then
		echo "$defaffinity" > /proc/irq/default_smp_affinity 2>/dev/null || true
	fi

	for u in init.scope system.slice user.slice tune.slice; do
		systemctl set-property --runtime "$u" AllowedCPUs="0-$max" 2>/dev/null || true
	done
	for f in /proc/irq/[0-9]*/smp_affinity_list; do
		echo "0-$max" > "$f" 2>/dev/null || true
	done

	if have rfkill; then
		rfkill unblock all || true
	fi
	swapon -a 2>/dev/null || true
	for svc in irqbalance cron unattended-upgrades; do
		systemctl cat "$svc" >/dev/null 2>&1 && systemctl start "$svc" 2>/dev/null || true
	done
}

auto_select() {
	max=$1
	best=$max
	sibs=$(cat "/sys/devices/system/cpu/cpu$max/topology/thread_siblings_list" 2>/dev/null || echo "$max")
	for s in $(expand_cpulist "$sibs"); do
		if [ "$s" -lt "$best" ]; then
			best=$s
		fi
	done
	if [ "$best" = 0 ]; then
		die "auto-selected core is core 0 -- pass a CPU explicitly"
	fi
	echo "$best"
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

HOLD=0
if [ $# -ge 1 ] && [ "$1" = "--hold" ]; then
	HOLD=1
	shift
fi
[ $# -le 1 ] || die "usage: $0 [--hold] [cpu] | --reset | --check"

if [ "$HOLD" = 1 ] && [ $# -eq 1 ]; then
	case "$1" in
	--*) die "--hold cannot be combined with $1" ;;
	esac
fi

if [ $# -eq 1 ] && [ "$1" = "--check" ]; then
	[ "$(id -u)" = 0 ] || die "must run as root"
	report
	exit 0
fi

if [ $# -eq 1 ] && [ "$1" = "--reset" ]; then
	[ "$(id -u)" = 0 ] || die "must run as root"
	do_reset
	note "reset done"
	exit 0
fi

preflight

MAX=$(cpu_max)
[ "$MAX" -gt 0 ] || die "only one CPU present, nothing to isolate"

i=1
while [ "$i" -le "$MAX" ]; do
	f="/sys/devices/system/cpu/cpu$i/online"
	if [ -f "$f" ] && [ "$(cat "$f")" = 0 ]; then
		die_cmd "cpu $i is already offline, so a previous run did not finish" \
			"sudo $0 --reset"
	fi
	i=$((i + 1))
done
if [ -f "$STATE" ]; then
	die_cmd "$STATE exists: the system is already tuned, or a previous run left state behind" \
		"sudo $0 --reset"
fi

if [ $# -eq 1 ]; then
	case "$1" in
	*[!0-9]*) die "cpu must be a plain number, got '$1'" ;;
	esac
	BENCH=$1
	[ "$BENCH" -le "$MAX" ] || die "cpu $BENCH does not exist (max is $MAX)"
	if [ "$BENCH" = 0 ]; then
		die "refusing to isolate cpu 0"
	fi
else
	BENCH=$(auto_select "$MAX")
	note "auto-selected CPU $BENCH"
fi

{
	echo "governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
	echo "turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo unknown)"
	echo "boost=$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo unknown)"
	echo "aslr=$(cat /proc/sys/kernel/randomize_va_space)"
	echo "samplerate=$(cat /proc/sys/kernel/perf_event_max_sample_rate 2>/dev/null || echo unknown)"
	echo "thp=$(thp_current)"
	echo "defaffinity=$(cat /proc/irq/default_smp_affinity 2>/dev/null || echo unknown)"
} > "$STATE"
ARMED=1

note "blocking radios"
rfkill block all || die "rfkill block failed"

note "setting governor and turbo"
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
	[ -w "$f" ] || continue
	set_verify "$f" performance
done
# Turbo/boost is disabled before the ceiling is read below, so the clock
# gets pinned at the highest non-boost frequency. That is the only one
# the vendor guarantees can be sustained; any boost frequency may be
# dropped mid-run by thermal or power limits. Intel exposes the knob as
# intel_pstate/no_turbo, acpi-cpufreq and amd-pstate as cpufreq/boost.
if [ -w /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
	set_verify /sys/devices/system/cpu/intel_pstate/no_turbo 1
elif [ -w /sys/devices/system/cpu/cpufreq/boost ]; then
	set_verify /sys/devices/system/cpu/cpufreq/boost 0
else
	note "warning: no turbo/boost knob found; the pinned clock below may be one the CPU cannot sustain"
fi

# The governor alone only removes the scheduler's *preference* for lower
# clocks; the floor is still the hardware minimum. Raising
# scaling_min_freq to the maximum is what actually pins the clock, which
# is what keeps a perf cycle sample worth the same wall-clock time at the
# end of a recording as at the start.
note "pinning CPU frequency floor to its ceiling"
for d in /sys/devices/system/cpu/cpu*/cpufreq; do
	[ -w "$d/scaling_min_freq" ] || continue
	maxf=$(cat "$d/scaling_max_freq")
	set_verify "$d/scaling_min_freq" "$maxf"
done
PINNED=$(cat "/sys/devices/system/cpu/cpu$BENCH/cpufreq/scaling_max_freq" 2>/dev/null || echo unknown)

note "disabling ASLR and THP"
set_verify /proc/sys/kernel/randomize_va_space 0
echo never > /sys/kernel/mm/transparent_hugepage/enabled || die "cannot disable THP"
[ "$(thp_current)" = never ] || die "THP is still $(thp_current) after write"

used=$(swap_kb)
if [ "$used" -gt 0 ]; then
	note "disabling swap (${used} KiB in use -- this blocks until it is paged back in)"
else
	note "disabling swap (nothing in use)"
fi
swapoff -a || die "swapoff failed"
[ "$(swap_kb)" = 0 ] || die "swap still in use after swapoff"

note "stopping background services"
for svc in irqbalance cron unattended-upgrades; do
	if systemctl cat "$svc" >/dev/null 2>&1; then
		systemctl stop "$svc" || die "could not stop $svc"
	fi
done

# offline the SMT sibling(s) only after the governor pass above: taking a
# CPU down first leaves its cpufreq policy in a state that faults later
# writes (observed as "echo: I/O error").
note "offlining SMT sibling(s) of CPU $BENCH"
siblist=$(cat "/sys/devices/system/cpu/cpu$BENCH/topology/thread_siblings_list" 2>/dev/null || echo "$BENCH")
for s in $(expand_cpulist "$siblist"); do
	if [ "$s" = "$BENCH" ]; then
		continue
	fi
	set_verify "/sys/devices/system/cpu/cpu$s/online" 0
done

REMAINING=""
i=0
while [ "$i" -le "$MAX" ]; do
	if [ "$i" != "$BENCH" ]; then
		f="/sys/devices/system/cpu/cpu$i/online"
		if [ "$i" = 0 ] || { [ -f "$f" ] && [ "$(cat "$f")" = 1 ]; }; then
			REMAINING="$REMAINING,$i"
		fi
	fi
	i=$((i + 1))
done
REMAINING=${REMAINING#,}
[ -n "$REMAINING" ] || die "no CPUs left to host the system"

note "steering IRQs off CPU $BENCH"
moved=0
for f in /proc/irq/[0-9]*/smp_affinity_list; do
	echo "$REMAINING" > "$f" 2>/dev/null && moved=$((moved + 1)) || true
done
[ "$moved" -gt 0 ] || die "could not steer any IRQ away from CPU $BENCH"
# per-IRQ affinity only covers IRQs that exist now; default_smp_affinity
# governs any registered from here on
if [ -w /proc/irq/default_smp_affinity ]; then
	mask=$(cpulist_to_mask "$REMAINING" "$MAX")
	echo "$mask" > /proc/irq/default_smp_affinity ||
		die "could not set default_smp_affinity to $mask"
fi
note "  $moved IRQ(s) re-steered (some are pinned by the kernel and cannot move)"

# cgroup-v2-native shielding. cset is not an option: it only speaks
# cgroup v1, which Ubuntu dropped in 21.10.
note "shielding CPU $BENCH (AllowedCPUs=$REMAINING)"
for u in init.scope system.slice user.slice; do
	systemctl set-property --runtime "$u" AllowedCPUs="$REMAINING" ||
		die "systemctl set-property failed on $u"
done

# The isolated CPU needs a slice of its own, or nothing can run on it:
# every ordinary process lives under user.slice or system.slice, which
# were just restricted to the other CPUs. Workloads are started in it
# with "systemd-run --scope --slice=tune".
systemctl set-property --runtime tune.slice AllowedCPUs="$BENCH" ||
	die "could not create tune.slice for CPU $BENCH"

# verify the shielding actually constrains the cgroups, rather than just
# having been accepted by systemd
want=$(cpulist_norm "$REMAINING")
for c in system.slice user.slice; do
	f="/sys/fs/cgroup/$c/cpuset.cpus.effective"
	[ -r "$f" ] || die "cannot read $f to verify shielding"
	got=$(cpulist_norm "$(cat "$f")")
	[ "$got" = "$want" ] ||
		die "shielding did not take effect: $c has cpus '$(cat "$f")', expected '$REMAINING'"
done

# Everything pyperf's "system tune" would do here (ASLR, governor, turbo,
# IRQ affinity) is already done and verified above, and the one remaining
# thing it changes -- dropping perf_event_max_sample_rate to 1 -- would
# throttle the very perf record this machine is being tuned for. So the
# sample rate is raised here instead, and pyperf is not a dependency.
note "raising perf sample rate ceiling"
if [ -w /proc/sys/kernel/perf_event_max_sample_rate ]; then
	set_verify /proc/sys/kernel/perf_event_max_sample_rate "$SAMPLE_RATE"
else
	note "warning: perf_event_max_sample_rate not writable; left as-is"
fi

# nohz_full is deliberately not advised when intel_pstate is the driver:
# preflight refuses that combination outright (RH bug 1378529), so
# suggesting it here would contradict the check above.
params="isolcpus rcu_nocbs"
if [ ! -d /sys/devices/system/cpu/intel_pstate ]; then
	params="$params nohz_full"
fi
for p in $params; do
	case " $(cat /proc/cmdline) " in
	*" $p="*) ;;
	*) note "note: $p= absent from kernel cmdline (needs a reboot for full isolation)" ;;
	esac
done
if [ -d /sys/devices/system/cpu/intel_pstate ]; then
	note "note: nohz_full is not advised here -- it is incompatible with the intel_pstate driver this CPU uses"
fi

note "CPU $BENCH tuned and verified, clock pinned at $PINNED kHz"
note "run workloads on it inside tune.slice, e.g."
note ""
note "sudo systemd-run --scope --slice=tune --quiet perf record -e cycles:P -c 100003 -- ./program"
note ""

if [ "$HOLD" = 1 ]; then
	# ARMED stays set: Ctrl-C/SIGTERM raises a non-zero exit, and the
	# EXIT trap undoes everything on the way out.
	echo "$BENCH"
	note "holding CPU $BENCH -- profile from another terminal"
	note "press Ctrl-C here when done; the system will be restored"
	# short sleeps on purpose: a shell only runs a pending trap once the
	# current foreground command finishes, so a long sleep would delay
	# the rollback by however long remains of it.
	while :; do
		sleep 1
	done
fi

ARMED=0
echo "$BENCH"
