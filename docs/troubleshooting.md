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
