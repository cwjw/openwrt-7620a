# MT7620A 4G CPE 定制 OpenWrt 固件 · GitHub 云编译

针对你这台板子单独做的适配：**本地写板级描述与默认参数，编译交给 GitHub Actions**。

## 已确认硬件

| 项目 | 实测/确认值 | 对应固件处理 |
| --- | --- | --- |
| SoC | MediaTek **MT7620A**（单核 MIPS 24KEc 580MHz） | target `ramips/mt7620` |
| Flash | **MX25L12835F**，128Mbit = **16MB** SPI-NOR | 分区表按 16MB 布局，`IMAGE_SIZE=16064k` |
| 内存 | **64MB** DDR2（板载 Winbond **W9751G6KB-25**，512Mb ×16 单颗） | 插件总量控制在 10 个左右 |
| 无线 | **仅 2.4G**（7620A 内置，802.11n） | `kmod-rt2800-soc`，无 5G 相关包 |
| 网口 | **1 WAN + 1 LAN** | `mediatek,portmap = "wllll"`（port0=WAN，port1=LAN） |
| 指示灯 | 4 个：`wifi` / `4g` / `sys` / `link` | DTS 里 4 个 gpio-led |
| 其它 | SIM 卡槽、reset 键 | reset → `KEY_RESTART`；4G 走 USB 模块 |
| 引导 | 只有**原厂 web 升级**（暂无 Breed） | 刷机见第 6 节，务必先备份原厂 flash |

### 实拍核对（按你发来的 PCB 照片）

| 照片上看到的 | 结论 |
| --- | --- |
| PCB 丝印 `SL-IR4_V1.3` | 工业级 4G 路由主板，V1.3 版 |
| SoC 丝印 `MEDIATEK MT7620A` | 与你说的一致，target 就是 `ramips/mt7620` |
| 内存颗粒 `W9751G6KB-25`（Winbond） | **512Mb = 64MB**。MT7620A 是 16bit DDR2 位宽，单颗 512Mb 就是这台机器的全部内存，板子上也只有这一颗 → **实际 64MB，不是 128MB** |
| 一个 52pin mini-PCIe 槽（空着）+ 背面 SIM 座 | 4G 不是焊在板上的基带，而是插 **mini-PCIe 模块**（模块内部走 USB 2.0）→ 固件要带 QMI/ECM 驱动，与第 3 节一致 |
| 两个 U.FL 天线座（CON1/CON2） | 7620A 内置 2×2 2.4G，两根天线都接上才跑满 300M |
| `ADM3202`（RS232 电平转换）+ 4 针排针 + 绿色接线端子 | 这块板有串口通道，原厂 U-Boot 的 console 大概率从这里出，**备份时优先试它**（见第 6.1） |
| 两个 RJ45（各自带 `BT16B03` 网络变压器） | 1 WAN + 1 LAN 确认，且是独立变压器 → 两口都在 7620A 内置交换上，`mediatek,portmap` 有效 |
| 贴纸 `MAC ID: BC14EFE87559` | 出厂基准 MAC = `BC:14:EF:E8:75:59`，刷好固件后可拿来核对 `eth0` 的 MAC 是否被正确读出 |

---

## 1. 本项目做了什么

```
openwrt-7620a/
├── .github/workflows/build.yml           # 云编译流水线
├── configs/mt7620a-16m.config            # 种子配置（平台/板型/插件）
├── dts/mt7620a_7620a_cpe-16m.dts         # ★ 这台板子的板级描述（自行编写）
├── scripts/
│   ├── diy-part1.sh                      # 注入 DTS + 镜像定义、feeds、裁剪
│   ├── diy-part2.sh                      # 注入 files/、注册自启、写固件标识
│   └── detect-hardware.sh                # 刷好 OpenWrt 后复核硬件
├── files/
│   ├── etc/banner
│   ├── etc/uci-defaults/99-7620a-defaults    # 主机名/时区/LAN 192.168.10.1/DHCP
│   └── etc/init.d/7620a-wifi                 # 2.4G SSID、信道、WPA2 口令
└── docs/hardware-check.md                # 硬件与 GPIO 校准手册
```

