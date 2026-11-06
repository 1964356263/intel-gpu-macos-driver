# intel-gpu-macos-driver 0.1.3: macOS 26 Tahoe için kurulum (Intel Arc B580)

[English](README-INSTALL.md)

Deneysel bir sürüm. Yalnızca tek makinede denendi: Z790 masaüstü, Arc B580, macOS 26.7.1, OpenCore. Sürücü imzasız ve destek verilmiyor; üstelik bilgisayarınızın macOS'u nasıl açtığını değiştiriyor.
**Başlamadan önce çalışan bir OpenCore EFI'si olan bir USB bellek hazırlayın** ve anakartınızın önyükleme menüsünden o
belleği nasıl seçeceğinizi öğrenin. Yalnızca ticari olmayan kullanım içindir (`LICENSES/`).

Her şey yolunda giderse elinize şunlar geçer: masaüstü B580'de Metal ile çizilir (pencere sürüklemesi monitörün yenileme
hızında, 180 Hz'e kadar denendi), masaüstü widget'ları, Metal uygulamaları ve oyunlar çalışır, Safari
GPU'da çalışır (sistem diski kopyasıyla, 3.3), H.264, HEVC, AV1 ve VP9 çözme ile H.264, HEVC ve AV1 kodlama GPU'da yapılır.
DisplayPort'tan tek monitör, VRR, uyku ve uyanma da çalışır. İsteğe bağlı olarak Minecraft Java gibi LWJGL oyunları
OpenGL'i Mesa'nın zink'iyle çalıştırabilir (`-zink-gl.zip`, aşağıda "İsteğe bağlı: zink ile OpenGL").

Bilinen sorunlar:

