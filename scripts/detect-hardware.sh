#!/bin/sh
# 在原厂固件 / 已刷的 OpenWrt / Padavan 上运行，采集硬件信息，用于选定 .bin
# 用法：ssh 到设备后执行，或把输出贴回给我
#   sh detect-hardware.sh > /tmp/hw.txt
# 没有 ssh 的环境（Breed / 原厂 web），见 docs/hardware-check.md 的手工确认步骤

echo "===== 1. 板型标识 ====="
cat /tmp/sysinfo/board_name 2>/dev/null
cat /tmp/sysinfo/model 2>/dev/null
[ -f /etc/openwrt_release ] && cat /etc/openwrt_release

echo "===== 2. SoC / 内存 ====="
grep -E "system type|cpu model|Processor" /proc/cpuinfo 2>/dev/null
grep -E "MemTotal" /proc/meminfo 2>/dev/null

echo "===== 3. Flash 分区（看总容量与布局）====="
cat /proc/mtd 2>/dev/null

echo "===== 4. 内核识别到的 Flash 芯片 ====="
dmesg 2>/dev/null | grep -iE "spi|flash|mtd|nand|nor" | head -40

echo "===== 5. 无线芯片 ====="
dmesg 2>/dev/null | grep -iE "mt76|7612|7610|7620|rt28|ath" | head -40
ls /sys/class/net 2>/dev/null

echo "===== 6. 有线口 / 交换芯片 ====="
dmesg 2>/dev/null | grep -iE "switch|rtl8|mt7530|gsw" | head -20
swconfig list 2>/dev/null

echo "===== 7. 指示灯与按键 GPIO ====="
ls /sys/class/leds 2>/dev/null
cat /sys/kernel/debug/gpio 2>/dev/null | head -40

echo "===== 8. USB ====="
lsusb 2>/dev/null

echo "===== 采集结束 ====="
