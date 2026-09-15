#!/bin/bash

# 火焰图生成脚本（支持自定义路径与保留 perf.data）
# 版本: 6.0

# ============== 配置区 ==============
PERF_PATH="/usr/bin/perf"                              # perf 绝对路径
FLAMEGRAPH_DIR="/home/xu/ysmd_humble/perf_analysis/FlameGraph"
DEFAULT_FREQ=99
MIN_DURATION=5
KEEP_DATA=true                                         # 是否保留 perf 数据包
# ===================================

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

show_help() {
    echo -e "${GREEN}火焰图生成脚本${NC}"
    echo -e "配置路径:"
    echo -e "  perf工具: ${BLUE}${PERF_PATH}${NC}"
    echo -e "  FlameGraph: ${BLUE}${FLAMEGRAPH_DIR}${NC}"
    echo -e "\n用法:"
    echo -e "  $0 ${BLUE}<pid> [频率] [时长] [输出名] [--keep-data]${NC}"
    echo -e "  $0 ${BLUE}--check${NC}"
    echo -e "  $0 ${BLUE}--help${NC}"
    echo -e "\n说明:"
    echo -e "  --keep-data    采样完成后保留原始 perf 数据包，保存为 <输出名>.data"
    echo -e "\n示例:"
    echo -e "  $0 1234"
    echo -e "  $0 1234 199 10"
    echo -e "  $0 1234 99 30 my_app --keep-data"
    echo -e "  $0 --check"
}

check_environment() {
    local all_ok=true
    echo -e "\n${GREEN}▶ 环境检查${NC}"

    # perf
    if [ -x "$PERF_PATH" ]; then
        echo -e "✓ perf工具: ${BLUE}$PERF_PATH${NC}"
        $PERF_PATH --version | head -n 1 ||:
    else
        echo -e "${RED}✗ 找不到perf工具: $PERF_PATH${NC}"
        echo -e "  尝试查找: find /usr/lib/linux-tools -name perf"
        all_ok=false
    fi

    # FlameGraph
    if [ -f "${FLAMEGRAPH_DIR}/flamegraph.pl" ] && [ -f "${FLAMEGRAPH_DIR}/stackcollapse-perf.pl" ]; then
        echo -e "\n✓ FlameGraph工具: ${BLUE}${FLAMEGRAPH_DIR}${NC}"
        grep -m1 'Version' "${FLAMEGRAPH_DIR}/flamegraph.pl" 2>/dev/null ||:
    else
        echo -e "\n${RED}✗ 找不到FlameGraph工具${NC}"
        echo -e "  缺失文件: ${FLAMEGRAPH_DIR}/{flamegraph.pl,stackcollapse-perf.pl}"
        echo -e "  解决方案: git clone https://github.com/brendangregg/FlameGraph.git"
        all_ok=false
    fi

    # 权限
    local paranoid
    paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "unknown")
    echo -e "\n✓ 系统检查:"
    echo -e "  内核版本: $(uname -r)"
    echo -e "  perf_event_paranoid: ${paranoid}"
    if [ "$paranoid" != "unknown" ]; then
        if [ "$paranoid" -gt 1 ]; then
            echo -e "${YELLOW}⚠ 需要调整权限 (当前值 $paranoid > 1)${NC}"
            echo -e "  临时方案: sudo sh -c 'echo 1 >/proc/sys/kernel/perf_event_paranoid'"
            all_ok=false
        else
            echo -e "  权限状态: ${GREEN}OK${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ 无法读取 perf_event_paranoid${NC}"
    fi

    $all_ok && echo -e "\n${GREEN}✔ 所有检查通过，环境就绪${NC}"
    $all_ok
}

validate_input() {
    local pid=$1 freq=$2 duration=$3
    if ! ps -p "$pid" >/dev/null 2>&1; then
        echo -e "${RED}错误: 进程 $pid 不存在或无法访问${NC}"
        return 1
    fi
    if ! [[ "$freq" =~ ^[0-9]+$ ]] || [ "$freq" -lt 1 ]; then
        echo -e "${RED}错误: 频率必须为正整数${NC}"; return 1
    fi
    if ! [[ "$duration" =~ ^[0-9]+$ ]] || [ "$duration" -lt 1 ]; then
        echo -e "${RED}错误: 时长必须为正整数${NC}"; return 1
    fi
    [ "$duration" -lt $MIN_DURATION ] && echo -e "${YELLOW}警告: 采样时长建议不少于 ${MIN_DURATION} 秒${NC}"
    return 0
}

