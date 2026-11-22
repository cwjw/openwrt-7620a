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
# 原厂 3.10.14 SDK 内核没有 common clock framework，外设时钟开机后一直开着；
# mainline 6.6 末尾会 clk_disable_unused() 把没人持有的时钟关掉。
# 用 clk_ignore_unused 把行为对齐成“一律不关时钟”。
# ---------------------------------------------------------------------------
echo "==> 对齐原厂：cmdline 加 clk_ignore_unused"
if ! grep -q 'clk_ignore_unused' "$DTS"; then
	sed -i 's|bootargs = "console=ttyS1,57600n8";|bootargs = "console=ttyS1,57600n8 clk_ignore_unused";|' "$DTS"
fi
grep -q 'clk_ignore_unused' "$DTS" || { echo '!! bootargs 未加上 clk_ignore_unused'; exit 1; }

# ---------------------------------------------------------------------------
# 看门狗 —— 174.4 秒静默复位的真正修复
#   实机坐实：MT7620 的 TMR1 是从 0 数到 TMR1MAX（复位后默认 0x1A000）的计数器，
#     0x1A000 * 65536 / 40MHz ≈ 174.42 s，与四次实测死点完全吻合。
#   主线 ping 只写 TMR1LOAD，在本硬件上不会重装计数器 → 喂狗无效 → 到点硬复位，
#     且 RSTSTAT 的 WDT_RST_CAUSE 不置位、复位前内核零日志。
#   修正：ping 改为 关使能 → 写 LOAD → 开使能 的完整重装序列。
# ---------------------------------------------------------------------------
echo "==> 注入内核补丁：rt2880_wdt 完整重装序列"
PATCH_SRC="$ROOT/patches/rt2880-wdt-fix-ping.patch"
PATCH_DST="target/linux/ramips/patches-6.6/999-rt2880-wdt-fix-ping.patch"
[ -f "$PATCH_SRC" ] || { echo "!! 找不到 $PATCH_SRC"; exit 1; }
cp -f "$PATCH_SRC" "$PATCH_DST"
# 关键行必须在，否则说明补丁写坏了（旧版用 TMRSTAT_GAP 标记，已废弃）
for k in 't & ~TMR1CTL_ENABLE' 'rt_wdt_w32(drvdata->base, TIMER_REG_TMR1CTL, t | TMR1CTL_ENABLE)'; do
	grep -qF "$k" "$PATCH_DST" || { echo "!! 补丁缺少关键行：$k"; exit 1; }
done
if grep -q 'TIMER_TMRSTAT_GAP' "$PATCH_DST"; then
	echo '!! 补丁里还残留无效的 TMRSTAT_GAP 写法（实测无效，必须删）'; exit 1
fi

echo "==> 校验：&watchdog 必须为 okay"
grep -q '&watchdog {' "$DTS" || { echo '!! DTS 中没有 &watchdog 节点'; exit 1; }
grep -A3 '&watchdog {' "$DTS" | grep -q 'okay' \
	|| { echo '!! DTS 里 &watchdog 不是 okay'; exit 1; }

# ---------------------------------------------------------------------------
# 内核配置（只能写在 target/linux/.../config-6.6，写完 openwrt/.config 会被 defconfig 丢掉）
# ---------------------------------------------------------------------------
KCFGS="target/linux/generic/config-6.6 target/linux/ramips/config-6.6 target/linux/ramips/mt7620/config-6.6"
set_kopt() {
	local opt="$1" val="$2" f
	for f in $KCFGS; do
		[ -f "$f" ] || continue
		if grep -qE "^${opt}=" "$f"; then
			sed -i -e "s|^${opt}=.*|${opt}=${val}|" "$f"
		elif grep -qx "# ${opt} is not set" "$f"; then
			sed -i -e "s|^# ${opt} is not set|${opt}=${val}|" "$f"
		fi
	done
	echo "${opt}=${val}" >> target/linux/ramips/mt7620/config-6.6
}

echo "==> 内核配置：WATCHDOG_SYSFS / GPIO_SYSFS / PSTORE"
# WATCHDOG_SYSFS：现场看 /sys/class/watchdog/watchdog0/{state,timeout,bootstatus}
# 上一版漏了这一项，导致 hb.txt 里 wd_state 全是 No such file。
set_kopt CONFIG_WATCHDOG_SYSFS y
set_kopt CONFIG_GPIO_SYSFS y
set_kopt CONFIG_PSTORE y
set_kopt CONFIG_PSTORE_RAM y
set_kopt CONFIG_PSTORE_CONSOLE y
set_kopt CONFIG_PSTORE_PMSG y

# 自检（只校验真正需要的，不再强求 DEVMEM：两轮都没生效，不拖累构建）
for opt in CONFIG_WATCHDOG_SYSFS CONFIG_PSTORE CONFIG_PSTORE_RAM CONFIG_PSTORE_CONSOLE; do
	grep -qx "${opt}=y" target/linux/ramips/mt7620/config-6.6 \
		|| { echo "!! ${opt} 未写入 mt7620 内核配置"; exit 1; }
done

# ---------------------------------------------------------------------------
# 镜像尺寸精确等于原厂 firmware 分区 0xAC0000 = 11,272,192 B
# ---------------------------------------------------------------------------
echo "==> 追加镜像定义到 ramips/mt7620（尺寸对齐原厂 0xAC0000）"
MK=target/linux/ramips/image/mt7620.mk
if ! grep -q 'Device/7620a_cpe-16m' "$MK"; then
	cat >> "$MK" <<'EOF'

# ---------------------------------------------------------------------------
# 自制板型：Sealan SL-IR4 / TX20
# MT7620A + 16MB SPI-NOR(MX25L12835F) + 64MB 可用 DDR2 + 1WAN/1LAN + 仅 2.4G
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
	# 否则尾部会写穿到原厂 jffs2 起点 0xB10000。
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
grep -q 'pad-to 11272192' "$MK" || { echo '!! 镜像尺寸未改成 0xAC0000'; exit 1; }

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
