# 硬件复核与板级参数校准

本机已确认：

- SoC **MT7620A**，单核 580MHz
- Flash **MX25L12835F**（128Mbit = 16MB SPI-NOR）
- 内存 **128MB** DDR2
- 无线 **仅 2.4G**（7620A 内置）
- 网口 **1 WAN + 1 LAN**
- 指示灯 **wifi / 4g / sys / link** 共 4 个，另有一个 reset 键、一个 SIM 卡槽

固件里的板级描述在 `dts/mt7620a_7620a_cpe-16m.dts`，其中 3 项是**推断值**，需要实测校准：

| # | 项目 | 当前推断值 | 校准手段 |
| --- | --- | --- | --- |
| 1 | 分区偏移 | u-boot `0x0-0x30000`、env `0x30000-0x40000`、factory `0x40000-0x50000`、firmware `0x50000-0x1000000` | TTL 进 U-Boot：`printenv` / `flinfo`；或编程器整片 dump 后看实际布局 |
| 2 | LED GPIO | sys `gpio1 2`、wifi `gpio3 0`、4g `gpio1 14`、link `gpio0 2` | 见下文第 3 节 |
| 3 | reset GPIO | `gpio0 1`，低有效 | 见下文第 3 节 |

---

## 1. 用 TTL 确认分区（最可靠）

接线：3.3V USB-TTL，GND—GND，TX—RX，RX—TX，先不要接 3.3V（板子自己供电）。
串口参数：`57600 8N1`（部分板子 `115200`），打开终端后给板子上电。

U-Boot 启动倒计时里按任意键打断，然后：

```
printenv                 # 重点看 bootcmd / bootargs / mtdparts
flinfo                   # 或 fli，看 Flash 型号与分区列表
```

- 若 `bootargs` 里出现 `mtdparts=...:0x30000@0x0(uboot),...0x10000@0x40000(factory),0xfb0000@0x50000(firmware)` → 与我们的 DTS 一致，可放心写
- 若 firmware 起始偏移不是 `0x50000`（例如 `0x30000`，那是洪电 H8922 那类布局），**必须**把 DTS 里 `partition@50000` 的 `reg` 改成实测值，否则刷完找不到 rootfs

整片备份（有 `sf` 命令时）：

```
sf probe 0
sf read 0x80000000 0 0x1000000
tftpput 0x80000000 0x1000000 backup-stock-16m.bin     # 板子网口要通
```

---

## 2. 系统起来后复核（刷成功之后）

```sh
sh scripts/detect-hardware.sh > /tmp/hw.txt
```

核对：

| 检查项 | 期望 |
| --- | --- |
| `dmesg \| grep -i spi` | 出现 `mx25l12835f` 或 `jedec,spi-nor` + 16MB |
| `cat /proc/mtd` | `mtd0 u-boot`、`mtd1 u-boot-env`、`mtd2 factory`、`mtd3 firmware` |
| `ls /sys/class/leds` | 4 个灯（名字对应 DTS 的 function） |
| `ip link` | 2 个以太口（`eth0`/`eth1` 或 br-lan 里 1 个口） |
| `lsusb` | 4G 模块（插卡上电后出现） |

---

## 3. GPIO 校准（灯不对、reset 不灵时）

系统起来后：

```sh
cat /sys/kernel/debug/gpio          # 列出所有已申请的 GPIO 及用途、当前电平
ls /sys/class/leds                  # 每个灯一个目录
```

**判断某个 GPIO 是不是某个灯**：

```sh
# 把编号 N 的 GPIO 拉高/拉低，观察哪个灯变化
gpioset gpiochip0 N=0      # 或 gpioset gpiochip0 N=1
```

MT7620 的 GPIO 编号分 5 组（gpio0~gpio4），DTS 里的 `<&gpioX Y>` 对应 `gpiochip` 中的绝对编号
`X*32 + Y`（例如 `gpio1 14` → 46）。用 `gpioinfo` 可以看到 chip 名称与每根线的编号/占用情况。

**判断 reset 键**：

```sh
gpioinfo | grep -i key
# 或者按一下 reset，看 dmesg 有无 input 事件
evtest                              # 选 gpio-keys 设备，按键看是否出 KEY_RESTART
```

如果按键无反应，说明 `gpios = <&gpio0 1 ...>` 的编号不对：把它换成 `gpioinfo` 里标记为 `reset` 或未被占用的那根线，重编即可。

修改位置都在 `dts/mt7620a_7620a_cpe-16m.dts`：

```dts
leds { led-sys { gpios = <&gpio1 2 GPIO_ACTIVE_LOW>; ... }; }   // 改这里
keys { reset   { gpios = <&gpio0 1 GPIO_ACTIVE_LOW>; ... }; }   // 或这里
```

改完 → push → 重跑 workflow → 只刷 `sysupgrade.bin`（同板型可保留配置）。

---

## 4. 有线口映射（LAN/WAN 反了怎么办）

DTS 当前是 `mediatek,portmap = "wllll"`：port0 = WAN，port1..4 = LAN。
本机只引出 2 个口，若实测 WAN/LAN 位置相反，可依次尝试：

```dts
mediatek,portmap = "lwlll";   // port0=LAN, port1=WAN
mediatek,portmap = "llwll";
```

判断依据：插网线后 `swconfig dev switch0 show` 看哪个 port 有 link，或 `dmesg | grep -i link`。

---

## 5. 4G 模块

插卡上电后：

```sh
lsusb
dmesg | tail -40
ls /dev/ttyUSB* /dev/cdc-wdm* 2>/dev/null
```

| 现象 | 说明 | 处理 |
| --- | --- | --- |
| `lsusb` 看不到模块 | 模块没上电 / mini-PCIe 供电 GPIO 没拉 | 查 DTS 是否需要 4G 电源使能 GPIO（本 DTS 未加，可后补） |
| 出现 `/dev/ttyUSB0-3` | PPP/AT 类模块 | 用 `comgt`/`pppd` 或 `luci-proto-3g` |
| 出现 `/dev/cdc-wdm0` | QMI 模块（EC20/EC25/EP06） | LuCI 新建接口，协议 QMI，APN 按运营商填 |
| 出现 `wwan0`（usb0） | ECM/RNDIS 模块 | 新建接口，协议 DHCP，绑定 `wwan0` |

如果 `lsusb` 只看到模块但设备号一直在变（`05c6:9008` 之类），是模块停在下载模式，需要 `usb-modeswitch`（已装）或手动发 AT 切模式。
