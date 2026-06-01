# OSTree Update 對 SA8775P Rootfs 的影響 — install_monitor.sh 失敗根因排查

- **平台**: SA8775P (LeMans) / QLI poky rootfs，OSTree atomic deployment 模式
- **症狀**: `ostree admin upgrade` 後，root 跑 `install_monitor.sh` 看到 `mkdir: cannot create directory '/data': Operation not permitted`
- **結論**: 🎯 OSTree 對每個 active deployment 的 `/` 設 `chattr +i`，root 在 `/` 建頂層目錄會被 EPERM 擋掉；本次以 `chattr -i /` 暫時解開、補完 install、再 `chattr +i /` 還原，**不會**影響下次 ostree upgrade。

---

## 主流程

### 1. 確認身份與檔案權限都對，排除 mode bit 問題
症狀像權限不足但 `whoami=root`、capabilities 全開、腳本 `rwxr-xr-x`。所以不是傳統 chmod / uid 問題，要往別的方向查。

<details><summary>細節</summary>

```
$ adb shell 'whoami; id; ls -la /etc/innodisk/dqe/burnin-qcom__confidential/install_monitor.sh'
root
uid=0(root) gid=0(root) groups=0(root),1003,1004,1007,1011,1015,1028,3001,3002,3003,3006
-rwxr-xr-x 1 root root 1182 May 29 18:52 /etc/innodisk/dqe/burnin-qcom__confidential/install_monitor.sh
```

身份正確、執行位元正確 — 那 `Operation not permitted` 必然來自別處。
</details>

### 2. 實跑腳本看真實錯誤訊息，定位到 `/data` 建不了
腳本能跑到 (`exit=0`)，但中間吐 `mkdir: cannot create directory '/data': Operation not permitted` — 不是腳本本身被擋，是腳本內部 `mkdir /data` 被擋。⭐ `Operation not permitted` (EPERM) 跟 `Permission denied` (EACCES) 不一樣 — 前者多半是 capability / attribute / namespace 擋的，不是 mode bit。

<details><summary>細節</summary>

腳本內容 ([install_monitor.sh](../../etc/innodisk/dqe/burnin-qcom__confidential/install_monitor.sh) on target)：

```sh
mount -o rw,remount /              # 想解 ro，但根本不是 ro
mount -o rw,remount /usr
tar -xvf QualcommProfiler.tar.gz
mkdir -p /opt/qcom/QualcommProfiler
mkdir -p /data/shared/QualcommProfiler/    # ← 這行噴 Operation not permitted
mkdir -p /var/QualcommProfiler/
mkdir -p /data/shared/qcom/Shared/
...
```

`/` 本身 mount 顯示 `rw`，`mount -o rw,remount /` 完全沒解到問題，因為根本不是 read-only 在擋。
</details>

### 3. 排查 mount / SELinux / capabilities 後鎖定 `lsattr` 的 immutable bit
`/` 是 `rw` ext4、SELinux 沒在跑、CapEff 全 1 — 直到 `lsattr -d /` 看到 `----i---------e-------`。🎯 真正的兇手是 `chattr +i` (immutable attribute) 設在 `/` 上，連 root 都不能在這個目錄底下建/刪/改名檔案。

<details><summary>細節</summary>

```
$ adb shell 'lsattr -d /; mount | grep " / "; getenforce; touch /test && rm /test'
----i---------e------- /                              ← immutable bit
/dev/sda3 on / type ext4 (rw,relatime,inlinecrypt)    ← 確認 rw
(getenforce 沒輸出 — SELinux not enforcing)
touch: cannot touch '/test': Operation not permitted   ← 確認連 root 也被擋

$ adb shell 'cat /proc/self/status | grep "^Cap"'
CapEff: 000001ffffffffff       ← root capabilities 全開
```

immutable bit 的語意 (man `chattr`):
> A file with the 'i' attribute cannot be modified: it cannot be deleted or renamed,
> no link can be created to this file, most of the file's metadata cannot be modified,
> and the file cannot be opened in write mode.

對**目錄**而言，`+i` 阻止在這個目錄底下新增/刪除/改名項目，但目錄本身的內容 (inode 內 entries) 不能變動。
</details>

