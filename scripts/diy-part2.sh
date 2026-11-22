#!/usr/bin/env bash
# 编译前第二步：把仓库里的 files/ overlay 注入源码，做最终配置收尾
# 注意：本步骤在 make defconfig 之后运行，**不要在这里改 .config**——
# 否则构建途中会触发一次交互式 kconfig 重整，CI 里无 stdin 就会卡到 job 超时。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/openwrt"

echo "==> 校验内核配置落在 target/linux/*/config-6.6（openwrt/.config 会丢弃内核符号）"
KCFG_LIST="target/linux/generic/config-6.6 target/linux/ramips/config-6.6 target/linux/ramips/mt7620/config-6.6"
for opt in CONFIG_WATCHDOG_SYSFS CONFIG_PSTORE CONFIG_PSTORE_RAM CONFIG_PSTORE_CONSOLE; do
	if ! grep -h -qx "${opt}=y" $KCFG_LIST; then
		echo "::error::${opt} 没有写进任何内核配置文件"
		exit 1
	fi
done
echo "==> 内核配置校验通过"

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

test "$(basename files/lib/preinit/82_7620a_overlay_guard)" \> "80_mount_root" || exit 1

echo "==> 校验 rc.local 带验收标记"
grep -qF 'CHECKPOINT t165' files/etc/rc.local || { echo "::error::rc.local 缺少 t165 检查点"; exit 1; }
grep -qF 'ALIVE@200' files/etc/rc.local || { echo "::error::rc.local 缺少 t200 alive 标记"; exit 1; }
grep -qF 'wdog0_state' files/etc/rc.local || { echo "::error::rc.local 缺少看门狗状态取证"; exit 1; }
chmod +x files/etc/rc.local

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

echo "==> 写入固件标识"
echo "MT7620A custom build / $(date '+%Y-%m-%d %H:%M') / branch $(git -C . rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)" \
  > files/etc/mt7620a-build-info

echo "==> 自定义内容注入完成"
