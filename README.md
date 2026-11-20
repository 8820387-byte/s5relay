# s5relay

把一台 VPS 搭成前置代理（sing-box：VLESS-Reality + Hysteria2），给 SOCKS5 加速，自带网页后台管理 S5，自动生成 Clash（Mihomo）订阅。

链路：本机 → VPS → SOCKS5 → 目标网站

## 两种模式

**伪装模式（推荐，需要宝塔里有一个开了 HTTPS 的网站）**

- Reality 伪装成你自己的网站：任何人探测代理端口，看到的都是你真实的网站和正规证书
- Hysteria2 用网站的正规证书，被探测时也返回你的网站；宝塔续期证书后每天自动同步
- 后台和订阅挂在 `https://你的域名/隐藏路径/`，正规证书，不额外开端口
- 不改网站本身的 443 监听，宝塔照常管理网站；卸载后网站配置自动还原

**普通模式（不填域名）**

- Reality 伪装成 www.microsoft.com，后台用自签名证书单独开端口

## 功能

- 网页后台：添加 / 批量导入 / 测试 / 删除 S5，改完订阅自动更新
- 每个 S5 生成「直连」和「加速（经 VPS 中转）」两个节点
- 后台测试可看到 S5 的延迟、出口 IP、账号密码是否正确

## 安全设计

- 前置默认 Reality；后台需要密码，错 5 次锁 15 分钟；后台地址带随机路径
- 订阅链接带 48 位随机密钥，可在后台一键换新
- 国外域名不交给国内 DNS 解析，防 DNS 泄露
- fail2ban 防 SSH 暴力破解；开启 BBR

## 安装

伪装模式先在宝塔准备好：网站 → 设置 → SSL → Let's Encrypt 申请证书，TLS 版本勾上 TLSv1.3。

在服务器上以 root 运行（Debian 11+ / Ubuntu 20.04+）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/8820387-byte/s5relay/main/install.sh)
```

提示「宝塔里 WordPress 网站的域名」时填域名即为伪装模式。装完会显示后台地址、后台密码、订阅链接。

云服务器安全组和宝塔「安全」页放行脚本最后显示的端口（伪装模式一般是 TCP 2443、UDP 8443）。

## 常用命令

```bash
# 重置后台密码
bash <(curl -fsSL https://raw.githubusercontent.com/8820387-byte/s5relay/main/install.sh) reset-pass
# 关闭网页后台和订阅（S5 列表保留，重新安装即可再打开）
bash <(curl -fsSL https://raw.githubusercontent.com/8820387-byte/s5relay/main/install.sh) web-off
# 卸载（网站不受影响）
bash <(curl -fsSL https://raw.githubusercontent.com/8820387-byte/s5relay/main/install.sh) uninstall
```

重新运行安装命令会换一套新密钥和新订阅链接，S5 列表、后台密码、后台地址保留不变。
