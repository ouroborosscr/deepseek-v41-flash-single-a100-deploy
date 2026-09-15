# 故障排查

[返回中文 README](../README.zh-CN.md) | [English README](../README.md)

## Git clone 长时间没有对象传输

症状：目录只有 `.git` 元数据，`git-remote-https` 长时间运行但 pack 文件没有增长。

处理：使用固定 commit 的 GitHub codeload tarball。`03-build-runtime.sh` 已采用该方式，避免依赖完整 Git 协议。

## CUDA 11.5 编译出现 parameter packs 错误

典型错误：

```text
/usr/include/c++/11/bits/std_function.h: error: parameter packs not expanded with '...'
```

原因：服务器发行版 CUDA 11.5 NVCC 与 GCC 11 的兼容问题。处理方法是使用 CUDA 12.8，并将 `CMAKE_CUDA_ARCHITECTURES` 固定为 80。

## `std::isfinite` 不存在

固定实验分支的 `src/llama-moe-stream.cpp` 使用 `std::isfinite`，但缺少 `<cmath>`。应用 `patches/include-cmath.patch`；如果未来上游已包含该头文件，构建脚本会跳过补丁。

## L2 显示 PAGEABLE

目标日志应为：

```text
MoE L2 host tier = 120.00 GiB PINNED
```

如果显示 `PAGEABLE`，检查 pinned/locked memory 限制、可用主存、CUDA host buffer 分配，以及其他进程是否持有大块 pinned memory。Pageable L2 仍可运行，但主存到 GPU 上传会更慢。

## 重启时 GPU busy or unavailable

测试服务器的 GPU 使用 `Exclusive_Process` compute mode。旧进程退出后，CUDA context 可能需要数秒才能释放。

```bash
nvidia-smi -i "$GPU_INDEX" \
  --query-compute-apps=pid,process_name,used_memory \
  --format=csv,noheader
```

确认没有 compute process 后再启动，不要同时运行两个实例争抢同一张卡。

## 关闭 thinking 后正文出现 `</think>`

不要使用：

```json
{"chat_template_kwargs":{"thinking":false}}
```

使用：

```json
{"reasoning_effort":"none"}
```

## 根路径 curl 返回 HTTP 415

内置 Web UI 使用 gzip。如果客户端不声明 gzip 支持，根路径可能返回 `Error: gzip is not supported by this browser`。浏览器可正常访问；curl 使用：

```bash
curl --compressed http://127.0.0.1:7888/
```

API 路径 `/health` 和 `/v1/*` 不受此问题影响。

## ModelScope 下载完整性

运行 `02-download-model.sh`。脚本会比较 `model.safetensors.index.json` 与实际分片，并打印张量数、分片数和总字节数。

## 服务长时间返回 503

加载期间 `/health` 返回以下内容属于预期：

```json
{"error":{"message":"Loading model","type":"unavailable_error","code":503}}
```

只有日志出现 `model loaded` 且 `/health` 返回 200 后才能接收业务流量。
