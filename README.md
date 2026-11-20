# s5relay

把一台 VPS 搭成前置代理（sing-box：VLESS-Reality + Hysteria2，开启 BBR），用它给 SOCKS5 加速，并自动生成 Clash（Mihomo）订阅链接。

链路：本机 → VPS → SOCKS5 → 目标网站

## 安装

在服务器上以 root 运行（Debian 11+ / Ubuntu 20.04+）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<用户名>/s5relay/main/install.sh)
```

按提示输入 S5 地址、端口、账号、密码，完成后会输出订阅链接。

也可以直接带参数：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<用户名>/s5relay/main/install.sh) S5地址 端口 账号 密码
```

## 必须放行的端口

云服务器安全组：TCP 443、TCP 8443、UDP 8443

## 客户端

Clash Verge Rev / FlClash / Clash Meta for Android / Stash，导入订阅链接 → 选「S5-加速」→ 打开系统代理。

## 其他

- 导入后关闭订阅链接：`systemctl disable --now clash-sub`
- 换 S5：重新运行安装命令
- 卸载：`bash <(curl -fsSL https://raw.githubusercontent.com/<用户名>/s5relay/main/install.sh) uninstall`
