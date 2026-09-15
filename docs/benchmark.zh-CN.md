# A100 实测记录

[返回中文 README](../README.zh-CN.md) | [English README](../README.md)

## 测试环境

| 项目 | 配置 |
|---|---|
| GPU | 单张 NVIDIA A100-SXM4-80GB，`sm_80` |
| RAM | 1 TiB |
| Driver | 570.158.01 |
| CUDA build toolkit | 12.8 |
| Runtime | JigSawPT llama.cpp `dsv41-porte` |
| Commit | `3b6fcfe4f7e2c282076f0c159278d3acfa3ad4e5` |
| GGUF | MXFP4 MoE，完整 Engram，11 分片 |
| Context | 8,192 |
| Parallel slots | 1 |
| VRAM cache | 60 GiB |
| Pinned L2 | 120 GiB |
| DSpark | 关闭 |

## 加载与资源

| 指标 | 结果 |
|---|---:|
| 首次冷加载 | 约 4 分 22 秒 |
| 页缓存热态加载 | 约 1 分 18 秒至 1 分 26 秒 |
| GPU 稳态占用 | 约 70.6-70.8 GiB |
| GPU 剩余 | 约 10.3-10.5 GiB |
| Pinned L2 | 120.00 GiB，20,533 slots |

## 生成性能

| 场景 | Prompt | Completion | 结果 |
|---|---:|---:|---:|
| 非 reasoning，首次中文内容 | 38 tokens | 100 tokens | 8.20 tok/s |
| 相同请求再次执行 | 4 个未缓存 tokens | 100 tokens | 16.58 tok/s |
| Reasoning CRT 测试 | 42 tokens | 200 tokens | 11.48 tok/s |
| 公网短算术 | 16 tokens | 2 tokens | 端到端 3.06 秒 |

短算术输出过短，其 decode tok/s 不适合作为持续生成指标。

## 正确性检查

- `17 * 19` 返回 `323`。
- `29 * 31` 在 `reasoning_effort:"none"` 下返回干净正文 `899`。
- 中国剩余定理测试返回 `17`，推导正确。
- reasoning 响应以 `finish_reason:"stop"` 结束。
- parser 将推理放入 `reasoning_content`，最终答案放入 `content`。
- 重复中文请求内容完全一致。

## 缓存观察

100-token 中文请求后，累计专家命中率约 79.8%；重复相同请求后约 85.1%。同期 L2 未发生 eviction，decode 从 8.20 tok/s 上升到 16.58 tok/s。

这些数字只代表该硬件和测试提示词下的单请求测量，不是生产并发 SLA。

## 最大上下文测试

所有大上下文测试都使用独立的 `127.0.0.1:7889` 实例，不开放公网；每次测试结束后
恢复公网 `7888` 的 8K 配置。这里区分“能初始化监听”和“能完成一次真实生成”：

| Context | 初始化/监听 | 短请求生成 | 备注 |
|---:|---|---|---|
| 524,288 | 通过 | 通过 | 约 4.78 tok/s decode |
| 655,360 | 通过 | 通过 | 约 4.92 tok/s decode |
| 786,432 | 通过 | 通过 | 最大的本轮端到端验证点，约 5.01 tok/s decode |
| 819,200–847,872 | 通过 | 未重复做端到端验证 | 只证明可初始化，不等于可承载生产请求 |
| 849,920 | 通过 | 失败 | 第一条短请求即 CUDA OOM |
| 850,944 | 失败 | — | 边界附近已不稳定 |
| 917,504 | 失败 | — | compute buffer 约需 8.59 GiB |
| 1,048,576 | 失败 | — | compute buffer 约需 9.77 GiB |

`1,048,576` 的代表性日志为：

```text
allocating 9774.26 MiB on device 0: cudaMalloc failed: out of memory
failed to allocate compute buffers
```

所以本次没有通过 1M context 配置验证；公网服务已恢复到 8,192 tokens。实用结论是：
`786,432` 是本轮已完成短生成的最大 context，不能把更高的“初始化成功”误称为可服务上限。
失败不表示权重不兼容，而表示单卡显存账本在更大 context 下无法同时满足 compute buffer
和生成阶段的临时 CUDA 分配。
