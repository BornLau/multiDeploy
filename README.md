# 多节点 vLLM Ascend 部署

配置按职责分层，通用入口不绑定模型或节点数量：

```text
compose.yml                         # Docker、A2 设备和健康恢复
scripts/node-entrypoint.sh          # 通用 vLLM 启动入口
deployments/2xa2/topology.yml       # 2 节点的 DP/TP 拓扑
deployments/2xa2/node0.env          # node0 的 IP、rank 和宿主机路径
deployments/2xa2/node1.env          # node1 的 IP、rank 和宿主机路径
models/glm-5.3-flash/compose.yml    # 模型镜像及配置挂载
models/glm-5.3-flash/vllm.yml       # vLLM 原生模型参数
run.sh                              # 统一命令入口
```

## 启动

本项目直接使用目标机器已有的 `docker-compose v2.40.3`，不需要安装 `docker compose` 插件，也不需要 SSH 用户或密码。

在 `7.150.2.118`：

```bash
bash run.sh node0
```

在 `7.150.2.157`：

```bash
bash run.sh node1
```

常用管理命令：

```bash
bash run.sh node0 logs
bash run.sh node0 ps
bash run.sh node0 restart
bash run.sh node0 down
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
max-num-seqs: 64
enable-prefix-caching: true
limit-mm-per-prompt:
  image: 1
  video: 0
additional-config:
  enable_cpu_binding: true
```

## 网卡自动检测

入口脚本根据 `NODE_IP` 从 `ip -o -4 addr show` 的结果中精确查找所属网卡，再设置 HCCL、GLOO 和 TP 通信环境变量。当前两个节点都用 `EXPECTED_NIC=enp67s0f5` 做额外校验。

- 找不到 IP：打印容器可见的全部 IPv4 接口并退出。
- IP 匹配多个接口：退出，避免选择不确定的通信路径。
- 实际接口不是 `EXPECTED_NIC`：显示实际接口并退出。
- 不需要校验固定接口名时：删除或留空 `EXPECTED_NIC`，自动检测仍然生效。

## 自动恢复

两端持续检查 node0 的 `/health`。连续三次失败或 vLLM 进程退出时，入口脚本主动结束容器；`restart: always` 随后自动拉起。Compose `healthcheck` 用于显示健康状态，主动监控循环负责真正触发重启。

## 宿主机挂载和日志

Ascend 驱动、固件、系统工具及 HCCL 配置从宿主机只读挂载；模型从节点配置的 `MODEL_HOST_PATH` 只读挂载到容器 `/models/current`。日志目录由 `LOG_HOST_PATH` 挂载到容器 `/data/logs`。

所有入口和 vLLM 输出会同时出现在 `docker-compose logs` 和宿主机日志文件中：node0 为 `vllm-rank0.log`，node1 为 `vllm-rank1.log`。Docker 自身日志启用了 `100MB × 5` 轮转；宿主机持久化日志可按运维策略配置 logrotate。
