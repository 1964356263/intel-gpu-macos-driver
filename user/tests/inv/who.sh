# SPDX-License-Identifier: MIT
for L in /tmp/nvmtl.log /private/var/folders/zz/zyxvpxvq6csfxvn_n00000bh00002w/T/nvmtl.log $(ls ~/Library/Containers/*/Data/tmp/nvmtl.log 2>/dev/null); do
  m=$(stat -f %Sm "$L")
  for p in $(grep -o "+load in pid [0-9]*" "$L" | awk '{print $4}' | sort -u); do
    c=$(ps -o comm= -p $p 2>/dev/null); [ -n "$c" ] && echo "$p ${c##*/}  [$L]"
  done
done
