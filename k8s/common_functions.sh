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

    # Nếu pod không còn tồn tại (có thể đã được xóa bởi process khác) thì bỏ qua, không coi là lỗi
    if ! pod_exists "$pod" "$namespace"; then
        echo "  ⚠ Pod $pod not found in namespace $namespace, skipping"
        return 0
    fi

    # Nếu pod đang terminating thì đợi nó terminate xong trước khi tiếp tục,
    # nhưng không fail nếu sau timeout vẫn còn (vì việc xóa có thể đang được xử lý bởi K8s)
    if is_pod_terminating "$pod" "$namespace"; then
        local elapsed=0
        while [ $elapsed -lt $timeout ] && pod_exists "$pod" "$namespace"; do
            sleep 2
            elapsed=$((elapsed + 2))
        done
    fi

    # Thử xóa pod. Nếu lệnh xóa trả về thành công hoặc pod biến mất sau đó,
    # chúng ta coi như restart đã được trigger thành công (Deployment/StatefulSet sẽ tự tạo lại pod).
    if kubectl delete pod "$pod" -n "$namespace" --wait=false >/dev/null 2>&1; then
        return 0
    fi

    # Nếu lệnh delete fail, nhưng pod thực tế đã biến mất thì vẫn coi là thành công.
    if ! pod_exists "$pod" "$namespace"; then
        return 0
    fi

    # Lệnh delete fail và pod vẫn còn tồn tại -> coi là thất bại.
    echo "  ✗ Failed to delete pod $pod in namespace $namespace"
    return 1
}

restart_pods_parallel() {
    local pods_input="$1"
    local namespace=$2
    local timeout=${3:-30}
    
    local temp_dir=$(mktemp -d 2>/dev/null || echo "/tmp/restart_pods_$$")
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
            restart_pod "$pod" "$namespace" "$timeout" > "$temp_dir/${pod}.log" 2>&1
            echo $? > "$temp_dir/${pod}.result"
        ) &
    done < "$pod_list_file"
    
    local total_pods=$(wc -l < "$pod_list_file" 2>/dev/null | tr -d ' \n\r')
    total_pods=$(echo "$total_pods" | grep -E '^[0-9]+$' || echo "0")
    total_pods=$((total_pods + 0))
    
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
    echo "Step $step_num: Restarting $group_name workloads in namespace $namespace"
    
    # Tìm các Deployment/StatefulSet theo pattern
    local temp_workloads_file
    temp_workloads_file=$(mktemp 2>/dev/null || echo "/tmp/workloads_$$")
    > "$temp_workloads_file"
    
    for pattern; do
        local found_workloads
        found_workloads=$(kubectl get deploy,statefulset -n "$namespace" --no-headers 2>/dev/null \
            -o custom-columns=KIND:.kind,NAME:.metadata.name \
            | awk -v p="$pattern" '$2 ~ p {print $1 " " $2}')
        if [ -n "$found_workloads" ]; then
            printf "%s\n" "$found_workloads" >> "$temp_workloads_file"
        else
            echo "  ⚠ No workloads found for pattern '$pattern' in namespace '$namespace'"
        fi
    done
    
    if [ ! -s "$temp_workloads_file" ] 2>/dev/null; then
        echo "  ⚠ No workloads found for $group_name, skipping..."
        rm -f "$temp_workloads_file" 2>/dev/null || true
        return 0
    fi
    
    # Loại trùng lặp và chuẩn hóa danh sách workload
    sort -u "$temp_workloads_file" -o "$temp_workloads_file" 2>/dev/null || true
    
    local workload_count
    workload_count=$(wc -l < "$temp_workloads_file" 2>/dev/null | tr -d ' ' || echo "0")
    workload_count=${workload_count:-0}
    
    if [ "$workload_count" -eq 0 ] 2>/dev/null; then
        echo "  ⚠ No workloads found for $group_name, skipping..."
        rm -f "$temp_workloads_file" 2>/dev/null || true
        return 0
    fi
    
    echo "  ✓ Found $workload_count workload(s):"
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        echo "    - $line"
    done < "$temp_workloads_file"
    echo ""
    
    # Rollout restart cho từng workload
    local restarted=0
    local failed=0
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        local kind name
        kind=$(printf "%s" "$line" | awk '{print $1}')
        name=$(printf "%s" "$line" | awk '{print $2}')
        [ -z "$kind" ] && continue
        [ -z "$name" ] && continue
        
        local kind_lc
        kind_lc=$(printf "%s" "$kind" | tr 'A-Z' 'a-z')
        
        if kubectl rollout restart "$kind_lc/$name" -n "$namespace" >/dev/null 2>&1; then
            restarted=$((restarted + 1))
        else
            failed=$((failed + 1))
            echo "  ✗ Failed to rollout restart $kind_lc/$name"
        fi
    done < "$temp_workloads_file"
    
    rm -f "$temp_workloads_file" 2>/dev/null || true
    
    echo "  ✓ $group_name: $restarted restarted, $failed failed"
    if [ $wait_time -gt 0 ]; then
        countdown "$wait_time" "Stabilizing $group_name pods"
    fi
    
    # Hiển thị trạng thái health sau khi stabilizing (Running/Ready) cho toàn bộ patterns trong group
    if [ "$restarted" -gt 0 ] 2>/dev/null; then
        local combined_pattern=""
        for pattern; do
            if [ -z "$combined_pattern" ]; then
                combined_pattern="$pattern"
            else
                combined_pattern="$combined_pattern|$pattern"
            fi
        done
        if [ -n "$combined_pattern" ]; then
            show_pod_status "$combined_pattern" "$namespace"
        fi
    fi
}

show_pod_status() {
    local pattern=$1
    local namespace=$2
    echo ""
    echo "Current pod status:"
    kubectl get pods -n "$namespace" | grep -E "$pattern" || echo "  (No pods found)"
}
