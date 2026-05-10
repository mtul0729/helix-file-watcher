#!/usr/bin/env bash
set -euo pipefail

session="hx-file-watcher-test-$$"
workdir="${HELIX_FILE_WATCHER_TEST_DIR:-/tmp/hx-file-watcher-zellij}"
file="$workdir/watched.txt"
hx_log="$workdir/hx.log"
zellij_log="$workdir/zellij.typescript"
layout="$workdir/layout.kdl"
cpu_samples="$workdir/cpu-samples.tsv"
cpu_summary="$workdir/cpu-summary.txt"

rm -rf "$workdir"
mkdir -p "$workdir"
printf 'initial\n' > "$file"

cat > "$layout" <<EOF
layout {
    pane split_direction="vertical" {
        pane name="hx" command="bash" {
            args "-lc" "TERM=xterm-256color RUST_BACKTRACE=1 timeout 10 hx -vvv --log '$hx_log' '$file'"
        }
        pane name="writer" command="bash" {
            args "-lc" "sleep 2; printf 'first\n' > '$file'; sleep 3; printf 'second\n' > '$file'; sleep 6"
        }
    }
}
EOF

total_ticks() {
    awk '/^cpu / { total = 0; for (i = 2; i <= NF; i++) total += $i; print total }' /proc/stat
}

thread_ticks() {
    local pid="$1"
    local tid="$2"
    local stat_file="/proc/$pid/task/$tid/stat"
    [[ -r "$stat_file" ]] || return 1
    awk '{ print $14 + $15 }' "$stat_file"
}

find_hx_pid() {
    ps -eo pid,comm,args |
        awk -v file_path="$file" -v hx_log_path="$hx_log" '
            ($2 == ".hx-wrapped" || $2 == "hx") && ($0 ~ file_path || $0 ~ hx_log_path) {
                print $1
                exit
            }
        '
}

hx_threads() {
    local pid="$1"
    [[ -n "$pid" && -d "/proc/$pid/task" ]] || return 0
    for task in /proc/"$pid"/task/*; do
        [[ -d "$task" ]] || continue
        local tid comm
        tid="${task##*/}"
        comm="$(cat "$task/comm" 2>/dev/null || true)"
        printf '%s\t%s\t%s\n' "$pid" "$tid" "$comm"
    done
}

sample_cpu() {
    local parent_pid="$1"
    local ncpu prev_total current_total timestamp hx_pid pid tid comm previous current cpu
    ncpu="$(nproc)"
    declare -A previous_ticks=()
    printf 'timestamp\tpid\ttid\tcomm\tinterval_cpu_percent\n' > "$cpu_samples"

    while kill -0 "$parent_pid" 2>/dev/null; do
        hx_pid="$(find_hx_pid)"
        if [[ -z "$hx_pid" ]]; then
            sleep 0.2
            continue
        fi

        prev_total="$(total_ticks)"
        while kill -0 "$parent_pid" 2>/dev/null && [[ -d "/proc/$hx_pid/task" ]]; do
            sleep 0.5
            current_total="$(total_ticks)"
            timestamp="$(date +%s.%N)"
            while IFS=$'\t' read -r pid tid comm; do
                [[ -n "${tid:-}" ]] || continue
                current="$(thread_ticks "$pid" "$tid" || true)"
                [[ -n "$current" ]] || continue
                previous="${previous_ticks[$tid]:-}"
                if [[ -n "$previous" && "$current_total" -gt "$prev_total" ]]; then
                    cpu="$(awk -v dt="$((current - previous))" -v ds="$((current_total - prev_total))" -v n="$ncpu" 'BEGIN { printf "%.2f", (dt / ds) * n * 100 }')"
                    printf '%s\t%s\t%s\t%s\t%s\n' "$timestamp" "$pid" "$tid" "$comm" "$cpu" >> "$cpu_samples"
                fi
                previous_ticks[$tid]="$current"
            done < <(hx_threads "$hx_pid")
            prev_total="$current_total"
        done
    done
}

summarize_cpu() {
    if [[ ! -s "$cpu_samples" ]] || [[ "$(wc -l < "$cpu_samples")" -le 1 ]]; then
        printf 'no hx cpu samples captured\n' > "$cpu_summary"
        return
    fi

    awk -F '\t' '
        NR > 1 {
            sample_count += 1
            cpu = $5 + 0
            total += cpu
            if (cpu > max) {
                max = cpu
                max_line = $0
            }
            per_tid_sum[$3] += cpu
            per_tid_count[$3] += 1
            if (cpu > per_tid_max[$3]) per_tid_max[$3] = cpu
        }
        END {
            printf "sample_count=%d\n", sample_count
            printf "overall_avg_cpu_percent=%.2f\n", total / sample_count
            printf "overall_max_cpu_percent=%.2f\n", max
            printf "overall_max_sample=%s\n", max_line
            print "per_thread:"
            for (tid in per_tid_sum) {
                printf "tid=%s avg=%.2f max=%.2f samples=%d\n", tid, per_tid_sum[tid] / per_tid_count[tid], per_tid_max[tid], per_tid_count[tid]
            }
        }
    ' "$cpu_samples" > "$cpu_summary"
}

set +e
script -qfec "TERM=xterm-256color timeout 14 zellij --session '$session' --new-session-with-layout '$layout'" "$zellij_log" >/dev/null &
zellij_pid=$!
sample_cpu "$zellij_pid" &
sampler_pid=$!
wait "$zellij_pid"
zellij_status=$?
wait "$sampler_pid" 2>/dev/null
set -e

zellij kill-session "$session" >/dev/null 2>&1 || true
summarize_cpu

echo "zellij_status=$zellij_status"
echo "workdir=$workdir"
echo "file_content=$(tr '\n' ' ' < "$file")"
echo
echo "cpu summary:"
cat "$cpu_summary"
echo
echo "interesting hx log lines:"
rg -n "watching open files|starting event loop|reloading file|Failed canonicalizing|err|panic|Error|init\\.scm|file-watcher|borrowed mutably" "$hx_log" || true
echo
echo "remaining processes:"
ps -eo pid,ppid,comm,args --sort=pid | rg 'hx|nixd|zellij|hx-file-watcher-zellij' || true
