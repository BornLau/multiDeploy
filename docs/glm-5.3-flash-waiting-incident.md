# GLM-5.3-Flash 请求持续 Waiting 现场分析

## 1. 摘要

双 Atlas 800 A2、`DP=2`、每个 DP rank 使用 `TP=8` 的 GLM-5.3-Flash 服务在
长输入并发测试中多次出现请求持续停留在 Waiting、没有进入 Running 的现象。
HTTP `/health` 与 `/metrics` 仍可访问，容器和 Engine 进程也未退出，因此这是
推理数据面的软故障，而不是进程崩溃。

当前证据显示，外部可见的 `reason="capacity"` 不能解释为主机内存、HBM 或
KV Cache 已耗尽。更符合以下状态：vLLM Scheduler/Engine 状态没有完成请求准入，
而 NPU 侧仍存在计算、编译、重复执行或集合通信活动。具体卡点仍需通过稳定版本
对照和双节点同步采样确认。

## 2. 官方基线

vLLM Ascend 的 GLM-5.3-Flash 文档针对双 A2 给出的拓扑和关键参数为：

```yaml
max-model-len: 133120
max-num-seqs: 128
max-num-batched-tokens: 8192
gpu-memory-utilization: 0.85
enable-expert-parallel: true

speculative-config:
  num_speculative_tokens: 2
  method: deepseek_mtp
  enforce_eager: true
```

官方命令没有显式启用 Chunked Prefill、Prefix Caching 或 DCP。仓库的模型配置
已恢复为这一基线。官方参考：

- <https://docs.vllm.ai/projects/ascend/zh-cn/latest/tutorials/models/GLM5.3-Flash.html>

## 3. 已观察到的现场

### 3.1 运行若干批后软挂

早期现场中，约 10K Prompt 的请求先正常完成 24 个，随后新进入的 8 个请求
平均分配到两个 Engine：

```text
engine 0: running=0, waiting=4
engine 1: running=0, waiting=4
waiting reason: capacity
KV cache usage: 0%
```

此前完成的 24 个请求均以 `length` 结束，总生成 token 为 24576，即每请求约
1024 token。批次切换附近多次出现：

```text
Received stats for out-of-order step
```

该现场一度支持“上一批结束后 Scheduler capacity 或 DP coordinator 状态没有正确
回收”的假设，但后续冷启动现场证明状态回收不是唯一触发条件。

### 3.2 服务启动后的首批请求即软挂

后续现场使用 4 并发，输入约为 45K、31K、18K、22K。两个 Engine 各有两个
Waiting 请求。连续 8 次、约 16 秒的 metrics 采样完全不变：

```text
running=0
waiting=4
waiting reason=capacity
KV cache usage=0
prompt_tokens_total=0
generation_tokens_total=0
request_success_total=0
```

这证明请求不是 Prefill 较慢，而是没有任何 token 处理进度。与此同时：

```text
/health: HTTP 200，约 1.2 ms
主机 CPU: 约 97% idle
主机可用内存: 约 1.4 TiB
内核日志: 无相关错误
EngineCore: 持续占用 CPU
```

### 3.3 NPU 现场

node0 的 8 张 910B3 均为健康状态，每张卡的数据大致为：

```text
AICore: 67%～68%
HBM: 约 45.6 GB / 65.5 GB
VLLMWorker_DP 进程显存: 约 42.3 GB
```

因此 NPU 并非空闲，且每卡仍约有 20 GB HBM 余量。vLLM 同时报告
`running=0`、`KV=0`、token counters 为零，说明控制面指标与设备侧活动脱节。

### 3.4 实际软件版本

故障现场采集到：

```text
image: quay.io/ascend/vllm-ascend:glm-5.3-flash
vllm: 0.23.0+empty
vllm-ascend: 0.1.dev50+gdb701c1fd
```

这是开发构建版本。版本因素应排在后续验证的高优先级位置。

## 4. 已完成的参数实验

以下调整均未消除持续 Waiting：

- 将 `max-num-batched-tokens` 从 16384 提高到 65536；
- 将 `max-model-len` 调整到 160K 附近；
- 使用 4 并发而不是 8 并发；
- 关闭 Prefix Caching；
- 关闭 MTP。

因此不能把问题简单归因于 batch token 上限、并发数、APC 或 MTP。

曾尝试启用 DCP，但 Engine 初始化直接失败：

```text
AssertionError: DCP not support sliding window.
```

调用栈位于 hybrid/sliding-window KV Cache 内存计算路径，说明当前模型与镜像组合
不支持 DCP；DCP 不是可用的规避方案。

## 5. Chunked Prefill 假设

Chunked Prefill 仍是重要嫌疑项，原因如下：

1. 官方双 A2 示例没有显式启用 `enable-chunked-prefill`；
2. GLM-5.3-Flash 使用稀疏注意力、线性注意力及 sliding-window/hybrid KV spec；
3. 首批长 Prompt 可以在任何 token 开始处理前停在 capacity waiting；
4. NPU 有明显活动，但 Scheduler 指标没有进入 Running。

不过目前不能仅凭这些现象把根因最终定为 Chunked Prefill。65K batch budget 仍失败
只排除了“单批 token 上限太小”，没有排除 Chunked Prefill 在混合 KV spec 上的
实现或状态机问题。最终确认需要严格官方配置的 A/B：保持其他参数不变，仅比较
是否显式启用 Chunked Prefill。

## 6. 当前排除项与判断

已基本排除：

- 主机 CPU、内存或磁盘资源耗尽；
- 普通 KV Cache 高水位或抢占；
- `max-num-seqs` 并发上限；
- DCP 可作为修复手段；
- MTP 或 APC 是唯一根因；
- 单纯提高 `max-num-batched-tokens` 可以解决问题。

当前候选原因按优先级排列：

1. Chunked Prefill 与 GLM hybrid/sliding-window KV spec 的兼容或调度缺陷；
2. 当前 vLLM Ascend 开发构建的 Scheduler/Engine 状态机缺陷；
3. 双节点 DP coordinator 状态不同步，尤其是已观察到 out-of-order step；
4. NPU kernel、图编译或集合通信仍在执行，但请求状态未正确迁移到 Running。

## 7. 后续验证方案

首先使用仓库中的严格官方基线，不添加 Chunked Prefill、APC 或 DCP。测试顺序：

1. 单请求 8K、18K、45K；
2. 4 并发 18K/22K/31K/45K；
3. 连续运行至少 10 批；
4. 在官方声明的 133120 上限内测试单个接近 128K 的请求。

若官方基线稳定，再只添加 `enable-chunked-prefill: true` 重复相同请求集。如果只在
启用后复现，即可将问题收敛到 Chunked Prefill 路径。

每次复现应同时采集两个节点，并使用 tar 格式避免文本总长度裁剪：

```bash
OUTPUT_FORMAT=tar MAX_CAPTURE_KB=512 \
  bash scripts/collect-failure-diagnostics.sh watch
```

最终问题报告应包含两节点连续 metrics、NPU 连续采样、实际配置、镜像 digest、软件
版本、启动阶段 KV 容量日志、Engine/Worker 栈，以及相同请求集的成功与失败对照。
