# 日常运维

## 状态与日志

~~~bash
sudo bash scripts/verify.sh
sudo systemctl status xray nginx certbot.timer --no-pager
sudo journalctl -u xray -u nginx -n 100 --no-pager
sudo ss -lntp
sudo ufw status verbose
~~~

可选监控：

~~~bash
cd /opt/self-vps-monitoring
sudo docker compose ps
sudo docker compose logs --tail 100
~~~

## 证书续期

~~~bash
sudo certbot renew --dry-run --run-deploy-hooks
sudo systemctl status certbot.timer --no-pager
~~~

部署钩子会把续期证书复制到 Xray 目录并重启 Xray。不要让 Xray 直接读取 root-only 的 Let's Encrypt 私钥。

## 配置变更

先备份，再修改仓库的 .env 并重新运行安装脚本：

~~~bash
sudo bash scripts/backup.sh
sudo bash scripts/install.sh
sudo bash scripts/verify.sh
~~~

安装脚本只会覆盖带有 /etc/self-vps/managed 标记的本项目配置。它不会接管其他已有 Xray 或 self-vps Nginx 配置。

## 升级

核心组件升级前先创建云厂商快照和脚本备份，然后拉取仓库更新、检查差异，再重新运行安装与验证。Xray 官方安装器固定到仓库审核过的提交；只有本仓库更新该引用后才会改变安装逻辑。

监控容器升级：

~~~bash
cd /opt/self-vps-monitoring
sudo docker compose pull
sudo docker compose up -d
sudo docker compose ps
~~~

Uptime Kuma 使用主版本标签 2；Beszel 采用其官方 Compose 示例使用的 latest 标签。因此 Beszel 更新前必须备份数据并查看上游发布说明。

## 回滚

恢复最近一次完整备份：

~~~bash
sudo bash scripts/restore.sh --confirm /path/to/self-vps-TIMESTAMP.tar.gz
sudo bash scripts/verify.sh
~~~

数据库格式升级后，旧容器镜像不一定能读取新数据库。回滚监控版本前应同时恢复升级前的数据备份。

## 停用

~~~bash
sudo systemctl disable --now xray
sudo systemctl disable --now nginx
cd /opt/self-vps-monitoring
sudo docker compose stop
~~~

这些命令保留配置、证书和监控数据。永久删除数据不属于自动流程。