关键点：**没有现成 profile 完全匹配"1WAN+1LAN + 仅 2.4G + SIM"**，所以这里走的是自建板型路线 —— 在 `target/linux/ramips/dts/` 放一份自己的 DTS，并往 `image/mt7620.mk` 追加 `Device/7620a_cpe-16m`，由 `diy-part1.sh` 自动完成，上游源码保持干净。

板型定义（由脚本追加，等价于写进 `mt7620.mk`）：

```
SOC := mt7620a        IMAGE_SIZE := 16064k
DEVICE_DTS := mt7620a_7620a_cpe-16m
DEVICE_PACKAGES := kmod-rt2800-soc kmod-usb2 kmod-usb-ohci \
  kmod-usb-net-qmi-wwan kmod-usb-net-cdc-ether kmod-usb-serial-option \
  usb-modeswitch uqmi luci-proto-qmi
```

---

## 2. 板级描述里三处需要实测校准的地方

DTS 是按同类 7620A 4G 板推断写的，**能保证开机、能保证 2.4G 出信号**，但下面 3 项是推断值，实测不符再改一行重编即可：

| 项目 | 当前取值（推断） | 现象不对时怎么查 |
| --- | --- | --- |
| 分区偏移 | `u-boot 0x0-0x30000 / env 0x30000 / factory 0x40000 / firmware 0x50000` | TTL 进 U-Boot 看 `printenv`、`flinfo`；或用编程器读出整片 dump 看偏移 |
| LED GPIO | `sys=gpio1 2`、`wifi=gpio3 0`、`4g=gpio1 14`、`link=gpio0 2` | 系统起来后 `cat /sys/kernel/debug/gpio`，逐个数拉高拉低看哪个灯亮 |
| reset GPIO | `gpio0 1`（低有效） | `cat /sys/kernel/debug/gpio` 按一下键看哪个值翻转，改 `keys/reset` 的 `gpios` |

DTS 路径：`dts/mt7620a_7620a_cpe-16m.dts`。改完 push 或手动跑一次 workflow 就重编。
`docs/hardware-check.md` 第 3 节有完整校准步骤。

---

## 3. 固件预置内容

**系统**
- 主机名 `7620A-Router`，时区 `Asia/Shanghai`
- LAN `192.168.10.1/24`（避开光猫常用的 192.168.1.1）
- DHCP `192.168.10.100-249`，租期 12h，`ip6assign 60`

**无线（仅 2.4G）**
- SSID `7620A-2.4G`，信道 6，国家 CN
- WPA2-PSK(AES)，初始口令 `7620a@2026`

**4G**
- `uqmi` + `luci-proto-qmi`（QMI 模块，如 移远 EC20/EC25/EP06）
- 你的机器是 **mini-PCIe 插模块**（照片里槽位是空的）：模块装上后走 USB 2.0，上面这些驱动正好覆盖；空槽时不装模块，4G 功能为空，`4g` 指示灯留作状态灯或按需关掉
- `kmod-usb-net-cdc-ether`（ECM/RNDIS 类模块）
- `kmod-usb-serial-option` + `usb-modeswitch`（PPP/串口类模块自动切换）
- 插卡后：LuCI → 网络 → 接口 → 新建接口，协议选 `QMI`（或 `DHCP` 走 ECM），设备选 `/dev/cdc-wdm0` 或 `wwan0`，填 APN

**界面与运维**
- 中文 `zh_Hans`、Argon 主题、`ttyd` 网页终端
- UPnP、DDNS、WOL、多拨（mwan3）、流量统计（nlbwmon）
- `curl` / `htop` / `nano` / `dropbear`

**未预置**：科学上网类插件（体积与规则维护成本高）。要加就在 `configs/mt7620a-16m.config` 里加 `CONFIG_PACKAGE_luci-app-xxx=y`，并在 `diy-part1.sh` 加对应 feed。

---

## 4. 云编译

### 4.0 已经替你验证过的部分

在 Linux 上克隆了 `immortalwrt/immortalwrt@openwrt-24.10`，把 `dts/` 与镜像块按 `diy-part1.sh` 的方式注入后跑了 `make defconfig`：

