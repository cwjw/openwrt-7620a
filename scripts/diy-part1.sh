#!/usr/bin/env bash
# 编译前第一步：注入板级 DTS + 镜像定义，刷新 feeds，做少量裁剪
# 约定：由仓库根目录执行，源码目录为 ./openwrt
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/openwrt"

echo "==> 注入板级 DTS（Sealan SL-IR4 / TX20）"
cp -f "$ROOT/dts/mt7620a_7620a_cpe-16m.dts" target/linux/ramips/dts/

echo "==> 追加镜像定义到 ramips/mt7620"
MK=target/linux/ramips/image/mt7620.mk
if ! grep -q 'Device/7620a_cpe-16m' "$MK"; then
  cat >> "$MK" <<'EOF'

# ---------------------------------------------------------------------------
# 自制板型：Sealan SL-IR4 / TX20
# MT7620A + 16MB SPI-NOR(MX25L12835F) + 64MB DDR2 + 1WAN/1LAN + 仅 2.4G
# 固件区与原厂一致：0x50000 起，长 0xAC0000（11MB），U-Boot web 升级按整段覆盖
# ---------------------------------------------------------------------------
define Device/7620a_cpe-16m
	SOC := mt7620a
	DEVICE_DTS := mt7620a_7620a_cpe-16m
	DEVICE_VENDOR := Sealan
	DEVICE_MODEL := SL-IR4
	DEVICE_VARIANT := TX20
	IMAGE_SIZE := 11264k
	IMAGES += factory.bin
	# 原厂 U-Boot 的 web 升级会校验镜像尺寸，这里 pad 到 0xAC0000(11534336) 整段
	IMAGE/factory.bin := append-kernel | append-rootfs | pad-rootfs | \
		pad-to 11534336 | check-size
	DEVICE_PACKAGES := kmod-rt2800-soc kmod-usb2 kmod-usb-ohci \
		kmod-usb-net-qmi-wwan kmod-usb-net-cdc-ether kmod-usb-net-cdc-mbim \
		kmod-usb-serial-option usb-modeswitch uqmi luci-proto-qmi
	SUPPORTED_DEVICES += generic,7620a-cpe-16m
endef
TARGET_DEVICES += 7620a_cpe-16m
EOF
fi

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
