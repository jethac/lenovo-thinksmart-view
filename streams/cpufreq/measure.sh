#!/bin/sh
# CPU frequency / thermal measurements on the ThinkSmart View (run as root on
# the device, under the device lock). Output goes to stdout.
#
#   measure.sh info            governor, OPPs, idle states, trips
#   measure.sh idle [S]        sample freq/voltage/temps for S s (default 30)
#   measure.sh follow          idle -> one busy thread -> eight -> idle, 0.25 s samples
#   measure.sh volts           rail voltage at each OPP (userspace governor, restored)
#   measure.sh bench           openssl sha256 throughput, 1 core and 8 cores
#   measure.sh soak [S]        all-core load for S s (default 600), 10 s samples
set -u
CF=/sys/devices/system/cpu/cpufreq/policy0
S5=$(grep -l '^s5$' /sys/class/regulator/regulator.*/name | head -1 | xargs dirname)
TZ=/sys/class/thermal

temps() {	# "max cpu0..7 gpu pmic" in 0.1 C
	for z in $TZ/thermal_zone*; do printf '%s=%s ' "$(cat $z/type | sed 's/-thermal//')" "$(cat $z/temp)"; done
}
maxcpu() {
	m=0; for z in $TZ/thermal_zone*; do case $(cat $z/type) in cpu*) t=$(cat $z/temp); [ $t -gt $m ] && m=$t;; esac; done; echo $m
}
cdev() {
	for c in $TZ/cooling_device*; do printf '%s=%s ' "$(cat $c/type)" "$(cat $c/cur_state)"; done
}
line() {
	printf '%s f=%s max=%s uv=%s tmax=%s %s %s\n' "$(cut -d' ' -f1 /proc/uptime)" \
		"$(cat $CF/scaling_cur_freq)" "$(cat $CF/scaling_max_freq)" "$(cat $S5/microvolts)" \
		"$(maxcpu)" "$(cdev)" "$*"
}
burn() {	# burn N: N pinned busy loops, prints pids
	i=0; while [ $i -lt $1 ]; do taskset -c $i sh -c 'while :; do :; done' & i=$((i+1)); done
}

case ${1:-info} in
info)
	uname -r
	for f in scaling_driver scaling_governor related_cpus scaling_available_frequencies \
		cpuinfo_min_freq cpuinfo_max_freq scaling_min_freq scaling_max_freq; do
		echo "$f: $(cat $CF/$f)"; done
	echo "cpuidle: $(cat /sys/devices/system/cpu/cpuidle/current_driver)"
	for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
		echo "  $(cat $s/name) lat=$(cat $s/latency) res=$(cat $s/residency) usage=$(cat $s/usage) time_us=$(cat $s/time)"; done
	for z in $TZ/thermal_zone*; do printf '%s %s temp=%s' $(basename $z) $(cat $z/type) $(cat $z/temp)
		for t in $z/trip_point_*_temp; do n=${t%_temp}; printf ' %s/%s/hyst%s' $(cat $t) $(cat ${n}_type) $(cat ${n}_hyst 2>/dev/null); done; echo; done
	for c in $TZ/cooling_device*; do echo "$(basename $c) $(cat $c/type) $(cat $c/cur_state)/$(cat $c/max_state)"; done
	dmesg | grep -iE 'opp config|psci|cpr4pd|cpufreq' ;;
idle)
	n=${2:-30}; cp $CF/stats/time_in_state /tmp/tis0 2>/dev/null
	i=0; while [ $i -lt $n ]; do line "$(temps)"; sleep 1; i=$((i+1)); done
	echo "time_in_state delta (10 ms units):"; cat $CF/stats/time_in_state | while read f t; do
		o=$(awk -v f=$f '$1==f{print $2}' /tmp/tis0); echo "  $f $((t-o))"; done ;;