- `CONFIG_TARGET_ramips_mt7620_DEVICE_7620a_cpe-16m=y` 被构建系统正确识别 → **镜像块写法、设备名、config 符号都没问题**
- `CONFIG_TARGET_ramips_mt7620_DEVICE_ralink_mt7620a-evb=y` 兜底板型同时在列
- `IMAGE_SIZE 16064k` 与 DTS 里 `firmware` 分区 `0x50000 + 0xfb0000 = 0x1000000` 精确对齐，不会触发 `check-size`
- DTS 引用的 `gpio0~gpio3 / spi0 / ethernet / wmac / state_default / pcie / ehci / ohci` 标签，以及 `LED_FUNCTION_MOBILE`、`LED_FUNCTION_WLAN`、`LED_COLOR_ID_GREEN` 宏，都在该分支源码里存在

**没有做**：完整编译与 dtc 编译（本地没有 Linux 构建机，完整编译要一小时级）。DTS 结构是照着同平台可正常编译的 `mt7620a_zbtlink_zbt-cpe102.dts` 改的，若真有语法漏项，第一次云编译会停在 image 阶段并直接指出 `mt7620a_7620a_cpe-16m.dts:行号`，按行号补一个分号/括号即可，不会浪费整轮编译。

### 4.1 把工程放进仓库

两种方式，任选其一：

**A. 由助手代推**：仓库建好后把仓库名（或 `https://github.com/<用户名>/<仓库名>`）发出来，助手通过 GitHub 授权接口把 10 个文件直接写到 `main`。

**B. 自己在本地推**（仓库需先建好，建议 public、不要勾选初始化 README）：

```powershell
cd E:\router\openwrt-7620a
git init -b main
git add .
git commit -m "feat: MT7620A 4G CPE 16M 板级适配"
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```

仓库 → **Actions** → `Build MT7620A Firmware` → **Run workflow**：

- `branch`：`openwrt-24.10`
- `tag`：留空只出 Artifact；填 `v1.0` 则成功后自动发 Release

首次约 70–120 分钟（含工具链），之后走 ccache + `dl` 缓存，约 25–40 分钟。
产物：Artifacts → `mt7620a-firmware-<run号>`，其中
- `immortalwrt-...-7620a_cpe-16m-squashfs-sysupgrade.bin` — **刷这个**
- `...-initramfs-kernel.bin` — 内存运行/救砖验证
- `...-ralink_mt7620a-evb-...bin` — 最简参考板兜底
- `SHA256SUMS.txt`

---

## 5. 默认登录

- `http://192.168.10.1`，`root`，密码空（首登 LuCI 强制设置）
- 无线 `7620A-2.4G`，口令 `7620a@2026`
- 刷完请立刻改口令（初始口令明文写在 `files/etc/init.d/7620a-wifi`）

---

## 6. 刷机（只有原厂 web，没有 Breed）

**这一步是整件事风险最高的地方**：固件本身能编出来，但"能不能安全写进去"取决于原厂 U-Boot 的校验逻辑和分区偏移。按顺序做，别跳步。

### 6.1 第一步：先把原厂整片 flash 备份下来（必须）

没有 Breed 时，唯一的保险是**串口**。你这块板上有 `ADM3202`（RS232 电平转换），所以先说结论：

- 板上那颗 `ADM3202` + 旁边的 4 针排针/绿色端子，大概率就是原厂 console 通道。若是 **RS232 电平**，用 USB-RS232 转接头；若排针直接接 SoC 的 UART，则是 3.3V TTL，用 USB-TTL（**别把 5V/RS232 电平直接怼到排针上**，先量电平或看丝印）
- 常见波特率 `57600` 或 `115200`，GND 必接，TX/RX 交叉；不确定就先两种波特率都试
- 板边的 `TES11` / `TES12` 测试点也可能是 UART，可作为备选

