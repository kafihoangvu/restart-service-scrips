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
    
    echo "  - Restarting $pod"
    
    # Kiểm tra pod có tồn tại không
    if ! pod_exists "$pod" "$namespace"; then
        echo "    ⚠ Pod $pod does not exist, may have been deleted already"
        echo "    Waiting for pod to be recreated..."
        local elapsed=0
        while [ $elapsed -lt $timeout ]; do
            if pod_exists "$pod" "$namespace"; then
                local new_phase=$(get_pod_phase "$pod" "$namespace")
                if [ "$new_phase" = "Running" ] || [ "$new_phase" = "Pending" ]; then
                    echo "    ✓ Pod recreated, new status: $new_phase"
                    return 0
                fi
            fi
            sleep 2
            elapsed=$((elapsed + 2))
        done
        echo "    ⚠ Pod recreation timeout (waited ${timeout}s)"
        return 1
    fi
    
    local phase=$(get_pod_phase "$pod" "$namespace")
    echo "    Current status: $phase"
    
    # Nếu pod đang terminating, đợi nó terminate xong
    if is_pod_terminating "$pod" "$namespace"; then
        echo "    ⚠ Pod is already terminating, waiting for termination..."
        local elapsed=0
        while [ $elapsed -lt $timeout ] && pod_exists "$pod" "$namespace"; do
            sleep 2
            elapsed=$((elapsed + 2))
        done
        if pod_exists "$pod" "$namespace"; then
            echo "    ⚠ Pod still exists after ${timeout}s, trying to force delete..."
        else
            echo "    ✓ Pod terminated successfully"
        fi
    fi
    
    # Thử delete pod
    if kubectl delete pod "$pod" -n "$namespace" --wait=false >/dev/null 2>&1; then
        echo "    ✓ Delete command sent successfully"
    elif ! pod_exists "$pod" "$namespace"; then
        echo "    ✓ Pod already deleted"
    else
        echo "    ⚠ Delete command failed, but continuing to wait for recreation..."
    fi
    
    # Đợi pod được recreate
    echo "    Waiting for pod to be recreated..."
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if pod_exists "$pod" "$namespace"; then
            local new_phase=$(get_pod_phase "$pod" "$namespace")
            if [ "$new_phase" = "Running" ] || [ "$new_phase" = "Pending" ]; then
                echo "    ✓ Pod recreated, new status: $new_phase"
                return 0
            elif [ "$new_phase" = "Unknown" ]; then
                # Nếu vẫn Unknown, đợi thêm một chút
                sleep 2
                elapsed=$((elapsed + 2))
                continue
            fi
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    # Kiểm tra lại lần cuối
    if pod_exists "$pod" "$namespace"; then
        local final_phase=$(get_pod_phase "$pod" "$namespace")
        if [ "$final_phase" = "Running" ] || [ "$final_phase" = "Pending" ]; then
            echo "    ✓ Pod recreated, new status: $final_phase"
            return 0
        else
            echo "    ⚠ Pod recreation timeout, final status: $final_phase (waited ${timeout}s)"
            return 1
        fi
    else
        echo "    ⚠ Pod recreation timeout, pod not found (waited ${timeout}s)"
        return 1
    fi
}

restart_pods_parallel() {
    local pods="$1"
    local namespace=$2
    local timeout=${3:-30}
    
    # Tạo temp directory để lưu output và kết quả của mỗi pod
    local temp_dir=$(mktemp -d 2>/dev/null || echo "/tmp/restart_pods_$$")
    
    # Thu thập và normalize pod names vào file
    printf "%s" "$pods" | while IFS= read -r pod || [ -n "$pod" ]; do
        pod=$(printf "%s" "$pod" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\n\r')
        [ -z "$pod" ] && continue
        echo "$pod" >> "$temp_dir/pod_list"
    done
    
    # Khởi động restart cho mỗi pod trong background
    while IFS= read -r pod; do
        [ -z "$pod" ] && continue
        (
            restart_pod "$pod" "$namespace" "$timeout" > "$temp_dir/${pod}.log" 2>&1
            echo $? > "$temp_dir/${pod}.result"
        ) &
    done < "$temp_dir/pod_list"
    
    # Đợi tất cả background jobs hoàn thành
    wait
    
    # Hiển thị output và đếm kết quả
    local restarted=0
    local failed=0
    while IFS= read -r pod; do
        [ -z "$pod" ] && continue
        
        [ -f "$temp_dir/${pod}.log" ] && cat "$temp_dir/${pod}.log"
        
        if [ -f "$temp_dir/${pod}.result" ]; then
            [ "$(cat "$temp_dir/${pod}.result")" = "0" ] && restarted=$((restarted + 1)) || failed=$((failed + 1))
        else
            failed=$((failed + 1))
        fi
    done < "$temp_dir/pod_list"
    
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
    echo "Step $step_num: Restarting $group_name pods..."
    
    # Thu thập pods từ tất cả patterns
    local all_pods=""
    for pattern; do
        local found_pods=$(get_pods_by_pattern "$pattern" "$namespace")
        if [ -n "$found_pods" ]; then
            all_pods="$all_pods$found_pods\n"
        fi
    done
    
    # Normalize: loại bỏ dòng trống, trim whitespace, sort, loại bỏ duplicate
    all_pods=$(printf "%s" "$all_pods" | grep -v '^[[:space:]]*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sort -u)
    
    if [ -z "$all_pods" ]; then
        echo "  ⚠ No pods found for $group_name"
        return
    fi
    
    local pod_count=$(printf "%s" "$all_pods" | grep -c . || echo "0")
    echo "  ✓ Found $pod_count pod(s):"
    printf "%s" "$all_pods" | sed 's/^/    - /'
    echo ""
    
    # Restart pods song song
    local result=$(restart_pods_parallel "$all_pods" "$namespace" "$wait_time")
    local restarted=$(echo "$result" | awk '{print $1}')
    local failed=$(echo "$result" | awk '{print $2}')
    
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
