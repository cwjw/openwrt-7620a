#!/usr/bin/env bash
# 编译前第一步：注入板级 DTS + 镜像定义 + 内核看门狗补丁，刷新 feeds，做少量裁剪
# 约定：由仓库根目录执行，源码目录为 ./openwrt
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/openwrt"

echo "==> 注入板级 DTS（Sealan SL-IR4 / TX20）"
cp -f "$ROOT/dts/mt7620a_7620a_cpe-16m.dts" target/linux/ramips/dts/
DTS=target/linux/ramips/dts/mt7620a_7620a_cpe-16m.dts

# ---------------------------------------------------------------------------
# 差异修正 1：时钟门控。
# 原厂 3.10.14 SDK 内核里根本没有 common clock framework（对 vmlinux 字符串扫描
# “clk_”“Disabling unused clocks”“clk_” 均为 0 命中），所有外设时钟开机后一直
# 保持开启；而 mainline 6.6 在启动末尾会执行 clk_disable_unused()，把没人显式
# 持有的时钟全部关掉（我们的启动日志第 100 行就是 “clk: Disabling unused clocks”）。
# 这是二者在硬件电源/时钟域上的头号差异，先用 clk_ignore_unused 把行为对齐成
# “一律不关时钟”，与原厂保持一致。
# ---------------------------------------------------------------------------
echo "==> 对齐原厂：cmdline 加 clk_ignore_unused（禁止内核关闭未使用时钟）"
if ! grep -q 'clk_ignore_unused' "$DTS"; then
	sed -i 's|bootargs = "console=ttyS1,57600n8";|bootargs = "console=ttyS1,57600n8 clk_ignore_unused";|' "$DTS"
fi
grep -q 'clk_ignore_unused' "$DTS" || { echo '!! bootargs 未加上 clk_ignore_unused'; exit 1; }
grep -q 'bootargs = "console=ttyS1,57600n8 clk_ignore_unused";' "$DTS" || { echo '!! bootargs 写法与预期不符'; exit 1; }

# ---------------------------------------------------------------------------
# 方案B（备选）：修正 rt2880_wdt 的喂狗逻辑
# 放到 ramips 的 patches-6.6，编号 999 排在其他 ramips 补丁之后，避免上下文冲突。
# 当前 DTS 已把 &watchdog 置为 disabled（方案C），驱动不会被 probe，本补丁只会被
# 编译进内核但不会执行；保留它便于回头做“真喂狗”的永久修法。
# ---------------------------------------------------------------------------
echo "==> 注入方案B 内核补丁（rt2880_wdt fix-ping，目前不生效，仅保留待用）"
PATCH_SRC="$ROOT/patches/rt2880-wdt-fix-ping.patch"
PATCH_DST="target/linux/ramips/patches-6.6/999-rt2880-wdt-fix-ping.patch"
[ -f "$PATCH_SRC" ] || { echo "!! 找不到 $PATCH_SRC"; exit 1; }
cp -f "$PATCH_SRC" "$PATCH_DST"
for k in 'TIMER_TMRSTAT_GAP' 'rt_wdt_stat_w32(drvdata, TMRSTAT_TMR1RST)'; do
	grep -qF "$k" "$PATCH_DST" || { echo "!! 补丁缺少关键行：$k"; exit 1; }
done

# ---------------------------------------------------------------------------
# 方案C：看门狗彻底不武装（已实测：无 /dev/watchdog、dmesg 中 rt2880 0 命中）
# ---------------------------------------------------------------------------
echo "==> 校验方案C：&watchdog 必须为 disabled"
grep -q '&watchdog {' "$DTS" || { echo '!! DTS 中没有 &watchdog 节点'; exit 1; }
if ! grep -A3 '&watchdog {' "$DTS" | grep -q 'disabled'; then
	echo '!! DTS 仍把 watchdog 置为开启，方案C 要求 disabled'; exit 1
fi

