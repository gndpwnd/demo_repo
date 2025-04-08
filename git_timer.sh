#!/bin/bash

# File: git_timer.sh - track commit time, session time, and total time across sessions

TMP_START="/tmp/git_timer_start"
TMP_LAST="/tmp/git_timer_last"
TMP_LOG="/tmp/git_timer_log"
TMP_SESSION="/tmp/git_timer_session"
ALIAS_FILE="/tmp/git_timer_aliases"

# Generate a unique session ID
generate_session_id() {
    while true; do
        id=$(head -c 32 /dev/urandom | sha256sum | cut -c1-12)
        if ! git log --grep="SESSID: $id" | grep -q "$id"; then
            echo "$id"
            return
        fi
    done
}

start_timer() {
    now=$(date +%s)
    echo "$now" > "$TMP_START"
    echo "$now" > "$TMP_LAST"

    if [ ! -f "$TMP_SESSION" ]; then
        session_id=$(generate_session_id)
        echo "$session_id" > "$TMP_SESSION"
    fi

    echo "✅ Timer started at $(date -d @$now)"

    cat <<EOF > "$ALIAS_FILE"
alias gcm='bash $(realpath "$0") commit'
alias gtimer-stop='bash $(realpath "$0") stop'
alias gtime='bash $(realpath "$0") time'
alias gcmm='bash $(realpath "$0") gcmm'
alias gcl='git log --pretty=format:"%ad %s"'
alias gll='git log'
alias gch='git checkout'
EOF

    echo "🔗 To use aliases in this terminal, run: source $ALIAS_FILE"
}

format_time() {
    seconds=$1
    printf "%02d:%02d:%02d" $((seconds / 3600)) $(((seconds / 60) % 60)) $((seconds % 60))
}

log_duration() {
    now=$(date +%s)
    echo "$now $1" >> "$TMP_LOG"
}

get_session_and_total_seconds() {
    session_total=0
    session_id=$(cat "$TMP_SESSION")

    while read -r line; do
        ts=$(echo "$line" | awk '{print $1}')
        dur=$(echo "$line" | awk '{print $2}')
        sid=$(echo "$line" | awk '{print $3}')

        if [ "$sid" = "$session_id" ]; then
            session_total=$((session_total + dur))
        fi
    done < "$TMP_LOG"

    echo "$session_total"
}

commit_with_time() {
    if [ ! -f "$TMP_LAST" ]; then
        echo "❌ Timer not started. Run: $(realpath "$0") start"
        exit 1
    fi

    session_id=$(cat "$TMP_SESSION")
    now=$(date +%s)
    last_time=$(cat "$TMP_LAST")

    diff=$((now - last_time))
    echo "$now" > "$TMP_LAST"

    echo "$now $diff $session_id" >> "$TMP_LOG"

    session_total=$(get_session_and_total_seconds)
    formatted_diff=$(format_time $diff)
    formatted_session=$(format_time $session_total)

    custom_message="$*"
    if [ -z "$custom_message" ]; then
        full_message="Commit ($formatted_diff), Session ($formatted_session) [SESSID: $session_id]"
    else
        full_message="$custom_message ($formatted_diff), Session ($formatted_session) [SESSID: $session_id]"
    fi

    echo "📝 Committing with message:"
    echo "\"$full_message\""

    git add -A
    git commit -m "$full_message"

    branch=$(git rev-parse --abbrev-ref HEAD)

    if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
        echo "🚀 Pushing to upstream: $branch"
        git push
    else
        echo "🚧 No upstream for '$branch'. Setting upstream and pushing..."
        git push --set-upstream origin "$branch"
    fi
}