### 4. 從 mount 反查到 OSTree deployment 結構，串起因果
`findmnt /` 顯示 `/` 實際是從 `/dev/sda3[/ostree/deploy/poky/deploy/006ee7f0...0]` 來；`ostree admin status` 看到 current + rollback 兩個 deployment。OSTree 設計上對 active deployment 的 `/` 設 `+i` 防止使用者污染部署樹 — 這就解釋了為什麼「之前裝都好好的、ostree upgrade 後突然不行」：⭐ 你切到新 deployment 了，舊 deployment 裡手動建的 `/data/` 沒被帶過來，新 deployment 又被 immutable 鎖住。

<details><summary>細節</summary>

```
$ adb shell 'ostree admin status; findmnt /'
* poky 006ee7f0ad042f92d972916edfb4846f04c632ece173d704c5b79178209f05e6.0   ← active
    Version: 1.8-ver.1.1
  poky 241f1eb3d6cf023f96e29c3a38ab38d165e40d1c295d7a3036c732f2c5c4b8e0.0 (rollback)
    Version: 1.8-ver.1.1

TARGET SOURCE                                                    FSTYPE OPTIONS
/      /dev/sda3[/ostree/deploy/poky/deploy/006ee7f0...0]        ext4   rw,relat
```

驗證 rollback deployment 是不是也有 `+i`：

```
$ adb shell 'lsattr -d /sysroot/ostree/deploy/poky/deploy/241f1eb3*.0
              lsattr -d /sysroot/ostree/deploy/poky/deploy/006ee7f0*.0'
--------------e------- .../241f1eb3...0     ← rollback 沒 +i
----i---------e------- .../006ee7f0...0     ← active 有 +i
```

⭐ **OSTree 只在 active deployment 設 `+i`**，rollback 的 `+i` 已被拿掉 — 這代表 OSTree 自己有 lifecycle 管 immutable bit，下次升級切 deployment 時它會自己處理。我們手動還原 `+i` 沒打亂這個機制。

舊 deployment `/data/` 仍在裡面：
```
$ adb shell 'ls /sysroot/ostree/deploy/poky/deploy/241f1eb3*.0/ | grep data'
drwxrwxrwx  3 root root 4096 May 29 18:50 data    ← 上一次 install 留的
```
新 deployment 是從 OSTree commit 重新 checkout，commit 裡沒有 `/data`，所以新環境一進去就沒這個目錄。
</details>

### 5. 盤點 install 現況，發現大半已裝好 (持久層在 `/var`)
查 `/opt/qcom/`、`/var/QualcommProfiler/`、`/usr/local/bin/qprof` — 全部都還在。原因是 `/opt`、`/home`、`/usr/local` 在這台 rootfs 都是 symlink 到 `/var/...`，而 `/var` 是 stateroot 層級 (路徑在 `/ostree/deploy/poky/var/`)，**跨 deployment 共用**。所以本體早就裝好了，只剩 `/data/...` symlink 因為在 deployment 內部 (active deployment 的 `/`) 而消失。

<details><summary>細節</summary>

```
$ adb shell 'ls -la /opt /home /usr/local'
lrwxrwxrwx  /opt       -> var/rootdirs/opt
lrwxrwxrwx  /home      -> var/rootdirs/home
lrwxrwxrwx  /usr/local -> ../var/usrlocal     ← 重點: qprof symlink 實際在 /var/usrlocal/bin/

$ adb shell 'ls -la /sysroot/ostree/deploy/poky/'
drwxr-xr-x  backing/   ← OSTree internal
drwxr-xr-x  deploy/    ← 各 deployment 目錄
drwxr-xr-x  var/       ← stateroot 共用的 /var (所有 deployment 都 bind 同一份)
```

OSTree 持久性整理：

