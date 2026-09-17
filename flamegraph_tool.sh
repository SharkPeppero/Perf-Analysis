#!/bin/bash

# 火焰图生成脚本（支持自定义路径与保留 perf.data）
# 版本: 6.0

# ============== 配置区 ==============
PERF_PATH="/usr/bin/perf"                              # perf 绝对路径
FLAMEGRAPH_DIR="/home/yjh/下载/perf_analysis/FlameGraph"
DEFAULT_FREQ=200
DEFAULT_DURATION=30
MIN_DURATION=5
# ===================================

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

show_help() {
    echo -e "${GREEN}火焰图生成脚本${NC}"
    echo -e "配置路径:"
    echo -e "  perf工具: ${BLUE}${PERF_PATH}${NC}"
    echo -e "  FlameGraph: ${BLUE}${FLAMEGRAPH_DIR}${NC}"
    echo -e "\n用法:"
    echo -e "  $0 ${BLUE}${NC}                         # 交互式配置"
    echo -e "  $0 ${BLUE}<pid> [频率] [时长] [输出目录]${NC}"
    echo -e "  $0 ${BLUE}--check${NC}"
    echo -e "  $0 ${BLUE}--help${NC}"
    echo -e "\n说明:"
    echo -e "  频率默认: ${BLUE}${DEFAULT_FREQ} Hz${NC}"
    echo -e "  时长默认: ${BLUE}${DEFAULT_DURATION} 秒${NC}"
    echo -e "  输出目录不存在会自动创建，目录内会保存 .svg 和 .data"
    echo -e "\n示例:"
    echo -e "  $0"
    echo -e "  $0 1234"
    echo -e "  $0 1234 200 30 ./perf_result"
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
    local pid=$1 freq=$2 duration=$3 output_dir=$4
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
    if [ -z "$output_dir" ]; then
        echo -e "${RED}错误: 输出目录不能为空${NC}"; return 1
    fi
    [ "$duration" -lt $MIN_DURATION ] && echo -e "${YELLOW}警告: 采样时长建议不少于 ${MIN_DURATION} 秒${NC}"
    return 0
}

generate_flamegraph() {
    local pid=$1 freq=$2 duration=$3 output_dir=$4
    local timestamp output_base perf_data svg_file perf_out perf_folded

    mkdir -p "$output_dir"
    output_dir=$(realpath "$output_dir")
    timestamp=$(date +%Y%m%d_%H%M%S)
    output_base="${output_dir}/flamegraph_${pid}_${timestamp}"
    perf_data="${output_base}.data"
    svg_file="${output_base}.svg"
    perf_out="${output_base}.perf.out"
    perf_folded="${output_base}.perf.folded"

    echo -e "\n${GREEN}▶ 开始分析 PID: $pid${NC}"
    echo -e "采样频率: ${BLUE}${freq} Hz${NC}"
    echo -e "采样时长: ${BLUE}${duration} 秒${NC}"
    echo -e "输出目录: ${BLUE}${output_dir}${NC}"
    echo -e "火焰图: ${BLUE}${svg_file}${NC}"
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
    if ! "$PERF_PATH" script -i "$perf_data" > "$perf_out"; then
        echo -e "${RED}数据转换失败${NC}"
        return 1
    fi

    # 3) 堆栈折叠
    echo -e "\n${GREEN}[3/4] 折叠堆栈...${NC}"
    if ! "${FLAMEGRAPH_DIR}/stackcollapse-perf.pl" "$perf_out" > "$perf_folded"; then
        echo -e "${RED}堆栈折叠失败${NC}"
        return 1
    fi

    # 4) 生成火焰图
    echo -e "\n${GREEN}[4/4] 生成火焰图...${NC}"
    if "${FLAMEGRAPH_DIR}/flamegraph.pl" "$perf_folded" > "$svg_file"; then
        echo -e "\n${GREEN}✔ 分析完成${NC}"
        echo -e "火焰图: ${BLUE}${svg_file}${NC}"
        echo -e "原始数据: ${BLUE}${perf_data}${NC}"
    else
        echo -e "${RED}生成火焰图失败${NC}"
        return 1
    fi

    # 清理
    rm -f "$perf_out" "$perf_folded"
}

prompt_config() {
    echo -e "${GREEN}火焰图交互式配置${NC}"
    read -r -p "请输入 PID: " PID
    read -r -p "请输入采样频率 Hz [${DEFAULT_FREQ}]: " FREQ
    read -r -p "请输入采样时间 秒 [${DEFAULT_DURATION}]: " DURATION
    read -r -p "请输入输出目录: " OUTPUT_DIR

    FREQ=${FREQ:-$DEFAULT_FREQ}
    DURATION=${DURATION:-$DEFAULT_DURATION}
}

case "$1" in
    "")
        prompt_config

        if ! validate_input "$PID" "$FREQ" "$DURATION" "$OUTPUT_DIR"; then exit 1; fi
        if ! check_environment; then
            echo -e "\n${RED}请先解决环境问题再继续${NC}"; exit 1
        fi
        generate_flamegraph "$PID" "$FREQ" "$DURATION" "$OUTPUT_DIR"
        ;;
    -h|--help)
        show_help; exit 0;;
    --check)
        check_environment; exit $?;;
    [0-9]*)
        PID="$1"
        FREQ=${2:-$DEFAULT_FREQ}
        DURATION=${3:-$DEFAULT_DURATION}
        OUTPUT_DIR=${4:-./perf_result}

        if ! validate_input "$PID" "$FREQ" "$DURATION" "$OUTPUT_DIR"; then exit 1; fi
        if ! check_environment; then
            echo -e "\n${RED}请先解决环境问题再继续${NC}"; exit 1
        fi
        generate_flamegraph "$PID" "$FREQ" "$DURATION" "$OUTPUT_DIR"
        ;;
    *)
        echo -e "${RED}错误: 无效参数${NC}"
        show_help; exit 1;;
esac
