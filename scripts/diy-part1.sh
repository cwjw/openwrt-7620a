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
# 原厂 3.10.14 SDK 内核里根本没有 common clock framework，所有外设时钟开机后
# 一直保持开启；而 mainline 6.6 启动末尾会 clk_disable_unused() 把没人持有的
# 时钟全关掉。先用 clk_ignore_unused 把行为对齐成“一律不关时钟”。
# ---------------------------------------------------------------------------
echo "==> 对齐原厂：cmdline 加 clk_ignore_unused"
if ! grep -q 'clk_ignore_unused' "$DTS"; then
	sed -i 's|bootargs = "console=ttyS1,57600n8";|bootargs = "console=ttyS1,57600n8 clk_ignore_unused";|' "$DTS"
fi
grep -q 'clk_ignore_unused' "$DTS" || { echo '!! bootargs 未加上 clk_ignore_unused'; exit 1; }

# ---------------------------------------------------------------------------
# 看门狗：照抄原厂“武装 + 每5秒喂狗”
#   ＿主补丁修正 rt2880_wdt 的喂狗逻辑
#   ＿DTS 的 &watchdog 必须 okay
# ---------------------------------------------------------------------------
echo "==> 注入内核补丁：rt2880_wdt fix-ping"
PATCH_SRC="$ROOT/patches/rt2880-wdt-fix-ping.patch"
PATCH_DST="target/linux/ramips/patches-6.6/999-rt2880-wdt-fix-ping.patch"
[ -f "$PATCH_SRC" ] || { echo "!! 找不到 $PATCH_SRC"; exit 1; }
cp -f "$PATCH_SRC" "$PATCH_DST"
for k in 'TIMER_TMRSTAT_GAP' 'rt_wdt_stat_w32(drvdata, TMRSTAT_TMR1RST)'; do
	grep -qF "$k" "$PATCH_DST" || { echo "!! 补丁缺少关键行：$k"; exit 1; }
done

echo "==> 校验：&watchdog 必须为 okay"
grep -q '&watchdog {' "$DTS" || { echo '!! DTS 中没有 &watchdog 节点'; exit 1; }
grep -A3 '&watchdog {' "$DTS" | grep -q 'okay' \
	|| { echo '!! DTS 里 &watchdog 不是 okay'; exit 1; }

# ---------------------------------------------------------------------------
# 内核仪表（关键修：必须写在“内核配置文件”里，openwrt/.config 里的内核符号会被 defconfig 丢掉）
#
# 实测教训（2026-11-21）：把 CONFIG_DEVMEM 写进 configs/mt7620a-16m.config（即 openwrt/.config）后，
#   make defconfig 直接把它清掉，固件里 devmem 命令在、/dev/mem 却不存在——
#   几轮“取数”都是空仪表。
# 所以这里对 generic / ramips / ramips-mt7620 三个内核配置文件全部置为肯定值，
# 并把 STRICT_DEVMEM 系列统一改成否定行（直接写文件，不靠 defconfig 猜）。
# ---- 正确做法：这三层文件按 generic → target → subtarget 合并，后者覆盖前者 ----------
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
	# 最后写进 mt7620（优先级最高），确保肯定是最后一条
echo "${opt}=${val}" >> target/linux/ramips/mt7620/config-6.6
}
unset_kopt() {
	local opt="$1" f
	for f in $KCFGS; do
		[ -f "$f" ] || continue
		sed -i -e "s|^${opt}=.*|# ${opt} is not set|" "$f" 2>/dev/null || true
	done
echo "# ${opt} is not set" >> target/linux/ramips/mt7620/config-6.6
}

echo "==> 内核仪表：DEVMEM / PSTORE / RAMOOPS"
set_kopt CONFIG_DEVMEM y
unset_kopt CONFIG_STRICT_DEVMEM
unset_kopt CONFIG_IO_STRICT_DEVMEM
set_kopt CONFIG_PSTORE y
set_kopt CONFIG_PSTORE_RAM y
set_kopt CONFIG_PSTORE_CONSOLE y
set_kopt CONFIG_PSTORE_PMSG y

# 自检：肯定行必须存在，且不得残留未置位的 STRICT_DEVMEM
for opt in CONFIG_DEVMEM CONFIG_PSTORE CONFIG_PSTORE_RAM CONFIG_PSTORE_CONSOLE; do
	grep -qx "${opt}=y" target/linux/ramips/mt7620/config-6.6 \
		|| { echo "!! ${opt} 未写入 mt7620 内核配置"; exit 1; }
done
for bad in CONFIG_STRICT_DEVMEM CONFIG_IO_STRICT_DEVMEM; do
	grep -qx "${bad}=y" target/linux/ramips/mt7620/config-6.6 \
		&& { echo "!! ${bad} 仍为 y"; exit 1; }
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
