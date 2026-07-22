# VPS 与域名迁移

迁移前先确认旧节点健康，并把 DNS TTL 降低到可接受值。保留旧 VPS，直到新节点完成客户端验证。

## 同域名迁移到新 VPS

1. 在旧 VPS 创建备份并复制到加密的本地存储。
2. 为新 VPS 准备一个临时测试域名，使用本仓库完成核心安装。
3. 把备份和校验文件复制到新 VPS，执行恢复。
4. 确认新 VPS 的 Xray、Nginx、证书、BBR 和监控数据正常。
5. 更新生产域名 DNS 到新 VPS。
6. 用客户端连接并确认出口地址。
7. 执行 Certbot dry-run 并观察稳定性，再下线旧 VPS。

~~~bash
# 旧 VPS
sudo bash scripts/backup.sh

# 新 VPS：先通过临时域名完成基础安装，再恢复
sudo bash scripts/restore.sh --confirm /path/to/self-vps-TIMESTAMP.tar.gz
sudo bash scripts/verify.sh
~~~

备份含真实密码、证书私钥和监控数据库，只能通过受保护通道传输。不要上传到 GitHub Release、Issue 或公开对象存储。

## 更换域名

1. 新域名 DNS 指向当前或新 VPS。
2. 修改本地 .env 中的 NODE_DOMAIN 和 ACME_EMAIL。
3. 保留原 TROJAN_PASSWORD 可减少客户端改动，或显式轮换密码。
4. 重新执行安装脚本，签发新证书并渲染 Xray/Nginx 配置。
5. 更新 FlClash 的 server、sni 和密码。
6. 更新 Uptime Kuma 监控项及 Cloudflare Tunnel 公共主机名。
7. 验证新域名后再删除旧 DNS 和旧证书。

~~~bash
sudo bash scripts/backup.sh
sudo bash scripts/install.sh
sudo bash scripts/verify.sh
~~~

## 切换验证

~~~bash
systemctl is-active ssh nginx xray certbot.timer
sysctl net.ipv4.tcp_congestion_control
sudo docker compose -f /opt/self-vps-monitoring/compose.yaml ps
~~~

Windows 客户端：

~~~powershell
curl.exe -x http://127.0.0.1:7890 https://api.ipify.org
~~~

当前 Beta 不承诺无停机迁移。需要无停机时，应另行设计 DNS-01 证书签发、双节点并行和客户端切换策略。
