#!/usr/bin/env bash
# 编译前第一步：注入板级 DTS + 镜像定义 + 方案B 内核补丁，刷新 feeds，做少量裁剪
# 约定：由仓库根目录执行，源码目录为 ./openwrt
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/openwrt"

echo "==> 注入板级 DTS（Sealan SL-IR4 / TX20）"
cp -f "$ROOT/dts/mt7620a_7620a_cpe-16m.dts" target/linux/ramips/dts/

# ---------------------------------------------------------------------------
# 方案B：修正 rt2880_wdt 的喂狗逻辑（ping 时脉冲 TMRSTAT.TMR1RST）
# 放到 ramips 的 patches-6.6，编号 999 排在其他 ramips 补丁之后，避免上下文冲突。
# ---------------------------------------------------------------------------
echo "==> 注入方案B 内核补丁（rt2880_wdt fix-ping）"
PATCH_SRC="$ROOT/patches/rt2880-wdt-fix-ping.patch"
PATCH_DST="target/linux/ramips/patches-6.6/999-rt2880-wdt-fix-ping.patch"
[ -f "$PATCH_SRC" ] || { echo "!! 找不到 $PATCH_SRC"; exit 1; }
cp -f "$PATCH_SRC" "$PATCH_DST"
# 自检：补丁必须真的动到了两处关键位置，否则等于没打
for k in 'TIMER_TMRSTAT_GAP' 'rt_wdt_w32(drvdata->stat, TIMER_REG_TMRSTAT, TMRSTAT_TMR1RST)'; do
  grep -qF "$k" "$PATCH_DST" || { echo "!! 补丁缺少关键行：$k"; exit 1; }
done

# 自检：看门狗节点必须是 okay（方案B 依赖驱动真的 probe）
grep -q '&watchdog {' target/linux/ramips/dts/mt7620a_7620a_cpe-16m.dts || { echo "!! DTS 中没有 &watchdog 节点"; exit 1; }
if grep -A3 '&watchdog {' target/linux/ramips/dts/mt7620a_7620a_cpe-16m.dts | grep -q 'disabled'; then
  echo "!! DTS 仍把 watchdog 置为 disabled，方案B 不会生效"; exit 1
fi

echo "==> 追加镜像定义到 ramips/mt7620"
MK=target/linux/ramips/image/mt7620.mk
if ! grep -q 'Device/7620a_cpe-16m' "$MK"; then
  cat >> "$MK" <<'EOF'

# ---------------------------------------------------------------------------
# 自制板型：Sealan SL-IR4 / TX20
# MT7620A + 16MB SPI-NOR(MX25L12835F) + 128MB DDR2(W9751G6KB-25) + 1WAN/1LAN + 仅 2.4G
# 固件区与原厂一致：0x50000 起，长 0xAC0000，U-Boot web 升级按该整段处理
# ---------------------------------------------------------------------------
define Device/7620a_cpe-16m
	SOC := mt7620a
	DEVICE_DTS := mt7620a_7620a_cpe-16m
	DEVICE_VENDOR := Sealan
	DEVICE_MODEL := SL-IR4
	DEVICE_VARIANT := TX20
	IMAGE_SIZE := 11264k
	IMAGES += factory.bin
	# 固件区长度 0xAC0000 = 11272192，镜像正好填满该段；
	# 之前 pad 到 11534336(0xB00000) 会尾部越界 0x40000，落到 0xB10000 之后的无分区区。
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

# 追加后自检：板型定义必须能被源码树解析到（否则 defconfig 里这个符号会消失）
grep -q 'define Device/7620a_cpe-16m' "$MK" || { echo "!! mt7620.mk 追加失败"; exit 1; }
grep -q 'TARGET_DEVICES += 7620a_cpe-16m' "$MK" || { echo "!! TARGET_DEVICES 未登记"; exit 1; }

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
