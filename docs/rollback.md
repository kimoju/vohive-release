# Rollback

1. 直接安装指定旧版本（默认自动校验 `SHA256SUMS`）：

```bash
curl -fsSL https://raw.githubusercontent.com/kimoju/vohive-release/master/install.sh | bash -s -- --version v1.5.2
```

```sh
wget -O - https://raw.githubusercontent.com/kimoju/vohive-release/master/install.sh | sh -s -- --version v1.5.2
```

> 若回退到早期尚未发布 `SHA256SUMS` 校验资产的历史版本，且确认下载来源可信，可在末尾显式追加 `--skip-checksum`。

2. 若升级失败且 `.bak` 存在，可使用原子替换（避免直接 `cp` 覆盖运行中进程触发 `Text file busy` / `ETXTBSY`）手动恢复：

systemd 环境（Debian / Ubuntu 等）：

```bash
sudo install -m 0755 /opt/vohive/bin/vohive.bak /opt/vohive/bin/vohive.tmp
sudo mv -f /opt/vohive/bin/vohive.tmp /opt/vohive/bin/vohive
sudo systemctl restart vohive
```

OpenWrt `procd` 环境：

```sh
cp -f /opt/vohive/bin/vohive.bak /opt/vohive/bin/vohive.tmp
chmod 0755 /opt/vohive/bin/vohive.tmp
mv -f /opt/vohive/bin/vohive.tmp /opt/vohive/bin/vohive
/etc/init.d/vohive restart
```