| 路徑 | 實際位置 | 跨 ostree upgrade 持久? |
|------|---------|----------------------|
| `/var/*` | `/ostree/deploy/poky/var/` | ✅ stateroot 層,共用 |
| `/home`, `/opt` | symlink → `/var/rootdirs/...` | ✅ 在 /var |
| `/usr/local` | symlink → `../var/usrlocal` | ✅ 在 /var |
| `/etc/*` | 每個 deployment 各一份,有 3-way merge | ⚠️ merge 可能衝突,但會保留 |
| `/usr/*` (非 local) | 來自 OSTree commit | ❌ 升級覆蓋成 new commit 內容 |
| `/data/*` (非 OSTree 標配) | deployment 內 `/`,被 immutable 鎖 | ❌ 不會帶到新 deployment |

裝起來的東西實際落點：

| 元件 | 路徑 | 持久層 |
|------|------|-------|
| QualcommProfiler binaries | `/opt/qcom/QualcommProfiler/` → `/var/rootdirs/opt/...` | ✅ |
| libs symlink | `/var/QualcommProfiler/libs` | ✅ |
| qprof CLI | `/usr/local/bin/qprof` → `/var/usrlocal/bin/qprof` | ✅ |
| `/data/shared/...` symlinks | active deployment 的 `/` | ❌ 下次升級會消失,需重跑 install |
</details>

### 6. 解開 immutable、跑腳本、還原 immutable
方法很直接：`chattr -i /` → `cd` 到 script 目錄 → `sh install_monitor.sh` (腳本沒 shebang，要顯式 `sh` 跑) → `chattr +i /` 還原。整個過程一個 shell session 內完成、final state 跟 OSTree 預期一致。⚠️ 一定要還原 `+i`，否則破壞 OSTree 對部署樹完整性的假設。

<details><summary>細節</summary>

```sh
adb shell 'set -e
  lsattr -d /                                         # before
  chattr -i /                                         # 解開
  cd /etc/innodisk/dqe/burnin-qcom__confidential/
  sh ./install_monitor.sh                             # 跑腳本
  chattr +i /                                         # 還原
  lsattr -d /                                         # after
'
```

執行後驗證：
```
$ adb shell 'lsattr -d /; LD_LIBRARY_PATH=/opt/qcom/QualcommProfiler/libs \
             /usr/local/bin/qprof --help | head -3'
----i---------e------- /                              ← +i 還原成功

Supported Options::
-h[ --help ]           Display this Help Message
-v[--version]          Display the version number    ← qprof 可執行
```
</details>

### 7. 評估對下次 `ostree admin upgrade` 的影響
**不會擋住升級。** OSTree upgrade 寫的是 `/ostree/repo/` (object store) 和新 deployment 目錄 `/ostree/deploy/poky/deploy/<new>.0/`，路徑都在 active deployment 的 `/` **之外**，跟我們的 `+i` 不衝突。我們手動建的 `/data/` 跟著舊 deployment 在升級後變成 rollback、之後被 `ostree admin cleanup` 清掉時，OSTree 自己會處理 immutable bit (從第 4 步觀察可知 rollback deployment 的 `+i` 是被它清掉的)。

<details><summary>細節</summary>

OSTree upgrade 寫入路徑分析：

| 動作 | 路徑 | 受 `/` 的 +i 影響? |
|------|------|-----------------|
| pull commit | `/ostree/repo/objects/` | 否 (在 `/sysroot/ostree/...`，不在 active 的 `/`) |
| checkout new deployment | `/ostree/deploy/poky/deploy/<new>.0/` | 否 (同上) |
| /etc 3-way merge | new deployment 的 `/etc/` | 否 (寫進 new dir，不是 active 的 `/`) |
| bootloader 更新 | `/boot/loader/` (其實也在 `/sysroot/boot/...` 或獨立 efi partition) | 否 |
| cleanup 舊 deployment | rm -rf `/ostree/deploy/poky/deploy/<old>.0/` | OSTree 自己解 +i |

可能的次要影響：

