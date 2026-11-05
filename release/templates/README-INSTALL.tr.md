# intel-gpu-macos-driver @VER@: @MACOS@ için kurulum (Intel Arc B580)

[English](README-INSTALL.md)

@TESTED_TR@ Sürücü imzasız ve destek verilmiyor; üstelik bilgisayarınızın macOS'u nasıl açtığını değiştiriyor.
**Başlamadan önce çalışan bir OpenCore EFI'si olan bir USB bellek hazırlayın** ve anakartınızın önyükleme menüsünden o
belleği nasıl seçeceğinizi öğrenin. Yalnızca ticari olmayan kullanım içindir (`LICENSES/`).

Her şey yolunda giderse elinize şunlar geçer: masaüstü B580'de Metal ile çizilir (pencere sürüklemesi monitörün yenileme
hızında, 180 Hz'e kadar denendi), Metal uygulamaları ve oyunlar çalışır, H.264, HEVC, AV1 ve VP9 çözme ile H.264, HEVC ve
AV1 kodlama GPU'da yapılır. DisplayPort'tan tek monitör, VRR, uyku ve uyanma da çalışır.

Bilinen sorunlar:

- Safari'nin GPU süreci, Dock'un simge çizicisi ve NotificationCenter (masaüstü widget'ları) şimdilik macOS'un yazılımsal
  yolunda çalışıyor (`Library/GPUBundles/nvmtl-allow.txt`).
- İlk girişten sonraki ilk saniyelerde, shader'lar çevrilirken takılmalar oluyor.
- Yeniden başlatmadan sonra giriş ekranında açık gri bir bant görünüyor.
- Metal'i VideoToolbox kodlamasıyla başlatan ffmpeg benzeri araçlar, ilk oturumlarında kodlayıcılarımızı görmüyor.

Bu sürücünün eski bir sürümünü kullanıyorsanız doğrudan [Yükseltme](#yükseltme) bölümüne geçin.

## Neler gerekiyor?

- OpenCore'un macOS açabildiği bir bilgisayar (Intel işlemci, x86_64), Arc B580 ve **B580'in DisplayPort çıkışına bağlı tek
  monitör**. Dahili GPU gerekmiyor: test makinesinde macOS yalnızca B580'le kuruldu.
- USB belleği hazırlamak ve EFI'yi düzenlemek için Windows, Linux ya da macOS çalışan herhangi bir bilgisayar. Mac şart
  değil.
- Sürüm sayfasından iki dosya:

  | Dosya | İçinde ne var | Nerede açılmalı |
  |---|---|---|
  | `intel-gpu-macos-driver-@VER@-efi.zip` | OpenCore parçaları: `IntelXe.kext`, `SSDT-ARCOFF.aml` ve kaynağı | herhangi bir sistemde |
  | `intel-gpu-macos-driver-@VER@-@CODENAME@.zip` | geri kalan her şey ve `install.sh` | **bilgisayardaki macOS'ta** (3. aşama) |

  İkinci dosyayı yalnızca macOS'ta açın. Windows ve çoğu Linux arşiv aracı, çalıştırma izinlerini ve kurulum betiğinin
  kontrol ettiği kod imzalarını bozuyor.
- GPU dışındaki her şey için [Dortania'nın OpenCore rehberi](https://dortania.github.io/OpenCore-Install-Guide/): anakartınıza
  uygun EFI, ACPI tabloları, SMBIOS, USB haritası.
- Sisteminize uygun bir `config.plist` düzenleyicisi, örneğin [ProperTree](https://github.com/corpnewt/ProperTree) (Windows,
  Linux ve macOS'ta çalışır, Python ister).

## Aşamalar

| Aşama | Nerede yapılıyor | Ne yapılıyor | Sonrasında ekran |
|---|---|---|---|
| 1 | Windows, Linux ya da macOS, sonra kurulacak bilgisayar | macOS'u sürücüsüz, düz bir OpenCore EFI'siyle kurmak | B580'in UEFI çıktısı: hızlandırma yok, yavaş |
| 2 | `config.plist`, herhangi bir sistemden | SIP, AMFI, iki quirk ve bir çıktı ayarı | aynı |
| 3 | Bilgisayardaki macOS | `sudo ./install.sh --apply`, **henüz yeniden başlatmadan** | aynı |
| 4 | EFI, herhangi bir sistemden | `IntelXe.kext` ve `SSDT-ARCOFF.aml`, sonra yeniden başlatma | hızlandırmalı |

`IntelXe.kext` ve `SSDT-ARCOFF.aml`'yi 4. aşamadan önce EFI'ye koymayın. Bu tablo, kurulum ekranını gösteren genel ekran
sürücüsünden B580'i gizliyor; 3. aşamada sürücünün kendi ekran kext'i kurulana kadar onun yerini alacak bir şey yok.

Her aşamanın sonundaki durumda test makinesi çalıştı, ama bu dört aşama temiz bir kurulumda baştan sona hiç uygulanmadı.
Takıldığınız yeri bildirirseniz rehberi düzeltiriz.

## 1. macOS'u düz bir OpenCore EFI'siyle kurmak

1. **BIOS:** Above 4G Decoding **açık**, Resizable BAR **açık**, CSM **kapalı**. Gerisini Dortania'nın platformunuz için
   anlattığı gibi ayarlayın.
2. **USB kurulum belleği:** Elinizdeki sisteme göre Dortania'yı izleyin:
   - [Windows'ta](https://dortania.github.io/OpenCore-Install-Guide/installer-guide/windows-install.html) ya da
     [Linux'ta](https://dortania.github.io/OpenCore-Install-Guide/installer-guide/linux-install.html): ikisi de macOS
     recovery'yi `macrecovery.py` ile indiriyor, macOS'un kendisi de kurulum sırasında internetten iniyor. Bu yüzden
     bilgisayarın recovery'de çalışan bir ağ bağlantısı olmalı (doğru kext'le Ethernet ya da bir Wi-Fi kext'i).
   - [macOS'ta](https://dortania.github.io/OpenCore-Install-Guide/installer-guide/mac-install.html): tam kurulum dosyasıyla.
3. **EFI:** İşlemcinize ve anakartınıza göre Dortania'nın anlattığı gibi hazırlayın. Dortania'nın en yeni masaüstü sayfası
   [Comet Lake](https://dortania.github.io/OpenCore-Install-Guide/config.plist/comet-lake.html); Alder Lake ve Raptor Lake
   (12–14. nesil) için ayrı sayfası yok. Bu işlemcilerde o sayfayla birlikte
   [test makinesinin örnek yapılandırmasını](https://github.com/yusufklncc/intel-gpu-macos-driver/tree/main/efi/sample-z790)
   (Z790, i7-14700K) kullanın. Orada seri numaraları çıkarılmış `config.plist`, SSDT kaynakları, sürümleriyle kext listesi
   ve kurulum için neyin değiştirileceği var.

   Gereken araçlar Windows'ta da çalışıyor: [SSDTTime](https://github.com/corpnewt/SSDTTime) (anakartınızın DSDT'sinden
   SSDT'ler; DSDT'yi Windows ve Linux'ta alabilir), [USBToolBox](https://github.com/USBToolBox/tool) (USB haritası, Windows'ta)
   ve [GenSMBIOS](https://github.com/corpnewt/GenSMBIOS) (seri numaraları).

   B580'e özel bir şey eklemeyin: `DeviceProperties` ve WhateverGreen ayarı gerekmiyor. `UEFI > Output >
   ReconnectGraphicsOnConnect` ayarını `false` bırakın (nedeni 2. aşamada).
4. macOS'u kurup ilk açılış sihirbazını bitirin. Ekran, macOS'un genel ekran sürücüsüyle B580'in UEFI çıktısında (GOP) çalışır:
   tek çözünürlük, hızlandırma yok, her şey yavaş, uyku da henüz çalışmaz. Bu aşamada bu normal.

## 2. SIP, AMFI, quirk'ler ve konsol ayarı (`config.plist`)

EFI bölümü küçük bir FAT32 bölümü, her sistem bağlayabilir:

| Sistem | EFI bölümünü bağlamak |
|---|---|
| Windows | Yönetici olarak açılmış Komut İstemi'nde `mountvol S: /S`, ardından aynı pencereden ProperTree'yi başlatıp `S:\EFI\OC\config.plist` dosyasını açın; bitince `mountvol S: /D` |
| Linux | `lsblk -o NAME,FSTYPE,PARTTYPENAME` bölümü gösterir (`vfat`, tür "EFI System"), sonra kendi bölümünüzle `sudo mount /dev/nvme0n1p1 /mnt` |
| macOS | `diskutil list` bölümü gösterir (açılış diskinizdeki `EFI`), sonra kendi bölümünüzle `sudo diskutil mount disk0s1` |

`config.plist`'te:

1. `Booter > Quirks > ResizeAppleGpuBars = 10`. macOS, B580'in 16 GB'lık BAR'ını eşleyemiyor; bu ayar 1 GB'lık bir pencere
   açıyor.
2. `Kernel > Quirks > DisableIoMapper = true`.
3. `NVRAM > Add > 7C436110-AB2A-4BBB-A880-FE41995C9F82` altında:
   - `csr-active-config` = `03080000` (Data): imzasız kext'ler Yardımcı Kernel Koleksiyonu'ndan yüklenebilsin diye SIP
     gevşetiliyor;
   - `boot-args`'a `amfi_get_out_of_my_way=0x1` (yoksa WindowServer imzasız Metal sürücüsünü reddediyor) ve
     `intelxe_surfvram=2` (süreçler arasında VRAM'de paylaşılan IOSurface'ler) ekleyin.
4. `NVRAM > Delete > 7C436110-AB2A-4BBB-A880-FE41995C9F82` listesinde `csr-active-config` ve `boot-args` olmalı (Dortania'nın
   örnek yapılandırmasında var); yeni değerler eskilerin yerine böyle geçiyor.
5. `UEFI > Output > ReconnectGraphicsOnConnect = false`. Bu ayar `true` olursa OpenCore'un RELEASE sürümü, B580'in UEFI
   ekran sürücüsü (GOP) yeniden bağlanmadan konsolu kurmaya çalışıyor. macOS konsol ekranı olmadan açılıyor, Lilu başlatmasını
   tamamlayamıyor, VirtualSMC'nin SMC aygıtı bağlanmıyor ve `watchdogd` açılışın yaklaşık 20. saniyesinde panik veriyor.
   OpenCore'un DEBUG sürümü yavaş olduğu için bu sorunu gizliyor.
6. Yalnızca isteğe bağlı Safari WebGL kopyası için (3. aşama, 4. madde): `Misc > Security > SecureBootModel = Disabled`.

macOS'u yeniden başlatın. Ekran hâlâ UEFI çıktısında çalışır.

## 3. macOS tarafı (kurulacak bilgisayarda)

1. Paketi Terminal'den indirip açın. `curl` ile indirilen dosyalar "internetten indirildi" işareti taşımadığı için Gatekeeper
   onlara karışmaz:

   ```sh
   cd ~/Downloads
   curl -LO https://github.com/yusufklncc/intel-gpu-macos-driver/releases/download/v@VER@/intel-gpu-macos-driver-@VER@-@CODENAME@.zip
   ditto -x -k intel-gpu-macos-driver-@VER@-@CODENAME@.zip .
   cd intel-gpu-macos-driver-@VER@-@CODENAME@
   ```

   Tarayıcıyla indirdiyseniz çift tıklayıp açın, klasörde Terminal açın ve önce `xattr -dr com.apple.quarantine .` çalıştırın.
2. Önce kontrol edin, sonra kurun:

   ```sh
   ./install.sh                # yalnızca kontrol: macOS, SIP, AMFI, kart, sağlama toplamları, imzalar
   sudo ./install.sh --apply
   ```

   Bu aşamada kontrol, `IntelXe.kext`'in yüklü olmadığını söyler; o 4. aşamada geliyor. `--apply`, değiştirdiği her şeyi
   `/Library/Application Support/intel-gpu-macos-driver/backup-<tarih>/` altına yedekler, kext'leri ve Metal sürücüsünü
   `/Library`'ye kopyalar ve Yardımcı Kernel Koleksiyonu'nu yeniden oluşturur.
3. **Henüz yeniden başlatmayın:** önce 4. aşamayı yapın.
4. İsteğe bağlı, Safari WebGL. Safari'nin GPU süreci yalnızca sistem diskinden kod yükleyebiliyor.
   `system-volume/ssv-install.sh`, OpenCore Legacy Patcher'ın kök yamaları gibi Metal sürücüsünü oraya kopyalar ve yeni bir açılış
   anlık görüntüsü oluşturur. Başka hiçbir şey buna ihtiyaç duymuyor; zaten bu sürümde Safari'nin GPU süreci sürücüyü kullanmıyor
   (`nvmtl-allow.txt`). macOS güncellemesi bu kopyayı siler (`./ssv-install.sh --check` söyler).

   ```sh
   cd system-volume && ./ssv-install.sh          # yalnızca kontrol
   sudo ./ssv-install.sh --apply
   ```

## 4. IntelXe.kext ve SSDT-ARCOFF (EFI)

Dosyaları `intel-gpu-macos-driver-@VER@-efi.zip`'ten alın (macOS paketinde de `EFI/OC/` altında aynıları var). EFI bölümünü
2. aşamadaki gibi bağlayın; kurulacak bilgisayarda kendi bölümünüzle `sudo diskutil mount disk0s1`.

1. `IntelXe.kext`'i `EFI/OC/Kexts/` klasörüne kopyalayın ve `Kernel > Add` altına ekleyin: `BundlePath IntelXe.kext`,
   `ExecutablePath Contents/MacOS/IntelXe`, `PlistPath Contents/Info.plist`, `Enabled true`. GPU sürücüsü bu (GuC/HuC yazılımları
   içinde); Lilu istemiyor.
2. `SSDT-ARCOFF.aml`, kartı macOS'un genel ekran sürücüsünden gizliyor (Tahoe'da o sürücü kartı alırsa IntelXe kext'leri
   başlayamıyor). **ACPI yolu anakarta göre değişiyor.** Paketteki tablo, yuvanın kök portunu `\_SB.PC00.PEG1`, kartın kendi PCIe
   anahtarını da onun altında `PEGP` diye adlandıran bir anakart için. `PEGP`'nin altı her B580'de aynı: `PCI(0100)`'de bir alt
   port, `PCI(0000)`'da GPU. Kendi yolunuzu şöyle bulun:

   | Sistem | Nasıl |
   |---|---|
   | Windows | Aygıt Yöneticisi → Görüntü bağdaştırıcıları → B580 (Intel'in sürücüsü yoksa "Microsoft Temel Görüntü Bağdaştırıcısı") → Özellikler → Ayrıntılar → **Konum yolları**. `ACPI(...)` ile başlayan satır `ACPI(_SB_)#ACPI(PC00)#ACPI(PEG1)#ACPI(PEGP)#PCI(0100)#PCI(0000)` gibi görünür; bu `\_SB.PC00.PEG1.PEGP` demektir |
   | Linux | `lspci -nn \| grep e20b` GPU'yu verir (ör. `03:00.0`); `lspci -tv` kartın iki seviye üstündeki portu gösterir (ör. `01:00.0`); `cat /sys/bus/pci/devices/0000:01:00.0/firmware_node/path` ACPI yolunu yazar, ör. `\_SB_.PC00.PEG1.PEGP` |
   | macOS | [gfxutil](https://github.com/acidanthera/gfxutil/releases) bütün PCI aygıtlarını ACPI yollarıyla listeler: `8086:e20b` satırına bakın. IORegistryExplorer aynı adları IOService düzleminde gösterir (`PC00@0` → `PEG1@1` → `PEGP@0` → ...) |

   Yolunuz paketteki gibiyse (`\_SB.PC00.PEG1.PEGP`) `SSDT-ARCOFF.aml`'yi olduğu gibi kullanın. Değilse `SSDT-ARCOFF.dsl`'de yolun
   geçtiği iki yere (`External` ve `Scope` satırları) kendi yolunuzu yazıp `iasl SSDT-ARCOFF.dsl` ile derleyin. `iasl`, ACPICA'nın
   parçası: Windows'ta ACPICA'nın Windows araçları (acpica.org, Downloads), Linux'ta `acpica-tools` (ya da `iasl`) paketi, macOS'ta
   `brew install acpica` ya da [MaciASL](https://github.com/acidanthera/MaciASL/releases)'in içindeki `iasl`. Hiçbir `ACPI(...)`
   parçası kartın üst portunu adlandırmıyorsa (son `ACPI(...)` parçasından sonra iki değil üç `PCI(...)` geliyorsa) tabloya bir köprü
   seviyesi daha gerekiyor: Konum yolları satırınızla bir issue açın.
3. `.aml` dosyasını `EFI/OC/ACPI/` klasörüne kopyalayın ve `ACPI > Add` altına ekleyin (`Path SSDT-ARCOFF.aml`, `Enabled true`).
4. Yeniden başlatın. Masaüstü artık hızlandırmalı olmalı: saydamlık ve bulanıklık, akıcı pencere sürükleme, `Bu Mac Hakkında`'da
   12 GB'lık Arc B580. Terminal'de `kmutil showloaded | grep -i intelxe` `IntelXe` ve `IntelXeFB`'yi listeler, `sysctl
   debug.nmxaccelfb` de `1` yazar.

## Açılmazsa

- **Siyah ekran ya da sürekli yeniden başlama:** Çalışan EFI'nin olduğu USB bellekten açın ya da OpenCore'da macOS seçiliyken Shift'e
  basarak güvenli modda açın (Yardımcı Kernel Koleksiyonu'nu atlar). Sonra `sudo ./install.sh --undo` çalıştırın ve `IntelXe.kext` ile
  `SSDT-ARCOFF.aml`'yi EFI'den çıkarın.
- **Bir çökmeden sonra masaüstü hızlandırmasız:** Üst üste iki açılış, hızlandırmalı ilk dakikası içinde biterse (panik ya da güç
  düğmesine basılı tutmak) açılış koruması sonraki açılışlarda hızlandırmayı kapalı tutar. Tek bir böyle açılış yalnızca bir sonrakinin
  yeniden denemesine yol açar. Masaüstü yalnızca framebuffer ile çalışır, `sysctl
  debug.nmxaccelfb` `0` yazar, `ioreg -rc IntelXeFramebuffer -d1 | grep AccelHeld` da sebebini söyler. Sebep ortadan kalkınca
  hızlandırmayı açıp yeniden başlatın:

  ```sh
  sudo nvram intelxe-accel-off=ok
  ```

  (`sudo nvram -d intelxe-accel-off` macOS 26'da hata vermez ama değişkeni silmez; `=ok` her sürümde çalışır. 0.1.x kernel'inin log mesajı
  hâlâ `nvram -d` diyor; kaynak düzeltildi, bir sonraki kernel derlemesinde yeni metin gelecek.)
- **Açılışın yaklaşık 20. saniyesinde panik, `watchdogd ... exited`** (`/Library/Logs/DiagnosticReports/Kernel-*.panic` içinde `watchdogd`
  geçiyorsa): `UEFI > Output > ReconnectGraphicsOnConnect` `true` kalmıştır; `false` yapın (2. aşama, 5. madde).
- **Her şeyi geri almak:** `sudo ./install.sh --undo`, sonra `IntelXe.kext` ve `SSDT-ARCOFF.aml` EFI'den çıkarılmış olarak yeniden başlatın.
- **`install.sh`'nin diğer komutları:** `./install.sh --status` kurulu olanı bu paketle karşılaştırır, hiçbir şeyi değiştirmez.
  `sudo ./install.sh --repair` kurulu dosyalardan paketle uyuşmayanları yeniden kopyalar, son yedeğe dokunmaz. `sudo ./install.sh --uninstall`
  kext'leri ve Metal sürücüsünü `/Library`'den siler, yedekleri bırakır; `--undo` ise son kurulumun değiştirdiklerini geri getirir.
  `--uninstall`'dan sonra, yeniden başlatmadan önce `IntelXe.kext`'i EFI'den çıkarın.

## Yükseltme

**0.1.0 ya da 0.1.1'den:** Sürücü dosyaları 0.1.0, 0.1.1 ve 0.1.2'de aynı, yeniden kurmanız gerekmiyor. `config.plist`'te `UEFI > Output >
ReconnectGraphicsOnConnect = false` olduğunu kontrol edin (2. aşama, 5. madde), özellikle OpenCore'u RELEASE sürümüne geçirmeden önce.
Masaüstü widget'larının yeniden çizilmesi için `/Library/GPUBundles/nvmtl-allow.txt` dosyasına `-com.apple.dock.extra` satırının altına
`-NotificationCenter` ekleyin, sonra `killall NotificationCenter` çalıştırın. `install.sh --apply` bu dosyayı kendisi değiştirmiyor, çünkü
paketten farklı bir izin listesini olduğu gibi bırakıyor.

**0.1.0'dan önceki, B580 adlı özel derlemelerden:** Adı değişen kext'ler ve boot-arg'ların tablosu İngilizce rehberde (`README-INSTALL.md`,
"Upgrading from an earlier build").

## Paketin içindekiler

| Yol | Nereye gidiyor |
|---|---|
| `EFI/OC/Kexts/IntelXe.kext` | EFI, `Kernel > Add` (4. aşama); `-efi.zip`'tekiyle aynı dosya |
| `EFI/OC/ACPI/SSDT-ARCOFF.aml`, `.dsl` | EFI, `ACPI > Add`, yolu kontrol ettikten sonra (4. aşama) |
| `Library/Extensions/IntelXeFB.kext`, `NMXAccel.kext`, `NMXAGDC.kext` | `/Library/Extensions` (ekran, hızlandırıcı), `install.sh` ile |
| `Library/GPUBundles/NVMTLDriverLib.bundle`, `nvmtl/`, `nvmtl-allow.txt` | `/Library/GPUBundles` (Metal sürücüsü, Mesa, codec'ler), `install.sh` ile |
| `system-volume/` | isteğe bağlı: Metal sürücüsünün sistem diskindeki kopyası (Safari WebGL, 3. aşama, 4. madde) |
| `SHA256SUMS`, `sigcheck` | `install.sh`'nin yaptığı kontroller |
| `SOURCES.md`, `LICENSES/` | hangi kaynağın ve betiğin hangi dosyayı ürettiği; lisans metinleri |

## Sorun bildirmek

GitHub'da hata şablonuyla bir issue açın. Depodaki `tools/report/` logları toplar ve önce seri numaralarını, UUID'leri, MAC adreslerini ve
kullanıcı adlarını çıkarır. Lütfen ham sistem raporlarını paylaşmayın.
