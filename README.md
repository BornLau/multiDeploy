# 多节点 vLLM Ascend 部署

配置按职责分层，通用入口不绑定模型或节点数量：

```text
compose.yml                         # Docker、A2 设备和健康恢复
scripts/node-entrypoint.sh          # 通用 vLLM 启动入口
deployments/2xa2/topology.yml       # 2 节点的 DP/TP 拓扑
deployments/2xa2/cluster.conf       # 节点列表、SSH 用户和项目路径
deployments/2xa2/node0.env          # node0 的 IP、rank 和宿主机路径
deployments/2xa2/node1.env          # node1 的 IP、rank 和宿主机路径
models/glm-5.3-flash/compose.yml    # 模型镜像及配置挂载
models/glm-5.3-flash/vllm.yml       # vLLM 原生模型参数
run.sh                              # 统一命令入口
```

## 启动

本项目直接使用目标机器已有的 `docker-compose v2.40.3`。先把项目放到每个
节点的相同路径，并配置节点之间的 SSH 密钥免密登录。本机节点会直接执行，
不通过 SSH。
在 `deployments/2xa2/cluster.conf` 中填写 SSH 用户和远端项目路径。

然后在任意一个节点执行一次，脚本会并行拉起全部节点：

```bash
bash run.sh
# 等价于
bash run.sh up
```

集群管理命令：

```bash
bash run.sh ps
bash run.sh restart
bash run.sh down
```

仍然可以仅管理一个节点：

```bash
bash run.sh node0 logs
bash run.sh node0 ps
```

服务地址是 `http://7.150.2.118:8080/v1`。

## 修改配置

- 换 IP 或宿主机模型目录：修改对应 `deployments/2xa2/nodeN.env`。
- 调整节点数量和并行策略：新增一个 `deployments/<拓扑>/`，配置 `DP_SIZE`、`DP_LOCAL_SIZE`、`TP_SIZE` 和各节点 rank。
- 调整模型参数：修改 `models/glm-5.3-flash/vllm.yml`。
- 增加模型：新增 `models/<模型>/compose.yml` 和 `vllm.yml`，用 `MODEL=<模型> bash run.sh node0` 启动。
- 选择其他拓扑：用 `DEPLOYMENT=<拓扑> bash run.sh node0` 启动。

模型在容器内统一挂载到 `/models/current`，因此通用入口不包含任何模型名称或模型路径。

模型参数直接使用 vLLM 原生 `--config` YAML。普通参数写值，开关写布尔值，JSON 类型参数直接写成嵌套 YAML，不需要引号转义：

```yaml
max-model-len: 133120
max-num-seqs: 128
max-num-batched-tokens: 8192
gpu-memory-utilization: 0.85
limit-mm-per-prompt:
  image: 1
  video: 0
```

该文件保持 vLLM Ascend 官方 GLM-5.3-Flash 双 A2（DP2/TP8）示例参数；实验参数
和故障结论记录在 `docs/glm-5.3-flash-waiting-incident.md`，不写回生产基线。

## 网卡自动检测

`NODE_IP` 是宿主机通信 IP。由于使用 `network_mode: host`，入口脚本会把它直接
传给 HCCL 和 vLLM。脚本优先采用 `EXPECTED_NIC` 设置 HCCL、GLOO 和 TP 通信
网卡，仅通过 `/sys/class/net` 检查该网卡是否可见，不要求镜像安装 `ip`。

- 配置的网卡不可见：打印容器可见网卡并退出。
- `EXPECTED_NIC` 留空时：镜像含 `ip` 命令才会按 `NODE_IP` 自动探测，否则退出并提示配置网卡。

## 自动恢复

默认情况下，Compose 的 `healthcheck` 只展示服务健康状态，不会因 `/health`
的短暂失败重启容器；vLLM 进程自身退出时，`restart: always` 仍会自动拉起。
这避免了 DP 集群中 node0 短暂不可达时所有从属节点级联重启。如确实需要把
连续健康检查失败升级为重启，可在对应节点环境中设置
`ACTIVE_HEALTH_RESTART=true`；默认每 30 秒检查一次，连续 3 次失败后触发。
首次启动等待服务就绪的总超时为 30 分钟，可通过 `SERVICE_START_TIMEOUT` 覆盖。

## 宿主机挂载和日志

Ascend 驱动、固件、系统工具及 HCCL 配置从宿主机只读挂载；模型从节点配置的 `MODEL_HOST_PATH` 只读挂载到容器 `/models/current`。日志目录由 `LOG_HOST_PATH` 挂载到容器 `/data/logs`。

所有入口和 vLLM 输出会同时出现在 `docker-compose logs` 和宿主机日志文件中：node0 为 `vllm-rank0.log`，node1 为 `vllm-rank1.log`。Docker 自身日志启用了 `100MB × 5` 轮转；宿主机持久化日志可按运维策略配置 logrotate。

## 卡死现场采集

从任意节点立即采集整个集群：

```bash
bash scripts/collect-failure-diagnostics.sh snapshot
```

也可在压测前启动监视。连续 3 次（默认每 10 秒）观察到
`running<=1 && waiting>=1`，或 metrics/health 接口无法访问时，会自动采集并退出。
这可以覆盖 8 并发下 `running=1, waiting=7` 和 `running=0, waiting=8` 等情况：

```bash
bash scripts/collect-failure-diagnostics.sh watch
```

阈值可覆盖：

```bash
INTERVAL=5 CONSECUTIVE=4 MAX_RUNNING=1 MIN_WAITING=1 \
  bash scripts/collect-failure-diagnostics.sh watch
```

结果默认保存为各节点的纯文本 `diagnostics/vllm-failure-*.log`，包含 Docker 状态、容器日志尾部、
宿主机/容器进程等待点、NPU 状态、内核近期日志、连接和 vLLM metrics。采集器不导出
容器环境变量，也不会采集 Prompt、请求正文或 API Key。远端节点的结果保留在远端
相同的 `OUTPUT_PARENT` 路径。

如需保留分文件目录或生成压缩包，可分别设置 `OUTPUT_FORMAT=dir` 或
`OUTPUT_FORMAT=tar`；默认值是便于直接查看和传递的 `OUTPUT_FORMAT=log`。
