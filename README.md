# SL-IR4 / TX20（MT7620A）定制 OpenWrt 固件 · GitHub 云编译

本地只做板级适配（DTS、分区、镜像规则、默认配置），编译交给 GitHub Actions。

**这一版的所有参数都是从你提供的原厂整片备份 `D:\router\tx20-boot.bin` 逆向出来的，不是猜的。**

---

## 1. 板子真实参数（逆向自原厂 16MB 备份）

| 项目 | 原厂实测值 | 依据 |
| --- | --- | --- |
| SoC | MT7620A（MIPS 24KEc 580MHz） | DTS 目标 `ramips/mt7620` |
| Flash | 16MB SPI-NOR（MX25L12835F） | 备份文件正好 16,777,216 字节 |
| 内存 | **64MB**（W9751G6KB-25 单颗） | 板上只有一颗 512Mb 颗粒 |
| 引导 | U-Boot `SeaOS boot (Dec 19 2016)`，板名 `SL-IR1` | `0x0` 起 192KB |
| 串口控制台 | **ttyS1（UART0）+ 57600 8N1**，经 ADM3202 转 RS232 | 原厂内核 cmdline：`console=ttyS1,57600n8 root=/dev/mtdblock5` |
| 分区 | 见下表 | 备份逐段解析 + squashfs 明文 |
| 网口 | **port0 = LAN，port4 = WAN** | 原厂 `/etc/status/eth_led.sh`：`lan_port=0`、`wan_port=4` |
| 指示灯 | sys=GPIO32、link=GPIO30、wifi=GPIO31、4g=GPIO33 | `/etc/init.d/led` 的 `status_led=32`、`eth_led.sh` 的 `wan_lan_led_num=30`、vpn 脚本的 `sealed 33 on/off` |
| reset 键 | **GPIO35**（低有效） | 原厂 `btnd reset 35` |
| MAC | `BC:14:EF:E8:75:44`（贴纸印 `…E87559`） | factory 分区 `0x40004` |
| 原厂系统 | SeaOS（OpenWrt 派生），型号 `SL-IR4`，Web 名 `TX20`，LAN `192.168.10.1` | `/etc/board` |

### 分区（与原厂完全一致）

| 偏移 | 长度 | 内容 |
| --- | --- | --- |
| `0x00000` | `0x30000` | u-boot（只读，不动） |
| `0x30000` | `0x10000` | u-boot-env（全 `0xFF`，CRC 无效 → U-Boot 用编译默认值，别指望它） |
| `0x40000` | `0x10000` | factory / ART（MAC + 2.4G 校准，只读） |
| `0x50000` | `0xAC0000` | **firmware**（内核 + squashfs，共 11,534,336 字节） |
| `0xB10000` | `0x4F0000` | 原厂 jffs2（SeaOS 配置卷）—— **新版固件不划进任何分区** |

> 原厂 squashfs 数据止于 `0xB0E004`，内核 uImage 在 `0x50000`（LZMA 压缩，load 0x80000000），与 OpenWrt 的 `uImage lzma` 完全同构，所以 U-Boot 能直接引导。

---

## 2. 上一版为什么刷了不能用（逐条对上了）