generate_flamegraph() {
    local pid=$1 freq=$2 duration=$3 output=${4:-flamegraph}

    # 若用户附带了 --keep-data，则 KEEP_DATA 已在外层设置为 true
    local perf_data="${output}.data"  # 始终用自定义数据文件，避免与默认 perf.data 混淆

    echo -e "\n${GREEN}▶ 开始分析 PID: $pid${NC}"
    echo -e "采样频率: ${BLUE}${freq} Hz${NC}"
    echo -e "采样时长: ${BLUE}${duration} 秒${NC}"
    echo -e "输出前缀: ${BLUE}${output}${NC}"
    echo -e "原始数据: ${BLUE}${perf_data}${NC}"

    # 1) 采集
    echo -e "\n${GREEN}[1/4] 采集数据...${NC}"
    # 使用 -o 将数据直接写到 <输出名>.data，避免覆盖当前目录的 perf.data
    if ! sudo "$PERF_PATH" record -F "$freq" -p "$pid" -g -o "$perf_data" -- sleep "$duration"; then
        echo -e "${RED}采集失败${NC}"
        echo -e "  可能原因: 进程终止、权限不足、perf_event_paranoid 限制"
        return 1
    fi

    # 变更所有权，便于后续处理
    sudo chown "$(id -u):$(id -g)" "$perf_data" 2>/dev/null ||:

    # 2) 转换
    echo -e "\n${GREEN}[2/4] 转换数据...${NC}"
    if ! "$PERF_PATH" script -i "$perf_data" > perf.out; then
        echo -e "${RED}数据转换失败${NC}"
        return 1
    fi

    # 3) 堆栈折叠
    echo -e "\n${GREEN}[3/4] 折叠堆栈...${NC}"
    if ! "${FLAMEGRAPH_DIR}/stackcollapse-perf.pl" perf.out > perf.folded; then
        echo -e "${RED}堆栈折叠失败${NC}"
        return 1
    fi

    # 4) 生成火焰图
    echo -e "\n${GREEN}[4/4] 生成火焰图...${NC}"
    if "${FLAMEGRAPH_DIR}/flamegraph.pl" perf.folded > "${output}.svg"; then
        echo -e "\n${GREEN}✔ 分析完成${NC}"
        echo -e "火焰图: ${BLUE}$(realpath "${output}.svg")${NC}"
        if $KEEP_DATA; then
            echo -e "已保留原始数据: ${BLUE}$(realpath "${perf_data}")${NC}"
        fi
    else
        echo -e "${RED}生成火焰图失败${NC}"
        return 1
    fi

    # 清理
    if $KEEP_DATA; then
        rm -f perf.out perf.folded
    else
        rm -f perf.out perf.folded "$perf_data"
        echo -e "${YELLOW}提示: 使用 --keep-data 可保留 ${perf_data}${NC}"
    fi
}

# 解析是否包含 --keep-data
for arg in "$@"; do
    if [ "$arg" = "--keep-data" ]; then
        KEEP_DATA=true
        # 从位置参数中去掉 --keep-data，避免干扰 PID 与可选参数
        set -- "${@:1:$(($#-1))}"
        break
    fi
done

case "$1" in
    -h|--help)
        show_help; exit 0;;
    --check)
        check_environment; exit $?;;
    [0-9]*)
        PID="$1"
        FREQ=${2:-$DEFAULT_FREQ}
        DURATION=${3:-30}
        OUTPUT=${4:-flamegraph}

        if ! validate_input "$PID" "$FREQ" "$DURATION"; then exit 1; fi
        if ! check_environment; then
            echo -e "\n${RED}请先解决环境问题再继续${NC}"; exit 1
        fi
        generate_flamegraph "$PID" "$FREQ" "$DURATION" "$OUTPUT"
        ;;
    *)
        echo -e "${RED}错误: 无效参数${NC}"
        show_help; exit 1;;
esac
