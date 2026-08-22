#!/bin/sh

# IPv6状态监控脚本
# 保存为 /etc/ppp/monitor_ipv6.sh
# 添加执行权限: chmod +x /etc/ppp/monitor_ipv6.sh

# 日志函数
log() {
    logger -t "IPv6-Monitor" "$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> /var/log/ipv6-monitor.log
}

# 检查IPv6是否正常（是否有全局IPv6地址）
check_ipv6_normal() {
    # 检查pppoe-wan是否有全局IPv6地址（不以fe80开头）
    if ip -6 addr show pppoe-wan 2>/dev/null | grep -q "inet6 2[0-9a-f:]*" || \
       ip -6 addr show pppoe-wan 2>/dev/null | grep -q "inet6 3[0-9a-f:]*"; then
        return 0  # 正常，有全局IPv6
    else
        return 1  # 异常，只有链路本地地址
    fi
}

# 检查IPv6是否异常（只有链路本地地址）
check_ipv6_abnormal() {
    # 检查是否有pppoe-wan接口
    if ! ip link show pppoe-wan >/dev/null 2>&1; then
        return 1  # 接口不存在，也算异常
    fi

    # 检查是否有链路本地地址但没有全局地址
    if ip -6 addr show pppoe-wan 2>/dev/null | grep -q "inet6 fe80" && \
       ! ip -6 addr show pppoe-wan 2>/dev/null | grep -q "inet6 2[0-9a-f:]" && \
       ! ip -6 addr show pppoe-wan 2>/dev/null | grep -q "inet6 3[0-9a-f:]"; then
        return 1  # 确实处于异常状态（只有fe80地址）
    else
        return 0  # 不是异常状态
    fi
}

# 重启wan6接口
restart_wan6() {
    log "正在重启wan6接口..."

    # 重启wan6接口
    ifdown wan6 >/dev/null 2>&1
    sleep 3
    ifup wan6 >/dev/null 2>&1

    log "wan6接口重启命令已执行"
}

# 等待IPv6恢复正常
wait_for_ipv6_recovery() {
    local wait_time=0
    local max_wait=30  # 最大等待30秒

    log "等待IPv6恢复，最多等待${max_wait}秒..."

    while [ $wait_time -lt $max_wait ]; do
        if check_ipv6_normal; then
            log "IPv6已恢复正常，耗时${wait_time}秒"
            return 0
        fi

        sleep 1
        wait_time=$((wait_time + 1))
    done

    log "等待超时，IPv6未能恢复正常"
    return 1
}

# 主监控逻辑
main() {
    log "IPv6状态监控脚本启动"
    log "正常状态: 有全局IPv6地址"
    log "异常状态: 只有链路本地地址(fe80::)"

    PREV_STATE="normal"  # 假设初始状态为normal
    ABNORMAL_START_TIME=0
    CHECK_INTERVAL=2  # 检查间隔2秒
    CONFIRM_TIME=5    # 确认时间为5秒

    while true; do
        CURRENT_TIME=$(date +%s)

        # 检查当前IPv6状态
        if check_ipv6_normal; then
            # 当前状态正常
            if [ "$PREV_STATE" = "abnormal" ]; then
                log "IPv6已恢复正常，重置监控状态"
                PREV_STATE="normal"
                ABNORMAL_START_TIME=9999999999
            fi
        elif check_ipv6_abnormal; then
            # 当前状态异常
            case "$PREV_STATE" in
                "normal")
                    # 第一次检测到异常，开始计时
                    log "首次检测到IPv6异常，开始5秒确认"
                    PREV_STATE="checking"
                    ABNORMAL_START_TIME=$CURRENT_TIME
                    ;;
                "checking")
                    # 在确认阶段，检查是否达到5秒
                    if [ $((CURRENT_TIME - ABNORMAL_START_TIME)) -ge $CONFIRM_TIME ]; then
                        log "IPv6异常已持续5秒，执行重启操作"

                        # 重启wan6接口
                        restart_wan6

                        # 等待恢复
                        if wait_for_ipv6_recovery; then
                            log "IPv6已成功恢复"
                            PREV_STATE="normal"
                            ABNORMAL_START_TIME=9999999999
                        else
                            log "IPv6恢复失败，将继续监控"
                            PREV_STATE="abnormal"  # 重置状态，避免连续重启
                        fi
                    fi
                    ;;
                "abnormal")
                    # 计算时间差
                    diff=$((CURRENT_TIME - ABNORMAL_START_TIME))

                    # 判断是否为5分钟的倍数（300秒）
                    if [ $((diff % 300)) -eq 0 ] && [ $diff -ge 300 ]; then
                        echo "时间差正好是5分钟的倍数，当前差值: ${diff}秒"
                        restart_wan6
                        if wait_for_ipv6_recovery; then
                            log "IPv6已成功恢复"
                            PREV_STATE="normal"
                            ABNORMAL_START_TIME=9999999999
                        fi
                    fi
                    ;;
            esac
        fi
        sleep $CHECK_INTERVAL
    done
}

# 运行主函数
main