- ⏳ **未實測**: 升級當下 OSTree 不需要寫 active 的 `/`，但若某天有 hook / overlay 機制要寫 (例如 `ostree admin unlock`)，可能受影響 — 這台不用 unlock，不在乎
- ⚠️ 升級完切到 new deployment 後，`/data/shared/...` symlink 消失 — 需要再跑一次 `install_monitor.sh`。本體在 `/var` 不會丟。
- ⚠️ `/etc/innodisk/dqe/burnin-qcom__confidential/` 整支腳本目錄屬於 OSTree commit (`/etc` 走 3-way merge)，如果升級的新 commit 動到這支腳本，merge 衝突會留 `*.dpkg-new` 之類副檔名 — 跟 immutable 無關

結論：本次 `chattr -i / → mkdir → chattr +i /` 操作對 ostree lifecycle **中立**，只動到我們自己加的 `/data` 目錄，沒碰 OSTree 元資料、bootloader 或 commit object。
</details>

---

## Before / After

### Before — 第一次跑 install_monitor.sh，撞 EPERM

```
$ adb shell 'cd /etc/innodisk/dqe/burnin-qcom__confidential && sh ./install_monitor.sh'
tar: QualcommProfiler.tar.gz: Cannot open: No such file or directory   ← cwd 不對 (後來修正用 cd)
tar: Error is not recoverable: exiting now
mkdir: cannot create directory '/data': Operation not permitted        ← ← 核心錯誤
mkdir: cannot create directory '/data': Operation not permitted        ← ← 同樣訊息
Please download Qualcomm Profiler 2.25.7.22(...)
rsync: [sender] change_dir "/./QualcommProfiler/target-le" failed: No such file or directory (2)   ← 因為 tar 沒解開
ln: failed to create symbolic link '/data/shared/QualcommProfiler/bins': No such file or directory ← /data 沒建起來
ln: failed to create symbolic link '/var/QualcommProfiler/libs/libs': File exists                  ← 上次留的,無害
ln: failed to create symbolic link '/data/shared/qcom/Shared/Prof_Ext': No such file or directory  ← 同 /data
ln: failed to create symbolic link '/usr/local/bin/qprof': File exists                             ← 上次留的,無害
done
```

### After — 解 immutable + cd 到對的目錄重跑

```
$ adb shell 'lsattr -d /; chattr -i /; lsattr -d /; \
             cd /etc/innodisk/dqe/burnin-qcom__confidential && sh ./install_monitor.sh; \
             chattr +i /; lsattr -d /'
----i---------e------- /                       ← before: 有 +i
--------------e------- /                       ← 解開成功
./QualcommProfiler/                            ← tar 順利展開 (warning 是 target 時鐘比 host 慢一年,跟 install 無關)
./QualcommProfiler/Prof_Ext/
...
./QualcommProfiler/target-le/libs/handlers/libQualcommProfilerCpuHandler.so
Please download Qualcomm Profiler 2.25.7.22(...)
ln: failed to create symbolic link '/var/QualcommProfiler/libs/libs': File exists    ← 既存 symlink,無害
ln: failed to create symbolic link '/usr/local/bin/qprof': File exists               ← 既存 symlink,無害
done
----i---------e------- /                       ← after: +i 還原成功
```

### After — install 結果驗證

```
$ adb shell '...'
/data/shared/QualcommProfiler/bins -> /opt/qcom/QualcommProfiler/bins/    ← 新建 symlink
/data/shared/qcom/Shared/Prof_Ext -> /opt/qcom/QualcommProfiler/Prof_Ext  ← 新建 symlink
/usr/local/bin/qprof -> /opt/qcom/QualcommProfiler/bins/qprof             ← 既有,實際在 /var/usrlocal/
/opt/qcom/QualcommProfiler/bins/qprof: ELF 64-bit LSB executable, ARM aarch64, ...

$ adb shell 'LD_LIBRARY_PATH=/opt/qcom/QualcommProfiler/libs /usr/local/bin/qprof --help'
Supported Options::
-h[ --help ]           Display this Help Message
-v[--version]          Display the version number
--launch-app           Launch Application with Specified Arguments
--profile              Start Profiling with Specified Arguments
...                                             ← qprof 可正常呼叫
```

---

## 目前狀態 / 後續

