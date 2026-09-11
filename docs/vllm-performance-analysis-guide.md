# vLLM 性能监控与调优指南

本文适用于当前 GLM-5.3-Flash 部署：两台 Atlas 800 A2、每台 8 卡，`DP=2`、`TP=8`、Expert Parallel 开启。生产配置保持官方验证的 133120 上下文基线。

## 1. 当前建议基线

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

官方双 A2 示例没有显式启用 Chunked Prefill、Prefix Caching 或 DCP。相关实验与
Waiting 软故障分析见 `glm-5.3-flash-waiting-incident.md`。

## 2. 监控数据链路

```text
vLLM /metrics
    ↓ Prometheus 每 15 秒抓取
Prometheus 保存 30 天历史
    ↓ PromQL 聚合
中文性能诊断面板
```

vLLM 的 `/metrics` 是当前累计状态。Prometheus负责保存历史并计算最近 15 分钟或一小时的趋势；诊断面板负责展示指标、组合判断瓶颈和导出文本摘要。Prometheus和面板均不参与推理，监控异常不会中断 vLLM 服务。

监控部署文件位于：

```text
monitoring/
├── compose.yml
├── prometheus.yml
└── dashboard/
```

在提供 vLLM API 的 Node 0 启动：

```bash
cd monitoring
docker-compose -f compose.yml up -d --build
```

从个人电脑建立安全隧道：

```bash
ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 用户名@NODE0_IP
```

浏览器访问 `http://127.0.0.1:3000`。

## 3. 指标含义

### 3.1 Running

当前正在模型中执行的请求数。有流量时大于零是正常现象，必须与 Waiting、KV Cache 一起判断。

`max-num-seqs` 对每个 DP Engine 生效。当前 `DP=2`、`max-num-seqs=128`，理论上两个 Engine 最多各调度 128 个 sequence，但实际可承载量会受到 Prompt 长度、输出长度和 KV Cache 限制。

### 3.2 Waiting

请求已进入 vLLM，但尚未获得执行资源。

- 偶尔出现：正常波动。
- 持续五分钟大于零：开始出现容量或调度压力。
- Waiting 上升且 KV 超过 90%：通常是 KV 容量瓶颈。
- Waiting 上升但 KV 较低：检查调度限制、Engine 不均衡或计算性能。

### 3.3 KV Cache 使用率

KV Cache 保存正在执行请求的上下文状态。Prompt 越长、并发越高、生成越长，占用通常越高。

| KV 使用率 | 含义 |
|---:|---|
| 0%～70% | 余量充足 |
| 70%～80% | 正常负载 |
| 80%～90% | 关注趋势 |
| 90%～95% | 高风险 |
| 超过 95% | 容易排队或抢占 |

KV 使用率是容量指标，不是需要追求的利用率目标。

### 3.4 Engine 占用差

两个 DP Engine 的 KV 使用率差值。短暂差异可能只是某个 Engine 接收了一个 200K 请求；只有差值持续 15 分钟超过 40%，同时高占用 Engine 排队、低占用 Engine 空闲，才判断为路由或调度不均。

### 3.5 TTFT P95

从请求进入服务到返回第一个 token 的时间。P95 表示 95% 的请求能在该时间内返回首 token。

主要影响因素：

- Prompt 长度；
- 排队时间；
- Prefill 计算速度；
- `max-num-batched-tokens`；
- Prefix Cache 命中率；
- NPU、HCCL 和 Engine 负载。

TTFT 必须结合 Prompt P95 判断。200K Prompt 的 TTFT 高不一定是故障。

### 3.6 E2E P95

从请求进入服务到完整输出结束的总时间，包括排队、Prefill 和 Decode。E2E 适合衡量用户总体体验，但不能单独定位瓶颈。

### 3.7 Prompt P95

最近统计窗口中，95% 请求的 Prompt token 数不超过该值。

- Prompt P95 与 TTFT 同时上升：通常是业务输入变长。
- Prompt P95 稳定而 TTFT 上升：检查排队、NPU、HCCL、批处理或 Engine 调度。

### 3.8 Prefix Cache 命中率

