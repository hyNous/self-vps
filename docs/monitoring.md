# 监控与状态页

## 两个面板分别看什么

| 地址 | 组件 | 用途 |
|---|---|---|
| `https://status.hynous.cc/` | Uptime Kuma | 统一状态页；根路径会跳到 `/status/hynous` |
| `https://monitor.hynous.cc/` | Beszel | CPU、内存、磁盘、网卡流量和容器资源 |

状态页是给人看的；Beszel 是给排障和容量判断用的。不要用 Beszel 的流量图判断“代理协议是否正常”，也不要只看 Uptime Kuma 的 443 绿灯就认为 Reality 一定能出站。

## 状态页分组

### 代理入口

| 监控 | 说明 |
|---|---|
| `Reality 443（本机）` | 本机 Xray Reality 端口；红灯表示直连节点不可用 |
| `Reality 443（外部 TCP）` | 从外部域名检查 443；只能证明端口开放 |
| `CDN 443（Cloudflare）` | Cloudflare Tunnel → Nginx 8082 的 HTTP 面具页 |
| `端到端探针（客户端）` | 从你的 Windows 客户端经 FlClash 访问外网；这是最有价值的一层 |

### 网站与管理

| 监控 | 说明 |
|---|---|
| `Nginx 80（本机入口）` | 本机 Nginx 80，301 跳转也算可达；不是 www 主页 HTTPS |
| `QQQ 8443（管理）` | QQQ Dashboard；401 是 Basic Auth，正常 |
| `Beszel API` | Beszel 健康接口 |
| `Uptime Kuma` | 状态页自身 |

## 颜色怎么看

- **绿色**：最近一次探测成功。
- **红色**：最近一次探测失败；先看“消息”里的状态码/超时。
- **灰色/Pending**：新监控尚未完成第一次探测，或 Push 监控还没收到客户端上报。

红灯处理顺序：

1. `Reality 443（本机/外部）` 红：先看 `systemctl status xray`，再在 FlClash 切到 `CDN` 备用；
2. `CDN 443` 红：检查 `cloudflared`、Nginx 8082、Xray 10086；
3. `端到端探针` 红：检查 FlClash 是否运行、7890 是否监听、TUN/系统代理设置；
4. `主页入口` 红：检查 Nginx 80 和主页 8080；
5. `QQQ 8443` 红：检查 `qqq-proxy.service` 和 8000；
6. `Beszel/Uptime Kuma` 红：先看 Docker `DOCKER` 链和 3001/8090 端口。

## 端到端探针

Windows 客户端脚本在仓库的 `scripts/client-probe.ps1`。它通过 `127.0.0.1:7890` 请求 `https://api.ipify.org`，成功时上报出口 IP，失败时上报 down。

推送地址不放进仓库，保存在：

```text
%APPDATA%\self-vps\probe.url
```

计划任务名称：

```text
SelfVPS-EndToEnd-Probe
```

手动运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\hynous\vps\scripts\client-probe.ps1
```

手动触发计划任务：

```powershell
Start-ScheduledTask -TaskName 'SelfVPS-EndToEnd-Probe'
Get-ScheduledTaskInfo -TaskName 'SelfVPS-EndToEnd-Probe'
```

这个探针依赖 FlClash 正在运行且 7890 可用。FlClash 关闭时它会变红，这是预期行为，不代表 VPS 一定故障。

## Docker 自动检测/恢复

`self-vps-docker-watchdog.timer` 每 2 分钟检查：

- Docker 的 `DOCKER` iptables 链；
- `127.0.0.1:3001` 和 `127.0.0.1:8090`；
- Uptime Kuma 和 Beszel 的 HTTP 健康接口。

如果链丢失且端口失效，会重启 Docker、拉起 compose，并在必要时重建 Uptime Kuma/Beszel，使端口映射恢复。现有端口仍然正常时，不会为了修链而重启所有容器。

查看：

```bash
systemctl status self-vps-docker-watchdog.timer --no-pager
systemctl status self-vps-docker-watchdog.service --no-pager
journalctl -u self-vps-docker-watchdog -n 100 --no-pager
```

## 证书

`status_page` 已启用证书到期显示；HTTPS 监控项会在状态页上显示证书剩余天数。Reality 本身不使用 Let's Encrypt 证书，证书只影响可选的网站/8443 入口。

## 监控不要过度

建议保持 8-10 个有明确含义的监控即可。每新增一个监控，都要能回答：

- 它代表哪条用户路径？
- 红灯时用户会遇到什么？
- 第一个排查动作是什么？

如果回答不了，就不要加，否则只会增加噪声。
