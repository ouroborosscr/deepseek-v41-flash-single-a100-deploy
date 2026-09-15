# 单张 A100 80GB 部署 DeepSeek-V4.1-Flash

[English](README.md) | 简体中文

本仓库给出一套经过真实验证的部署方案：将 MoE 专家分层放置在显存、锁页主存、Linux 页缓存和存储设备中，从而在一张 NVIDIA A100-SXM4-80GB 上运行 DeepSeek-V4.1-Flash 文本模型。

仓库只包含部署脚本和实测数据，不包含模型权重、GGUF、认证信息或 llama.cpp 源码。

## 部署结果

本方案于 2026 年 9 月 15 日部署并验证完成：

- 单张 A100-SXM4-80GB；
- 1 TiB 系统内存（建议最低 768 GiB）；
- 60 GiB 显存专家缓存；
- 120 GiB pinned host expert cache；
- 初始服务上下文 8,192 tokens；
- OpenAI 兼容 HTTP API；
- 首次内容实测 8.20 tok/s、内容驻留后 16.58 tok/s、200-token reasoning 实测 11.48 tok/s。

这证明的是：**单卡异构分层部署可行**，而不是模型可以完整装入 80GB 显存。常规 vLLM 全驻留路径并不适用于单张 A100；当前 vLLM 配方的建议聚合显存预算约为 614GB。

## 为什么能够运行

DeepSeek-V4.1-Flash 包含 552B backbone、约 196.6B Engram 参数；prefill 每 token 激活约 8B 参数，decode 每 token 激活约 16B 参数。激活稀疏降低了计算量，但所有专家仍必须存放在某个可访问层中。

```text
A100 常驻权重与工作区
  -> 60 GiB VRAM 专家缓存
      -> 120 GiB pinned RAM 专家缓存
          -> Linux 文件页缓存
              -> 存储设备上的分片 GGUF
```

详细显存与主存账本见[架构说明](docs/architecture.zh-CN.md)。

## 已验证的硬件和软件条件

- NVIDIA A100 80GB（`sm_80`）
- 约 1 TiB 内存；主机检查脚本将 768 GiB 作为最低保护值
- 同时保留原始权重和 GGUF 时，至少需要 1.1 TiB 可用磁盘
- CUDA 12.8 和兼容的 host compiler
- CMake、Ninja、curl、patch、tar、Python、tmux、ModelScope
- 固定 commit 的 V4.1 llama.cpp 实验分支

其他 GPU、更小内存、网络文件系统、多模态服务和多请求吞吐均不在本仓库的已验证范围内。

## 仓库结构

```text
config/env.example           路径与资源预算配置
patches/include-cmath.patch  固定 commit 所需的编译补丁
scripts/01-check-host.sh     内存、GPU、磁盘预检查
scripts/02-download-model.sh ModelScope 下载与分片校验
scripts/03-build-runtime.sh  固定源码、打补丁并构建 sm_80
scripts/04-convert-model.sh  全量 dry-run 与分片 GGUF 转换
scripts/05-serve.sh          带公网安全门的单 GPU 服务启动
scripts/06-smoke-test.sh     健康、模型列表和推理验证
docs/                        架构、基准和故障排查记录
```

## 快速开始

### 1. 配置环境

```bash
cp config/env.example .env
${EDITOR:-vi} .env
source .env
export CONFIG_FILE=$PWD/.env
```

不要提交 `.env`。所有目录应使用绝对路径，并确保所在文件系统空间充足。

### 2. 检查主机

```bash
./scripts/01-check-host.sh
```

### 3. 从魔塔社区下载官方权重

长任务建议在 tmux 中执行：

```bash
tmux new-session -d -s dsv41-download \
  "CONFIG_FILE='$PWD/.env' '$PWD/scripts/02-download-model.sh' \
   >'$PWD/download.log' 2>&1"
```

实测 checkpoint 包含 96,085 个索引张量、48 个 safetensors 分片，共 510,296,708,312 bytes。

### 4. 构建运行时

```bash
./scripts/03-build-runtime.sh
```

脚本下载 `JigSawPT/llama.cpp` commit `3b6fcfe4f7e2c282076f0c159278d3acfa3ad4e5`，按需加入 `<cmath>` 补丁，并针对 `sm_80` 构建 CUDA 代码。

### 5. 准备转换环境