表示 Prompt token 中复用了多少已有 KV Cache。大量请求共享稳定的 system prompt、工具定义或 few-shot 时，应产生一定命中。

命中率为零时先检查请求前缀是否字节一致，包括字段顺序、工具顺序、空格和动态时间等。前缀本身都不同时，零命中可能是正常现象。

### 3.9 Preemption

请求因为 KV 或调度压力被抢占。理想值为零。持续增长表示压力已经影响请求执行，而不是单纯接近容量上限。

### 3.10 输入与输出吞吐

- Input tokens/s：整个服务的 Prompt/Prefill 吞吐。
- Output tokens/s：所有并发请求的总输出吞吐。

吞吐没有通用正常值，必须在相同请求长度和并发下建立自己的基线。总输出吞吐不等于单请求输出速度；单请求体验应补充观察 TPOT/ITL。

### 3.11 Length 结束比例

`finished_reason="length"` 表示请求输出达到 `max_tokens`。固定长度压测时比例高可能正常；真实业务中比例过高，应检查客户端 `max_tokens`、停止条件、重复生成和 parser 行为。

## 4. 固定分析顺序

每次打开面板按以下顺序检查：

1. Prometheus 是否正常采集数据。
2. Waiting 是否持续大于零。
3. KV Cache 是否持续超过 90%。
4. Preemption 是否增长。
5. 两个 Engine 是否长期不均。
6. TTFT 是否升高。
7. TTFT 升高时，Prompt P95 是否同时升高。
8. Prefix Cache 是否符合业务的前缀复用特征。
9. 输入、输出吞吐是否偏离相同负载下的历史基线。
10. Length 和 Error 比例是否异常。

常见组合判断：

```text
KV 高 + Waiting 高 + Preemption 增长
= KV 容量或并发瓶颈

TTFT 高 + Prompt 很长 + Waiting 为零
= 长上下文 Prefill 成本

TTFT 高 + Prompt 稳定 + KV 正常
= NPU、HCCL 或执行性能问题

Engine 差异大 + 一边排队、一边空闲
= DP 路由或成本感知调度问题

缓存为零 + 大量相同公共前缀
= Prefix Cache 未正常发挥作用
```

## 5. 根据指标调整 vLLM 参数

### 5.1 KV 高、Waiting 高、Preemption 增长

先降低每个 Engine 的并发：

```text
max-num-seqs: 64 → 48 → 32
```

每次只改一级。目标不是 Waiting 永远为零，而是：

```text
Preemption = 0
KV 峰值低于约 90%～95%
Waiting 可控
总体吞吐可接受
```

如果降低并发后排队时间不可接受，应限制 128K～200K 请求并发、区分长短请求资源池或扩容。

### 5.2 KV 接近 90%，但没有 Waiting 和 Preemption

暂不调整。偶发高水位不是故障，继续观察是否持续并伴随排队。

### 5.3 TTFT 高、Prompt 长、无排队

优先优化 Chunked Prefill。保持其他参数不变，依次测试：

```text
max-num-batched-tokens: 16384
max-num-batched-tokens: 24576
max-num-batched-tokens: 32768
```

较大的值通常提高 Prefill 吞吐、降低 TTFT，但可能拖慢 Decode 或增加瞬时内存压力。每组使用相同请求集运行至少 15～30 分钟，对比：

- Prompt P95；
- TTFT P95；
- TPOT/ITL；
- Input/Output tokens/s；
- KV、Waiting 和 Preemption。

不要直接跳到 65536，也不要同时修改 `max-num-seqs`。

### 5.4 Waiting 高，但 KV 较低

继续检查：

- Running 是否接近每个 Engine 的 `max-num-seqs`；
- Engine 差值是否长期超过 40%；
- Input/Output tokens/s 是否达到历史平台期；
- API Server、NPU 或 HCCL 是否存在瓶颈。

只有在 KV 峰值明显低于 80%、Preemption 始终为零、HBM 有安全余量时，才考虑提高 `max-num-seqs`。

### 5.5 `gpu-memory-utilization`

当前保持官方基线 `0.85`。只有确认 HBM 有充足安全余量、没有 OOM，并且 KV 容量确实限制业务后，才进行单变量测试。

