#!/usr/bin/env bash
# 编译前第二步：把仓库里的 files/ overlay 注入源码，做最终配置收尾
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/openwrt"

echo "==> 注入 files/ 默认配置"
rm -rf files
mkdir -p files
cp -a "$ROOT/files/." files/
find files -type f -name "*.sh" -exec chmod +x {} \;
chmod +x files/etc/uci-defaults/* files/etc/init.d/* files/etc/board.d/* \
	files/lib/preinit/* 2>/dev/null || true

echo "==> 校验 board.d 网络脚本已注入（上游 mt7620 的 02_network 无默认分支，必须自带）"
ls -l files/etc/board.d/
grep -q 'ucidef_add_switch' files/etc/board.d/02_network_sl-ir4

echo "==> 校验首启 overlay 守护脚本已注入"
ls -l files/lib/preinit/
grep -q 'boot_hook_add preinit_main' files/lib/preinit/82_7620a_overlay_guard

# 862：preinit 钩子按文件名排序，82 必须排在 80_mount_root 之后
test "$(basename files/lib/preinit/82_7620a_overlay_guard)" \> "80_mount_root" || exit 1

echo "==> 注册开机自启（7620a-wifi）"
mkdir -p files/etc/rc.d
ln -sf ../init.d/7620a-wifi files/etc/rc.d/S957620a-wifi

echo "==> 设置默认 LuCI 主题为 argon（若已编译该主题）"
if grep -q 'CONFIG_PACKAGE_luci-theme-argon=y' .config; then
  mkdir -p files/etc/uci-defaults
  cat > files/etc/uci-defaults/98-theme-argon <<'EOFT'
#!/bin/sh
uci -q set luci.main.mediaurlbase='/luci-static/argon' || true
uci -q commit luci || true
exit 0
EOFT
  chmod +x files/etc/uci-defaults/98-theme-argon
fi

# ---------------------------------------------------------------------------
# busybox devmem：排障期用来从用户空间直读 SoC 寄存器（/dev/mem + mmap，零额外包）
# 注意两个 kconfig 事实（已在源码树核实）：
#   1. 符号名是 CONFIG_BUSYBOX_CONFIG_DEVMEM（不是 CONFIG_DEVMEM）；
#   2. 它只在 CONFIG_BUSYBOX_CUSTOM=y 时可见（busybox Makefile 里
#      BUSYBOX_SYM=$(if $(CONFIG_BUSYBOX_CUSTOM),CONFIG,DEFAULT)）。
#   打开 CUSTOM 只会把其余 applet 拉回各自的 BUSYBOX_DEFAULT_* 默认值，
#   与当前镜像行为一致，不会增减其他命令。
# ---------------------------------------------------------------------------
echo "==> 打开 busybox devmem（读 SoC 寄存器用）"
sed -i '/^# CONFIG_BUSYBOX_CONFIG_DEVMEM is not set/d;/^CONFIG_BUSYBOX_CONFIG_DEVMEM=/d' .config
grep -q '^CONFIG_BUSYBOX_CUSTOM=y' .config || echo 'CONFIG_BUSYBOX_CUSTOM=y' >> .config
echo 'CONFIG_BUSYBOX_CONFIG_DEVMEM=y' >> .config
grep -q '^CONFIG_BUSYBOX_CUSTOM=y' .config || { echo '!! BUSYBOX_CUSTOM 未写入'; exit 1; }
grep -q '^CONFIG_BUSYBOX_CONFIG_DEVMEM=y' .config || { echo '!! DEVMEM 未写入'; exit 1; }
# 让 kconfig 真正收敛一次（不会改动已显式设置的项），并回读确认没被默认值冲掉
yes '' | ./scripts/config --file .config -e BUSYBOX_CUSTOM 2>/dev/null || true
grep -q '^CONFIG_BUSYBOX_CONFIG_DEVMEM=y' .config || { echo '!! DEVMEM 被 kconfig 否决'; exit 1; }

echo "==> 写入固件标识"
echo "MT7620A custom build / $(date '+%Y-%m-%d %H:%M') / branch $(git -C . rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)" \
  > files/etc/mt7620a-build-info

echo "==> 自定义内容注入完成"
