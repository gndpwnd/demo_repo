#!/bin/bash

# File: git_timer.sh - track commit time, today time, and total time across sessions

TMP_START="/tmp/git_timer_start"
TMP_LAST="/tmp/git_timer_last"
TMP_LOG="/tmp/git_timer_log"
ALIAS_FILE="/tmp/git_timer_aliases"

start_timer() {
    now=$(date +%s)
    echo "$now" > "$TMP_START"
    echo "$now" > "$TMP_LAST"

    echo "✅ Timer started at $(date -d @$now)"

    cat <<EOF > "$ALIAS_FILE"
alias gcm='bash $(realpath "$0") commit'
alias gtimer-stop='bash $(realpath "$0") stop'
alias gtime='bash $(realpath "$0") time'
alias gcmm='bash $(realpath "$0") gcmm'
alias gcl='git log --pretty=format:"%ad %s"'
alias gll='git log'
alias gch='git checkout'  # Add this line for the alias
EOF

    echo "🔗 To use aliases in this terminal, run: source $ALIAS_FILE"
}


format_time() {
    secs=$1
    printf "%02d:%02d:%02d" $((secs/3600)) $(((secs%3600)/60)) $((secs%60))
}

log_duration() {
    now=$(date +%s)
    echo "$now $1" >> "$TMP_LOG"
}

get_today_and_total_seconds() {
    today_total=0
    total=0
    today_date=$(date +%Y-%m-%d)

    while read -r line; do
        ts=$(echo "$line" | awk '{print $1}')
        dur=$(echo "$line" | awk '{print $2}')
        line_date=$(date -d @"$ts" +%Y-%m-%d)
        total=$((total + dur))
        if [ "$line_date" = "$today_date" ]; then
            today_total=$((today_total + dur))
        fi
    done < "$TMP_LOG"

    echo "$today_total $total"
}

commit_with_time() {
    if [ ! -f "$TMP_LAST" ]; then
        echo "❌ Timer not started. Run: $(realpath "$0") start"
        exit 1
    fi

    now=$(date +%s)
    last_time=$(cat "$TMP_LAST")

    diff=$((now - last_time))
    echo "$now" > "$TMP_LAST"

    log_duration "$diff"

    read today_total total < <(get_today_and_total_seconds)

    formatted_diff=$(format_time $diff)
    formatted_today=$(format_time $today_total)
    formatted_total=$(format_time $total)

    custom_message="$*"
    if [ -z "$custom_message" ]; then
        full_message="Commit ($formatted_diff), Today ($formatted_today), Total ($formatted_total)"
    else
        full_message="$custom_message ($formatted_diff), Today ($formatted_today), Total ($formatted_total)"
    fi

    echo "📝 Committing with message:"
    echo "\"$full_message\""
    
    git add -A
    git commit -m "$full_message"

    # Get current branch name
    branch=$(git rev-parse --abbrev-ref HEAD)

    # Check if upstream exists
    if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
        echo "🚀 Pushing to upstream: $branch"
        git push
    else
        echo "🚧 No upstream for '$branch'. Setting upstream and pushing..."
        git push --set-upstream origin "$branch"
    fi

}

# Convert time in HH:MM:SS format to total seconds
convert_to_seconds() {
    time_str=$1
    IFS=':' read -r hours minutes seconds <<< "$time_str"
    echo $((hours * 3600 + minutes * 60 + seconds))
}

# Convert seconds back to HH:MM:SS format
format_time() {
    seconds=$1
    printf "%02d:%02d:%02d\n" $((seconds / 3600)) $(( (seconds / 60) % 60)) $((seconds % 60))
}

gcmm() {
    # Check if the timer file exists
    if [ ! -f "$TMP_LAST" ]; then
        echo "❌ Timer not started. Run: $(realpath "$0") start"
        exit 1
    fi

    # Define current branch and source branch to merge
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    source_branch="$1"  # The first argument is the source branch to merge from

    if [ -z "$source_branch" ]; then
        echo "❌ Please specify a source branch to merge from."
        exit 1
    fi

    # Check if the source branch exists
    if ! git show-ref --quiet refs/heads/"$source_branch"; then
        echo "❌ Source branch '$source_branch' does not exist."
        exit 1
    fi

    # Get the total timestamp from the source branch (to be merged)
    source_branch_commit_time=$(git log "$source_branch" --pretty=format:"%s" -n 1 | grep -oP "Total \(\K[0-9]{2}:[0-9]{2}:[0-9]{2}" || echo "00:00:00")
    
    # Get the total timestamp from the current branch (target branch)
    current_branch_commit_time=$(git log "$current_branch" --pretty=format:"%s" -n 1 | grep -oP "Total \(\K[0-9]{2}:[0-9]{2}:[0-9]{2}" || echo "00:00:00")
    
    # Convert the timestamps to seconds
    source_seconds=$(convert_to_seconds "$source_branch_commit_time")
    current_seconds=$(convert_to_seconds "$current_branch_commit_time")
    
    # Calculate the combined total time (source + current)
    # If both are zero, use the data from the time tracking file
    if [ "$source_seconds" -eq 0 ] && [ "$current_seconds" -eq 0 ]; then
        read today_total total < <(get_today_and_total_seconds)
        total_seconds=$total
        # If still zero, default to current branch time
        if [ "$total_seconds" -eq 0 ]; then
            total_seconds=$current_seconds
        fi
    else
        total_seconds=$((source_seconds + current_seconds))
    fi
    
    # Final safeguard: if total is still zero, use at least the current branch time
    if [ "$total_seconds" -eq 0 ]; then
        total_seconds=$current_seconds
    fi
    
    # Format the times for the commit message
    formatted_source_time=$(format_time $source_seconds)
    formatted_current_time=$(format_time $current_seconds)
    formatted_total_time=$(format_time $total_seconds)
    
    # Create the merge commit message
    merge_message="🔀 Merging branch '$source_branch' into '$current_branch' - Source ($formatted_source_time), Current ($formatted_current_time), Total ($formatted_total_time)"
    
    echo "📝 Merging with message:"
    echo "\"$merge_message\""
    
    # Perform the actual merge with the custom message
    git merge "$source_branch" --no-ff -m "$merge_message"
    
    # Log the merge duration in our time tracking
    now=$(date +%s)
    last_time=$(cat "$TMP_LAST")
    diff=$((now - last_time))
    echo "$now" > "$TMP_LAST"
    log_duration "$diff"
    
    # Push changes
    if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
        echo "🚀 Pushing to upstream: $current_branch"
        git push
    else
        echo "🚧 No upstream for '$current_branch'. Setting upstream and pushing..."
        git push --set-upstream origin "$current_branch"
    fi
}


print_git_times() {
    if [ ! -f "$TMP_LAST" ]; then
        echo "❌ Timer not started. Run: bash $(realpath "$0") start"
        return 1
    fi

    now=$(date +%s)
    last_time=$(cat "$TMP_LAST")
    diff=$((now - last_time))

    read today_total total < <(get_today_and_total_seconds)

    formatted_diff=$(format_time $diff)
    formatted_today=$(format_time $today_total)
    formatted_total=$(format_time $total)

    echo "⏱️ Time since last commit: $formatted_diff"
    echo "📆 Total time today:        $formatted_today"
    echo "🕒 Total time overall:      $formatted_total"
}

stop_timer() {
    rm -f "$TMP_START" "$TMP_LAST" "$ALIAS_FILE"
    echo "🛑 Timer stopped and aliases removed."
    echo "💡 You may want to run: unalias gcm; unalias gtime; unalias gtimer-stop"
}

# Main handler
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