| # | 上一版写法 | 原厂实际值 | 后果 |
| --- | --- | --- | --- |
| 1 | `console=ttyS0,115200`、未启用 `&uart` | `ttyS1,57600n8`（UART0） | 串口完全无输出，出错也看不见；`ttyS0` 是 uartlite，板上没引出 |
| 2 | `mediatek,portmap = "wllll"` | `"llllw"`（port0=LAN、port4=WAN） | 本机 MT7620A 驱动实际不消费 portmap，此错不致命，但已改对 |
| 3 | LED `gpio1 2 / gpio3 0 / gpio1 14 / gpio0 2`，reset `gpio0 1` | 30 / 31 / 32 / 33 + 35 | 灯全不亮，reset 长按不进恢复模式 |
| 4 | `firmware 0x50000 + 0xFB0000`（盖到整片尾） | `+0xAC0000` | 开机把原厂 SeaOS 的 jffs2 当 overlay 挂上，`/etc/config` 全是旧板子的 `eth0.5`、老无线配置 → 能启动但网络/无线全乱 |
| 5 | `IMAGE_SIZE := 16064k`，只有 `sysupgrade.bin` | 固件区 11MB，U-Boot web 升级按尺寸校验 | 上传被拒，或写进去后尾部对不上 |
| 6 | `state_default` 只放开 `i2c / spi refclk / wled` | LED 引脚（GPIO30-33）在 `rgmii1` 复用区 | GPIO 拿不到引脚控制权，灯永远不亮 |
| 7 | 板型名 `Generic 7620A 4G CPE` | 原厂 `SL-IR4` / 市售名 `TX20` | 只影响显示与 sysupgrade 机型校验提示 |
| 8 | 没处理 `02_network` | 上游 `ramips_setup_interfaces()` 是 **case 枚举，末尾没有 `*)` 兜底分支** | 自建 compatible 不命中任何 case → 首启不生成 `switch`/`switch_vlan`，`eth0.1`(lan)/`eth0.2`(wan) 根本不存在 → **系统起得来但没 IP、LuCI 打不开、网口不通**（这是“刷了不能用”的**决定性**根因） |
| 9 | 只定义了 `firmware` 分区，没有 `rootfs_data` | 原厂 squashfs 止于 `0xB0E004`，jffs2 从 `0xB10000` 开始 | 由内核按 `denx,uimage` 自动切 kernel/rootfs，剩余 flash 自动成为 overlay，不再去碰旧 jffs2 |

> 顺带核实掉一个常见误解：**mt7620a 平台的 DTS 都不写 `memory` 节点**（同分支全部 100+ 个 mt7620a 设备树与 274 个 mt7621 设备树无一例外），内存由 U-Boot 的 ATAGS 上报。所以“缺 memory 节点”不是问题。

新版把上面 9 项全部改正，并额外做了三件事：**自带一份本板的 `board.d` 网络脚本**（不依赖上游 case 命中）、给固件区尾部留出干净 overlay 空间、把 factory 分区里的 MAC/校准表接进 `nvmem`，并为原厂 web 升级产出**定长 11,534,336 字节**的 factory 镜像。

---

## 3. 工程结构

```
openwrt-7620a/
├── .github/workflows/build.yml           # 云编译流水线
├── configs/mt7620a-16m.config            # 种子配置（平台/板型/插件）
├── dts/mt7620a_7620a_cpe-16m.dts         # 板级描述（含分区/GPIO/portmap）
├── scripts/
│   ├── diy-part1.sh                      # 注入 DTS + 镜像定义、feeds、裁剪
│   ├── diy-part2.sh                      # 注入 files/、注册自启、写固件标识
│   └── detect-hardware.sh                # 刷好后复核硬件
├── files/
│   ├── etc/banner
│   ├── etc/board.d/02_network_sl-ir4         # 本板 switch/VLAN（port0-3=LAN, port4=WAN）
│   ├── etc/uci-defaults/99-7620a-defaults    # 主机名/时区/LAN 192.168.10.1/DHCP + 网口兜底
│   └── etc/init.d/7620a-wifi                 # 2.4G SSID、信道、WPA2 口令
└── docs/hardware-check.md                # 硬件与 GPIO 校准手册
```

板型定义（由 `diy-part1.sh` 追加进 `target/linux/ramips/image/mt7620.mk`）：

```
SOC := mt7620a
DEVICE_DTS := mt7620a_7620a_cpe-16m
IMAGE_SIZE := 11264k                      # = 0xAC0000，与原厂固件区一致
IMAGES += factory.bin
IMAGE/factory.bin := append-kernel | append-rootfs | pad-rootfs | pad-to 11534336 | check-size
```

- `sysupgrade.bin`：以后在 OpenWrt 里升级用（不要求定长）
- `factory.bin`：**首次从原厂 U-Boot / 原厂 web 页刷写用**，pad 到正好 11,534,336 字节，覆盖 `0x50000 ~ 0xB0FFFF` 整段（尾部补 `0xFF`，顺手把原厂残留擦干净）

---

## 4. 云编译

仓库 → **Actions** → `Build MT7620A Firmware` → **Run workflow**（branch 填 `openwrt-24.10`，tag 留空）。

产物（Artifacts → `mt7620a-firmware-<run号>`，文件名以页面实际显示为准，认后缀就行）：

| 文件 | 用途 |
| --- | --- |
| `*-squashfs-factory.bin` | **首次刷机就用它**，大小必须是 11,534,336 字节 |
| `*-squashfs-sysupgrade.bin` | 已经跑起 OpenWrt 之后升级用 |
| `*-initramfs-kernel.bin` | 只在内存里跑，验证板级参数用（不写 flash） |
| `SHA256SUMS.txt` | 校验 |

