#!/usr/bin/env bash
# 编译前第二步：把仓库里的 files/ overlay 注入源码，做最终配置收尾
# 注意：本步骤在 make defconfig 之后运行，**不要在这里改 .config**——
# 否则构建途中会触发一次交互式 kconfig 重整，CI 里无 stdin 就会卡到 job 超时
# （Plan E 就是这样卡满 6 小时被 cancel 的）。需要改 kconfig 请放 diy-part1 或种子配置。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/openwrt"

echo "==> 校验内核仪表真的进了 .config"
# 实测教训：CONFIG_DEVMEM 只写在 target/linux/ramips/mt7620/config-6.6 时并没生效，
# 固件里 devmem 命令存在、/dev/mem 却不存在。这里在 defconfig 之后硬校验，
# 不满足就直接停，不浪费 40 分钟编译出一个“白刷”的固件。
for opt in CONFIG_DEVMEM CONFIG_PSTORE CONFIG_PSTORE_RAM CONFIG_PSTORE_CONSOLE; do
	if ! grep -qx "${opt}=y" .config; then
		echo "::error::${opt} 未在 .config 生效（内核仪表不可用，继续编译=白刷）"
		grep -nE "${opt}" .config || true
		exit 1
	fi
	grep -qx "${opt}=y" .config || exit 1
done
grep -q 'CONFIG_IO_STRICT_DEVMEM=y' .config && { echo "::error::IO_STRICT_DEVMEM 仍开着，devmem 会被拦"; exit 1; }
echo "==> DEVMEM / PSTORE 校验通过"

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

echo "==> 校验 rc.local 带寄存器取证与验收标记"
grep -qF '/root/hb.txt' files/etc/rc.local || { echo "::error::rc.local 缺少寄存器取证"; exit 1; }
grep -qF 'CHECKPOINT t165' files/etc/rc.local || { echo "::error::rc.local 缺少 t165 检查点"; exit 1; }
grep -qF 'ALIVE@200' files/etc/rc.local || { echo "::error::rc.local 缺少 t200 alive 标记"; exit 1; }
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