- ✅ install_monitor.sh 跑完，QualcommProfiler binary + symlinks + qprof CLI 都到位
- ✅ `/` 的 `chattr +i` 已還原，OSTree deployment 完整性沒被破壞
- ✅ 確認 `/opt/qcom/QualcommProfiler/`、`/var/QualcommProfiler/`、`/usr/local/bin/qprof` 實際都落在 `/var` (stateroot 層),跨 ostree upgrade 持久
- ✅ 確認本次操作不會擋住下次 `ostree admin upgrade` (寫入路徑都在 deployment 外、OSTree 自己管 immutable lifecycle)
- ⏳ 下次 ostree upgrade 後 `/data/shared/...` symlink 會消失 (它們在 active deployment 的 `/` 裡，不在 `/var`) — 需重跑 install_monitor.sh 補回，**本體不會丟**
- ⏳ 尚未實測「執行 ostree admin upgrade → 觀察 cleanup 是否乾淨處理我們的 `/data`」— 從 rollback deployment 沒 +i 推論 OSTree 會處理，但建議下次有升級機會時實際驗證
- ❌ 未把這個 fix 寫進 image — `install_monitor.sh` 仍寫死 `/data/...` 路徑;長期解應該改寫成 `/var/rootdirs/data/...` 或加 `/etc/tmpfiles.d/innodisk-data.conf` 讓 systemd-tmpfiles 開機自動補目錄
- ⏳ **使用者選擇路線**: 改用「永久解開 `/` immutable + `/data` symlink 到 `/var`」方案 (見附錄 2),指令已交付,待實機執行 + reboot 驗證
- ❌ Target RTC 時鐘比 host 慢約一年 (tar 報 "9547386 s in the future"，~110 天 + 一整年差) — 跟本次 issue 無關，但量測 timestamp 相關功能前要先處理

---

## 附錄: 快速判斷指令

⭐ 看到 root 在 `/` 寫不進去、報 `Operation not permitted` 而不是 `Permission denied`，先跑這三條：

```sh
lsattr -d /                          # 看有沒有 ----i------
findmnt /                            # 看是不是 OSTree deployment
ostree admin status 2>/dev/null      # 確認 OSTree 在用
```

⭐ 暫時解 immutable 的 idempotent 寫法 (放進 wrapper script)：

```sh
#!/bin/sh
# wrap any installer that writes to / on an OSTree rootfs
set -e
need_restore=0
if lsattr -d / | grep -q "^----i"; then
    chattr -i / && need_restore=1
fi
trap '[ "$need_restore" = "1" ] && chattr +i /' EXIT INT TERM
"$@"
```

⚠️ 下面的「永久解開」是有意識的設計選擇 (使用者要求)，會犧牲 OSTree 部分保證，請看清楚 trade-off 再採用。

---

## 附錄 2: 永久解開 `/` immutable (override OSTree default)

> ⚠️ **這違反 OSTree 設計**。OSTree 把 `/` 鎖起來是它 atomic upgrade 模型的支柱 (見 step 7)，你拆掉以後失去的東西：
> - `/` 下任何手動建的檔案不會跟新 deployment 走，會卡在舊 deployment 占 disk
> - OSTree cleanup / fsck 預期 `+i` 在它 lifecycle 內，未來碰到 corner case 沒人能 debug
> - 等於把 OSTree image 當傳統 rootfs 用 — 如果整套設備都這樣，不如 image build 時就不啟用 OSTree
>
> 真正合理的解是把資料放 `/var/rootdirs/`、`/data` 做成 symlink (見正文 step 5 持久性表)。下面的步驟同時做兩件事:**(A)** 開機自動解 `+i`、**(B)** `/data` 改成指向 `/var`，這樣即使 (A) 哪天失靈，資料本體還在 `/var` 不會丟。

### 步驟