# ---------------------------------------------------------------------------
# 内核调试开关：CONFIG_WATCHDOG_SYSFS（排障预留）、CONFIG_GPIO_SYSFS（现场试灯）
# ---------------------------------------------------------------------------
echo "==> 打开 CONFIG_WATCHDOG_SYSFS / CONFIG_GPIO_SYSFS"
KCFG=target/linux/ramips/mt7620/config-6.6
for opt in CONFIG_WATCHDOG_SYSFS CONFIG_GPIO_SYSFS; do
	if grep -q "$opt" "$KCFG"; then
		sed -i "s/.*$opt.*/$opt=y/" "$KCFG"
	else
		echo "$opt=y" >> "$KCFG"
	fi
	grep -qx "$opt=y" "$KCFG" || { echo "!! $opt 未写入"; exit 1; }
done

# ---------------------------------------------------------------------------
# 差异修正 2：镜像尺寸精确等于原厂 firmware 分区。
# 原厂镜像 tx20-stock-firmware.bin = 11,272,192 B = 0xAC0000，与分区
# firmware 0x50000 +0xAC0000 完全相等，不多一个字节。
# 之前用 pad-to 11534336(0xB00000) 会让镜像尾部越过分区边界 0x40000，
# 在 U-Boot web 升级时会写进原厂 jffs2 的起点 0xB10000——这是与原厂的
# 真实差异，本版收回到 0xAC0000。
# ---------------------------------------------------------------------------
echo "==> 追加镜像定义到 ramips/mt7620（尺寸对齐原厂 0xAC0000）"
MK=target/linux/ramips/image/mt7620.mk
if ! grep -q 'Device/7620a_cpe-16m' "$MK"; then
	cat >> "$MK" <<'EOF'

# ---------------------------------------------------------------------------
# 自制板型：Sealan SL-IR4 / TX20
# MT7620A + 16MB SPI-NOR(MX25L12835F) + 64MB 可用 DDR2 + 1WAN/1LAN + 仅 2.4G
# 固件区与原厂完全一致：0x50000 起，长 0xAC0000，镜像也正好 0xAC0000
# ---------------------------------------------------------------------------
define Device/7620a_cpe-16m
	SOC := mt7620a
	DEVICE_DTS := mt7620a_7620a_cpe-16m
	DEVICE_VENDOR := Sealan
	DEVICE_MODEL := SL-IR4
	DEVICE_VARIANT := TX20
	IMAGE_SIZE := 11008k
	IMAGES += factory.bin
	# 原厂镜像长度就是 11272192(0xAC0000)，与原厂分区等长；不要改大，
	# 否则尾部会写穿到原厂 jffs2 起点 0xB10000（这是与原厂的真实差异）。
	IMAGE/factory.bin := append-kernel | append-rootfs | pad-rootfs | \
		pad-to 11272192 | check-size
	DEVICE_PACKAGES := kmod-rt2800-soc kmod-usb2 kmod-usb-ohci \
		kmod-usb-net-qmi-wwan kmod-usb-net-cdc-ether kmod-usb-net-cdc-mbim \
		kmod-usb-serial-option usb-modeswitch uqmi luci-proto-qmi
	SUPPORTED_DEVICES += generic,7620a-cpe-16m
endef
TARGET_DEVICES += 7620a_cpe-16m
EOF
fi
grep -q 'define Device/7620a_cpe-16m' "$MK" || { echo '!! mt7620.mk 追加失败'; exit 1; }
grep -q 'TARGET_DEVICES += 7620a_cpe-16m' "$MK" || { echo '!! TARGET_DEVICES 未登记'; exit 1; }
grep -q 'pad-to 11272192' "$MK" || { echo '!! 镜潠尺寸未改成 0xAC0000'; exit 1; }

echo "==> feeds update"
./scripts/feeds update -a

echo "==> feeds install"
./scripts/feeds install -a

echo "==> 常用裁剪"
for opt in \
  CONFIG_PACKAGE_luci-app-example \
  CONFIG_PACKAGE_luci-app-openvpn-server
do
  printf '# %s is not set\n' "$opt" >> .config
done

echo "==> 第一步完成"
