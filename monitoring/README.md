# vLLM 中文性能诊断台

部署在运行 vLLM API Server 的 Node 0。不会采集 Prompt、请求正文或 API Key。

## 启动

```bash
cd monitoring
docker-compose -f compose.yml up -d --build
```

验证：

```bash
curl -f http://127.0.0.1:9090/-/ready
curl -f http://127.0.0.1:3000/health
```

从个人电脑安全访问：

```bash
ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 用户名@NODE0_IP
```

浏览器打开 `http://127.0.0.1:3000`。点击“导出文本”可下载不超过 10KB 的诊断摘要并发给 Codex 分析。

## 常用操作

```bash
docker-compose -f compose.yml ps
docker-compose -f compose.yml logs --tail=100 dashboard prometheus
docker-compose -f compose.yml restart
docker-compose -f compose.yml down
```

`down` 不会删除历史数据。只有显式追加 `-v` 才会删除 Prometheus 数据卷。