convert_to_seconds() {
    time_str=$1
    if [[ $time_str =~ ([0-9]+):([0-9]+):([0-9]+) ]]; then
        hours=${BASH_REMATCH[1]#0}
        minutes=${BASH_REMATCH[2]#0}
        seconds=${BASH_REMATCH[3]#0}
        echo $((10#$hours * 3600 + 10#$minutes * 60 + 10#$seconds))
    else
        echo "0"
    fi
}

gcmm() {
    now=$(date +%s)
    last_time=$(cat "$TMP_LAST")
    diff=$((now - last_time))
    echo "$now" > "$TMP_LAST"
    session_id=$(cat "$TMP_SESSION")
    echo "$now $diff $session_id" >> "$TMP_LOG"

    echo "ℹ️ Merge session logged"
}

print_git_times() {
    now=$(date +%s)
    session_id=$(cat "$TMP_SESSION")
    last_sess_commit_time=0

    while read -r line; do
        ts=$(echo "$line" | awk '{print $1}')
        sid=$(echo "$line" | awk '{print $3}')
        if [[ "$sid" == "$session_id" ]]; then
            last_sess_commit_time=$ts
        fi
    done < "$TMP_LOG"

    if [[ "$last_sess_commit_time" -eq 0 ]]; then
        start_time=$(cat "$TMP_START")
        diff=$((now - start_time))
        formatted_diff=$(format_time $diff)
        echo "⏱️ No commits in this session yet. Time since timer started: $formatted_diff"
    else
        diff=$((now - last_sess_commit_time))
        formatted_diff=$(format_time $diff)
        echo "⏱️ Time since last commit (this session): $formatted_diff"
    fi

    declare -A session_times
    declare -A branches

    while read -r branch_hash; do
        branch=$(git branch --contains "$branch_hash" 2>/dev/null | sed -n 's/*\? //p')
        [[ -n "$branch" ]] && branches["$branch"]=1
    done < <(git log --format=%H)

    while IFS= read -r line; do
        sess_id=$(echo "$line" | grep -oE "SESSID: [a-f0-9]{12}" | awk '{print $2}')
        dur=$(echo "$line" | grep -oE "\([0-9]{2}:[0-9]{2}:[0-9]{2}\)" | head -1 | tr -d '()')
        dur_secs=$(convert_to_seconds "$dur")

        if [[ -n "$sess_id" && "$dur_secs" -gt "${session_times[$sess_id]:-0}" ]]; then
            session_times[$sess_id]=$dur_secs
        fi
    done < <(git log --pretty=format:"%s")

    total_sum=0
    for val in "${session_times[@]}"; do
        total_sum=$((total_sum + val))
    done

    formatted_total=$(format_time $total_sum)
    echo "🧩 Total across sessions:  $formatted_total"
    echo -n "       Branches Included: "
    echo "${!branches[@]}" | tr ' ' ','
}

stop_timer() {
    rm -f "$TMP_START" "$TMP_LAST" "$TMP_SESSION" "$ALIAS_FILE"
    echo "🛑 Timer stopped and aliases removed."
    echo "💡 You may want to run: unalias gcm; unalias gtime; unalias gtimer-stop"
}

case "$1" in
    start)
        start_timer
        ;;
    commit)
        shift
        commit_with_time "$@"
        ;;
    time)
        print_git_times
        ;;
    stop)
        stop_timer
        ;;
    gcmm)
        shift
        gcmm "$@"
        ;;
    *)
        echo "Usage:"
        echo "  bash git_timer.sh start         # Start the timer and create aliases"
        echo "  gcm <your message>              # Add files to commit, commit with time info, push origin"
        echo "  gtime                           # Show elapsed/total time"
        echo "  gtimer-stop                     # Stop timer and cleanup"
        echo "  gcmm <target_branch>            # Merge target branch into current with timestamp commit message"
        ;;
esac
#!/bin/bash

# File: git_timer.sh - track commit time, session time, and total time across sessions

TMP_START="/tmp/git_timer_start"
TMP_LAST="/tmp/git_timer_last"
TMP_LOG="/tmp/git_timer_log"
TMP_SESSION="/tmp/git_timer_session"
ALIAS_FILE="/tmp/git_timer_aliases"

