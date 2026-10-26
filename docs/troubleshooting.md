# 故障排查

## 安装脚本拒绝覆盖配置

如果 /usr/local/etc/xray/config.json 或 /etc/nginx/sites-available/self-vps 已存在，但没有 /etc/self-vps/managed 标记，脚本会停止。这是防止覆盖现有生产配置的安全边界。

先手动备份并审查差异。不要为了绕过检查而直接创建 managed 标记。

## Certbot 签发失败

~~~bash
getent ahosts node.example.com
sudo ss -lntp
sudo nginx -t
curl -I http://node.example.com/.well-known/acme-challenge/test
sudo journalctl -u nginx -n 100 --no-pager
~~~

确认 DNS 指向本机、TCP 80 可从公网访问、云防火墙和 UFW 已放行。Cloudflare 代理设置也可能影响非标准部署；排查时保持清晰的 DNS 与源站路径。

## Xray 无法启动

~~~bash
sudo /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
sudo ls -l /usr/local/etc/xray/cert
sudo journalctl -u xray -n 100 --no-pager
~~~

常见原因是证书文件不存在、私钥权限不允许 Xray 服务用户读取，或 JSON 配置错误。

## 443 正常但客户端无法连接

核对客户端的域名、端口、Trojan 密码和 SNI。skip-cert-verify 应保持 false。然后分别检查：

~~~bash
openssl s_client -connect node.example.com:443 -servername node.example.com
sudo ss -tin '( sport = :443 )'
sudo journalctl -u xray -n 100 --no-pager
~~~

## 国内直连 22/443 超时，但境外可连、Cloudflare Tunnel 正常

如果服务器上 Xray/Nginx 都在运行，境外节点能连 443，而中国大陆直连 22/443/8443 都是 SYN 到达、SYN-ACK 回不来，优先判断为 IP/路径级回程丢包，不是 Trojan 密码或端口问题。不要继续换端口或反复改密码。

使用 Cloudflare Tunnel 绕开直连入站：

- `cdn.example.com` → `http://localhost:8082` 承载 VLESS/WS
- `ssh.example.com` → `tcp://localhost:22` 承载 SSH，并加 Cloudflare Access

WebSocket 手工测试必须用 HTTP/1.1；HTTP/2 没有 Upgrade 语义，返回 404 属于正常。

## FlClash 显示节点不可用，但服务端没有请求日志

先确认 FlClash 真正加载的是哪份 profile，而不是只看“导入成功”。检查：

- 当前 profile 是否是自建节点，而不是旧机场订阅；
- `autoRun` 是否开启；
- TUN 是否造成回环，可先关闭 TUN 用 7890 测试；
- DNS fallback 是否指向 `1.1.1.1` / `dns.google`，国内可能超时；
- 是否有 `DOMAIN-SUFFIX,example.com,DIRECT` 之类的规则。

服务端 ground truth：

~~~bash
sudo tail -f /var/log/nginx/access.log | grep '<your-ws-path>'
sudo journalctl -u xray -f
~~~

客户端：

~~~powershell
curl.exe -x http://127.0.0.1:7890 https://api.ipify.org
~~~

如果服务端完全没有客户端请求，问题在 FlClash 本地配置/规则/DNS，不在 VPS。

## SSH 提示 Permission denied (publickey)

这是预期的 key-only 行为：

- 密码登录已关闭；
- root SSH 已关闭；
- 只允许 `ubuntu` 公钥登录，然后 `sudo -i`。

确认使用 Cloudflare Tunnel 和正确的私钥：

~~~powershell
ssh hynous
~~~

如果失败，用 OrcaTerm 或腾讯云 VNC 进入，检查：

~~~bash
sudo sshd -T | grep -E 'passwordauthentication|permitrootlogin|pubkeyauthentication'
sudo ls -l /home/ubuntu/.ssh/authorized_keys
sudo journalctl -u ssh -n 100 --no-pager
~~~

## Cloudflare 访问返回登录页或 403

- `ssh.example.com` 应该被 Cloudflare Access 保护；
- `cdn.example.com` 不应被 Access 保护，否则 VLESS 会被登录页挡住；
- 检查是否有 `*.example.com` 的通配 Access 应用覆盖到 cdn；
- 检查 WAF / Bot Fight Mode / Under Attack 是否对 WebSocket upgrade 发 challenge。

## 节点速度慢

先区分 VPS 本机出口和“客户端到 VPS”链路：

~~~bash
curl -L -o /dev/null -s -w 'vps speed=%{speed_download}B/s\n' \
  'https://speed.cloudflare.com/__down?bytes=20000000'
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
~~~

客户端再通过 FlClash 代理测试相同目标。Beszel 只能看到 VPS 汇总流量，不能定位家庭运营商到 VPS 的慢速路由。

## 监控界面无法访问

~~~bash
curl --fail http://127.0.0.1:8090/
curl --fail http://127.0.0.1:3001/
sudo docker compose -f /opt/self-vps-monitoring/compose.yaml ps
sudo journalctl -u cloudflared -n 100 --no-pager
~~~

如果 Tunnel 显示在线但页面返回源站不可达，优先确认两个回环端口正在监听，以及 Tunnel 路由指向正确端口。
