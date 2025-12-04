#!/bin/sh

countdown() {
    local seconds=$1
    local message=${2:-"Waiting"}
    if [ "$seconds" -gt 0 ] 2>/dev/null; then
        printf "  ⏳ %s (%ds)...\n" "$message" "$seconds"
        sleep "$seconds"
    fi
}

get_pods_by_pattern() {
    local pattern=$1
    local namespace=$2
    kubectl get pods -n "$namespace" --no-headers 2>/dev/null 2>&1 | awk '{print $1}' 2>/dev/null | grep -E "$pattern" 2>/dev/null || true
}

get_pod_phase() {
    local pod=$1
    local namespace=$2
    kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown"
}

is_pod_terminating() {
    local pod=$1
    local namespace=$2
    local deletion_timestamp=$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)
    [ -n "$deletion_timestamp" ]
}

pod_exists() {
    local pod=$1
    local namespace=$2
    kubectl get pod "$pod" -n "$namespace" >/dev/null 2>&1
}

restart_pod() {
    local pod=$1
    local namespace=$2
    local timeout=${3:-30}
    local progress_file="${4:-}"
    
    if ! pod_exists "$pod" "$namespace"; then
        [ -n "$progress_file" ] && echo "[$pod] Waiting for recreation..." >> "$progress_file"
        local elapsed=0
        while [ $elapsed -lt $timeout ]; do
            if pod_exists "$pod" "$namespace"; then
                local new_phase=$(get_pod_phase "$pod" "$namespace")
                if [ "$new_phase" = "Running" ] || [ "$new_phase" = "Pending" ]; then
                    [ -n "$progress_file" ] && echo "[$pod] ✓ Recreated ($new_phase)" >> "$progress_file"
                    return 0
                fi
            fi
            sleep 2
            elapsed=$((elapsed + 2))
        done
        [ -n "$progress_file" ] && echo "[$pod] ✗ Timeout" >> "$progress_file"
        return 1
    fi
    
    local phase=$(get_pod_phase "$pod" "$namespace")
    [ -n "$progress_file" ] && echo "[$pod] Status: $phase, deleting..." >> "$progress_file"
    
    if is_pod_terminating "$pod" "$namespace"; then
        [ -n "$progress_file" ] && echo "[$pod] Already terminating, waiting..." >> "$progress_file"
        local elapsed=0
        while [ $elapsed -lt $timeout ] && pod_exists "$pod" "$namespace"; do
            sleep 2
            elapsed=$((elapsed + 2))
        done
    fi
    
    if kubectl delete pod "$pod" -n "$namespace" --wait=false >/dev/null 2>&1; then
        [ -n "$progress_file" ] && echo "[$pod] Deleted, waiting for recreation..." >> "$progress_file"
    elif ! pod_exists "$pod" "$namespace"; then
        [ -n "$progress_file" ] && echo "[$pod] Already deleted, waiting for recreation..." >> "$progress_file"
    fi
    
    local elapsed=0
    local last_status=""
    while [ $elapsed -lt $timeout ]; do
        if pod_exists "$pod" "$namespace"; then
            local new_phase=$(get_pod_phase "$pod" "$namespace")
            if [ "$new_phase" != "$last_status" ]; then
                [ -n "$progress_file" ] && echo "[$pod] Status: $new_phase" >> "$progress_file"
                last_status="$new_phase"
            fi
            if [ "$new_phase" = "Running" ] || [ "$new_phase" = "Pending" ]; then
                [ -n "$progress_file" ] && echo "[$pod] ✓ Recreated ($new_phase)" >> "$progress_file"
                return 0
            fi
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    if pod_exists "$pod" "$namespace"; then
        local final_phase=$(get_pod_phase "$pod" "$namespace")
        if [ "$final_phase" = "Running" ] || [ "$final_phase" = "Pending" ]; then
            [ -n "$progress_file" ] && echo "[$pod] ✓ Recreated ($final_phase)" >> "$progress_file"
            return 0
        else
            [ -n "$progress_file" ] && echo "[$pod] ✗ Timeout (status: $final_phase)" >> "$progress_file"
            return 1
        fi
    else
        [ -n "$progress_file" ] && echo "[$pod] ✗ Timeout (not found)" >> "$progress_file"
        return 1
    fi
}

