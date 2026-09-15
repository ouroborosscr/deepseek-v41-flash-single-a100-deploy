# Security

## Public serving

The model server can consume substantial GPU, pinned memory, CPU, and disk I/O. An unauthenticated public endpoint allows anyone to consume those resources and submit data to the model.

The repository defaults to `HOST=127.0.0.1`. When a non-loopback host is selected, `scripts/05-serve.sh` requires either a non-empty `API_KEY` or the explicit override `ALLOW_UNAUTHENTICATED_PUBLIC=1`.

Prefer an authenticated TLS reverse proxy, VPN, firewall allowlist, and request rate/token limits. Do not send sensitive data over plain HTTP.

## Secrets

Never commit `.env`, API keys, SSH keys, passwords, cookies, cloud credentials, or raw service logs containing private data. The `.gitignore` is not a substitute for reviewing `git diff --cached` before every push.

## Model and runtime supply chain

The scripts download model weights and third-party runtime source. Verify upstream licenses, repository ownership, the pinned commit, checksums where available, and your organization's model-use policy before deployment.

# 安全说明

模型服务会大量消耗 GPU、锁页主存、CPU 和磁盘 I/O。无认证公网接口允许任何人消耗这些资源并向模型提交数据。

仓库默认监听 `127.0.0.1`。选择非回环地址时，启动脚本要求配置 `API_KEY`，或者显式设置 `ALLOW_UNAUTHENTICATED_PUBLIC=1`。正式环境建议使用带 TLS 和鉴权的反向代理、VPN、防火墙白名单以及请求速率和 token 上限。

提交前必须检查暂存区，禁止上传 `.env`、API key、SSH 凭据、cookie、含隐私的提示词/响应和服务日志。
