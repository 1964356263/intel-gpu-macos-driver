# IntelXe-EFI.ps1: the OpenCore changes on Windows

[Türkçe](#türkçe)

`IntelXe-EFI.ps1` makes the `config.plist` changes and copies the files of stages 2 and 4 of the install guide
(`README-INSTALL.md`) in an OpenCore EFI folder that **you** point it to: the EFI folder on a USB stick, or the EFI
partition of a disk. It does not build an EFI: you keep the one you made with Dortania's guide, and the tool changes
only what the driver needs, the rest of `config.plist` as it is (key order, comments, layout). These are the same
changes as `efi.sh` makes on macOS.

It comes in `intel-gpu-macos-driver-VERSION-efi.zip`, next to `EFI/OC/Kexts/IntelXe.kext` and
`EFI/OC/ACPI/SSDT-ARCOFF.aml`. It runs in Windows PowerShell 5.1 (part of Windows 10 and 11) or PowerShell 7; nothing
needs to be installed.

**Not yet run on Windows by its author.** Its config-editing engine was checked on macOS against `efi.sh` (see
[Testing](#testing)); the window, the EFI partition mounting and the script on a real Windows PC are untested. Keep a
USB stick with a working EFI, and read each plan before you confirm it.

## Starting it

1. Unpack the `-efi.zip` (right-click > Extract All).
2. Right-click `IntelXe-EFI.ps1` > **Run with PowerShell**. A window opens.
   If Windows refuses to run it ("running scripts is disabled"), start it from a PowerShell window instead:

   ```powershell
   cd $HOME\Downloads\intel-gpu-macos-driver-VERSION-efi
   powershell -ExecutionPolicy Bypass -File .\IntelXe-EFI.ps1
   ```

   `-ExecutionPolicy Bypass` applies to that one run only. A file downloaded with a browser may also need
   `Unblock-File .\IntelXe-EFI.ps1` once.

**Administrator rights** are needed only for an EFI partition: Windows lets only administrators mount it and write
to it. A USB stick or a copy of an EFI folder works without them. The window's **Restart as administrator** button
starts it again elevated (Windows asks), with your folders filled in.

## Step by step (the window)

1. **EFI folder.** For a USB stick, *Browse...* to its `EFI` folder (the one with `OC` and `BOOT` in it), e.g.
   `E:\EFI`. For the EFI partition of a disk, press **Mount EFI partition...** (administrator): it lists the EFI
   partitions of the PC with their disk's name and size, mounts the one you choose with `mountvol` (nothing is
   written to it) and fills in `S:\EFI`. **Unmount EFI partition** takes the letter away again.
2. **Package folder** is filled in when the script sits in the unpacked `-efi.zip`.
3. **Backups**: leave it empty. Before each change the whole EFI folder is copied to a numbered, dated folder:
   next to the EFI folder (`E:\IntelXe-EFI-backups\...`), or, for an EFI partition (less than 2 GB, its space is for
   booting), to `%LOCALAPPDATA%\intel-gpu-macos-driver\efi-backups\`. Undo looks in the same place.
4. **Stage 2, any time after macOS is installed:** *Settings: plan* shows what changes; *Settings: apply...* shows the
   plan again and asks, then backs up and writes. It sets `csr-active-config` to at least `03080000` (a wider value
   stays), adds `amfi_get_out_of_my_way=0x1` and `intelxe_surfvram=2` to the boot-args (yours stay), puts
   `csr-active-config` and `boot-args` in `NVRAM > Delete`, and sets `ResizeAppleGpuBars = 10`,
   `DisableIoMapper = true`, `ReconnectGraphicsOnConnect = false`.
5. **Stage 4, after `sudo ./install.sh --apply` on macOS, before the reboot:** *Driver: plan* / *Driver: apply...*
   copy `IntelXe.kext` (when missing or different), add or enable its `Kernel > Add` entry, turn off an earlier
   `B580.kext` entry, and add 1 to `Misc > Security > ExposeSensitiveData` (so that macOS tools find the EFI
   OpenCore booted from).
6. **SSDT-ARCOFF.aml** is added only when you tick its box and give your card's ACPI path. **Not before macOS is
   installed:** the table hides the B580 from the display driver that the macOS installer runs on. Its path depends
   on the board; the shipped table is for `\_SB.PC00.PEG1.PEGP`. In Device Manager > Display adapters > the B580 (or
   "Microsoft Basic Display Adapter") > Properties > Details > **Location paths**, the line
   `ACPI(_SB_)#ACPI(PC00)#ACPI(PEG1)#ACPI(PEGP)#PCI(0100)#PCI(0000)` is `\_SB.PC00.PEG1.PEGP`; you can paste that
   line. *Read from Windows* reads it when Windows runs on the PC with the card. With another path the tool does not
   copy the table and says what to do (stage 4, step 2 of the install guide).
7. **Undo last change...** puts back, from the newest backup, the files that change touched (`config.plist`,
   `IntelXe.kext`, `SSDT-ARCOFF.aml`); each undo goes one change further back. It warns when `config.plist` was edited
   after that change (putting it back loses those edits). The backups stay.

Every change is planned first and carries the plan's SHA-256: if the EFI changed between the plan you read and your
confirmation, nothing is written. `config.plist` is edited in memory, read back and checked before it replaces the
old one; a damaged package (its files differ from its `SHA256SUMS`) is refused.

## Command line

```powershell
.\IntelXe-EFI.ps1 -Status -Efi E:\EFI
.\IntelXe-EFI.ps1 -Plan settings -Efi E:\EFI            # prints the plan and its SHA-256
.\IntelXe-EFI.ps1 -Apply settings -Efi E:\EFI -Expect <SHA-256>
.\IntelXe-EFI.ps1 -Plan driver -Efi E:\EFI [-CardAcpiPath '\_SB.PC00.PEG1.PEGP']
.\IntelXe-EFI.ps1 -Apply driver -Efi E:\EFI [-CardAcpiPath ...] -Expect <SHA-256>
.\IntelXe-EFI.ps1 -Plan undo -Efi E:\EFI
.\IntelXe-EFI.ps1 -Undo -Efi E:\EFI -Expect <SHA-256>
.\IntelXe-EFI.ps1 -ListEsp                              # administrator: the EFI partitions
.\IntelXe-EFI.ps1 -MountEsp '\\?\Volume{...}\'          # administrator; -MountEsp system = mountvol S: /S
.\IntelXe-EFI.ps1 -UnmountEsp S:
.\IntelXe-EFI.ps1 -Help
```

`-Package DIR` (default: the script's folder) and `-BackupDir DIR` work with all of them. `mountvol S: /S` mounts the
EFI partition Windows booted from; when OpenCore is on another disk, use `-ListEsp` and `-MountEsp` with its volume.

## Testing

`windows/test/` in the repository:

- `Test-IntelXe-EFI.ps1`, on Windows: runs the script, as a user would, against a throwaway EFI folder made from
  `efi/sample-z790/config.plist` as stage 1 leaves it (`stage1/config.plist`), in `%TEMP%`, without administrator
  rights: status, both plans, apply with a wrong hash and with the right one, undo step by step, the confirmed and
  unconfirmed ACPI path, a damaged package, a different kext, an earlier `B580.kext` entry, a wider SIP value, adding
  missing entries, the default backup place. Each `config.plist` it writes must hold the same keys and values as
  `efi.sh` writes for that step (`expected/efi-sh/`) and the same text as the engine writes on macOS
  (`expected/engine/`, layout kept). Run it with both PowerShells:

  ```powershell
  powershell -ExecutionPolicy Bypass -File windows\test\Test-IntelXe-EFI.ps1
  pwsh -File windows\test\Test-IntelXe-EFI.ps1
  ```

  `-RealPackage DIR` uses an unpacked package's `IntelXe.kext` and `SSDT-ARCOFF.aml` instead of stand-ins.
- `make-expected.sh`, on macOS: makes `stage1/` and `expected/` with `efi.sh`, builds the script's engine (C# 5,
  compiled by `Add-Type` on Windows) with `dotnet` and checks it against them (`macos/EngineTest.cs`). `--check` only
  compares.

---

## Türkçe

`IntelXe-EFI.ps1`, kurulum rehberinin (`README-INSTALL.tr.md`) 2. ve 4. aşamalarındaki `config.plist` değişikliklerini
ve dosya kopyalarını, **sizin** gösterdiğiniz bir OpenCore EFI klasöründe yapar: bir USB belleğin EFI klasörü ya da bir
diskin EFI bölümü. EFI oluşturmaz: Dortania rehberiyle hazırladığınız EFI sizde kalır, araç yalnızca sürücünün
gerektirdiklerini değiştirir; `config.plist`'in geri kalanı olduğu gibi kalır (anahtar sırası, açıklamalar, düzen).
macOS'ta `efi.sh`'in yaptığı değişikliklerin aynısıdır.

`intel-gpu-macos-driver-SÜRÜM-efi.zip` içinde, `EFI/OC/Kexts/IntelXe.kext` ve `EFI/OC/ACPI/SSDT-ARCOFF.aml` ile birlikte
gelir. Windows PowerShell 5.1'de (Windows 10 ve 11'de hazır gelir) ya da PowerShell 7'de çalışır; hiçbir şey kurmak
gerekmez.

**Henüz yazarı tarafından Windows'ta çalıştırılmadı.** `config.plist` düzenleyen çekirdeği macOS'ta `efi.sh`'e karşı
denendi (bkz. [Deneme](#deneme)); pencere, EFI bölümünü bağlama ve betiğin gerçek bir Windows bilgisayardaki çalışması
denenmedi. Çalışan bir EFI'si olan USB belleği elinizde tutun ve her planı onaylamadan önce okuyun.

### Başlatmak

1. `-efi.zip`'i açın (sağ tık > Tümünü Ayıkla).
2. `IntelXe-EFI.ps1`'e sağ tık > **PowerShell ile Çalıştır**. Bir pencere açılır.
   Windows çalıştırmayı reddederse ("betik çalıştırma devre dışı") bir PowerShell penceresinden başlatın:

   ```powershell
   cd $HOME\Downloads\intel-gpu-macos-driver-SÜRÜM-efi
   powershell -ExecutionPolicy Bypass -File .\IntelXe-EFI.ps1
   ```

   `-ExecutionPolicy Bypass` yalnızca o çalıştırma için geçerlidir. Tarayıcıyla indirilen dosya için bir kez
   `Unblock-File .\IntelXe-EFI.ps1` de gerekebilir.

**Yönetici hakları** yalnızca EFI bölümü için gerekir: Windows bu bölümü yalnızca yöneticilerin bağlamasına ve yazmasına
izin verir. USB bellek ya da bir EFI klasörünün kopyası için gerekmez. Penceredeki **Restart as administrator** düğmesi
aracı klasörleriniz doldurulmuş olarak yönetici olarak yeniden başlatır (Windows izin ister).

### Adım adım (pencere)

1. **EFI folder.** USB bellek için *Browse...* ile `EFI` klasörünü seçin (içinde `OC` ve `BOOT` olan), örneğin `E:\EFI`.
   Bir diskin EFI bölümü için **Mount EFI partition...** (yönetici): bilgisayardaki EFI bölümlerini diskin adı ve
   boyutuyla listeler, seçtiğinizi `mountvol` ile bağlar (bölüme hiçbir şey yazılmaz) ve `S:\EFI`'yi doldurur.
   **Unmount EFI partition** sürücü harfini geri kaldırır.
2. **Package folder**, betik açılmış `-efi.zip`'in içindeyse kendiliğinden dolar.
3. **Backups**: boş bırakın. Her değişiklikten önce EFI klasörünün tamamı numaralı ve tarihli bir klasöre kopyalanır:
   EFI klasörünün yanına (`E:\IntelXe-EFI-backups\...`) ya da EFI bölümü için (2 GB'tan küçük; alanı açılış içindir)
   `%LOCALAPPDATA%\intel-gpu-macos-driver\efi-backups\` altına. Geri alma da aynı yere bakar.
4. **2. aşama, macOS kurulduktan sonra istediğiniz zaman:** *Settings: plan* nelerin değişeceğini gösterir;
   *Settings: apply...* planı yeniden gösterip sorar, sonra yedekleyip yazar. `csr-active-config`'i en az `03080000`
   yapar (daha geniş bir değer kalır), boot-args'a `amfi_get_out_of_my_way=0x1` ve `intelxe_surfvram=2` ekler (sizinkiler
   kalır), `csr-active-config` ve `boot-args`'ı `NVRAM > Delete`'e koyar; `ResizeAppleGpuBars = 10`,
   `DisableIoMapper = true`, `ReconnectGraphicsOnConnect = false` yapar.
5. **4. aşama, macOS'ta `sudo ./install.sh --apply`'dan sonra, yeniden başlatmadan önce:** *Driver: plan* /
   *Driver: apply...* `IntelXe.kext`'i kopyalar (yoksa ya da farklıysa), `Kernel > Add` kaydını ekler ya da açar,
   eski bir `B580.kext` kaydını kapatır ve `Misc > Security > ExposeSensitiveData`'ya 1 ekler (macOS araçları
   OpenCore'un açıldığı EFI'yi bulabilsin diye).
6. **SSDT-ARCOFF.aml** yalnızca kutusunu işaretleyip kartınızın ACPI yolunu yazarsanız eklenir. **macOS kurulmadan
   önce değil:** bu tablo B580'i macOS kurulum programının çalıştığı ekran sürücüsünden gizler. Yolu anakarta göre
   değişir; paketteki tablo `\_SB.PC00.PEG1.PEGP` içindir. Aygıt Yöneticisi > Görüntü bağdaştırıcıları > B580 (ya da
   "Microsoft Temel Görüntü Bağdaştırıcısı") > Özellikler > Ayrıntılar > **Konum yolları**'ndaki
   `ACPI(_SB_)#ACPI(PC00)#ACPI(PEG1)#ACPI(PEGP)#PCI(0100)#PCI(0000)` satırı `\_SB.PC00.PEG1.PEGP` demektir; satırı olduğu
   gibi yapıştırabilirsiniz. *Read from Windows*, Windows kartın takılı olduğu bilgisayarda çalışıyorsa yolu okur.
   Başka bir yolda araç tabloyu kopyalamaz ve ne yapılacağını söyler (kurulum rehberi, 4. aşama, 2. madde).
7. **Undo last change...** en yeni yedekten, o değişikliğin dokunduğu dosyaları (`config.plist`, `IntelXe.kext`,
   `SSDT-ARCOFF.aml`) geri koyar; her geri alma bir değişiklik daha geriye gider. O değişiklikten sonra `config.plist`
   düzenlendiyse uyarır (geri koymak o düzenlemeleri siler). Yedekler kalır.

Her değişiklik önce planlanır ve planın SHA-256'sını taşır: okuduğunuz planla onayınız arasında EFI değiştiyse hiçbir
şey yazılmaz. `config.plist` bellekte düzenlenir, yerine konmadan önce yeniden okunup denetlenir; dosyaları
`SHA256SUMS` ile uyuşmayan (bozuk) bir paket reddedilir.

### Komut satırı

Komutlar yukarıdaki İngilizce bölümdekilerin aynısıdır (`-Status`, `-Plan settings|driver|undo`,
`-Apply settings|driver -Expect <SHA-256>`, `-Undo -Expect <SHA-256>`, `-ListEsp`, `-MountEsp`, `-UnmountEsp`,
`-Help`). `mountvol S: /S` Windows'un açıldığı EFI bölümünü bağlar; OpenCore başka bir diskteyse `-ListEsp` ve o
bölümün birimiyle `-MountEsp` kullanın.

### Deneme

Depodaki `windows/test/`: `Test-IntelXe-EFI.ps1` Windows'ta betiği, `efi/sample-z790/config.plist`'ten 1. aşama
hâline getirilmiş geçici bir EFI klasörüne karşı çalıştırır (yönetici hakkı gerekmez) ve yazdığı her `config.plist`'i
`efi.sh`'in sonucuyla (aynı anahtarlar ve değerler) ve çekirdeğin macOS'taki çıktısıyla (aynı metin) karşılaştırır:

```powershell
powershell -ExecutionPolicy Bypass -File windows\test\Test-IntelXe-EFI.ps1
pwsh -File windows\test\Test-IntelXe-EFI.ps1
```

`make-expected.sh` macOS'ta bu karşılaştırma dosyalarını `efi.sh` ile üretir ve betiğin çekirdeğini `dotnet` ile
derleyip onlara karşı dener.