```bash
python3 -m venv "$DEPLOY_ROOT/venv-convert"
"$DEPLOY_ROOT/venv-convert/bin/pip" install \
  -r "$RUNTIME_DIR/requirements/requirements-convert_hf_to_gguf.txt"
export CONVERT_PYTHON="$DEPLOY_ROOT/venv-convert/bin/python"
```

创建后把 `CONVERT_PYTHON` 写入 `.env`。

### 6. 先执行全量 dry-run

```bash
./scripts/04-convert-model.sh --dry-run
```

dry-run 会遍历并重排全部 40 层专家、验证 Engram 元数据，并打印 11 分片规划，但不会写出 GGUF。

### 7. 在 tmux 中正式转换

```bash
tmux new-session -d -s dsv41-convert \
  "CONFIG_FILE='$PWD/.env' '$PWD/scripts/04-convert-model.sh' --convert \
   >'$PWD/convert.log' 2>&1"
```

实测输出为 11 个文件，共 501,809,981,440 bytes。转换器通过 `memmap` 传输大型 Engram 表，不会将其完整展开成 FP32。

### 8. 启动服务

默认只监听本机回环地址：

```bash
tmux new-session -d -s dsv41-server \
  "CONFIG_FILE='$PWD/.env' '$PWD/scripts/05-serve.sh' \
   >'$PWD/server.log' 2>&1"
```

等待日志出现：

```text
MoE L2 host tier = 120.00 GiB PINNED
model loaded
```

如需监听网络接口，应设置 `HOST=0.0.0.0` 和 `API_KEY`。如果明确要无认证公开，还必须额外设置 `ALLOW_UNAUTHENTICATED_PUBLIC=1`。

### 9. 验证

```bash
./scripts/06-smoke-test.sh
```

脚本会检查 `/health`、`/v1/models`，并发送一个预期答案为 `899` 的确定性请求。

## API 示例

要获得干净的非 reasoning 响应，应使用 OpenAI 顶层字段 `reasoning_effort: "none"`：

```bash
curl http://127.0.0.1:7888/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "DeepSeek-V4.1-Flash",
    "messages": [{"role":"user","content":"What is 29*31? Return only the integer."}],
    "reasoning_effort": "none",
    "temperature": 0,
    "max_tokens": 32
  }'
```

不传 `reasoning_effort: "none"` 时使用 reasoning 路径。已验证的 parser 会把思考内容放入 `message.reasoning_content`，最终答案放入 `message.content`。

不要在固定实验分支上使用 `chat_template_kwargs.thinking=false`：该路径会在正文中留下孤立的 `</think>`。详见[故障排查](docs/troubleshooting.zh-CN.md)。

## 当前限制

- **仅文本：** 当前转换器排除了视觉编码器和 aligner。
- **实验性运行时：** 不是 upstream llama.cpp 或标准 vLLM 路径。
- **初始上下文为 8K：** 模型支持 1M，但单卡服务尚未验证该规模。
- **单请求 slot：** 增加并发会加剧专家缓存抖动，必须单独压测。
- **锁定 120 GiB 主存：** 必须确认日志显示 `PINNED`；pageable 回退会更慢。
- **未启用 DSpark：** 5090 报告中，expert streaming 下的混合内容收益为中性或负值。

## 安全

禁止提交 `.env`、API key、SSH 凭据、模型文件和服务日志。除非有认证反向代理、防火墙、VPN 或白名单保护，否则应保持回环监听。公网部署前请阅读 [SECURITY.md](SECURITY.md)。

## 证据与参考资料

- [实测基准](docs/benchmark.zh-CN.md)
- [故障排查记录](docs/troubleshooting.zh-CN.md)
- [DeepSeek ModelScope 模型页](https://www.modelscope.cn/models/deepseek-ai/DeepSeek-V4.1-Flash)
- [vLLM 部署配方](https://recipes.vllm.ai/deepseek-ai/DeepSeek-V4.1-Flash)
- [单张 RTX 5090 技术报告](https://github.com/JigSawPT/deepseek-v41-flash-on-5090)
- [V4.1 GGUF 模型卡](https://huggingface.co/JigSawPT/DeepSeek-V4.1-Flash-GGUF)

## 许可证

本仓库脚本和文档采用 MIT License。DeepSeek 模型权重和 llama.cpp 是独立的上游作品，适用其各自许可证；本仓库不重新分发二者。