### 5.6 推测解码

当前 `num_speculative_tokens=2` 的 draft token 接受率约 86%，暂时保持。只有补充 TPOT 和接受率长期监控后，才对比测试 3；如果接受率下降或 TPOT 变差，应回退到 2。

## 6. 当前 Prefill 判断

历史实验与最新 Waiting 现场已集中记录在
`glm-5.3-flash-waiting-incident.md`。当前先保持官方基线，通过相同请求集复现和
采集证据，不再在生产配置中并行修改多个参数。

## 7. DP 与 KV-aware 路由

### 7.1 当前内部 DP

```text
客户端
   ↓
Node 0 API Server
   ↓ vLLM 内部调度
   ├── Engine 0 / Node 0
   └── Engine 1 / Node 1
```

内部调度主要参考 running/waiting，请求数量相同不代表 token 成本相同。例如一个 200K 请求可能比多个 10K 请求占用更多 KV 和 Prefill 计算。因此单次 KV 不均衡并不表示配置错误。

当前应继续使用内部 DP，除非观察到：

```text
Engine KV 差值持续超过 40%
+ 高占用 Engine 持续 Waiting
+ 低占用 Engine 仍明显空闲
```

### 7.2 Hybrid DP 改造方向

目标拓扑：

```text
                  ┌── Node 0 API → Engine 0
客户端 → Router ──┤
                  └── Node 1 API → Engine 1
```

实施前确认镜像支持：

```bash
vllm serve --help 2>&1 | grep -A3 -B3 data-parallel-hybrid-lb
```

支持后才考虑：

- 两个节点均启动 API Server；
- 保持全局 `DP_SIZE=2` 和每节点 `DP_LOCAL_SIZE=1`；
- 添加 `--data-parallel-hybrid-lb`；
- Node 1 不再使用 `--headless`；
- 在两个节点 API 前增加 Router。

该改造涉及 DP+EP 的多节点协调，应先在非生产环境验证。

### 7.3 KV-aware Router 算法

Router 同时兼顾前缀亲和和容量：

```text
prefix_key = hash(model + system_prompt + tool_definitions + 固定 few-shot)
```

1. 相同 `prefix_key` 优先进入同一 Engine，提高 Prefix Cache 命中。
2. 首选 Engine 的 KV 低于 85% 且无 Waiting 时保持亲和。
3. 首选 Engine 的 KV 超过 90% 或已经排队时切换到其他健康 Engine。
4. 前缀映射设置有限 TTL，例如 30 分钟。

可使用以下思路给 Engine 评分，选择分数最低者：

```text
score = waiting × 100
      + kv_usage × 10
      + running
      + estimated_prompt_cost
```

普通 Nginx 可以轮询或按 Header 一致性哈希，但难以实时读取 Prometheus 并完成完整评分。真正的 KV-aware 路由通常需要自定义 Python/Go Gateway 或专用 LLM Router。

## 8. 调参纪律

- 每次只修改一个参数。
- 使用相同输入长度分布、并发和输出长度。
- 每组至少运行 15～30 分钟；生产趋势最好覆盖 24～72 小时。
- 保存调整前后的诊断文本。
- 比较 P95/P99，不只比较平均值。
- 出现 OOM、Error 或 Preemption 增长时立即回退。
- 记录配置、测试时间、请求集和结果，避免依靠印象判断。

推荐执行顺序：

```text
基础监控
→ Chunked Prefill 与 max-num-batched-tokens A/B
→ 观察 Engine 长期均衡性
→ 必要时 Hybrid DP + KV-aware Router
→ 长上下文规模继续增长时再评估 Prefill/Decode 分离
```

## 9. 一键导出诊断摘要

页面点击“导出文本”，或在 Node 0 项目根目录执行：

```bash
./scripts/collect-vllm-diagnostics.sh
```

生成文件：

```text
diagnostics/vllm-YYYYMMDD-HHMMSS.txt
```

文件不超过 10KB，只包含聚合指标和自动建议，不包含 Prompt、请求正文、用户信息或 API Key。最好分别在正常、明显变慢和高并发 128K～200K 场景采集，以便横向比较。
