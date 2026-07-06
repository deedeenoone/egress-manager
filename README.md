# egress-manager

**轻量级出网策略路由管理工具** — 为Linux上任意服务按实例绑定不同的出站IP

![License](https://img.shields.io/badge/license-MIT-green.svg)
![Shell Script](https://img.shields.io/badge/shell-bash-green.svg)
![Compatibility](https://img.shields.io/badge/compatibility-Linux%204.15%2B-blue.svg)

## 🎯 功能

在单VPS多IP或多协议混跑的场景下，为每个服务实例配置独立的出网IP和路由策略，无需修改应用层代码。

### 核心特性

- **按服务粒度绑定出站IP** — 不同入站端口可走不同的出站IP
- **完全透明** — 无需修改应用配置，仅通过systemd hook自动应用
- **连接稳定** — 通过connmark保护已建立连接，不会被错误改道
- **细粒度隔离** — 用cgroup v2进行进程隔离，精确匹配目标服务
- **故障可见** — 所有操作显式报错，避免沉默失效
- **轻量高效** — 纯bash实现，无外部依赖，启停速度快

## 🔧 工作原理

三层技术栈实现出网策略路由：

```
Layer 1: 配置管理 (config + fwmark)
         ↓
         每服务独立的配置文件 + 路由表号分配
         
Layer 2: 流量标记 (cgroup v2 + iptables mangle)
         ↓
         通过cgroup v2捕获该service的进程
         对NEW连接打fwmark标记
         
Layer 3: 路由 & SNAT (ip rule + iptables nat)
         ↓
         fwmark → 自定义路由表
         自定义路由表 → 指定网卡/网关
         POSTROUTING SNAT → 改源IP
```

### 为什么需要SNAT?

仅改路由表不能改变已绑定socket的源地址。在VPS多IP的场景，**公网身份由源IP决定**，所以必须通过SNAT把出网流量的源地址改成目标网段的本地IP。

## 📋 系统要求

- **OS**: Debian 11+、Ubuntu 20.04+ 或其他systemd支持的Linux发行版
- **Kernel**: 4.15+ (cgroup v2, conntrack支持)
- **工具**: `iptables`、`iproute2`、`systemd`
- **权限**: root用户

```bash
# 检查cgroup v2支持
grep cgroup2 /proc/filesystems

# 检查必要工具
which iptables ip systemctl
```

## 🚀 快速开始

### 快速安装（一键命令）

直接复制到VPS执行，会自动下载脚本并初始化系统：

**使用 curl：**
```bash
sudo bash -c 'curl -fsSL https://raw.githubusercontent.com/deedeenoone/egress-manager/main/egress-manager.sh -o /usr/local/bin/egress-manager && chmod +x /usr/local/bin/egress-manager && egress-manager init'
```

**使用 wget：**
```bash
sudo bash -c 'wget -qO- https://raw.githubusercontent.com/deedeenoone/egress-manager/main/egress-manager.sh > /usr/local/bin/egress-manager && chmod +x /usr/local/bin/egress-manager && egress-manager init'
```

执行后即可开始使用。

### 1. 初始化

也可以手动初始化（如果上面的命令不可用）：

```bash
sudo bash egress-manager.sh init
```

这会创建：
- 配置目录: `/etc/egress-manager/`
- Helper脚本: `/usr/local/bin/egress-helper.sh`

### 2. 配置服务的出网策略

```bash
# 为 snell-443 配置出网IP为 10.0.0.5
sudo bash egress-manager.sh set snell-443 eth0 10.0.0.1 10.0.0.0/24 10.0.0.5

# 为 snell-8443 配置出网IP为 10.0.0.6
sudo bash egress-manager.sh set snell-8443 eth0 10.0.0.1 10.0.0.0/24 10.0.0.6
```

参数说明：
- `snell-443` — systemd服务名
- `eth0` — 出网网卡
- `10.0.0.1` — 出网网关IP
- `10.0.0.0/24` — 出网网段
- `10.0.0.5` — 目标出站IP（多IP场景必须显式指定）

### 3. 重启服务

```bash
systemctl restart snell-443 snell-8443
```

systemd会自动调用egress-helper应用出网策略。

### 4. 验证

```bash
# 查看所有已配置的出网策略
sudo bash egress-manager.sh list

# 查看特定服务配置
sudo bash egress-manager.sh show snell-443

# 查看活跃的路由表
sudo bash egress-manager.sh routes

# 查看策略路由规则
sudo bash egress-manager.sh rules
```

## 💡 使用场景

### 场景1: VPS多IP，按入站端口使用不同出站IP

```bash
# VPS网卡eth0分配了多个IP: 10.0.0.5, 10.0.0.6, 10.0.0.7

# 443端口流量从10.0.0.5出
sudo bash egress-manager.sh set snell-443 eth0 10.0.0.1 10.0.0.0/24 10.0.0.5

# 8443端口流量从10.0.0.6出
sudo bash egress-manager.sh set snell-8443 eth0 10.0.0.1 10.0.0.0/24 10.0.0.6

# 9443端口流量从10.0.0.7出
sudo bash egress-manager.sh set snell-9443 eth0 10.0.0.1 10.0.0.0/24 10.0.0.7

systemctl restart snell-443 snell-8443 snell-9443
```

### 场景2: 多协议多网卡，隔离出网

```bash
# Snell通过eth0的10.0.0.5出
sudo bash egress-manager.sh set snell-443 eth0 10.0.0.1 10.0.0.0/24 10.0.0.5

# SS通过eth1的192.168.1.5出
sudo bash egress-manager.sh set ss-8388 eth1 192.168.1.1 192.168.1.0/24 192.168.1.5

systemctl restart snell-443 ss-8388
```

### 场景3: 清除某服务的出网策略

```bash
# 恢复snell-443到系统默认路由
sudo bash egress-manager.sh remove snell-443

systemctl restart snell-443
```

## 📖 完整命令参考

```bash
# 配置服务出网策略
# 用法: set <service> <iface> <gateway> <subnet> [srcip]
sudo bash egress-manager.sh set snell-443 eth0 10.0.0.1 10.0.0.0/24 10.0.0.5

# 删除配置（回到默认路由）
sudo bash egress-manager.sh remove snell-443

# 显示指定服务的配置详情
sudo bash egress-manager.sh show snell-443

# 列表显示所有已配置的服务
sudo bash egress-manager.sh list

# 显示当前活跃的自定义路由表
sudo bash egress-manager.sh routes

# 显示当前活跃的策略路由规则
sudo bash egress-manager.sh rules

# 初始化系统（仅需运行一次）
sudo bash egress-manager.sh init

# 显示帮助
sudo bash egress-manager.sh help

# 显示版本
sudo bash egress-manager.sh version
```

## 🔍 配置文件位置

```
/etc/egress-manager/
├── snell-443.conf      # snell-443 服务的出网配置
├── snell-8443.conf
├── ss-8388.conf
└── ...

/usr/local/bin/egress-helper.sh    # 核心helper脚本（自动生成）

/etc/systemd/system/snell-443.service.d/
└── egress.conf         # systemd drop-in（自动生成）
```

### 配置文件格式

```bash
$ cat /etc/egress-manager/snell-443.conf

service=snell-443
iface=eth0
gateway=10.0.0.1
subnet=10.0.0.0/24
srcip=10.0.0.5         # 关键: 多IP场景必须显式指定
table=700              # 自动分配的路由表号
mark=700               # firewall mark
```

## 🛠️ 故障排查

### 1. 验证cgroup v2

```bash
# 应该看到 cgroup2 列表
grep cgroup2 /proc/filesystems

# 检查systemd使用的cgroup版本
systemctl --version | grep systemd

# systemd 230+ 默认使用cgroup v2
```

### 2. 检查规则是否生效

```bash
# 检查指定服务的mangle规则
sudo iptables -t mangle -L OUTPUT -nv | grep snell-443

# 检查NAT规则
sudo iptables -t nat -L POSTROUTING -nv | grep mark

# 检查策略路由规则
sudo ip rule show

# 检查自定义路由表
sudo ip route show table 700
```

### 3. 查看systemd日志

```bash
# 查看服务启动日志
sudo journalctl -u snell-443.service -f

# 看是否有egress错误
sudo journalctl -u snell-443.service | grep egress
```

### 4. 测试连接

```bash
# 查看该服务的所有连接及其源IP
sudo ss -tupn | grep snell-443

# 从VPS内测试出站IP (需要工具: curl)
# 该命令应该使用指定的出站IP
sudo -u snell bash -c 'curl https://ifconfig.me'
```

### 常见问题

**Q: 为什么出站IP没有改变?**

A: 检查以下几点：
1. 是否指定了 `srcip` 参数？多IP场景必须显式指定
2. iptables SNAT规则是否存在？运行 `sudo iptables -t nat -L POSTROUTING -nv`
3. 是否正确重启了服务？需要 `systemctl restart`
4. 该IP是否真的分配到了网卡？运行 `ip addr show eth0`

**Q: 服务启动失败?**

A: 查看systemd日志：
```bash
sudo journalctl -u snell-443.service | tail -50
```
常见原因：
- cgroup v2不支持
- iptables命令不可用
- 路由表号耗尽（配置超过200个服务）

**Q: 性能影响有多大?**

A: 几乎没有。这个方案在内核层面工作：
- cgroup标记是内核native操作，性能成本 < 1%
- 路由表查询是O(1)操作
- SNAT转换发生在netfilter框架内，高效

## 🏗️ 技术细节

### connmark与连接隔离

关键机制是对NEW和ESTABLISHED连接分别处理：

```bash
# NEW连接: 打标 + 改源IP
iptables -A OUTPUT -m cgroup --path ... -m conntrack --ctstate NEW -j MARK --set-mark 700
iptables -A OUTPUT -m cgroup --path ... -m conntrack --ctstate NEW -j CONNMARK --save-mark

# ESTABLISHED回包: 恢复旧标（使用主表，不改源IP）
iptables -A OUTPUT -m cgroup --path ... -m conntrack --ctstate ESTABLISHED,RELATED -j CONNMARK --restore-mark
```

这样：
- 入站连接（客户端→服务器）默认使用主表处理，不会被改道
- 服务器主动发起的出站连接才会被改道到自定义表

### 反向路径过滤

启用非对称路由支持以处理多网卡场景：

```bash
sysctl -w net.ipv4.conf.all.rp_filter=2
sysctl -w net.ipv4.conf.eth0.rp_filter=2
```

这允许从A网卡出的回包从B网卡进（反向路径过滤模式2 = 宽松模式）。

## 📝 与proxy-manager的关系

本项目是从 [lingchenfs1/proxymanager](https://github.com/lingchenfs1/proxymanager) 中**完全独立抽离**的出网策略路由系统。

- ✅ 保留了proxy-manager的全部egress核心逻辑
- ✅ 移除了对特定协议（Snell、SS等）的依赖
- ✅ 可以作为通用工具为任意systemd服务配置出网策略
- ✅ 完整的文档和错误处理

## 📄 许可证

MIT License — 自由使用、修改和分发

## 🙏 致谢

- 感谢 [lingchenfs1/proxymanager](https://github.com/lingchenfs1/proxymanager) 提供的原始实现思路
- 感谢Linux内核的cgroup v2、conntrack等特性支持

## 💬 反馈与贡献

欢迎提交Issue或PR！

---

**Happy routing! 🚀**