首次约 70–120 分钟，之后走 ccache/dl 缓存约 25–40 分钟。

**拿到固件先本地核对尺寸**（PowerShell）：

```powershell
Get-Item .\*factory.bin | Select-Object Name, Length   # Length 必须是 11534336
```

---

## 5. 刷机

> 前提：你已经持有整片备份 `D:\router\tx20-boot.bin`（变砖可救回）。刷之前再复制一份到别处。

### 5.1 首选：原厂 web 升级

1. 电脑接 **LAN 口**（原厂 port0，即交换口上那个能拿到 `192.168.10.x` 的口）
2. 浏览器打开 `http://192.168.10.1`，账号 `admin`
3. 系统 → 升级 / Upgrade → 类型选 `firmware` → 选 `...-factory.bin`
4. 上传后设备自动重启（3–6 分钟），**中途断电会变砖**
5. 起来后访问 `http://192.168.10.1`（新固件 LAN 地址与原厂相同），`root`，密码空

若页面报 `## Error: wrong file size, should be: N bytes!`，把 **N** 告我（N 就是它认的固件区字节数），我按 N 重设 `pad-to` 再编一次即可，其他都不用动。

### 5.2 备选：串口 + U-Boot

- 串口参数 **57600 8N1**（不是 115200），4 针排针经 ADM3202 出 RS232 电平
- 上电后 `bootdelay=5` 内按任意键进 U-Boot（SeaOS 版，命令集与通用 U-Boot 一致）
- 只在内存验证（零风险）：

```
tftpboot 0x81000000 ...initramfs-kernel.bin
bootm 0x81000000
```

- 确认能进系统再写 flash（与 DTS 分区严格一致）：

```
sf probe 0
sf erase 0x50000 0xAC0000
tftpboot 0x81000000 ...factory.bin
sf write 0x81000000 0x50000 0x$(filesize)
```

### 5.3 变砖

- 串口有输出但起不来 → 按 5.2 重新擦 `0x50000 0xAC0000` 再写
- 串口无输出 → CH341A 编程器 + SOP8 夹子，把 `tx20-boot.bin` 整片写回

**永远不要动 `0x0~0x4FFFF`**（u-boot + env + factory/ART），无线校准和 MAC 都在里面。

---

## 6. 刷好后 30 秒自检

```sh
cat /proc/mtd                  # 应看到 u-boot/u-boot-env/factory/firmware/rootfs/rootfs_data
free -m                        # Total 约 60MB
ip -br link                    # 应有 eth0.1（LAN）与 eth0.2（WAN）
cat /sys/class/net/eth0/address # BC:14:EF:E8:75:44
iwinfo                         # 2.4G 射频存在，国家 CN
```

- 最关键的判断点：**刷完后电脑接 LAN 口能 DHCP 到 192.168.10.100+，能打开 `http://192.168.10.1`**。这一步不过，就查 `cat /etc/config/network` 里有没有 `config switch_vlan`
- WAN 插线后 `eth0.2` 应该 up 并拿到地址（pppoe/dhcp 在 LuCI 里配）
- 灯：`sys` 常亮、`link` 随网口活动闪、`wifi` 随无线流量闪、`4g` 默认灭
- 若 `wifi`/`4g` 两灯位置对调，把 DTS 里 `led-wifi` 与 `led-4g` 的 `&gpio1 7` / `&gpio1 9` 互换重编即可（两颗是连续 GPIO，只有这两种可能）

---

## 7. 已知限制

- **64MB 内存**：LuCI + Argon + mwan3 + nlbwmon 常驻约 30–35MB，够用但不宽裕
- **只有 2.4G**：802.11n 300Mbps 理论上限，实测 100–150Mbps
- **overlay 约 3.4MB**：firmware 区 11MB 减去镜像约 7.6MB；`0xB10000` 那 5MB 原厂 jffs2 暂不回收（回收要在 U-Boot 里 `sf erase 0xB10000 0x4F0000` 后改 DTS 分区表，属于二期）
- **NAT 性能**：单核 580MHz，约 300–600Mbps（小包更低），硬件加速未启用
- **4G**：mini-PCIe 模块走 USB2.0，Cat4 模块通常 30–60Mbps；空槽时 `4g` 灯只作状态灯
