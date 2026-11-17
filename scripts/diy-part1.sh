#!/usr/bin/env bash
# 编译前第一步：注入板级 DTS + 镜像定义，刷新 feeds，做少量裁剪
# 约定：由仓库根目录执行，源码目录为 ./openwrt
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/openwrt"

echo "==> 注入板级 DTS（7620A 4G CPE / 16MB）"
cp -f "$ROOT/dts/mt7620a_7620a_cpe-16m.dts" target/linux/ramips/dts/

echo "==> 追加镜像定义到 ramips/mt7620"
MK=target/linux/ramips/image/mt7620.mk
if ! grep -q 'Device/7620a_cpe-16m' "$MK"; then
  cat >> "$MK" <<'EOF'

# ---------------------------------------------------------------------------
# 自制板型：MT7620A + 16MB SPI-NOR( MX25L12835F ) + 128MB DDR2
# 1 WAN + 1 LAN，仅 2.4G，SIM 卡槽（外挂 USB 4G 模块）
# ---------------------------------------------------------------------------
define Device/7620a_cpe-16m
	SOC := mt7620a
	DEVICE_DTS := mt7620a_7620a_cpe-16m
	DEVICE_VENDOR := Generic
	DEVICE_MODEL := 7620A 4G CPE
	DEVICE_VARIANT := 16M
	IMAGE_SIZE := 16064k
	DEVICE_PACKAGES := kmod-rt2800-soc kmod-usb2 kmod-usb-ohci \
		kmod-usb-net-qmi-wwan kmod-usb-net-cdc-ether \
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
