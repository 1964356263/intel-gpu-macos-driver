# intel-gpu-macos-driver

[English](README.md) · **Türkçe**

> [!NOTE]
> **Yapay zekâ ile geliştirildi.** Bu proje yapay zekâ yardımıyla geliştiriliyor. Bu depodaki kod (çekirdek sürücüsü,
> nullmoth ve Mesa'ya yapılan değişiklikler, araçlar ve belgeler) Anthropic'in **Claude Opus 5.5** modeli tarafından
> **High** çaba seviyesinde, projenin sahibinin yönlendirmesiyle yazıldı; her derleme gerçek donanımda onun tarafından
> test ediliyor. Üzerine kurulduğu üçüncü taraf kodlar (nullmoth, Mesa, Linux, FFmpeg) kendi yazarlarına aittir.

**Intel Arc ekran kartlarını macOS'ta çalıştıran bir Metal sürücüsü.** Kartı Linux'taki `xe` sürücüsünün yaptığı gibi
ayağa kaldırıyor, üzerinde Mesa'nın Vulkan sürücüsünü (ANV) çalıştırıyor ve Metal'i Vulkan'ın üzerine kuruyor. Böylece
masaüstü (WindowServer), Metal uygulamaları ve oyunlar, VideoToolbox video işleri Intel kartta çalışıyor. Bugün
**Arc B580** ile **macOS 26 Tahoe**'da çalışıyor (x86_64, OpenCore).

<p align="center">
  <img src="docs/images/about-this-mac.png" width="27%" alt="Bu Mac Hakkında: Intel Arc B580, 12 GB">
  <img src="docs/images/desktop.png" width="71%" alt="Arc B580'de çizilen macOS masaüstü">
</p>

| | Arc B580'de (macOS 26.7.1) |
|---|---|
| Masaüstü | GPU'da çiziliyor; 180 Hz monitörde pencere sürüklerken 165 fps, VRR |
| Geekbench 7 | Metal **92 898** · OpenCL **86 920** (aynı kartın Windows'taki Vulkan / OpenCL skorlarının %80–84'ü) |
| Video | H.264 / HEVC / AV1 / VP9 çözme bit bit doğru ve 4K'ya kadar Windows'tan hızlı; H.264 / HEVC / AV1 kodlama |
| Vulkan uyumluluk testi | 3,15 milyon vaka, hiç takılmadan: 1,77 milyonu geçti, 84'ü başarısız |

> [!WARNING]
> **Deneysel bir proje.** Tek bir kart destekleniyor ve tek bir makinede test edildi. Kurmak için sistem güvenliğinin
> gevşetilmesi gerekiyor (SIP ve AMFI ayarları, imzasız kext'ler); hatalı bir derleme Mac'in açılmasını engelleyebilir.
> Denemeden önce çalışan bir OpenCore EFI'sini USB bellekte hazır tutun. Sürüm paketleri imzasızdır ve destek verilmez.

## Benim Mac'imde çalışır mı?

| | Desteklenen | Not |
|---|---|---|
| Ekran kartı | Intel Arc **B580** (8086:E20B) | Diğer Intel kartları için [Projenin durumu](#projenin-durumu) bölümüne bakın; bir kart gerçekten çalışmadan onun için hiçbir şey iddia etmiyoruz. |
| macOS | **26 Tahoe** (26.7.1'de test edildi); 15 Sequoia (aynı kaynaktan derlendi, Tahoe'ya geçtikten sonra yeniden denenmedi) | Yalnızca x86_64 |
| Bilgisayar | OpenCore ile çalışan bir PC (test edilen: Z790, i7-14700K) | Above 4G Decoding ve Resizable BAR açık olmalı |
| Monitör | B580'e DisplayPort ile bağlı tek monitör | İkinci monitör henüz desteklenmiyor |
| Apple Silicon | Hayır | Apple Silicon Mac'lere PCIe ekran kartı takılamıyor |

## Kurulum

Hazırlığın tamamını Windows, Linux ya da macOS'tan yapabilirsiniz; elinizde bir Mac olması gerekmiyor. Ayrıntılı
rehber [`release/README-INSTALL.md`](release/README-INSTALL.md)'de (İngilizce, her pakette de var). Kısaca:

1. macOS'u sürücüsüz, düz bir OpenCore EFI'siyle kurun ([Dortania rehberi](https://dortania.github.io/OpenCore-Install-Guide/);
   test makinesinin seri numaraları çıkarılmış yapılandırması [`efi/sample-z790/`](efi/sample-z790/) klasöründe).
   Kurulum ekranı B580'in kendi UEFI çıktısıyla, hızlandırmasız gelir; dahili GPU gerekmez.
2. `config.plist`'te SIP'i, AMFI boot-arg'ını, iki quirk'ü ve `ReconnectGraphicsOnConnect = false` ayarını yapın
   (bu ayar açık kalırsa OpenCore'un RELEASE sürümü açılışta panik veriyor).
3. macOS'ta [Releases](../../releases) sayfasından sürümünüze uygun paketi indirip `sudo ./install.sh --apply`
   çalıştırın. Betik önce sisteminizi kontrol eder, değiştirdiği her şeyin yedeğini alır; `--undo` ile geri alınır.
4. EFI'ye `-efi.zip`'teki `IntelXe.kext`'i ve anakartınızın yoluna göre uyarlanmış ACPI tablosunu ekleyin, sonra
   monitör B580'e bağlıyken yeniden başlatın.

Her şeyi kendiniz derlemek isterseniz: [Kaynaktan derleme](#kaynaktan-derleme).

## Neler çalışıyor?

- **Masaüstü:** WindowServer GPU'da çiziyor ve kareler gerçekten ekrana çevriliyor. Saydamlık, bulanıklık ve
  animasyonlar hızlandırılmış. DisplayPort üzerinden tek monitör; bütün çözünürlük ve tazeleme seçenekleri, VRR,
  donanım imleci, uyku ve uyanma.
- **Metal:** Uygulamalar, Chrome ve oyunlar. Mesa'nın `intel-rt` desteğiyle ışın izleme dahil Metal 3 özellikleri
  (hızlandırma yapıları, ışın sorguları, eğriler). Çevrilen shader'lar diske kaydediliyor; yeniden başlatmada ve sürücü
  güncellemesinde kaybolmuyor.
- **OpenGL ve OpenCL:** varsayılan olarak Apple'ın Metal üzerinde çalışan GL ve OpenCL'i ile. OpenGL, bağlamını
  GLFW/EGL ile açan uygulamalarda (Minecraft gibi LWJGL 3 oyunları) Mesa'nın Zink'iyle de çalışıyor; bu isteğe bağlı
  bir bileşen ve sürüm paketleri henüz kurmuyor.
- **Video:** VideoToolbox üzerinden H.264, HEVC, AV1 ve VP9 çözücüler; H.264, HEVC ve AV1 kodlayıcılar. Hepsi GPU'da;
  QuickTime, OBS, HandBrake ve ffmpeg'in `videotoolbox` kodlayıcıları bunları kullanıyor.
- **Hatadan toparlanma:** Takılan bir iş yalnızca kendi motorunu sıfırlatıyor; masaüstü çalışmaya devam ediyor.

### Bilinen sorunlar

- Safari'nin GPU süreci ve Dock'un yardımcı süreci (Takvim simgesini o çiziyor) şimdilik macOS'un yazılımsal yolunda
  tutuluyor (`nvmtl-allow.txt`). Sebebi: ilk kullanımda web içeriği siyah kalabiliyordu ve Takvim simgesi görünmüyordu.
- İlk girişten sonraki ilk saniyelerde, shader'lar ilk kez çevrilirken takılmalar oluyor.
- Yeniden başlattıktan sonra giriş ekranında, "Your password is required to log in" yazısının arkasında açık gri bir
  şerit görünüyor.
- Metal'i ilk kez bir VideoToolbox kodlamasıyla açan komut satırı araçları (ffmpeg gibi) ilk oturumda kodlayıcılarımızı
  göremiyor. Metal'i önce açan uygulamalarda (OBS, QuickTime, HandBrake) bu sorun yok.

## Windows'la karşılaştırma

Aynı makinede aynı kart; Intel'in Windows sürücüsü ve bu sürücü ([bütün tablolar](docs/devices/b580.md)):

| | Windows | macOS (bu sürücü) |
|---|---|---|
| Geekbench 7 GPU | Vulkan 111 056 · OpenCL 108 544 | Metal 92 898 · OpenCL 86 920 |
| 4K'ya kadar video çözme | referans | bit bit doğru ve daha hızlı |
| Intel QSV'ye göre kodlama kalitesi (BD-rate) | referans | HEVC ve AV1'de daha iyi; H.264'te fark %1,5'in altında |

## Nasıl çalışıyor?

```
 uygulamalar / WindowServer (Metal, Core Animation, Metal üstünde OpenGL ve OpenCL)
        │
 NVMTLDriver.bundle ── Metal sürücüsü (nullmoth'tan, uyarlanmış)            nullmoth/plugin
        │   └── libnvmtl_translate ── shader çevirici: AIR → SPIR-V          nullmoth/translator
        │
 Mesa ANV (libvulkan_intel.dylib) ── Vulkan ve Vulkan Video, xe arka ucu     mesa/  (+ user/xemac)
        │   xemac: xe arayüzü /dev/dri yerine bir IOUserClient üzerinden
        ▼
 NMXAccel.kext ── WindowServer'ın beklediği hızlandırıcı (IOAccelerator)     nullmoth/kexts/NVRM/accel
 NMXAGDC.kext  ── ekran hattı servisi (AppleGraphicsDeviceControl)           nullmoth/kexts/NVRMAGDC
        │
 IntelXeFB.kext ── ekran: modlar, EDID, bağlantı kurulumu, VRR, kare geçişi   kernel/IntelXeFB
        │
 IntelXe.kext ── kartın kendisi: GuC/HuC, bellek ve sayfa tabloları, motorlar kernel/IntelXe
        ▼
 Intel GPU (bugün: Arc B580, BMG-G21: grafik 20.01, medya 13.01, ekran 14.01)
```

Alttan yukarı doğru:
- **IntelXe.kext** kartı Linux'taki `xe` gibi ayağa kaldırıyor: bütün motorlarda GuC üzerinden iş gönderimi, SLPC güç
  yönetimi, HuC, ekran belleği, sayfa tabloları, hatadan toparlanma. Mesa'nın zaten bildiği `xe` arayüzünü sunuyor.
  Donanım bilgisi `xe`'deki gibi grafik, medya ve ekran bloklarının sürümlerine göre düzenlendi.
- **IntelXeFB** ekranı sürüyor.
- **NMXAccel ve NMXAGDC**, WindowServer'ın bir ekran kartından beklediği hızlandırma ve ekran hattı hizmetlerini veriyor.
- **Metal sürücüsü** Metal'i Vulkan'ın üzerine kuruyor ve uygulamaların Metal shader'larını (AIR) SPIR-V'ye çeviriyor.

Metal sürücüsü, shader çevirici ve iki NMX kext'i, NVIDIA kartları için yazılmış Metal sürücüsü
[nullmoth](https://github.com/nullmoth/nvidia-macos-driver)'tan geliyor; Intel'e biz uyarladık (`nullmoth/CHANGES.md`).

## Projenin durumu

Amacımız macOS'ta Intel kartlarının genelini çalıştırmak; bugün geliştirmeyi B580 üzerinde yapıyoruz. Tabloda her
platform için iki şey var: Intel'in kendi Linux sürücülerinin orada neyi desteklediği (yalnızca kaynak koddan okunarak)
ve bizim durumumuz. 🟩 çalışıyor, adı geçen kartta doğrulandı · 🟨 kod aynı, o platformda denenmedi · ⬜ henüz yok ·
— Intel de sunmuyor. Her kutunun kanıtı: [docs/PLATFORMS.md](docs/PLATFORMS.md).

![Intel GPU platformları](docs/parity/svg/platforms.tr.svg)

Linux `xe`'ye göre kod düzeyindeki ilerleme (tahmin değil, ölçüm): [docs/parity](docs/parity/README.md); geçmişi:
[docs/parity/HISTORY.md](docs/parity/HISTORY.md); sıradaki adımlar: [docs/ROADMAP.md](docs/ROADMAP.md).

![xe arayüzünün çekirdeğimizdeki karşılığı](docs/parity/svg/uapi.tr.svg)

## Kaynaktan derleme

| Klasör | İçindekiler |
|---|---|
| `kernel/IntelXe/` | kartın kext'i ve iki kext'i birden derleyen `build.py`; arayüz başlıkları `uapi/`'de |
| `kernel/IntelXeFB/` | ekran kext'i |
| `nullmoth/` | Metal sürücüsü, çevirici, NMXAccel, NMXAGDC; `build/build-intelxe.sh` |
| `mesa/` | Mesa değişiklikleri: upstream `f01e9b07a91`'e uygulanan `intelxe.diff` (`apply.sh`, `configure.sh`) ve aynı değişikliklerin yama serisi hâli |
| `user/` | `xemac` (arayüzün kullanıcı tarafı), testler ve araçlar |
| `videotoolbox/` | VideoToolbox çözücü ve kodlayıcıları; `ffmpeg/` (paylaşımlı FFmpeg kütüphanelerinin yamaları ve derleme ayarları) |
| `release/` | sürüm paketlerinin kurulum betiği ve kurulum kılavuzu (şablonlar `templates/`'te, `package.sh` dolduruyor) |
| `firmware/` | GuC/HuC yazılımlarını indiren `fetch.sh` |
| `efi/` | OpenCore notları ve `SSDT-ARCOFF.dsl` |
| `docs/` | ölçümler (`devices/b580.md`), platform tablosu, yol haritası, lisans, tasarım notları |

Sıra: `firmware/fetch.sh` → `kernel/IntelXe/build.py` (MacKernelSDK gerekir) → Mesa (`mesa/README.md`) →
`ANV_DYLIB` ayarlıyken `nullmoth/build/build-intelxe.sh` → codec'ler (`videotoolbox/README.md`). Her betiğin başında
neye ihtiyaç duyduğu yazıyor.

## Sürümlendirme

Sürücü günlük kullanıma hazır olana (1.0.0) kadar sürümler [Anlamsal Sürümleme](https://semver.org/lang/tr/)'nin 0.x
biçimini izliyor. Yeni bir özellik, yeni bir macOS sürümü ya da yeni bir kart ikinci sayıyı artırıyor (0.2.0); yalnızca
hata düzeltmeleri üçüncüyü (0.1.1). Güncellerken elle adım gerektiren değişiklikler (EFI'de bir değişiklik, adı değişen
boot-arg'lar) sürüm notlarında yükseltme adımlarıyla birlikte geliyor. Paketler, GitHub etiketi ve `install.sh`
sürüm numarasını taşıyor. Kext'ler ve Metal sürücüsü ise kendilerini en son yeniden derleyen sürümün numarasını taşıyor:
0.1.1 ve 0.1.2'de yalnızca rehber, dokümanlar ve paketleme değiştiği için ikili dosyalarda hâlâ 0.1.0 yazıyor.

## Yaklaşımımız

- **Linux'a ve Mesa'ya sadık kalmak.** Çekirdek sürücüsü Linux'taki `xe` ve i915 ekran kodunu izliyor (GuC arayüzü,
  bağlam yerleşimleri, donanım hatalarına karşı önlemler, SLPC, sayfa tabloları, DisplayPort bağlantı kurulumu, C20
  PHY). Her fonksiyon, Linux'ta hangi koddan geldiğini adıyla belirtiyor. Mesa'nın ANV'si de kendi mantığıyla çalışıyor ve
  çekirdekle gerçek `xe` arayüzü üzerinden konuşuyor.
- **Yama değil, gerçek çözüm.** Düzeltmeyi, Linux'un ya da Mesa'nın koyacağı yere koyuyoruz; mecburen başvurduğumuz geçici
  çözümleri not edip zamanla gerçeğiyle değiştiriyoruz.
- **Nesillere göre modüler yapı.** Donanım bilgisi bloklarının sürümlerine göre ayrılıyor; sonraki nesiller koda yeni
  `if`'ler olarak değil, modül olarak ekleniyor.

## Sıkça sorulan sorular

**Bu Intel'in ya da Apple'ın resmi sürücüsü mü?** Hayır. Bağımsız bir proje; Intel, Apple ya da NullMoth Systems ile
bağlantısı yok.

**Arc A serisi kartım, başka bir B serisi kart ya da işlemcinin kendi grafiği çalışır mı?** Henüz değil. Yalnızca B580
destekleniyor; [durum tablosu](#projenin-durumu) bu kartların B580'le ne kadar kodu paylaştığını gösteriyor.

**Güvenli mi?** Mac'in açılışını değiştiriyor ve gevşetilmiş güvenlikle çalışıyor. Önyükleme yapabilen bir USB EFI'si
tutun; geri dönmek için `./install.sh --undo` var.

**Adı neden IntelXe?** Sürücü, izlediği Linux `xe` sürücüsü gibi Intel'in Xe kartlarını hedefliyor. Daha önceki,
yayımlanmamış derlemelerin adı B580'di.

## Bir sorunla mı karşılaştınız?

GitHub'da hata şablonuyla bir issue açın. Şablonun istediği kayıtları `tools/report/` topluyor ve paylaşmadan önce seri
numaralarını, UUID'leri, MAC adreslerini ve kullanıcı adlarını içinden çıkarıyor. Lütfen ham sistem raporu paylaşmayın.

## Lisans

- **Bizim yazdığımız kod:** MIT (`LICENSE`).
- **PolyForm Noncommercial 1.0.0:** `nullmoth/` ve `kernel/IntelXeFB/IntelXeFB.cpp`.
- **LGPL-3.0-or-later:** `nullmoth/translator/`.
- **GuC/HuC yazılımları:** Intel'in `LICENSE.xe` lisansı; depoda yoklar (`firmware/fetch.sh` indiriyor), sürüm
  paketlerinde `IntelXe.kext`'in içine gömülü geliyorlar.

Depo da sürüm paketleri de **yalnızca ticari olmayan kullanım** içindir. Ayrıntılar `docs/LICENSING.md` ve `NOTICE`
dosyalarında.

## Teşekkürler

- [nullmoth](https://github.com/nullmoth/nvidia-macos-driver) (NullMoth Systems): bu projenin üzerine kurulduğu Metal
  sürücüsü, AIR'den SPIR-V'ye çevirici ve hızlandırıcı kext'leri.
- Anees Iqbal'in [metal2vulkan](https://github.com/steelbrain/metal2vulkan)'ı: nullmoth'un çeviricisinin temeli.
- Linux `xe` ve i915 (Intel): çekirdek sürücüsünün izlediği kaynak. Vulkan sürücüsü [Mesa](https://mesa3d.org) ANV.
- Emil J. Tywoniak ([widlarizer/mesa](https://github.com/widlarizer/mesa)): `mesa/xe2-venc/`'teki Xe2 video kodlama
  çalışması.
- FFmpeg: VideoToolbox codec'lerimizin kullandığı Vulkan video kodu.

Intel, Arc, Apple, macOS ve Metal, sahiplerinin ticari markalarıdır.