restart_pods_parallel() {
    local pods_input="$1"
    local namespace=$2
    local timeout=${3:-30}
    
    local temp_dir=$(mktemp -d 2>/dev/null || echo "/tmp/restart_pods_$$")
    local progress_file="$temp_dir/progress"
    > "$progress_file"
    
    local pod_list_file="$temp_dir/pod_list"
    > "$pod_list_file"
    
    if [ -f "$pods_input" ]; then
        cat "$pods_input" | while IFS= read -r pod || [ -n "$pod" ]; do
            pod=$(printf "%s" "$pod" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\n\r')
            [ -z "$pod" ] && continue
            printf "%s\n" "$pod" >> "$pod_list_file"
        done
    else
        printf "%s" "$pods_input" | while IFS= read -r pod || [ -n "$pod" ]; do
            pod=$(printf "%s" "$pod" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\n\r')
            [ -z "$pod" ] && continue
            printf "%s\n" "$pod" >> "$pod_list_file"
        done
    fi
    
    while IFS= read -r pod || [ -n "$pod" ]; do
        [ -z "$pod" ] && continue
        pod=$(printf "%s" "$pod" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\n\r')
        [ -z "$pod" ] && continue
        
        (
            restart_pod "$pod" "$namespace" "$timeout" "$progress_file" > "$temp_dir/${pod}.log" 2>&1
            echo $? > "$temp_dir/${pod}.result"
        ) &
    done < "$pod_list_file"
    
    local total_pods=$(wc -l < "$pod_list_file" 2>/dev/null | tr -d ' \n\r')
    total_pods=$(echo "$total_pods" | grep -E '^[0-9]+$' || echo "0")
    total_pods=$((total_pods + 0))
    
    local completed=0
    local last_line_count=0
    
    if [ "$total_pods" -eq 0 ] 2>/dev/null; then
        wait 2>/dev/null || true
        echo "0 0"
        rm -rf "$temp_dir" 2>/dev/null || true
        return 0
    fi
    
    wait
    
    local restarted=0
    local failed=0
    local restarted_pods=""
    local failed_pods=""
    
    while IFS= read -r pod || [ -n "$pod" ]; do
        [ -z "$pod" ] && continue
        pod=$(printf "%s" "$pod" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\n\r')
        [ -z "$pod" ] && continue
        
        if [ -f "$temp_dir/${pod}.result" ]; then
            if [ "$(cat "$temp_dir/${pod}.result")" = "0" ]; then
                restarted=$((restarted + 1))
                restarted_pods="$restarted_pods$pod "
            else
                failed=$((failed + 1))
                failed_pods="$failed_pods$pod "
            fi
        else
            failed=$((failed + 1))
            failed_pods="$failed_pods$pod "
        fi
    done < "$pod_list_file"
    
    if [ $restarted -gt 0 ]; then
        echo "  ✓ Successfully restarted ($restarted): $(echo "$restarted_pods" | sed 's/ $//')"
    fi
    
    if [ $failed -gt 0 ]; then
        echo "  ✗ Failed ($failed): $(echo "$failed_pods" | sed 's/ $//')"
    fi
    
    rm -rf "$temp_dir"
    echo "$restarted $failed"
}

restart_group_pods() {
    local step_num=$1
    local group_name=$2
    local namespace=$3
    local wait_time=${4:-30}
    shift 4
    
    echo ""
    echo "Step $step_num: Restarting $group_name pods in namespace $namespace"
    
    local temp_pods_file=$(mktemp 2>/dev/null || echo "/tmp/pods_$$")
    > "$temp_pods_file"
    
    for pattern; do
        local found_pods=$(get_pods_by_pattern "$pattern" "$namespace" 2>/dev/null || true)
        if [ -n "$found_pods" ] && [ "$found_pods" != "" ]; then
            printf "%s" "$found_pods" >> "$temp_pods_file" 2>/dev/null || true
            printf "\n" >> "$temp_pods_file" 2>/dev/null || true
        fi
    done
    
    local temp_normalized=$(mktemp 2>/dev/null || echo "/tmp/pods_norm_$$")
    cat "$temp_pods_file" | grep -v '^[[:space:]]*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r' | sort -u | while IFS= read -r pod || [ -n "$pod" ]; do
        pod=$(printf "%s" "$pod" | tr -d '\n\r')
        [ -z "$pod" ] && continue
        printf "%s\n" "$pod" >> "$temp_normalized"
    done
    
    rm -f "$temp_pods_file"
    
    if [ ! -s "$temp_normalized" ] 2>/dev/null; then
        echo "  ⚠ No pods found for $group_name, skipping..."
        rm -f "$temp_normalized" 2>/dev/null || true
        return 0
    fi
    
    local pod_count=$(wc -l < "$temp_normalized" 2>/dev/null | tr -d ' ' || echo "0")
    pod_count=${pod_count:-0}
    
    if [ "$pod_count" -eq 0 ] 2>/dev/null; then
        echo "  ⚠ No pods found for $group_name, skipping..."
        rm -f "$temp_normalized" 2>/dev/null || true
        return 0
    fi
    
    echo "  ✓ Found $pod_count pod(s):"
    cat "$temp_normalized" 2>/dev/null | while IFS= read -r pod || [ -n "$pod" ]; do
        [ -z "$pod" ] && continue
        pod=$(printf "%s" "$pod" | tr -d '\n\r')
        [ -n "$pod" ] && echo "    - $pod"
    done || true
    echo ""
    
    local result=$(restart_pods_parallel "$temp_normalized" "$namespace" "$wait_time" 2>/dev/null || echo "0 0")
    local restarted=$(echo "$result" | awk '{print $1}' 2>/dev/null || echo "0")
    local failed=$(echo "$result" | awk '{print $2}' 2>/dev/null || echo "0")
    
    rm -f "$temp_normalized" 2>/dev/null || true
    
    echo "  ✓ $group_name: $restarted restarted, $failed failed"
    if [ $wait_time -gt 0 ]; then
        countdown "$wait_time" "Stabilizing $group_name pods"
    fi
}

show_pod_status() {
    local pattern=$1
    local namespace=$2
    echo ""
    echo "Current pod status:"
    kubectl get pods -n "$namespace" | grep -E "$pattern" || echo "  (No pods found)"
}
