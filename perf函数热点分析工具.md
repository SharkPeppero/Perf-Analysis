# C++热点函数分析Perf

## 1、Perf工具安装以及版本检查

```bash
# perf工具安装
sudo apt update
sudo apt install linux-tools-common linux-tools-generic linux-tools-`uname -r`

# perf版本查询
perf --version
```

**PS：如果发现perf没有找到，说明内核与perf版本不匹配，需要手动安装**



## 2、如何使用Perf工具

### 2.1 修改CMakeLists.txt的编译器选项

最佳的编译选项是 ReleaseWithInfo -02 -g(保留符号信息)，也可以直接Release版本运行出图

```bash
# -------------------------------- 设置C++编译的优化 ---------------------
if (NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release) # Release Perf Debug ReleaseWithInfo
endif ()
message(STATUS "CMAKE_BUILD_TYPE: ${CMAKE_BUILD_TYPE}")

if (CMAKE_BUILD_TYPE STREQUAL "Release")
    # 纯发行版：体积小、速度快、无调试信息
    set(CMAKE_C_FLAGS_RELEASE
            "${CMAKE_C_FLAGS_RELEASE}   -O3 ${MCPU_FLAG} -DNDEBUG -ffunction-sections -fdata-sections")
    set(CMAKE_CXX_FLAGS_RELEASE
            "${CMAKE_CXX_FLAGS_RELEASE} -O3 ${MCPU_FLAG} -DNDEBUG -ffunction-sections -fdata-sections")
    add_link_options("$<$<CONFIG:Release>:LINKER:--gc-sections>")

elseif (CMAKE_BUILD_TYPE STREQUAL "ReleaseWithInfo")
    # 带调试信息的 Release：适合线上复现 + gdb / perf 分析
    set(CMAKE_C_FLAGS_RELEASEWITHINFO
            "${CMAKE_C_FLAGS_RELEASEWITHINFO}   -O3 ${MCPU_FLAG} -g3 -DNDEBUG -ffunction-sections -fdata-sections")
    set(CMAKE_CXX_FLAGS_RELEASEWITHINFO
            "${CMAKE_CXX_FLAGS_RELEASEWITHINFO} -O3 ${MCPU_FLAG} -g3 -DNDEBUG -ffunction-sections -fdata-sections")
    # 同样开启链接时垃圾回收
    add_link_options("$<$<CONFIG:ReleaseWithInfo>:LINKER:--gc-sections>")

elseif (CMAKE_BUILD_TYPE STREQUAL "Perf")
    # 支持热点函数分析的 Perf 版本
    set(CMAKE_CXX_FLAGS_PERF "-O2 -g3 -fno-omit-frame-pointer -fno-inline -fno-optimize-sibling-calls ${MCPU_FLAG} -w")
    set(CMAKE_C_FLAGS_PERF "-O2 -g3 -fno-omit-frame-pointer -fno-inline ${MCPU_FLAG} -w")

elseif (CMAKE_BUILD_TYPE STREQUAL "Debug")
    # 支持 GDB 的 Debug 调试版本
    set(CMAKE_C_FLAGS_DEBUG
            "${CMAKE_C_FLAGS_DEBUG}   -O0 -g3")
    set(CMAKE_CXX_FLAGS_DEBUG
            "${CMAKE_CXX_FLAGS_DEBUG} -O0 -g3 -DEIGEN_INITIALIZE_MATRICES_BY_NAN -D_GLIBCXX_ASSERTIONS")
endif ()
```



## 3、最终版本

用同文件夹目录下分析脚本 **flamegraph_tool.sh**

需要配置

**PERF_PATH="/usr/bin/perf"**                           # perf绝对路径 (可修改为系统中实际路径 bash: which perf)
**FLAMEGRAPH_DIR="/home/xu/ysmd_humble/perf_analysis/FlameGraph**"    # FlameGraph目录





## 4、备用QT工具查看热点函数

安装工具

```bash
sudo apt-get install -y hotspot
```

启动工具检查

hotspot