# Generate a unique session ID
generate_session_id() {
    while true; do
        id=$(head -c 32 /dev/urandom | sha256sum | cut -c1-12)
        if ! git log --grep="SESSID: $id" | grep -q "$id"; then
            echo "$id"
            return
        fi
    done
}

start_timer() {
    now=$(date +%s)
    echo "$now" > "$TMP_START"
    echo "$now" > "$TMP_LAST"

    if [ ! -f "$TMP_SESSION" ]; then
        session_id=$(generate_session_id)
        echo "$session_id" > "$TMP_SESSION"
    fi

    echo "✅ Timer started at $(date -d @$now)"

    cat <<EOF > "$ALIAS_FILE"
alias gcm='bash $(realpath "$0") commit'
alias gtimer-stop='bash $(realpath "$0") stop'
alias gtime='bash $(realpath "$0") time'
alias gcmm='bash $(realpath "$0") gcmm'
alias gcl='git log --pretty=format:"%ad %s"'
alias gll='git log'
alias gch='git checkout'
EOF

    echo "🔗 To use aliases in this terminal, run: source $ALIAS_FILE"
}

format_time() {
    seconds=$1
    printf "%02d:%02d:%02d" $((seconds / 3600)) $(((seconds / 60) % 60)) $((seconds % 60))
}

log_duration() {
    now=$(date +%s)
    echo "$now $1" >> "$TMP_LOG"
}

get_session_and_total_seconds() {
    session_total=0
    session_id=$(cat "$TMP_SESSION")

    while read -r line; do
        ts=$(echo "$line" | awk '{print $1}')
        dur=$(echo "$line" | awk '{print $2}')
        sid=$(echo "$line" | awk '{print $3}')

        if [ "$sid" = "$session_id" ]; then
            session_total=$((session_total + dur))
        fi
    done < "$TMP_LOG"

    echo "$session_total"
}

commit_with_time() {
    if [ ! -f "$TMP_LAST" ]; then
        echo "❌ Timer not started. Run: $(realpath "$0") start"
        exit 1
    fi

    session_id=$(cat "$TMP_SESSION")
    now=$(date +%s)
    last_time=$(cat "$TMP_LAST")

    diff=$((now - last_time))
    echo "$now" > "$TMP_LAST"

    echo "$now $diff $session_id" >> "$TMP_LOG"

    session_total=$(get_session_and_total_seconds)
    formatted_diff=$(format_time $diff)
    formatted_session=$(format_time $session_total)

    custom_message="$*"
    if [ -z "$custom_message" ]; then
        full_message="Commit ($formatted_diff), Session ($formatted_session) [SESSID: $session_id]"
    else
        full_message="$custom_message ($formatted_diff), Session ($formatted_session) [SESSID: $session_id]"
    fi

    echo "📝 Committing with message:"
    echo "\"$full_message\""

    git add -A
    git commit -m "$full_message"

    branch=$(git rev-parse --abbrev-ref HEAD)

    if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
        echo "🚀 Pushing to upstream: $branch"
        git push
    else
        echo "🚧 No upstream for '$branch'. Setting upstream and pushing..."
        git push --set-upstream origin "$branch"
    fi
}