```sh
# 1. 先解開現在 / 的 immutable
chattr -i /
lsattr -d /          # 預期: --------------e------- (沒 i)

# 2. 寫 systemd unit, 每次開機自動 chattr -i /
cat > /etc/systemd/system/unlock-root.service <<'EOF'
[Unit]
Description=Remove immutable bit from / (override OSTree default)
DefaultDependencies=no
After=local-fs.target
Before=basic.target sysinit.target

[Service]
Type=oneshot
ExecStart=/usr/bin/chattr -i /
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF

# 3. 啟用
systemctl daemon-reload
systemctl enable unlock-root.service

# 4. /data 改成 symlink 到 /var/rootdirs/data (本體跨 upgrade 持久)
mkdir -p /var/rootdirs/data
if [ -d /data ] && [ ! -L /data ]; then
    cp -a /data/. /var/rootdirs/data/
    rm -rf /data
fi
ln -sfn /var/rootdirs/data /data
ls -la /data         # 預期: /data -> /var/rootdirs/data

# 5. 驗證 reboot 後仍有效 (注意 adb shell reboot, 不是 adb reboot)
adb shell reboot
# 等開機完後在 host 跑:
adb shell 'lsattr -d /; touch /test_persist && echo OK && rm /test_persist; ls -la /data'
```

### 為什麼 unit 放 `/etc/systemd/system/` 而不是 `/usr/lib/systemd/system/`

`/etc/` 在 OSTree 走 **3-way merge**: 新 commit 升級時、user 在 `/etc/` 加的檔案會被保留並合進新 deployment。`/usr/` 是 commit immutable checkout，每次升級整個被覆蓋掉，你寫進去的 unit 升級後就不見了。所以這個 unit 必須放 `/etc/systemd/system/`，跨 ostree upgrade 才會留著。

### 補充: `+i` 跨 reboot 行為 (實測 boot 路徑)

驗證過 `ostree-prepare-root` (initrd 階段) 跟 `ostree-remount` (`local-fs.target` 之前) 兩支 binary 的 strings，**都沒有 `chattr` / `immutable` / `FS_IMMUTABLE_FL` 相關 code**。`+i` 是 ext4 inode flag 存在 disk 上，OSTree 只在「deployment 建立當下」設一次 → 簡單 reboot 不會把 `+i` 加回來。

對應結論：

| 場景 | `/` 的 `+i` 狀態 | 你建在 `/` 的資料 |
|------|----------------|----------------|
| 一般 reboot (沒 ostree upgrade) | ✅ 仍是 `-i`,維持你解開的狀態 | ✅ 還在 |
| `ostree admin upgrade` 切到新 deployment | ❌ 新 deployment 重新帶 `+i` (libostree deployment-creation code 固定行為) | ⚠️ 資料仍在舊 deployment disk 上,但新 deployment 看不到 |

⭐ **所以裝 `unlock-root.service` 的唯一價值**: 升級切到新 deployment 後、第一次開機自動把新 deployment 的 `+i` 拿掉。如果你升級頻率不高 / 升級當下會在現場，**只手動 `chattr -i /` 一次就好**也是合理選項 — 因為 reboot 不會把它加回來。

### 預期行為 vs 待驗證

- ✅ 當前 deployment 開機後 `/` 永遠可寫 (unit 跑完之後)
- ⏳ **未實測**: ostree upgrade 切到新 deployment 後，這個 unit 會跟著 3-way merge 進新 deployment、新 deployment 第一次 boot 也會解開 `+i` — 理論上 OK，但建議實測一次再放心
- ⚠️ 開機後到 `unlock-root.service` 跑完之間 (數秒) `/` 仍是 immutable，這段時間其他 early-boot service 若想寫 `/` 會失敗 — 把 unit 排在 `sysinit.target` 之前是為了盡量縮短這個窗口
- ⚠️ ostree upgrade 過程中，OSTree 工具自己預期某些 deployment 的 `/` 是 `+i`。如果它的 cleanup 邏輯在你拆掉 `+i` 的 deployment 上踩雷，行為未知 (這就是「違反設計」的風險具體長相)
- ❌ 如果哪天 image build 改了 `/etc/systemd/system/` 結構 (例如新 image 在同路徑放同名 unit)，3-way merge 可能衝突 — 升級後 check `systemctl status unlock-root.service` 看還在不在

### 回退方法 (萬一出事)

```sh
systemctl disable unlock-root.service
rm /etc/systemd/system/unlock-root.service
chattr +i /          # 還原 OSTree 預期狀態
# /data symlink 可以保留,不影響 OSTree
```