quiet)	# no sampling: diff time_in_state and idle residency over S s
	n=${2:-60}; cp $CF/stats/time_in_state /tmp/tis0
	for c in 0 4; do for s in 0 1; do cat /sys/devices/system/cpu/cpu$c/cpuidle/state$s/time; done; done > /tmp/idle0
	for g in cluster0 cluster1; do awk '/^S[0-9]/{print $2}' /sys/kernel/debug/pm_genpd/power-domain-$g/idle_states; done > /tmp/gpd0
	sleep $n
	echo "time_in_state over $n s (10 ms units):"; cat $CF/stats/time_in_state | while read f t; do
		o=$(awk -v f=$f '$1==f{print $2}' /tmp/tis0); echo "  $f $((t-o))"; done
	echo "cpuidle residency over $n s, ms (cpu0 WFI, cpu0 PC, cpu4 WFI, cpu4 PC):"
	for c in 0 4; do for s in 0 1; do cat /sys/devices/system/cpu/cpu$c/cpuidle/state$s/time; done; done | paste - /tmp/idle0 | awk '{printf "  %d", ($1-$2)/1000} END{print ""}'
	echo "cluster genpd state time over $n s, ms (cluster0 S0 S1 S2, cluster1 S0 S1 S2):"
	for g in cluster0 cluster1; do awk '/^S[0-9]/{print $2}' /sys/kernel/debug/pm_genpd/power-domain-$g/idle_states; done | paste - /tmp/gpd0 | awk '{printf "  %d", $1-$2} END{print ""}'
	cat /sys/kernel/debug/pm_genpd/power-domain-cluster0/idle_states_desc 2>/dev/null
	echo "temps: $(temps)" ;;
follow)
	sample() { k=0; while [ $k -lt $1 ]; do echo "$2 $(cut -d' ' -f1 /proc/uptime) $(cat $CF/scaling_cur_freq) $(cat $S5/microvolts)"; sleep 0.25; k=$((k+1)); done; }
	sample 12 idle
	burn 1; sample 20 load1; kill $(jobs -p) 2>/dev/null; wait 2>/dev/null
	sample 12 idle
	burn 8; sample 20 load8; kill $(jobs -p) 2>/dev/null; wait 2>/dev/null
	sample 16 idle ;;
volts)
	g=$(cat $CF/scaling_governor); echo userspace > $CF/scaling_governor
	for f in $(cat $CF/scaling_available_frequencies); do echo $f > $CF/scaling_setspeed; sleep 1
		echo "$f kHz: cur=$(cat $CF/scaling_cur_freq) $(cat $S5/microvolts) uV"; done
	echo $g > $CF/scaling_governor ;;
bench)
	echo "1 core (cpu0), 10 s:"; taskset -c 0 openssl speed -seconds 10 -bytes 16384 sha256 2>/dev/null | grep -E '^sha256'
	echo "1 core (cpu4), 10 s:"; taskset -c 4 openssl speed -seconds 10 -bytes 16384 sha256 2>/dev/null | grep -E '^sha256'
	echo "8 cores, 10 s:"; openssl speed -multi 8 -seconds 10 -bytes 16384 sha256 2>/dev/null | grep -E '^sha256'
	line "after bench" ;;
soak)
	n=${2:-600}; echo "start $(temps)"
	cp $CF/stats/time_in_state /tmp/tis0
	# eight workers, each reporting sha256 throughput every 10 s
	i=0; while [ $i -lt 8 ]; do
		taskset -c $i sh -c 'while :; do openssl speed -seconds 10 -bytes 16384 sha256 2>/dev/null | awk "/^sha256/{print \$NF}" > /tmp/soak.'$i'.new; mv /tmp/soak.'$i'.new /tmp/soak.'$i'; done' &
		i=$((i+1)); done
	t=0; while [ $t -lt $n ]; do sleep 10; t=$((t+10))
		tp=0; for i in 0 1 2 3 4 5 6 7; do v=$(cat /tmp/soak.$i 2>/dev/null | sed 's/k$//'); tp=$(awk -v a=$tp -v b=${v:-0} 'BEGIN{print a+b}'); done
		line "t=$t sha256_kBps_sum=$tp $(temps)"; done
	pkill -f 'openssl speed' ; kill $(jobs -p) 2>/dev/null; wait 2>/dev/null; pkill -f 'openssl speed'
	echo "time_in_state delta (10 ms units):"; cat $CF/stats/time_in_state | while read f t; do
		o=$(awk -v f=$f '$1==f{print $2}' /tmp/tis0); echo "  $f $((t-o))"; done
	echo "cooldown:"; k=0; while [ $k -lt 6 ]; do sleep 10; line "$(temps)"; k=$((k+1)); done
	dmesg | grep -iE 'thermal|critical|throttl' | tail ;;
esac
