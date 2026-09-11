import json
import math
import os
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PROMETHEUS = os.getenv("PROMETHEUS_URL", "http://prometheus:9090").rstrip("/")
REFRESH_SECONDS = int(os.getenv("REFRESH_SECONDS", "30"))
INDEX = Path(__file__).with_name("index.html").read_bytes()

QUERIES = {
    "up": 'up{job="vllm-glm-5-3-flash"}',
    "running": "sum(vllm:num_requests_running)",
    "waiting": "sum(vllm:num_requests_waiting)",
    "kv": "max(vllm:kv_cache_usage_perc) * 100",
    "imbalance": "(max(vllm:kv_cache_usage_perc)-min(vllm:kv_cache_usage_perc))*100",
    "ttft": "histogram_quantile(0.95,sum by(le)(rate(vllm:time_to_first_token_seconds_bucket[15m])))",
    "e2e": "histogram_quantile(0.95,sum by(le)(rate(vllm:e2e_request_latency_seconds_bucket[15m])))",
    "prompt": "histogram_quantile(0.95,sum by(le)(rate(vllm:request_prompt_tokens_bucket[15m])))",
    "cache": "100*sum(rate(vllm:prompt_tokens_cached_total[15m]))/clamp_min(sum(rate(vllm:prompt_tokens_total[15m])),1e-9)",
    "preempt": "sum(increase(vllm:num_preemptions_total[1h]))",
    "input_tps": "sum(rate(vllm:prompt_tokens_total[15m]))",
    "output_tps": "sum(rate(vllm:generation_tokens_total[15m]))",
    "errors": 'sum(increase(vllm:request_success_total{finished_reason="error"}[1h]))',
    "length_rate": '100*sum(rate(vllm:request_success_total{finished_reason="length"}[1h]))/clamp_min(sum(rate(vllm:request_success_total[1h])),1e-9)',
}

def query(promql):
    url = f"{PROMETHEUS}/api/v1/query?{urllib.parse.urlencode({'query': promql})}"
    with urllib.request.urlopen(url, timeout=8) as response:
        payload = json.load(response)
    results = payload.get("data", {}).get("result", [])
    if not results:
        return None
    value = float(results[0]["value"][1])
    return value if math.isfinite(value) else None

def diagnose(v):
    findings = []
    if (v.get("waiting") or 0) > 0 and (v.get("kv") or 0) >= 90:
        findings.append(["critical", "KV 容量瓶颈", "降低 64K–200K 请求并发；若持续发生，再考虑扩容。"]) 
    if (v.get("preempt") or 0) > 0:
        findings.append(["critical", "请求发生抢占", "KV 压力已影响执行，减少 max-num-seqs 或隔离超长请求。"]) 
    if (v.get("ttft") or 0) > 60 and (v.get("prompt") or 0) > 128000:
        findings.append(["warning", "长上下文 Prefill 瓶颈", "主要成本来自超长输入；应比较相同 Prompt 长度下的 TTFT。"]) 
    if (v.get("imbalance") or 0) > 40:
        findings.append(["warning", "Engine 负载不均", "若持续 15 分钟存在，检查 DP 路由并考虑 KV-aware 调度。"]) 
    if (v.get("cache") or 0) < 1 and (v.get("input_tps") or 0) > 0:
        findings.append(["warning", "前缀缓存无收益", "检查 system prompt 和工具定义是否稳定一致。"]) 
    if (v.get("length_rate") or 0) > 50:
        findings.append(["warning", "输出频繁触顶", "确认是否为压测；真实业务应检查 max_tokens 和停止条件。"]) 
    if (v.get("errors") or 0) > 0:
        findings.append(["critical", "最近一小时有请求错误", "检查 vLLM 服务日志中的异常和超时。"]) 
    if not findings:
        findings.append(["ok", "暂未发现明显瓶颈", "继续观察完整业务高峰，尤其是 128K–200K 请求时段。"]) 
    return findings

def snapshot():
    values, errors = {}, {}
    for name, promql in QUERIES.items():
        try:
            values[name] = query(promql)
        except Exception as exc:
            values[name] = None
            errors[name] = str(exc)[:160]
    return {
        "collected_at": time.strftime("%Y-%m-%d %H:%M:%S %z"),
        "refresh_seconds": REFRESH_SECONDS,
        "values": values,
        "findings": diagnose(values),
        "errors": errors,
    }

def report(data):
    v = data["values"]
    labels = {
        "running": "正在运行请求", "waiting": "等待请求", "kv": "KV最高占用(%)",
        "imbalance": "Engine占用差(%)", "ttft": "TTFT P95(秒)", "e2e": "E2E P95(秒)",
        "prompt": "Prompt P95(tokens)", "cache": "缓存命中率(%)", "preempt": "1小时抢占",
        "input_tps": "输入tokens/s", "output_tps": "输出tokens/s", "errors": "1小时错误",
        "length_rate": "触顶结束比例(%)",
    }
    lines = ["vLLM 性能诊断摘要", f"采集时间: {data['collected_at']}", ""]
    for key, label in labels.items():
        value = v.get(key)
        lines.append(f"{label}: {'无数据' if value is None else round(value, 2)}")
    lines.extend(["", "自动诊断:"])
    for level, title, advice in data["findings"]:
        lines.append(f"- [{level}] {title}: {advice}")
    lines.extend(["", "本文件只有聚合指标，不含 Prompt、请求正文、用户信息或 API Key。"]) 
    return "\n".join(lines)[:10000]

class Handler(BaseHTTPRequestHandler):
    def send(self, status, content_type, body):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/?"):
            return self.send(200, "text/html; charset=utf-8", INDEX)
        if self.path == "/api/status":
            body = json.dumps(snapshot(), ensure_ascii=False).encode()
            return self.send(200, "application/json; charset=utf-8", body)
        if self.path == "/api/report":
            body = report(snapshot()).encode()
            return self.send(200, "text/plain; charset=utf-8", body)
        if self.path == "/health":
            return self.send(200, "text/plain", b"ok\n")
        return self.send(404, "text/plain", b"not found\n")

    def log_message(self, fmt, *args):
        print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {fmt % args}")

ThreadingHTTPServer(("0.0.0.0", 3000), Handler).serve_forever()