- Girişten sonraki ilk saniyeler sonrasına göre daha az akıcı (0.1.3'ten beri daha az: WindowServer derlenmiş
  shader'larını saklıyor; kurulumdan sonraki ilk giriş onları bir kez derliyor).
- Yeniden başlatmadan sonra giriş ekranında açık gri bir bant görünüyor.
- Metal'i VideoToolbox kodlamasıyla başlatan ffmpeg benzeri araçlar, ilk oturumlarında kodlayıcılarımızı görmüyor.
- Kartın 12 GB belleğinin yalnızca 1 GB'ını işlemci görebiliyor (macOS sınırı, 2. aşama 1. madde). Sürücü bu pencereyi
  ihtiyacı olanlara ayırıyor, arka plan süreçlerinin arabelleklerini sistem belleğine koyuyor; yine de GPU'yu yoğun
  kullanan çok sayıda açık uygulama pencereyi doldurabilir.

Bu sürücünün eski bir sürümünü kullanıyorsanız doğrudan [Yükseltme](#yükseltme) bölümüne geçin.

## Neler gerekiyor?

- OpenCore'un macOS açabildiği bir bilgisayar (Intel işlemci, x86_64), Arc B580 ve **B580'in DisplayPort çıkışına bağlı tek
  monitör**. Dahili GPU gerekmiyor: test makinesinde macOS yalnızca B580'le kuruldu.
- USB belleği hazırlamak ve EFI'yi düzenlemek için Windows, Linux ya da macOS çalışan herhangi bir bilgisayar. Mac şart
  değil.
- [Sürüm sayfasından](https://github.com/yusufklncc/intel-gpu-macos-driver/releases/tag/v0.1.3) dosyalar:

  | Dosya | İçinde ne var | Nerede açılmalı |
  |---|---|---|
  | `intel-gpu-macos-driver-0.1.3-efi.zip` | OpenCore parçaları: `IntelXe.kext`, `SSDT-ARCOFF.aml` ve kaynağı; Windows'ta 2. ve 4. aşamaları yapan `IntelXe-EFI.ps1` | herhangi bir sistemde |
  | `IntelXe-Manager-0.1.3.zip` | IntelXe Manager uygulaması: 3. ve 4. aşamalar (ve sonraki güncellemeler) Terminal yerine düğmelerle; sonraki dosyayı kendisi indirir | bilgisayardaki macOS'ta |
  | `intel-gpu-macos-driver-0.1.3-tahoe.zip` | geri kalan her şey, `install.sh` ve `efi.sh` ile | **bilgisayardaki macOS'ta** (3. aşama) |
  | `intel-gpu-macos-driver-0.1.3-zink-gl.zip` | isteğe bağlı: LWJGL oyunları için zink ile OpenGL | bilgisayardaki macOS'ta, 4. aşamadan sonra |

  macOS dosyalarını yalnızca macOS'ta açın. Windows ve çoğu Linux arşiv aracı, çalıştırma izinlerini ve kurulum betiğinin
  kontrol ettiği kod imzalarını bozuyor. Sürüm sayfasındaki `.sha256` dosyası sağlama toplamlarını listeliyor.
- GPU dışındaki her şey için [Dortania'nın OpenCore rehberi](https://dortania.github.io/OpenCore-Install-Guide/): anakartınıza
  uygun EFI, ACPI tabloları, SMBIOS, USB haritası.
- Sisteminize uygun bir `config.plist` düzenleyicisi, örneğin [ProperTree](https://github.com/corpnewt/ProperTree) (Windows,
  Linux ve macOS'ta çalışır, Python ister).

## Aşamalar

| Aşama | Nerede yapılıyor | Ne yapılıyor | Sonrasında ekran |
|---|---|---|---|
| 1 | Windows, Linux ya da macOS, sonra kurulacak bilgisayar | macOS'u sürücüsüz, düz bir OpenCore EFI'siyle kurmak | B580'in UEFI çıktısı: hızlandırma yok, yavaş |
| 2 | `config.plist`, herhangi bir sistemden | SIP, AMFI, iki quirk ve bir çıktı ayarı | aynı |
| 3 | Bilgisayardaki macOS | uygulamada **Bu paketi kur** ya da `sudo ./install.sh --apply`; **henüz yeniden başlatmadan** | aynı |
| 4 | EFI, bilgisayardaki macOS'tan ya da herhangi bir sistemden | `IntelXe.kext` ve `SSDT-ARCOFF.aml` (uygulamanın EFI sayfası, `efi.sh`, `IntelXe-EFI.ps1` ya da elle), sonra yeniden başlatma | hızlandırmalı |

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

   B580'e özel bir şey eklemeyin: `DeviceProperties` ve WhateverGreen ayarı gerekmiyor. B580 için iki ayar şimdiden:
   `UEFI > Output > ReconnectGraphicsOnConnect` ayarını `false` bırakın (Dortania'nın örneğinde öyle) ve
   `Booter > Quirks > ResizeAppleGpuBars = 10` yapın (Dortania'da varsayılan `-1`). Test makinesi macOS'u ikisiyle
   kurdu; `-1` ve açık Resizable BAR ile B580'de kurulum denenmedi. İkisinin nedeni 2. aşamada.
4. macOS'u kurup ilk açılış sihirbazını bitirin. Ekran, macOS'un genel ekran sürücüsüyle B580'in UEFI çıktısında (GOP) çalışır:
   tek çözünürlük, hızlandırma yok, her şey yavaş, uyku da henüz çalışmaz. Bu aşamada bu normal.

## 2. SIP, AMFI, quirk'ler ve konsol ayarı (`config.plist`)

EFI bölümü küçük bir FAT32 bölümü, her sistem bağlayabilir:

| Sistem | EFI bölümünü bağlamak |
|---|---|
| Windows | Yönetici olarak açılmış Komut İstemi'nde `mountvol S: /S`, ardından aynı pencereden ProperTree'yi başlatıp `S:\EFI\OC\config.plist` dosyasını açın; bitince `mountvol S: /D` |
| Linux | `lsblk -o NAME,FSTYPE,PARTTYPENAME` bölümü gösterir (`vfat`, tür "EFI System"), sonra kendi bölümünüzle `sudo mount /dev/nvme0n1p1 /mnt` |
| macOS | `diskutil list` bölümü gösterir (açılış diskinizdeki `EFI`), sonra kendi bölümünüzle `sudo diskutil mount disk0s1` |

**Windows'ta** `-efi.zip`'teki `IntelXe-EFI.ps1` 1-5. maddeleri seçtiğiniz EFI klasöründe (bir USB belleğinkinde ya da
bağlayabildiği EFI bölümünde) sizin yerinize yapar: sağ tık > PowerShell ile Çalıştır, *Settings: plan*, ardından
*Settings: apply*. Önce EFI klasörünün tamamını yedekler, `config.plist`'in geri kalanını olduğu gibi bırakır ve
değişikliği geri alabilir; zip'teki `README-Windows.md`'ye bakın. Deneme takımı Windows'ta hatasız geçiyor; pencerenin
kendisi henüz ardından bir bilgisayarın açıldığı bir EFI'de kullanılmadı. **Bilgisayardaki macOS'ta** IntelXe Manager
uygulamasının EFI sayfası (*Bu ayarları değiştir*) ya da macOS paketindeki `sudo ./efi.sh --settings-apply` aynı
değişiklikleri OpenCore'un açıldığı EFI'de yapar (bkz. 3.1).

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
6. Sistem diski kopyası için (GPU'da Safari, 3.3): `Misc > Security > SecureBootModel = Disabled`.

macOS'u yeniden başlatın. Ekran hâlâ UEFI çıktısında çalışır.

## 3. macOS tarafı (kurulacak bilgisayarda)

### 3.1 IntelXe Manager uygulamasıyla

Uygulama 3. ve 4. aşamaları bilgisayarda düğmelerle yapar ve her adımın neyi değiştireceğini parolanızı sormadan önce
gösterir. İşi paketteki `install.sh` ve `efi.sh` yapıyor; yani 3.2'deki Terminal adımlarıyla aynı şey.

1. `IntelXe-Manager-0.1.3.zip`'i Terminal'den indirin ("internetten indirildi" işareti bırakmaz) ve Uygulamalar
   klasörünüze açın:

   ```sh
   cd ~/Downloads
   curl -LO https://github.com/yusufklncc/intel-gpu-macos-driver/releases/download/v0.1.3/IntelXe-Manager-0.1.3.zip
   mkdir -p ~/Applications && ditto -x -k IntelXe-Manager-0.1.3.zip ~/Applications
   open ~/Applications/"IntelXe Manager.app"
   ```

   Uygulama bir Apple geliştirici kimliğiyle değil, ad hoc imzalı. Tarayıcıyla indirdiyseniz macOS açmayı reddeder; o
   zaman `xattr -dr com.apple.quarantine ~/Applications/"IntelXe Manager.app"` çalıştırın ya da bir kez açmayı deneyip
   Sistem Ayarları > Gizlilik ve Güvenlik'te izin verin (*Yine de Aç*).
2. **Sistem** sürücünün neye ihtiyaç duyduğunu (macOS, SIP, AMFI boot-arg'ı, kart) ve neyin kurulu olduğunu gösterir.
3. **Sürücü:** *v0.1.3 sürümünü indir* macOS'unuza uygun paketi indirir ve sürümün sağlama listesiyle karşılaştırır. EFI
   sayfası da dosyalarını bu paketten alır.
4. 2. aşamayı henüz yapmadınız mı? Kurulum ona ihtiyaç duyuyor (SIP gevşetilmeden ve AMFI boot-arg'ı olmadan çalışmayı
   reddediyor): **EFI (OpenCore)** sayfasında OpenCore'un açıldığı EFI bölümünü seçin (ya da *Bir EFI klasörü kullan…*),
   "Ayarlar (2. aşama)" altında *Bu ayarları değiştir*'e basın, yeniden başlatın ve uygulamayı yeniden açın.
5. **Sürücü:** *Bu paketi kur* (`sudo ./install.sh --apply` ile aynı). **Henüz yeniden başlatmayın.**
6. **EFI (OpenCore):** "IntelXe.kext ve SSDT-ARCOFF (4. aşama)" altında *Bu değişiklikleri yap*; neyi değiştirdiği
   aşağıda 4. aşamada anlatılıyor. Her EFI değişikliği önce değişiklik listesini gösterip sorar. Sonra yeniden başlatın.

Uygulama ayrıca sürücüyü onarır, geri alır, kaldırır, isteğe bağlı zink paketini kurar ve sonraki sürümleri eskisinin
üzerine kurar. Yalnızca GitHub'a bağlanır, veri göndermez. Safari için sistem diski kopyası (3.3) uygulamada yok:
uygulamanın indirdiği paketin `system-volume` klasöründe Terminal'den iki komut (Sürücü sayfası klasörü gösteriyor).
Sürücü sayfası test makinesinde kullanıldı; EFI sayfası da orada SSD'nin EFI'sinde kullanıldı. Gerçek bir EFI'de
*Undo* ve temiz bir macOS'tan baştan sona uygulamayla kurulum henüz denenmedi. Arayüz sistem diline göre İngilizce ya
da Türkçe; buradaki adlar Türkçe arayüzdeki adlar.

### 3.2 Terminal'de

1. Paketi Terminal'den indirip açın. `curl` ile indirilen dosyalar "internetten indirildi" işareti taşımadığı için Gatekeeper
   onlara karışmaz:

   ```sh
   cd ~/Downloads
   curl -LO https://github.com/yusufklncc/intel-gpu-macos-driver/releases/download/v0.1.3/intel-gpu-macos-driver-0.1.3-tahoe.zip
   ditto -x -k intel-gpu-macos-driver-0.1.3-tahoe.zip .
   cd intel-gpu-macos-driver-0.1.3-tahoe
   ```

   Tarayıcıyla indirdiyseniz çift tıklayıp açın, klasörde Terminal açın ve önce `xattr -dr com.apple.quarantine .` çalıştırın.
2. Önce kontrol edin, sonra kurun:

   ```sh
   ./install.sh                # yalnızca kontrol: macOS, SIP, AMFI, kart, sağlama toplamları, imzalar
   sudo ./install.sh --apply
   ```

   Bu aşamada kontrol, `IntelXe.kext`'in yüklü olmadığını söyler; o 4. aşamada geliyor. `--apply`, değiştirdiği her şeyi
   `/Library/Application Support/intel-gpu-macos-driver/backup-<tarih>/` altına yedekler, kext'leri ve Metal sürücüsünü
   `/Library`'ye kopyalar, açılış korumasının LaunchDaemon'ını kurar (bkz. [Açılmazsa](#açılmazsa)) ve Yardımcı Kernel
   Koleksiyonu'nu yeniden oluşturur.
3. **Henüz yeniden başlatmayın:** önce 4. aşamayı yapın.

### 3.3 Safari için önerilir: sistem diski kopyası

Safari'nin GPU süreci yalnızca sistem diskinden kod yükleyebiliyor. Bu kopya olmadan Safari macOS'un yazılımsal yolunda
çalışır: daha yavaştır ve CSS renk filtresi olan bazı sayfa öğeleri çizilmez (Metal aygıtı yokken CoreGraphics'te
görülen bir sorun; Safari > Ayarlar > Özellik Bayrakları'nda *GraphicsContext Filter Rendering* kapatılınca düzelir,
bu sekme Gelişmiş > *Web geliştiricileri için özellikleri göster* açılınca görünür).
`system-volume/ssv-install.sh`, OpenCore Legacy Patcher'ın kök yamaları gibi Metal sürücüsünü oraya kopyalar ve yeni bir
açılış anlık görüntüsü oluşturur. `Misc > Security > SecureBootModel = Disabled` gerekir (2. aşama, 6. madde). Başka
hiçbir şey buna ihtiyaç duymuyor. macOS güncellemesi bu kopyayı siler (`./ssv-install.sh --check` söyler; yeniden
kurun). macOS 26.7.1'de denendi: Safari B580'de çalışıyor ve sayfaları filtreler dahil doğru çiziliyor. Safari'nin GPU
süreci sandbox yüzünden çevrilmiş shader'ları açılışlar arasında saklayamıyor; bu yüzden her açılıştan sonraki ilk
sayfalar birkaç saniye bekletir.

```sh
cd system-volume && ./ssv-install.sh          # yalnızca kontrol
sudo ./ssv-install.sh --apply
```

## 4. IntelXe.kext ve SSDT-ARCOFF (EFI)

Dosyaları `intel-gpu-macos-driver-0.1.3-efi.zip`'ten alın (macOS paketinde de `EFI/OC/` altında aynıları var). EFI bölümünü
2. aşamadaki gibi bağlayın; kurulacak bilgisayarda kendi bölümünüzle `sudo diskutil mount disk0s1`.

Kurulacak bilgisayarın kendisinde, macOS paketindeki `efi.sh` 1-3. maddeleri (ve 2. aşamanın ayarlarını) sizin yerinize
yapar: OpenCore'un açıldığı EFI'yi bulur, EFI klasörünün tamamını yedekler, dosyaları kopyalar, `config.plist` kayıtlarını
açar; `SSDT-ARCOFF.aml`'ı yalnızca ACPI yolu kartınızınkiyle aynıysa ekler. `./efi.sh --plan` değişiklikleri gösterir,
`sudo ./efi.sh --apply` yapar, `sudo ./efi.sh --undo` geri alır; `--settings-plan` / `--settings-apply` 2. aşamayı yapar.
Bütün seçenekler için yalnızca `./efi.sh`. IntelXe Manager uygulamasının EFI sayfası da aynısını yapar.

**Windows'ta** `-efi.zip`'teki `IntelXe-EFI.ps1` 1. ve 3. maddeleri (*Driver: plan*, *Driver: apply*) seçtiğiniz EFI
klasöründe, yedek ve geri alma ile yapar. Windows, ACPI yolunu `efi.sh`'in macOS'ta yaptığı gibi denetleyemez; bu
yüzden `SSDT-ARCOFF.aml`'ı yalnızca kutusunu işaretleyip 2. maddedeki kart yolunuzu yazdığınızda ekler (Windows kartın
takılı olduğu bilgisayarda çalışıyorsa yolu Aygıt Yöneticisi'nden okur). Zip'teki `README-Windows.md`'ye bakın.

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

## İsteğe bağlı: zink ile OpenGL

macOS'un kendi OpenGL'i Metal'in üzerinde çalışıyor ve bu sürücüde yavaş. LWJGL 3 Java oyunları (Minecraft Java 1.13 ve
sonrası) bunun yerine Mesa'nın zink'ini kullanabilir: zink OpenGL'i doğrudan sürücünün Vulkan'ına çeviriyor. Yalnızca
OpenGL'i GLFW/LWJGL ile açan uygulamalar kullanır; geri kalan her şey Apple'ın OpenGL'inde kalır. Sürücünün kurulu ve
`intelxe_surfvram=2` ayarının açık olması gerekiyor (2. aşama). IntelXe Manager'ın **OpenGL (Zink)** sayfası kurar ve
açar; ya da Terminal'de:

```sh
cd ~/Downloads
curl -LO https://github.com/yusufklncc/intel-gpu-macos-driver/releases/download/v0.1.3/intel-gpu-macos-driver-0.1.3-zink-gl.zip
ditto -x -k intel-gpu-macos-driver-0.1.3-zink-gl.zip .
cd intel-gpu-macos-driver-0.1.3-zink-gl
sudo ./install.sh                # /Library/IntelXe/GL ve Vulkan yükleyicisi; değiştirdiğini yedekler
./install.sh --test              # B580'de zink üzerinden bir GL bağlamı
sudo ./install.sh --global on    # bundan sonra açılan bütün LWJGL 3 uygulamaları zink kullanır
```

`--global off` geri alır, `--undo` kaldırır; ayrıntılar zip'teki `README.md`'de. Test makinesinde ölçüldü (macOS 26.7.1,
Minecraft 1.21.1, Sodium ve Iris ile, pencereli, aynı nokta): BSL shader paketiyle zink'te 197–205 fps, aynı bilgisayarda
Windows'ta Intel'in sürücüsüyle 214–218; shader paketi olmadan zink'te
1400–1500 fps, Windows'ta 700–1000. macOS'un girişte kendiliğinden
yeniden açtığı bir başlatıcı, ayar yerine oturmadan başlayıp Apple'ın OpenGL'inde kalabilir: kapatıp yeniden açın
(zink açıkken Java "Picked up JAVA_TOOL_OPTIONS" yazar).

## İsteğe bağlı: HiDPI modları (ekran ölçeklendirme)

Windows'taki ekran ölçeklendirmesi gibi: Sistem Ayarları > Ekranlar, yazıyı ve pencereleri daha büyük ama keskin çizen
"gibi görünür" boyutlar sunar (Daha Büyük Metin ... Daha Fazla Alan). 2560x1440 bir monitörde bunlar 2048x1152,
1920x1080, 1706x960, 1600x900 ve 1280x720. Monitörün tam yenileme hızında çalışırlar (test monitöründe 180 Hz ve
Değişken): macOS iki katı boyutta çizer, GPU her kareyi panelin boyutuna küçültür. Açılmadıkça kapalıdırlar. IntelXe
Manager'ın **Ekran** sayfası açıp kapatır; ya da Terminal'de, paket klasöründe:

```sh
./hidpi.sh               # şu an ne ayarlı
sudo ./hidpi.sh --on     # NVRAM intelxefb-hidpi=1, HiDPI boyutlarıyla bir ekran ayarı, DisplayResolutionEnabled
sudo ./hidpi.sh --off    # yalnızca --on'un yazdıklarını geri alır
```

İkisinden sonra da yeniden başlatın, sonra Sistem Ayarları > Ekranlar'dan bir boyut seçin. Ekran ayarı, diğer HiDPI
araçlarının kullandığı yere yazılır (`/Library/Displays/Contents/Resources/Overrides`); monitörünüz için başka bir
aracın (one-key-hidpi vb.) yazdığı bir ayar zaten varsa `hidpi.sh` ona dokunmaz ve durur: önce onu kaldırın. Bir boyut
ekranı siyah bırakırsa SSH'tan `sudo ./hidpi.sh --off` çalıştırıp yeniden başlatın; OpenCore menüsündeki **Reset NVRAM**
de modları kapatır (anahtar NVRAM değişkenidir).

## Açılmazsa

- **Siyah ekran ya da sürekli yeniden başlama:** Çalışan EFI'nin olduğu USB bellekten açın ya da OpenCore'da macOS seçiliyken Shift'e
  basarak güvenli modda açın (Yardımcı Kernel Koleksiyonu'nu atlar). Sonra `sudo ./install.sh --undo` çalıştırın ve `IntelXe.kext` ile
  `SSDT-ARCOFF.aml`'yi EFI'den çıkarın.
- **İlk dakikada çökmeler (açılış koruması):** Hızlandırmalı ilk dakikası içinde biten tek bir açılış (panik ya da güç düğmesine
  basılı tutmak) yalnızca bir sonrakinin yeniden denemesine yol açar. Üst üste iki taneden sonra sonraki açılışlar en güvenli ayarlarla
  hızlandırır (async ve flip kapalı; `ioreg -rc IntelXeFramebuffer -d1 | grep AccelSafe` `Yes` der); bir dakika sorunsuz çalışan bir
  açılıştan sonra koruma normale döner. Üst üste dört taneden sonra hızlandırma kapatılır ve **macOS 26'da monitör Apple logosunda
  kalır** (macOS çalışıyordur: WindowServer hızlandırma olmadan ekran kullanmıyor; B580'de denendi). Çıkmak için: yeniden başlatın ve
  OpenCore seçim ekranında **Reset NVRAM**'i seçin (gizliyse Boşluk tuşu). Bu korumayı temizler; OpenCore kendi boot-args ve SIP
  ayarını her açılışta yeniden yazar (B580'de denendi). Ya da başka bir bilgisayardan SSH ile (Uzaktan Giriş önceden açılmış olmalı)
  hızlandırmayı açıp yeniden başlatın:

  ```sh
  sudo nvram intelxe-accel-off=ok
  ```

  (`sudo nvram -d intelxe-accel-off` macOS 26'da hata vermez ama değişkeni silmez; `=ok` her sürümde çalışır. 0.1.0 ve
  0.1.1'in kernel log mesajı hâlâ `nvram -d` diyordu.) Koruma kurulmuş ama masaüstü çalışıyorsa, IntelXe Manager'ın
  Sistem sayfasındaki *Açılış korumasını sıfırla* düğmesi de korumayı temizler.
- **Açılışın yaklaşık 20. saniyesinde panik, `watchdogd ... exited`** (`/Library/Logs/DiagnosticReports/Kernel-*.panic` içinde `watchdogd`
  geçiyorsa): `UEFI > Output > ReconnectGraphicsOnConnect` `true` kalmıştır; `false` yapın (2. aşama, 5. madde).
- **Her şeyi geri almak:** `sudo ./install.sh --undo`, sonra `IntelXe.kext` ve `SSDT-ARCOFF.aml` EFI'den çıkarılmış olarak yeniden başlatın.
- **`install.sh`'nin diğer komutları:** `./install.sh --status` kurulu olanı bu paketle karşılaştırır, hiçbir şeyi değiştirmez.
  `sudo ./install.sh --repair` kurulu dosyalardan paketle uyuşmayanları yeniden kopyalar, son yedeğe dokunmaz. `sudo ./install.sh --uninstall`
  kext'leri ve Metal sürücüsünü `/Library`'den siler, yedekleri bırakır; `--undo` ise son kurulumun değiştirdiklerini geri getirir.
  `--uninstall`'dan sonra, yeniden başlatmadan önce `IntelXe.kext`'i EFI'den çıkarın.

## Yükseltme

**0.1.2'den:** `IntelXeFB.kext`, `NMXAGDC.kext`, video çözücü ve Mesa'nın Vulkan sürücüsü yeni (firmware'inkinden
yüksek tazeleme hızları, varsayılan olarak açık Adaptive-Sync modları, isteğe bağlı HiDPI modları, tam aralıklı videonun
tam aralıklı çözülmesi, WindowServer'ın derlenmiş shader'larını saklaması). Paketi kurun (uygulamada *v0.1.3 sürümünü
indir*, sonra *Bu paketi kur*; ya da `sudo ./install.sh --apply`) ve yeniden başlatın. EFI'deki `IntelXe.kext` ve Metal
eklentisi 0.1.2'ninkiler; oldukları gibi kalırlar. Sistem diski kopyasını kurduysanız (3.3) bu paketinkini de kurun
(`sudo ./system-volume/ssv-install.sh --apply`), sonra `install.sh --apply`'ın, kopya eski Mesa'yı taşıdığı için
oluşturduğu `/Library/GPUBundles/NVMTLDriver.use-library` dosyasını silin (`sudo rm ...`) ve yeniden başlatın.

**0.1.0 ya da 0.1.1'den:** Bütün kext'ler, Metal sürücüsü ve video kütüphaneleri yeni, **EFI'deki `IntelXe.kext` de**
(bir güvenlik açığını kapatıyor: yetkisiz bir süreç yalnızca okuyabileceği sayfalara yazılabilir GPU eşlemesi
alabiliyordu). Paketi kurun (uygulamada *v0.1.3 sürümünü indir*, sonra *Bu paketi kur*; ya da
`sudo ./install.sh --apply`), sonra yeniden başlatmadan önce EFI'deki `IntelXe.kext`'i değiştirin (macOS'ta uygulamanın
EFI sayfası ya da `sudo ./efi.sh --apply`, Windows'ta `IntelXe-EFI.ps1`, ya da elle kopyalayın; `config.plist` kaydı
olduğu gibi kalır).
`--apply` açılış korumasının LaunchDaemon'ını da kurar ve 0.1.0 ile 0.1.1'in izin listesini (0.1.1 rehberinin istediği
`-NotificationCenter` satırıyla ya da satırsız) değiştirir; böylece Safari'nin GPU süreci, Dock simgeleri ve masaüstü
widget'ları yeniden sürücüyü kullanır. Başka bir biçimde değiştirdiğiniz izin listesi korunur: paketteki
`Library/GPUBundles/nvmtl-allow.txt` ile karşılaştırın. Sistem diski kopyasını kurduysanız `--apply`, bu paketinkini
(3.3) kurup `/Library/GPUBundles/NVMTLDriver.use-library` dosyasını silene kadar bütün süreçlere `/Library` kopyasını
kullandırır. `config.plist`'te `UEFI > Output > ReconnectGraphicsOnConnect = false` olduğunu kontrol edin (2. aşama,
5. madde), özellikle OpenCore'u RELEASE sürümüne geçirmeden önce.

**0.1.0'dan önceki, B580 adlı özel derlemelerden:** Adı değişen kext'ler ve boot-arg'ların tablosu İngilizce rehberde (`README-INSTALL.md`,
"Upgrading from an earlier build").

## Paketin içindekiler

| Yol | Nereye gidiyor |
|---|---|
| `EFI/OC/Kexts/IntelXe.kext` | EFI, `Kernel > Add` (4. aşama); `-efi.zip`'tekiyle aynı dosya |
| `EFI/OC/ACPI/SSDT-ARCOFF.aml`, `.dsl` | EFI, `ACPI > Add`, yolu kontrol ettikten sonra (4. aşama) |
| `Library/Extensions/IntelXeFB.kext`, `NMXAccel.kext`, `NMXAGDC.kext` | `/Library/Extensions` (ekran, hızlandırıcı), `install.sh` ile |
| `Library/GPUBundles/NVMTLDriverLib.bundle`, `nvmtl/`, `nvmtl-allow.txt` | `/Library/GPUBundles` (Metal sürücüsü, Mesa, codec'ler), `install.sh` ile |
| (`install.sh` oluşturur) | `/Library/LaunchDaemons/io.github.yusufklncc.intelxe.guard.plist`: bir açılış bir dakika çalışınca açılış korumasını temizler |
| `system-volume/` | isteğe bağlı: Metal sürücüsünün sistem diskindeki kopyası (GPU'da Safari, 3.3) |
| `efi.sh` | isteğe bağlı, macOS'ta: OpenCore'un açıldığı EFI'de 2. ve 4. aşamalar, yedek ve geri alma ile |
| `hidpi.sh` | isteğe bağlı: monitör için HiDPI modları (ekran ölçeklendirme), açma ve kapama |
| `SHA256SUMS`, `sigcheck` | `install.sh`'nin yaptığı kontroller |
| `SOURCES.md`, `LICENSES/` | hangi kaynağın ve betiğin hangi dosyayı ürettiği; lisans metinleri |

## Sorun bildirmek

GitHub'da hata şablonuyla bir issue açın. Depodaki `tools/report/` logları toplar ve önce seri numaralarını, UUID'leri, MAC adreslerini ve
kullanıcı adlarını çıkarır. Lütfen ham sistem raporlarını paylaşmayın.