convert_to_seconds() {
    time_str=$1
    if [[ $time_str =~ ([0-9]+):([0-9]+):([0-9]+) ]]; then
        hours=${BASH_REMATCH[1]#0}
        minutes=${BASH_REMATCH[2]#0}
        seconds=${BASH_REMATCH[3]#0}
        echo $((10#$hours * 3600 + 10#$minutes * 60 + 10#$seconds))
    else
        echo "0"
    fi
}

gcmm() {
    now=$(date +%s)
    last_time=$(cat "$TMP_LAST")
    diff=$((now - last_time))
    echo "$now" > "$TMP_LAST"
    session_id=$(cat "$TMP_SESSION")
    echo "$now $diff $session_id" >> "$TMP_LOG"

    current_branch=$(git rev-parse --abbrev-ref HEAD)
    target_branch="$1"
    if [ -z "$target_branch" ]; then
        echo "❌ Please specify a branch to merge."
        return 1
    fi

    formatted_diff=$(format_time $diff)
    session_total=$(get_session_and_total_seconds)
    formatted_session=$(format_time $session_total)

    full_message="Merge $target_branch onto $current_branch Commit ($formatted_diff), Session ($formatted_session) [SESSID: $session_id]"

    echo "📝 Merging '$target_branch' into '$current_branch' with commit message:"
    echo "$full_message"

    git merge "$target_branch" -m "$full_message"

    if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
        echo "🚀 Pushing to upstream: $current_branch"
        git push
    else
        echo "🚧 No upstream for '$current_branch'. Setting upstream and pushing..."
        git push --set-upstream origin "$current_branch"
    fi

    echo "ℹ️ Merge session logged"
}

print_git_times() {
    now=$(date +%s)
    session_id=$(cat "$TMP_SESSION")
    last_sess_commit_time=0

    while read -r line; do
        ts=$(echo "$line" | awk '{print $1}')
        sid=$(echo "$line" | awk '{print $3}')
        if [[ "$sid" == "$session_id" ]]; then
            last_sess_commit_time=$ts
        fi
    done < "$TMP_LOG"

    if [[ "$last_sess_commit_time" -eq 0 ]]; then
        start_time=$(cat "$TMP_START")
        diff=$((now - start_time))
        formatted_diff=$(format_time $diff)
        echo "⏱️ No commits in this session yet. Time since timer started: $formatted_diff"
    else
        diff=$((now - last_sess_commit_time))
        formatted_diff=$(format_time $diff)
        echo "⏱️ Time since last commit (this session): $formatted_diff"
    fi

    declare -A session_times
    declare -A branches

    while read -r branch_hash; do
        branch=$(git branch --contains "$branch_hash" 2>/dev/null | sed -n 's/*\? //p')
        [[ -n "$branch" ]] && branches["$branch"]=1
    done < <(git log --format=%H)

    while IFS= read -r line; do
        sess_id=$(echo "$line" | grep -oE "SESSID: [a-f0-9]{12}" | awk '{print $2}')
        dur=$(echo "$line" | grep -oE "\([0-9]{2}:[0-9]{2}:[0-9]{2}\)" | head -1 | tr -d '()')
        dur_secs=$(convert_to_seconds "$dur")

        if [[ -n "$sess_id" && "$dur_secs" -gt "${session_times[$sess_id]:-0}" ]]; then
            session_times[$sess_id]=$dur_secs
        fi
    done < <(git log --pretty=format:"%s")

    total_sum=0
    for val in "${session_times[@]}"; do
        total_sum=$((total_sum + val))
    done

    formatted_total=$(format_time $total_sum)
    echo "🧩 Total across sessions:  $formatted_total"
    echo -n "       Branches Included: "
    echo "${!branches[@]}" | tr ' ' ','
}

stop_timer() {
    rm -f "$TMP_START" "$TMP_LAST" "$TMP_SESSION" "$ALIAS_FILE"
    echo "🛑 Timer stopped and aliases removed."
    echo "💡 You may want to run: unalias gcm; unalias gtime; unalias gtimer-stop"
}

case "$1" in
    start)
        start_timer
        ;;
    commit)
        shift
        commit_with_time "$@"
        ;;
    time)
        print_git_times
        ;;
    stop)
        stop_timer
        ;;
    gcmm)
        shift
        gcmm "$@"
        ;;
    *)
        echo "Usage:"
        echo "  bash git_timer.sh start         # Start the timer and create aliases"
        echo "  gcm <your message>              # Add files to commit, commit with time info, push origin"
        echo "  gtime                           # Show elapsed/total time"
        echo "  gtimer-stop                     # Stop timer and cleanup"
        echo "  gcmm <target_branch>            # Merge target branch into current with timestamp commit message"
        ;;
esac