#!/system/bin/sh
# power by 秋刀鱼 & https://t.me/qdykernel
# 动态验证 LSM 写时拦截（安全检测 + 失败回滚首字节）
# 说明：本脚本将遍历 /dev/block/by-name/ 下的所有块设备真实分区，并排除*boot分区，仅写首字节做拦截自检，失败时将触发回滚

ESC_G="\033[32m"; ESC_R="\033[31m"; ESC_Y="\033[33m"; ESC_N="\033[0m"
ESC_M="\033[35m"

echo "===== LSM受保护分区自检 ====="
date

BYNAME_DIR="/dev/block/by-name"
[ ! -d "$BYNAME_DIR" ] && { echo "找不到 $BYNAME_DIR，退出"; exit 1; }


is_excluded() {
  local name="$1"
  case "$name" in
    boot*|init_boot*|vendor_boot*|userdata*|metadata*|cache*|misc*|dtbo*|vbmeta_*|vbmeta|vbmeta_system_*|vbmeta_vendor_*|recovery_*)
      return 0 ;;
    *) return 1 ;;
  esac
}

# 记录已检测的“真实块设备”避免别名重复
SEEN_DEVICES=""

seen_has() {
  case " $SEEN_DEVICES " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

seen_add() {
  SEEN_DEVICES="$SEEN_DEVICES $1"
}

FAIL=0
COUNT=0

for link in "$BYNAME_DIR"/*; do
  [ -L "$link" ] || continue
  BNAME="$(basename "$link")"

  if is_excluded "$BNAME"; then
    printf "${ESC_Y}[SKIP] 排除高风险分区：%s${ESC_N}\n" "$BNAME"
    continue
  fi

  REALDEV="$(readlink -f "$link" 2>/dev/null)"
  if [ -z "$REALDEV" ] || [ ! -e "$REALDEV" ]; then
    printf "${ESC_Y}[SKIP] 无法解析真实设备：%s${ESC_N}\n" "$BNAME"
    continue
  fi
  if seen_has "$REALDEV"; then
    printf "${ESC_Y}[SKIP] 已检测过相同设备：%s -> %s${ESC_N}\n" "$BNAME" "$REALDEV"
    continue
  fi
  seen_add "$REALDEV"

  echo "---- 测试 ${BNAME} -> ${REALDEV} ----"
  COUNT=$((COUNT+1))

  PRE="$(dd if="$REALDEV" bs=1 count=1 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
  [ -z "$PRE" ] && PRE="--"
  echo "  首字节(写前)：$PRE"

  DD_OUT="$(dd if=/dev/zero of="$REALDEV" bs=1 count=1 2>&1 </dev/null)"
  RC=$?
  echo "$DD_OUT" | head -n2 | sed 's/^/  dd: /'
  echo "  dd 返回码: $RC"

  POST="$(dd if="$REALDEV" bs=1 count=1 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
  [ -z "$POST" ] && POST="--"
  echo "  首字节(写后)：$POST"

  if [ "$RC" -ne 0 ] && [ "$PRE" = "$POST" ]; then
    printf "${ESC_G}  [PASS] 被拦截（未实际写入）${ESC_N}\n"
    continue
  fi

  printf "${ESC_R}  [FAIL] 可疑：返回码=%s，内容变化：%s -> %s${ESC_N}\n" "$RC" "$PRE" "$POST"

  if [ "$PRE" = "--" ]; then
    printf "${ESC_Y}  [WARN] 读不到原始字节，无法回滚；请手动检查${ESC_N}\n"
    FAIL=1
    break
  fi

  printf "  尝试回滚首字节到 0x%s ...\n" "$PRE"
  printf "\\x$PRE" | dd if=/proc/self/fd/0 of="$REALDEV" bs=1 count=1 conv=notrunc 2>/dev/null

  NOW="$(dd if="$REALDEV" bs=1 count=1 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
  [ -z "$NOW" ] && NOW="--"
  echo "  回滚后首字节：$NOW"

  if [ "$NOW" = "$PRE" ]; then
    printf "${ESC_M}  [ROLLBACK-OK] 已恢复原始字节 0x%s${ESC_N}\n" "$PRE"
  else
    printf "${ESC_R}  [ROLLBACK-FAIL] 未能恢复首字节（期望 %s 实际 %s）${ESC_N}\n" "$PRE" "$NOW"
  fi

  FAIL=1
  break
done

echo
echo "==== 最近10条 baseband_guard 日志 ===="
dmesg | grep baseband_guard | tail -n 10

echo
if [ "$FAIL" -eq 0 ]; then
  if [ "$COUNT" -gt 0 ]; then
    printf "${ESC_G}==== 自检：PASS（共检测 %s 个分区，全部验证通过 无实际写入）====${ESC_N}\n\n" "$COUNT"
  else
    printf "${ESC_Y}==== 自检：SKIP（未找到可检测分区）====${ESC_N}\n\n"
  fi
else
  printf "${ESC_R}==== 自检：FAIL（出现异常；已在当处尝试回滚）====${ESC_N}\n"
fi

printf "绿色${ESC_G}[PASS]${ESC_N} = 成功拦截\n"
printf "黄色${ESC_Y}[SKIP]${ESC_N} = 排除/别名重复/无法解析 可无视\n"
printf "红色${ESC_R}[FAIL]${ESC_N} = 出现异常（已尝试回滚首字节）\n"
printf "如果出现红色${ESC_R}[FAIL]${ESC_N}请截图反馈给作者\n\n"
printf "秋刀鱼：https://t.me/qdykernel\n"