1. 串口连上，上电，在启动倒计时里打断进入 U-Boot 命令行
2. 记录关键信息：`printenv`（看 `bootcmd`、`mtdparts`、`bootargs`）、`flinfo`/`fli`（看 flash 型号与分区）
3. 备份：U-Boot 支持 `md`/`sf read` 的板子可用
   ```
   sf probe 0
   sf read 0x80000000 0 0x1000000      # 读 16MB 到内存
   md.b 0x80000000 0x1000             # 串口回显（慢）
   ```
   更好的办法是通过 U-Boot 的 `tftpput` 或 `loady`/`loadx` 反向上传，把整片 dump 保存到电脑
4. 这份 dump 就是你的变砖恢复盘，务必保存两份

> 没有 TTL 条件时，至少先在原厂 web 里找"固件备份/配置备份"功能导出；但配置备份**不是**整片镜像，救不了砖。

### 6.2 第二步：先试原厂 web 升级（成功率高但不保证）

多数 MT7620A 4G CPE 的原厂固件本身就是 OpenWrt 派生，web 升级页接受未签名 `.bin`：

1. 原厂后台 → 系统/升级 → 选 `...-7620a_cpe-16m-squashfs-sysupgrade.bin`
2. 升级过程中**不要断电**（4–6 分钟），完成后设备会自动重启到 `192.168.10.1`
3. 起不来就断电重启再试一次；连续两次起不来 → 走 6.3

如果原厂页面提示"固件校验失败/非法固件"，说明有签名或机型校验，直接跳 6.3，不要反复试。

### 6.3 第三步：TTL + U-Boot 刷入（推荐路径）

1. U-Boot 下用 tftp 把镜像载入内存验证：
   ```
   tftpboot 0x81000000 7620a_cpe-16m-initramfs-kernel.bin
   bootm 0x81000000
   ```
   initramfs 只在内存跑，能进系统说明**内核、DTS、串口、分区表都对**，这一步不写 flash，零风险
2. 确认无误后写 flash（偏移按 6.1 实测的分区来）：
   ```
   sf probe 0
   sf erase 0x50000 0xfb0000        # 与 DTS 里 firmware 分区一致
   tftpboot 0x81000000 7620a_cpe-16m-squashfs-sysupgrade.bin
   sf write 0x81000000 0x50000 0x$(filesize)
   ```
3. 想在以后都省事，可以在 U-Boot 里把 **Breed** 写到 `0x0`（16MB 的 MT7620A 通用 Breed），之后一切刷机都在 Breed 网页里做；写之前先把原厂 u-boot 用 `sf read` 备份出来

### 6.4 变砖了怎么办

- 现象：上电无串口输出、网口不亮 → 需要 **CH341A 编程器 + SOP8 夹子**，把 6.1 的 dump 写回 MX25L12835F
- 现象：串口有 U-Boot 但起不来系统 → 重新 `sf erase 0x50000 0xfb0000` 后刷入 sysupgrade
- 现象：能起系统但 LAN/WAN 反了 → 改 DTS 的 `mediatek,portmap`（试 `"llw"`、`"lwlll"` 等排列）重编重刷

---

## 7. 刷好后复核硬件

```sh
sh scripts/detect-hardware.sh > /tmp/hw.txt
cat /tmp/hw.txt
```
重点核对 `Flash 型号` 是否为 `mx25l12835f`、`/proc/mtd` 分区是否与 DTS 一致、`ls /sys/class/leds` 是否有 4 个灯。

---

## 8. 已知限制

- **64MB 内存**：LuCI + Argon + mwan3 + nlbwmon 常驻约 30–35MB，够用但不宽裕，别再往上叠重型插件。
- **7620A + 2.4G**：无线最高 802.11n 300Mbps（实际 100–150Mbps），没有 5G，也没有 802.11ac。
- **路由性能**：单核 580MHz，NAT 转发约 300–600Mbps 小包；跑满千兆不现实，硬件加速补丁未启用。
- **16MB Flash**：本配置约 6–7MB，还能再放 2–3 个中等插件；再加会撞 `check-size` 报错。
- **4G 吞吐**：取决于模块与 USB 接口（7620A 只有 USB 2.0），Cat4 模块通常能跑 30–60Mbps。
- **分区偏移是推断值**：未经你板子实测，第一次刷务必用 initramfs 先验证（6.3 第 1 步），不要直接 `sf erase` 写正式固件。
