# 可选监控

该模块部署 Beszel Hub、本机 Beszel Agent 和 Uptime Kuma。它们只绑定 VPS 回环地址，不需要开放 8090、3001 或 Beszel Agent 端口。

## 前置条件

按照 [Docker 官方 Ubuntu 指南](https://docs.docker.com/engine/install/ubuntu/)安装 Docker Engine 和 Compose 插件，然后确认：

~~~bash
docker version
docker compose version
~~~

## 启动

~~~bash
sudo install -d -m 750 /opt/self-vps-monitoring
sudo cp optional/monitoring/compose.yaml /opt/self-vps-monitoring/
sudo cp optional/monitoring/.env.example /opt/self-vps-monitoring/.env
sudo nano /opt/self-vps-monitoring/.env
cd /opt/self-vps-monitoring
sudo docker compose config
sudo docker compose up -d
~~~

由于两个界面只监听回环地址，在配置 Cloudflare Tunnel 前可从本地电脑建立 SSH 端口转发：

~~~bash
ssh -L 8090:127.0.0.1:8090 -L 3001:127.0.0.1:3001 ubuntu@your-server
~~~

然后访问 http://127.0.0.1:8090 和 http://127.0.0.1:3001。Tunnel 配置完成后，把 BESZEL_APP_URL 更新为实际 HTTPS 监控域名并重新运行 docker compose up -d。

首次启动时 BESZEL_KEY 和 BESZEL_TOKEN 可以暂时为空。浏览器进入 Beszel Hub 创建管理员账号并添加本机系统，再把界面提供的 Key 和 Token 写入 /opt/self-vps-monitoring/.env：

~~~bash
cd /opt/self-vps-monitoring
sudo nano .env
sudo docker compose up -d
~~~

在 Beszel 添加系统时，Host / IP 使用 Unix socket：

~~~text
/beszel_socket/beszel.sock
~~~

Uptime Kuma 首次访问时创建管理员账号，并手动添加 Xray TCP 443、Nginx HTTP 80、节点 HTTPS 和证书到期监控。账号、通知凭据和 Push URL 不应写入仓库。

## Cloudflare Tunnel

推荐在 Cloudflare Dashboard 创建 remotely-managed Tunnel，并添加两条 Published application：

| 公共主机名 | 本地服务 |
|---|---|
| monitor.example.com | http://127.0.0.1:8090 |
| status.example.com | http://127.0.0.1:3001 |

按照 Cloudflare 页面提供的 Linux 命令安装 cloudflared。避免把 Token 写进脚本、README 或 Compose 文件；命令执行完成后清理含 Token 的终端历史，并考虑使用 Cloudflare Access 保护两个界面。

[cloudflared-config.yml](cloudflared-config.yml)仅用于选择 locally-managed Tunnel 的用户。替换 Tunnel UUID、凭据路径和域名后，再按 [Cloudflare 官方 systemd 文档](https://developers.cloudflare.com/tunnel/advanced/local-management/as-a-service/linux/)安装服务。不要提交 Tunnel JSON 凭据。

## 验证

~~~bash
sudo docker compose ps
curl --fail http://127.0.0.1:8090/
curl --fail http://127.0.0.1:3001/
systemctl is-active cloudflared
~~~

Beszel Agent 使用 host network 是为了读取主机网卡统计，但监听 Unix socket，不在公网开放 45876。Docker socket 以只读方式挂载；仍应把能访问 Docker socket 的容器视为高权限组件。

## 更新和停止

~~~bash
cd /opt/self-vps-monitoring
sudo docker compose pull
sudo docker compose up -d
sudo docker compose stop
~~~

停止不会删除 ./data。不要运行 docker compose down -v 或删除 data，除非已经验证备份且明确希望永久清除数据。
