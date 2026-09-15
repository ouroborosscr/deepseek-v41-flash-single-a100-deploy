# 架构与容量分析

[返回中文 README](../README.zh-CN.md) | [English README](../README.md)

## 模型容量

公开模型卡给出的 backbone 参数量为 552B，另有约 196.6B Engram 条件记忆。实测 GGUF 元数据显示：

```text
n_params = 754,638,981,608
ftype = MXFP4 MoE
GGUF data size = 501,804,664,080 bytes
11 个分片文件总大小 = 501,809,981,440 bytes
```

官方 ModelScope checkpoint 的 48 个 safetensors 分片总大小为 510,296,708,312 bytes。

vLLM 配方对原始 checkpoint 的拆分约为：

| 组成 | 存储量 |
|---|---:|
| Routed + DSpark experts（MXFP4） | 259.5 GiB |
| Engram tables（FP8） | 183.1 GiB |
| Attention、dense projections、routers（FP8） | 6.9 GiB |
| Embedding、LM head、norms | 3.9 GiB |
| UE8M0 block scales | 21.9 GiB |

因此，常规全驻留服务的瓶颈是权重，而不是 KV cache。

## 激活参数不等于驻留参数

V4.1-Flash 在 prefill/decode 阶段每 token 分别激活约 8B/16B 参数。MoE router 会为不同 token 选择不同专家，因此当前未激活的专家不能被删除，只能常驻显存、放在主存按需上传、放在 mmap 文件中按需读取，或者分布到其他 GPU/节点。

本方案选择单 GPU 的多层缓存，而不是多 GPU tensor/expert parallel。

## 实测内存层级

```text
GPU: A100 80GB
  约 10.6 GiB：常驻权重、KV、CUDA context 与工作区余量
  60 GiB：MoE VRAM expert cache

Host RAM: 1 TiB
  120 GiB：CUDA pinned L2 expert cache
  其余：Linux page cache、进程页和系统服务

Storage
  467.35 GiB：11 个 GGUF 分片
```

服务稳定后，GPU 占用约 70.6 GiB，剩余约 10.5 GiB。日志确认 L2 为 `PINNED`，不是 pageable fallback。

## A100 与 RTX 5090 的差异

RTX 5090 支持 Blackwell 原生 FP4 MMA。A100 不支持该指令，但固定 llama.cpp 分支为 `GGML_TYPE_MXFP4` 提供了 Ampere `sm_80` MMQ 配置，因此能够通过不同的量化矩阵核执行。

两张卡的 PCIe、显存容量、显存带宽和 FP4 路径均不同。5090 报告只能证明 expert streaming 架构成立，不能作为 A100 吞吐预测；本仓库只报告 A100 实测结果。

## 为什么保留 Engram

两张 Engram 表约占 189 GiB。将其置零在数学上相当于让该模块变成恒等映射，但输出不再等同于官方模型。本部署通过原始 FP8 字节和 scale 的 mmap 转换完整保留 Engram。

## 上下文策略

模型训练上下文上限为 1,048,576 tokens，当前服务仅配置 8,192。虽然全局 KV 经过强压缩，上下文扩大仍会影响 prefill 时间、expert working set、page fault、缓存命中率和单卡延迟。

建议按 16K、32K、64K 逐级测试，不应直接将配置改为 1M。
