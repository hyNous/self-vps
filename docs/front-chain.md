# 机场前置与双客户端配置

## 目标

最终出口固定为自建 VPS，机场只承担"进来的路"。换机场或换节点只影响链路质量，不改变网站和 Anthropic 看到的出口 IP。

~~~text
FlClash / Mihomo（TUN）
      │
      ├─ 机场节点（dialer-proxy）
      │     ▼
      │   VPS Shadowsocks 8445 ──→ freedom / VPS 直接出站
      │
      ├─ VLESS + Reality 443（直连）
      │
      └─ VLESS/WS 443（Cloudflare 边缘，备用）
~~~

前置链路适合机场被封锁、直连 Reality 不稳定时使用；Reality 和 CDN 仍保留为独立入口。

## 为什么需要两份客户端配置

Claude Desktop 等 Chromium/Electron 应用会优先使用 HTTP/3：

~~~text
HTTP/3 = QUIC = UDP 443
~~~

- TCP 443 走 FlClash → 机场 → SS 8445 → VPS，出口是 VPS；
- 如果 SS 链路只承载 TCP，UDP/443 不会走完整链路，QUIC 请求可能从其他路径出去；
- Anthropic 按实际出口 IP 判断地区，看到非支持地区就返回 `region_unavailable`。

有两种处理方式：

| 策略 | 做法 | 代价 |
|---|---|---|
| 强制 TCP | 规则最前面阻断 `UDP/443`，让应用回退 HTTP/2 | 没有 HTTP/3，连接行为确定 |
| 保留 QUIC | SS 节点 `udp: true`，服务端和防火墙放行 UDP | 依赖机场节点真的承载 UDP |

Mihomo 的健康检查只测 TCP，无法判断"UDP 是否真的通"，所以单份配置无法自动兜底。保留两份 profile、手动切换，是当前最稳的做法。

## 客户端文件

以下文件只存在本地，已被 `.gitignore` 排除，包含 SS 密码和机场订阅地址：

| 文件 | 链路 | SS `udp` | QUIC |
|---|---|---|---|
| `seoul-tcp.yaml` | 机场 → SS → VPS | `false` | 阻断 UDP/443 |
| `seoul-udp.yaml` | 机场 → SS → VPS | `true` | 放行 |
| `seoul-direct.yaml` | Reality / CDN 直连 | - | 放行 |

FlClash 导入后保存的是副本，源文件改名不影响已导入的配置。要同步名称，需要删除旧条目后重新导入。

关键片段：

~~~yaml
proxies:
  - name: Seoul-SS-via-Airport
    type: ss
    server: __VPS_IP__
    port: 8445
    cipher: aes-256-gcm
    password: __SS_PASSWORD__
    udp: false            # UDP 版改为 true
    dialer-proxy: 前置机场

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - Seoul-SS-via-Airport
      - Seoul-Reality
      - Seoul-CDN
      - DIRECT

  - name: 前置机场
    type: select
    use:
      - __AIRPORT_PROVIDER__
    empty-fallback: REJECT

rules:
  - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT   # 仅 TCP 版保留
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
~~~

`dialer-proxy` 让 SS 节点先经机场节点拨号；这是机场前置的核心，不依赖机场客户端。

## 服务端要求

SS inbound 必须同时监听 TCP 和 UDP：

~~~json
{
  "tag": "ss-relay-in",
  "port": 8445,
  "protocol": "shadowsocks",
  "settings": {
    "method": "aes-256-gcm",
    "password": "__SS_PASSWORD__",
    "network": "tcp,udp"
  }
}
~~~

防火墙两层都要放行：

~~~bash
sudo ufw allow 8445/tcp
sudo ufw allow 8445/udp
~~~

云厂商安全组同样需要 TCP 和 UDP 8445。只开 TCP 时，`seoul-udp.yaml` 不会生效。

这一层是运维额外添加的，不由 `scripts/install.sh` 创建；SS 参数保存在 `/etc/self-vps/ss-relay.env`，权限保持 root-only。

## 验证

TCP 出口：

~~~powershell
curl.exe -x http://127.0.0.1:7890 https://ipinfo.io/json
curl.exe -sS -x http://127.0.0.1:7890 https://www.cloudflare.com/cdn-cgi/trace
~~~

期望 `ip=` 是 VPS 地址，`loc=` 是目标国家。

注意：`curl` 只能证明 TCP 出口，不能证明 QUIC/UDP 也走同一条链。判断 UDP 需要用 SOCKS5 UDP 发一次 DNS 查询（例如向 `1.1.1.1:53`），能收到响应才算通。只验证过当前选中的机场节点，订阅更新或换节点后需要重新验证。

## 切换流程

1. 在 FlClash 选择 `seoul-udp.yaml`（日常）或 `seoul-tcp.yaml`（兜底）；
2. 确认 `PROXY` 指向 `Seoul-SS-via-Airport`；
3. 从系统托盘彻底退出 Claude Desktop，确认没有残留进程；
4. 重新启动并测试。

改配置后不彻底重启，Electron 可能继续复用旧连接。

## 失败模式

**`seoul-tcp.yaml`**：机场节点整体不可用时 TCP 直接失败，健康检查变红，换节点即可。QUIC 被阻断，不会静默绕路。

**`seoul-udp.yaml`**：如果机场节点不支持 UDP，TCP 仍然正常、健康检查全绿，但 Claude 会静默报地区错误。这时切回 `seoul-tcp.yaml` 并重启 Desktop。

## 安全边界

- SS 密码、机场订阅地址和真实 IP 只存在本地 profile 与 `/etc/self-vps/ss-relay.env`，不提交仓库；
- 公开文档只保留占位符；
- SS 入口暴露公网，密码应足够长，更换后同步所有客户端配置。
