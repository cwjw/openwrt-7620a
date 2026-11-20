# 方案B：看门狗复位修复说明

> 适用于倒序重读：先看“五、刷完怎么看”即可验证，其余为备查。

## 一、改动清单

| 文件 | 作用 |
|---|---|
| `patches/rt2880-wdt-fix-ping.patch` | 内核补丁：重写 `rt288x_wdt_ping`（三套重装机制）+ 单独映射 TMRSTAT + probe 诊断打印 |
| `dts/mt7620a_7620a_cpe-16m.dts` | `&watchdog` 由 `disabled` 改回 `okay`（不再靠禁用躲问题） |
| `scripts/diy-part1.sh` | 把补丁拷到 `target/linux/ramips/patches-6.6/999-*`、自检 DTS 与补丁关键行；`factory.bin` 的 `pad-to` 从 11534336 改为 11272192 |

镜像尺寸变化：`factory.bin` 由 11,534,336 B 变为 **11,272,192 B**（正好等于固件区 `0x50000+0xAC0000`），不再尾部越界 256KB。`sysupgrade.bin` 不变。

## 二、为什么会 1~2 分钟复位（拆解）

`drivers/watchdog/rt2880_wdt.c` 的 `probe` 里 `max_timeout = 0xffff / (clk/65536)`，40MHz 时 ≈ **107 秒**，所以“1~2 分钟”本质上就是这个超时值。复位发生的前提只有一个：**计数器处于倒计时状态，且没人成功喂狗**。

计数器进入倒计时有两条路径：

1. **用户态武装**：`procd` 开机后 open `/dev/watchdog` → 驱动 `start()` 置 `TMR1CTL_ENABLE`；
2. **Bootloader 遗留**：U-Boot 启动前已置位，内核 `CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y` 接管。

无论哪条，只要 `ping` 实际无法重装计数器，到点必复位。而“能否重装”本身在 Ralink 定时器块上有三套可能实现，且**两套开源实现给出的证据互相矛盾**：

| 参考实现 | 喂狗方式 |
|---|---|
| MTK SDK 的 `ramips_wdt.c`（Barrier Breaker 时代）| 只写 `TMR1LOAD` |
| 同族 `mt7621_wdt.c`（mainline） | 只写 `TMRSTAT` 的重装位（`BIT(9)`） |
| 本 SoC 的 `rt2880_wdt.c`（mainline） | 只写 `TMR1LOAD`，且头文件里 `TMRSTAT_TMR1RST BIT(5)` **定义了但从未使用** |

`rt2880_wdt.c` 里那个“定义了却没人用”的常量，正是上游漏写重装动作的痕迹。

## 三、补丁做了什么

`rt288x_wdt_ping` 从“只写 TMR1LOAD”改为三条同时执行，任何一个生效就不会复位：

1. 写 `TMR1LOAD = timeout * freq`；
2. 写 `TMRSTAT` 的 `TMR1RST`（`BIT(5)`）重装位；
3. 重写一遍带 `EDNABLE` 的 `TMR1CTL`（覆盖“写 ENABLE 即重装”的设计）。

配套两点：

- **映射**：`TMRSTAT` 在 `0x100`，而 watchdog 节点是 `0x120 + 0x10`，窗口够不到。补丁用 `devm_ioremap(res->start - 0x20, 4)` 补一个只读/写 4 字节的附属映射（不用 `ioremap_resource`，避开与 `timer@100` 的资源重叠冲突）。
- **诊断**：probe 时打印 `TMR1CTL`（含 `running_at_probe`）、`TMRSTAT`、`SYSC_RSTSTAT`（含 `last_reset_watchdog`）。这三行是判断复位源的关键证据。

保留 `REG` 不变、不动 `mt7620a.dtsi`，避免影响其它 mt7620 板型。

## 四、为什么不选“方案A（直接 disabled）”

`disabled` 只能切断“驱动自己武装”这一条路径；如果计数器是 U-Boot 遗留武装的，禁用驱动等于**把唯一的喂狗人赶走**，照样 107 秒复位（这与现场“unbind 后仍复位”的观测一致）。方案B 对两条路径同时成立，且保留硬件看门狗保护。

## 五、刷完怎么看（按顺序）

```sh
# 1. 驱动必须真的 probe 成功，且看得到三行诊断
dmesg | grep -i -A1 "rt2880_wdt"
```

预期看到类似：

```
rt2880_wdt 10000120.watchdog: TMR1CTL=00000080 (running_at_probe=0) TMRSTAT=00000000
rt2880_wdt 10000120.watchdog: SYSC_RSTSTAT=00000000 (last_reset_watchdog=0)
rt2880_wdt 10000120.watchdog: Initialized
```

判读规则：

| 观测 | 含义 |
|---|---|
| `running_at_probe=1` | 计数器在上电时已被 U-Boot 武装（方案A 对此无效，方案B 有效） |
| `last_reset_watchdog=1` | 上一次复位确实是看门狗干的（根因坐实） |
| `last_reset_watchdog=0` | 上一次复位**不是**看门狗 → 需另外查电源/时钟/DDR，别在看门狗上打转 |
| 完全没有 `rt2880_wdt` 行 | 驱动未 probe（DTS 没生效或编译没打上补丁） |

```sh
# 2. 计数器确实被喂住（uptime 必须能过 107s 的两倍窗口）
uptime; sleep 240; uptime
```

- 能过 **15 分钟**：修复成立。
- 又在 **107 秒附近**归零：说明三套重装机制都没命中（极罕见），此时再看一次 `last_reset_watchdog`：为 1 → 硬件重装位定义与实际不符；为 0 → 复位根本不是看门狗。

```sh
# 3. 如果还想看复位计数（可选）
dmesg | grep -c "rt2880_wdt"
```

## 六、回退

- 只回退补丁：删 `patches/rt2880-wdt-fix-ping.patch` 并清掉 `diy-part1.sh` 里对应两段（镜像仍能编、只是回到老行为）。
- 彻底回退：`git revert` 这三个提交，或回到 `53a72a2`。

## 七、刷机通道提醒

- **推荐**：原厂 failsafe（`10.10.10.123`）页面刷 `factory.bin`：写入由 U-Boot 完成，不依赖正在运行的系统，**不会被看门狗复位打断**。
- **不推荐**：在 LuCI 里做 sysupgrade：写入期间若撞上复位就会变砖（上次变砖就是这个原因）。
- failsafe 页面要的是带 uImage 头的镜像，即 `factory.bin`；`sysupgrade.bin` 是 tar 包，原厂 U-Boot 不认。
