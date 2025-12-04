#!/bin/sh

countdown() {
    local seconds=$1
    local message=${2:-"Waiting"}
    local i=$seconds
    while [ $i -gt 0 ]; do
        printf "\r  ⏳ %s: %ds remaining..." "$message" "$i"
        sleep 1
        i=$((i - 1))
    done
    printf "\r  ✓ %s: Done!          \n" "$message"
}

get_pods_by_pattern() {
    local pattern=$1
    local namespace=$2
    kubectl get pods -n "$namespace" --no-headers 2>/dev/null | awk '{print $1}' | grep -E "$pattern" || true
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
    
    # Kiểm tra pod có tồn tại không
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
    
    # Nếu pod đang terminating, đợi nó terminate xong
    if is_pod_terminating "$pod" "$namespace"; then
        [ -n "$progress_file" ] && echo "[$pod] Already terminating, waiting..." >> "$progress_file"
        local elapsed=0
        while [ $elapsed -lt $timeout ] && pod_exists "$pod" "$namespace"; do
            sleep 2
            elapsed=$((elapsed + 2))
        done
    fi
    
    # Thử delete pod
    if kubectl delete pod "$pod" -n "$namespace" --wait=false >/dev/null 2>&1; then
        [ -n "$progress_file" ] && echo "[$pod] Deleted, waiting for recreation..." >> "$progress_file"
    elif ! pod_exists "$pod" "$namespace"; then
        [ -n "$progress_file" ] && echo "[$pod] Already deleted, waiting for recreation..." >> "$progress_file"
    fi
    
    # Đợi pod được recreate với progress updates
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
    
    # Kiểm tra lại lần cuối
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
    
    # Tạo temp directory để lưu output và kết quả của mỗi pod
    local temp_dir=$(mktemp -d 2>/dev/null || echo "/tmp/restart_pods_$$")
    local progress_file="$temp_dir/progress"
    > "$progress_file"
    
    # Nếu input là file path, dùng trực tiếp; nếu là string, normalize vào file
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
    
    # Khởi động restart cho mỗi pod trong background
    while IFS= read -r pod || [ -n "$pod" ]; do
        [ -z "$pod" ] && continue
        pod=$(printf "%s" "$pod" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\n\r')
        [ -z "$pod" ] && continue
        
        (
            restart_pod "$pod" "$namespace" "$timeout" "$progress_file" > "$temp_dir/${pod}.log" 2>&1
            echo $? > "$temp_dir/${pod}.result"
        ) &
    done < "$pod_list_file"
    
    # Hiển thị progress trong khi đợi
    local total_pods=$(wc -l < "$pod_list_file" 2>/dev/null | tr -d ' \n\r')
    total_pods=$(echo "$total_pods" | grep -E '^[0-9]+$' || echo "0")
    total_pods=$((total_pods + 0))
    
    local completed=0
    local last_line_count=0
    
    if [ "$total_pods" -eq 0 ] 2>/dev/null; then
        wait
        echo "0 0"
        rm -rf "$temp_dir"
        return
    fi
    
    echo "  Restarting $total_pods pod(s) in parallel..."
    while [ "$completed" -lt "$total_pods" ] 2>/dev/null; do
        sleep 2
        # Đếm số pods đã hoàn thành
        completed=$(grep -c "✓\|✗" "$progress_file" 2>/dev/null || echo "0")
        completed=$(echo "$completed" | tr -d ' \n\r')
        completed=$(echo "$completed" | grep -E '^[0-9]+$' || echo "0")
        completed=$((completed + 0))
        
        # Hiển thị progress mới
        local current_lines=$(wc -l < "$progress_file" 2>/dev/null | tr -d ' \n\r')
        current_lines=$(echo "$current_lines" | grep -E '^[0-9]+$' || echo "0")
        current_lines=$((current_lines + 0))
        if [ "$current_lines" -gt "$last_line_count" ] 2>/dev/null; then
            tail -n $((current_lines - last_line_count)) "$progress_file" 2>/dev/null | while IFS= read -r line; do
                echo "  $line"
            done
            last_line_count=$current_lines
        fi
        
        # Hiển thị progress nếu chưa xong
        if [ "$completed" -lt "$total_pods" ] 2>/dev/null; then
            local progress_percent=$((completed * 100 / total_pods))
            printf "  Progress: [%d/%d] %d%%\r" "$completed" "$total_pods" "$progress_percent"
        fi
    done
    
    # Đợi tất cả background jobs hoàn thành
    wait
    echo ""
    
    # Hiển thị kết quả cuối cùng
    echo ""
    local restarted=0
    local failed=0
    while IFS= read -r pod || [ -n "$pod" ]; do
        [ -z "$pod" ] && continue
        pod=$(printf "%s" "$pod" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\n\r')
        [ -z "$pod" ] && continue
        
        if [ -f "$temp_dir/${pod}.result" ]; then
            if [ "$(cat "$temp_dir/${pod}.result")" = "0" ]; then
                restarted=$((restarted + 1))
            else
                failed=$((failed + 1))
            fi
        else
            failed=$((failed + 1))
        fi
    done < "$pod_list_file"
    
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
    
    # Thu thập pods từ tất cả patterns vào temp file
    echo "  Searching for pods..."
    local temp_pods_file=$(mktemp 2>/dev/null || echo "/tmp/pods_$$")
    > "$temp_pods_file"
    local pattern_count=0
    local found_count=0
    
    for pattern; do
        pattern_count=$((pattern_count + 1))
        printf "  Checking pattern %d/%d: %s..." "$pattern_count" "$#" "$pattern"
        local found_pods=$(get_pods_by_pattern "$pattern" "$namespace" 2>&1)
        if [ -n "$found_pods" ]; then
            local pattern_pod_count=$(echo "$found_pods" | grep -c '^' || echo "0")
            found_count=$((found_count + pattern_pod_count))
            printf " found %d pod(s)\n" "$pattern_pod_count"
            printf "%s" "$found_pods" >> "$temp_pods_file"
            printf "\n" >> "$temp_pods_file"
        else
            printf " no pods found\n"
        fi
    done
    
    # Normalize: loại bỏ dòng trống, trim whitespace, sort, loại bỏ duplicate
    echo "  Normalizing pod list..."
    local temp_normalized=$(mktemp 2>/dev/null || echo "/tmp/pods_norm_$$")
    cat "$temp_pods_file" | grep -v '^[[:space:]]*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r' | sort -u | while IFS= read -r pod || [ -n "$pod" ]; do
        pod=$(printf "%s" "$pod" | tr -d '\n\r')
        [ -z "$pod" ] && continue
        printf "%s\n" "$pod" >> "$temp_normalized"
    done
    
    rm -f "$temp_pods_file"
    
    if [ ! -s "$temp_normalized" ]; then
        echo "  ⚠ No pods found for $group_name"
        rm -f "$temp_normalized"
        return
    fi
    
    # Đếm và hiển thị pods
    local pod_count=$(wc -l < "$temp_normalized" 2>/dev/null | tr -d ' \n\r')
    pod_count=$(echo "$pod_count" | grep -E '^[0-9]+$' || echo "0")
    pod_count=$((pod_count + 0))
    
    echo "  ✓ Found $pod_count pod(s):"
    cat "$temp_normalized" | while IFS= read -r pod; do
        [ -z "$pod" ] && continue
        pod=$(printf "%s" "$pod" | tr -d '\n\r')
        [ -n "$pod" ] && echo "    - $pod"
    done
    echo ""
    
    # Restart pods song song - truyền file thay vì string để tránh newline issues
    local result=$(restart_pods_parallel "$temp_normalized" "$namespace" "$wait_time")
    local restarted=$(echo "$result" | awk '{print $1}')
    local failed=$(echo "$result" | awk '{print $2}')
    
    rm -f "$temp_normalized"
    
    echo "  ✓ $group_name: $restarted restarted, $failed failed"
    if [ $wait_time -gt 0 ]; then
        echo "  ⏳ Waiting ${wait_time}s for pods to stabilize..."
        sleep "$wait_time"
    fi
}

show_pod_status() {
    local pattern=$1
    local namespace=$2
    echo ""
    echo "Current pod status:"
    kubectl get pods -n "$namespace" | grep -E "$pattern" || echo "  (No pods found)"
}
