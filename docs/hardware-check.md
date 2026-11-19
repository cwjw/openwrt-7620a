# 硬件复核与板级参数说明（参数已由原厂 dump 实证）

本文件记录的全部板级参数，来自你提供的原厂整片备份 `D:\router\tx20-boot.bin`（16,777,216 字节）的逆向结果，
**不再是推断值**。逆向脚本在 `E:\router\pcb\`（`analyze*.py`、`decompress_blocks.py`、`extract_sqfs.py`）。

## 0. 已确认参数一览

| 项目 | 值 | 证据位置 |
| --- | --- | --- |
| SoC / 内存 | MT7620A + 64MB DDR2（W9751G6KB-25） | 实拍 + DTS |
| Flash | 16MB SPI-NOR（MX25L12835F） | 备份文件恰好 16MB |
| 型号 | 板丝印 `SL-IR4_V1.3`；`/etc/board` → `Model:SL-IR4`；Web 名 `TX20` | 原厂 rootfs |
| U-Boot | `SeaOS boot (Dec 19 2016 - 10:41:57)`，`Board:SL-IR1`，web 升级页 `/index.html` | `0x0` 段 |
| 串口 | **ttyS1（UART0 / uart@500）+ 57600 8N1** | 原厂 cmdline `console=ttyS1,57600n8` |
| 分区 | u-boot `0x0/0x30000`、env `0x30000/0x10000`、factory `0x40000/0x10000`、firmware `0x50000/0xAC0000`、原厂 jffs2 `0xB10000/0x4F0000` | 逐段解析 + squashfs 边界 `0xB0E004` |
| MAC | `BC:14:EF:E8:75:44`（factory `0x40004`）；贴纸 `BC14EFE87559` | factory 段 |
| 网口 | **port0 = LAN，port4 = WAN** | `/etc/status/eth_led.sh`：`lan_port=0`、`wan_port=4` |
| 指示灯 | sys=GPIO32、link=GPIO30、wifi=GPIO31、4g=GPIO33 | `/etc/init.d/led` `status_led=32`、`eth_led.sh` `wan_lan_led_num=30`、vpn 脚本 `sealed 33 on/off` |
| reset 键 | **GPIO35 低有效** | 原厂 `btnd reset 35` |

对应 DTS：`dts/mt7620a_7620a_cpe-16m.dts`。

---

## 1. 串口复核（刷机当天确认）

- 串口在 ADM3202 那一路，**RS232 电平**；USB-RS232 转接头，或确认是 TTL 再用 CH340。
- 参数 **57600 8N1**（不是 115200，这是原厂 U-Boot 的 `baudrate=57600`）。
- 上电 5 秒内按任意键打断，进 U-Boot 命令行：

```
printenv              # bootdelay=5, bootcmd=tftp, ipaddr=10.10.10.123, serverip=10.10.10.3
sf probe 0
sf read 0x80000000 0x50000 0x100      # 读 uImage 头，0x64 年应为 27 05 19 56
md.b 0x80000000 0x40
```

`sf read` 有效即可证明「分区偏移 + 串口 + flash 型号」三项全对，可以进入刷写。

---

## 2. 刷好后复核

```sh
cat /proc/mtd          # u-boot / u-boot-env / factory / firmware / rootfs / rootfs_data
free -m                # Total ≈ 60
ls /sys/class/leds     # link / wifi / sys / 4g
ip -br a               # br-lan 192.168.10.1；插 WAN 后 eth0.2 获取地址
cat /sys/class/net/eth0/address   # BC:14:EF:E8:75:44
iwinfo                 # 2.4G 射频存在，国家 CN，信道 6
dmesg | grep -i "mt7620\|spi-nor" # flash 型号与 switch 初始化
```

---

## 3. 灯/键仍不对时怎么校准

```sh
cat /sys/kernel/debug/gpio
gpioinfo
```

`<&gpio1 N>` 的绝对编号是 `24 + N`（gpio1 管 24–39）：
`<&gpio1 6>` = 30、`<&gpio1 7>` = 31、`<&gpio1 8>` = 32、`<&gpio1 9>` = 33、`<&gpio1 11>` = 35。

若 `wifi` 与 `4g` 两颗灯位置对调（唯一可能的错法，两者是相邻 GPIO），改 DTS：

```dts
led-wifi { gpios = <&gpio1 7 GPIO_ACTIVE_LOW>; ... };   // 与下面互换
led-4g   { gpios = <&gpio1 9 GPIO_ACTIVE_LOW>; ... };
```

按键无反应先看 `evtest` 是否有 KEY_RESTART；无事件则把 `keys/reset` 的 `gpios` 换成 `gpioinfo` 里空闲的那根线。

---

## 4. 有线口

DTS 为 `mediatek,portmap = "llllw"`（port0 = LAN、port4 = WAN，与原厂 `lan_port=0 / wan_port=4` 一致）。
MT7620 的 OpenWrt 用 DSA，不再有 `swconfig`，看口状态用：

```sh
ip -br link
cat /sys/class/net/eth0.2/operstate
dmesg | grep -i "link up"
```

如果实测两口反了，把 `"llllw"` 改成 `"wllll"` 重编（其余排列对本板无意义，只有这两个口被引出）。

---

## 5. 4G 模块

```sh
lsusb
dmesg | tail -40
ls /dev/ttyUSB* /dev/cdc-wdm* 2>/dev/null
```

| 现象 | 说明 | 处理 |
| --- | --- | --- |
| `lsusb` 看不到模块 | mini-PCIe 槽的供电/复位可能由 GPIO 控制（原厂 `wwan_gpio_num=60`，相关代码被注释） | 先确认模块本身是否上电；必要时在 DTS 里加 `gpio-hog` 拉 GPIO60 |
| `/dev/cdc-wdm0` | QMI 模块（EC20/EC25/EP06） | LuCI 新建接口 → 协议 QMI → APN |
| `wwan0` | ECM/RNDIS 模块 | 协议 DHCP，绑 `wwan0` |
| `/dev/ttyUSB0-3` | PPP/AT 类 | `luci-proto-3g` 或手动 `pppd` |

模块停在下载模式（`05c6:9008`）时由 `usb-modeswitch` 自动切换（已编进固件）。
