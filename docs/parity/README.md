# Kod eşdeğerlik ızgarası / Code parity grid

`docs/parity/index.html` her upstream kaynak dosyasını bir kare olarak gösterir (alan ∝ satır sayısı). Sayfa kendi
kendine yeter: veri sayfaya JSON olarak gömülüdür, `file://` ile açılır.

`docs/parity/index.html` shows every upstream source file as one square (area ∝ lines). The page is self-contained
(data embedded as JSON) and opens from `file://`.

## Durumlar yalnızca kanıttan / Statuses come from evidence only

Çekirdek bölümü (Linux `drivers/gpu/drm/xe`, `drivers/gpu/drm/i915/display`, `include/uapi/drm/xe_drm.h`):

| Durum | Nasıl belirlenir |
|---|---|
| taşındı / ported (yeşil) | Upstream dosyanın tanımladığı **her** fonksiyon adı (fonksiyonu olmayan başlıklarda her `#define`) kaynaklarımızda geçiyor. |
| kısmi / partial (sarı) | Bir kısmı geçiyor; bulunan/toplam sayısı ve her eşleşmenin `dosya:satır (sembol, code/comment)` yeri saklanır. |
| eksik / missing (kırmızı) | `map.json`'da bir kanıt var ve `scan.py` onu doğruladı: `refuse` (özelliği hata ile reddeden kod satırı bulunmalı) ve/veya `absent` (adlar ya da register ofsetleri kaynaklarımızda hiç geçmemeli). Kanıt tutmazsa dosya "doğrulanmadı" olur. |
| doğrulanmadı / unverified (mavi-gri) | Hiçbir ad bulunmadı ve yokluk kanıtı yok. Kendi adlarımızla yazılmış karşılıklar da buraya düşer. |
| uygulanamaz / not_applicable (gri) | Elle, dosya başına tek satır gerekçeyle: `na: linux` (yalnızca Linux arayüzü/altyapısı) veya `na: hw` (B580'de olmayan donanım). Bu tek elle verilen durumdur; böyle bir dosyanın 3+ fonksiyonu kodumuzda geçerse `scan.py` uyarır. |

Kaynaklarımız: deponun `kernel/IntelXe` ve `kernel/IntelXeFB` dizinleri (kopya `uapi/` başlıkları, `tests/` hariç). Ad
eşleştirme bir alt sınırdır: karşılığın nerede olduğunu gösterir, doğru çalıştığını kanıtlamaz. Kodumuz Linux
fonksiyonlarını yorumlarda adıyla anar; bu yüzden yorumdaki anma da eşleşme sayılır (`in_code` sayısı ayrıca tutulur).

Mesa bölümü: `upstream` = taban commit'e göre değişmemiş ve derleniyor, `patched` = serimizce değiştirilmiş, `ours` =
serimizce eklenmiş (ve depodaki `user/xemac`), `not_built` = `compile_commands.json`'da yok (başlık, aynı adlı `.c`'yi
izler). Hepsi `git diff --name-status` ve derleme veritabanından hesaplanır.

Başlık sayıları: (1) upstream fonksiyon adlarının kodumuzda geçen oranı (birincil), (2) en az bir eşleşmesi olan
dosyaların satır payı, (3) doğrulanmadı ve kanıtlı eksik satır payları. Hepsi uygulanabilir dosyalar üzerinden.

## Parçalar / Pieces

| Dosya | Ne |
|---|---|
| `tools/parity/map.json` | `groups` (alt sistem grupları, glob → ad), `rules`: yalnızca `not_applicable` gerekçeleri ve `missing` kanıtları. |
| `tools/parity/scan.py` | Ağaçları gezer, adları arar, kanıtları doğrular, `data/parity.json` yazar, `--html` ile sayfadaki JSON'u yeniler. Yalnızca Python stdlib. |
| `data/parity.json` | `meta` (Linux commit, bizim dizinlerin depo commit'i, Mesa ağacı), `summary`, `files[]` (`status, kind, total, matched, evidence[], unmatched[], reason, proof`). |
| `docs/parity/index.html` | Izgara, ipuçları (eşleşmeler ve yerleri), tablo görünümü, açık/koyu tema. |

## Yeniden üretme / Regenerate

```sh
# Linux (sığ + seyrek klon; drm-tip de olur)
git clone --depth 1 --filter=blob:none --sparse https://github.com/torvalds/linux.git /path/linux
git -C /path/linux sparse-checkout set --no-cone /drivers/gpu/drm/xe/ /drivers/gpu/drm/i915/display/ /include/uapi/drm/xe_drm.h

# Mesa: serimizin uygulandığı ağaç ve meson derleme dizini (bkz. mesa/README.md); taban varsayılanı f01e9b07a91
python3 tools/parity/scan.py --linux /path/linux \
  --mesa /path/mesa --mesa-build /path/mesa/build \
  --html docs/parity/index.html
```

`--kernel` / `--fb` varsayılan olarak deponun `kernel/IntelXe` ve `kernel/IntelXeFB` dizinleridir; sayfa başlığı hangi depo
commit'inin tarandığını ve commit edilmemiş değişiklik olup olmadığını yazar. Kural eklerken daha özel kuralı genel
kuralın üstüne koyun (ilk eşleşen kazanır).

2026-10-30 tablosu: Linux 7.3.0 @ abf8c33470f7, depo 63ce788 (`kernel/IntelXe` son değişiklik c9397b9, `kernel/IntelXeFB`
ac15d47), Mesa ağacı a3ad934832bb (yerel `src/mesa-perf`, kurulu 1888a8db kütüphanesinin kaynağı), `build-perf`.

## Durum görselleri / Status images (README "Status")

Tek komut / one command:

```sh
LINUX=/path/linux MESA=/path/mesa MESA_BUILD=/path/mesa/build NEO=/path/compute-runtime MEDIA_DRIVER=/path/media-driver MEDIAKIT=/path/mediakit LABEL="kernel rbX, FB vY" \
  tools/parity/build.sh
```

| Araç | Ne üretir / what it produces |
|---|---|
| `scan.py` | `data/parity.json` + `index.html` (dosya düzeyi; fonksiyon düzeyindeki eşleşmeler de burada). |
| `uapi.py` | `data/uapi.json`: `xe_drm.h`'deki her `DRM_IOCTL_XE_*` / `DRM_XE_*` ögesi bir hücre, sayısal değeriyle. Önce ada göre (yorumlar sayılmaz): `implemented`, `noop` (gövdesi yalnızca `return 0;` olan case), `rejected` (her kullanım hata döndüren satırda). Sonra değere göre: `kernel/IntelXe/uapi`'deki kendi adlarımız, alan bağlamı (motor tablosu `gEngines[..] = {V, ..}`, `num > V) return EINVAL`), aynı ailenin dağıtıcı `switch`'i (aynı değerde case → `implemented`; hata döndüren `default` → `rejected`), reddedilen üst ioctl, hiç okunmayan `extensions` zinciri (→ `noop`), sorgu işleyicisinin yazmadığı değerler (→ `absent`, kanıtlı). Hiçbiri karar veremezse `unverified`. Her hücre `dosya:satır` kanıtını taşır. |
| `cts_import.py` | Bir deqp-vk koşusunu (`run.sh` shard çıktısı: `*.qpa`, `events.txt`, `run.log`) `data/cts/<koşu>.tsv.gz` + `data/cts/runs.json`'a alır; tarih ve sürücü yığını elle verilir, erken durdurulan shard grupları "partial" diye işaretlenir. Yalnızca gerçekten koşan vakalar yazılır. |
| `video.py` | `data/video.json`: mediakit `out_mac/results_mac.txt`'ten codec × yön × bit derinliği × çözünürlük; çözmede kare kare md5, kodlamada hız ve her VBR akışının bit hızı sapması (`bytes*8 / (kare/60) / hedef − 1`). Windows sonucu yoksa "bekleniyor" (sarı). |
| `caps.py` | `data/caps.json`: Intel'in Linux medya sürücüsünün (intel/media-driver, `MEDIA_DRIVER`) platform başına sunduğu her codec × yön: VA-API profilleri, `VAConfigAttribRTFormat` bit derinlikleri, en büyük resim, cihaz kimlikleri; her girdi kaynak satırıyla. MTL/ARL, LNL, BMG, PTL yetenek tablolarından (capstable); Gen12 ve DG2 eski koddan (platformun `Init…MediaSku` fonksiyonunun özellik bayrakları; boyut çıkarılmaz). `video.py` B580'in "desteklenmiyor" hücrelerini buradan alır. / every codec × direction Intel's media-driver offers per platform, each entry with its source line; `video.py` takes the B580's "unsupported" cells from it. |
| `platforms.py` | Platform × özellik matrisi: `docs/parity/svg/platforms.svg`, `docs/PLATFORMS.md` ve README'deki tablo (`<!-- platforms:begin/end -->`). Hücre başına iki bilgi: Intel'in yığınının sunduğu (`data/platforms.json` "intel" kaynak satırlarıyla; video satırları `data/caps.json`) ve bizim durumumuz (works / same / not yet; `data/platforms.json` "ours" kanıtıyla, B580'in video satırları `data/video.json`). / the platform × feature matrix, two facts per cell, each with its source or evidence. |
| `consumers.py` | İhtiyaç sınıfı: her uAPI ögesi tüketicilerin gerçek kaynağında aranır — şimdi: Mesa `src/intel/vulkan`, `src/intel/common`, `src/intel/dev`, bu depodaki eklenti ve VideoToolbox kodu; gelecek: iris (yerel OpenGL), Mesa `src/intel/perf` (profiler), Intel compute-runtime/NEO `shared/source/os_interface/linux` (OpenCL/oneAPI). Uygulanmamış ögeler: şimdi gerekli (kırmızı), yalnızca gelecek hedef için (turuncu, özellik adıyla), macOS'ta gerekmiyor (siyah: PXP/RAS gibi Linux kavramı ya da hiçbir tüketicide yok). Her sınıf `dosya:satır` ya da aranan ağaçlar@commit ile kanıtlanır. xemac tüketici sayılmaz (ioctl'ları ileten katman). `docs/parity/TODO.md`'yi de yazar. |
| `next.py` | Tek iş listesi `docs/parity/NEXT.md`: docs/devices/b580.md'nin (eski PARITY.md) 🟥 ve ⬜ satırları, video.json'da hedefin altında kalan hücreler, en yeni CTS koşusunun başarısız vakaları ve grup başına NotSupported sayıları, uAPI'nin kırmızı ögeleri ve turuncu ögelerin özellik başına sayısı; hedefe göre sıralı, her satır kanıtıyla. `consumers.py` ayrıca Linux'un Xe2'de kendisinin de raporlamadığı ögeleri (kaynak satırıyla) siyah sayar. |
| `render.py` | `docs/parity/svg/*.svg` (rozetler, uAPI, fonksiyon ve CTS ağaç haritaları, video matrisi, geçmiş), `docs/parity/HISTORY.md`; `--history-append` ile `data/history.json`'a bir satır. |
| `history_backfill.py` | Geçmişi depodaki `kernel/` commit'lerinden yeniden ölçer (bir kez çalıştırıldı). |

Bilinen sınırlar / known limits:
- uAPI'de 29 öge `unverified`: çoğu bayrak bitleri (ör. `DRM_XE_VM_CREATE_FLAG_SCRATCH_PAGE`, `VM_BIND_FLAG_IMMEDIATE`) — işleyiciler bilinmeyen bayrakları reddetmiyor ve bu bitleri ne adla ne değerle test ediyor; ayrıca `ENGINE_CLASS_VIDEO_ENHANCE`, PXP tipleri, RAS adları. 29 uAPI items stay unverified (mostly flag bits that our handlers neither test nor reject).
- CTS: iki koşu içe alındı (`data/cts/runs.json`): 2026-10-29 21:03–21:20 (çekirdek sv7, Mesa wsi, stub iç shader'lar; g1–g7, g3/g5/g7 erken durdu) ve 2026-10-30 00:19–00:25 (`results3`: çekirdek rb2, Mesa cpu3; g1/g2 yeniden koşulmadı, bilinen askı vakaları EXCLUDE.re ile dışarıda). README son koşuyu, `svg/cts-<koşu>.svg` her koşuyu gösterir. `~/vk-cts/results7` yalnızca hariç tutulan 27 vakanın rb7i koşusu (2026-10-31 02:52: 13 geçti, 14 desteklenmiyor, 0 askı); tam bir koşu olmadığı için içe alınmadı, README hâlâ `results3`'ü gösterir. `~/b580/cts7/runs` tek vakalık tanı koşuları, içe alınmadı.
- Donanım: B580'de olmayan donanımın dosyaları gri değil; `map.json`'da `future` alanıyla "diğer Intel GPU'ları: <platform>" (turuncu) olarak işaretli, gerekçe Linux kaynağındaki koşul. Gen12 öncesi platformlar (xe dışı) "gerekmiyor".
- media-driver: `data/caps.json` 2026-10-31 tarihinde intel/media-driver f55f1c8ea764 (2026-10-29) ile üretildi / generated from intel/media-driver f55f1c8ea764 (2026-10-29). Varsayılan derleme / default build (ENABLE_KERNELS, ENABLE_NONFREE_KERNELS on); Tiger Lake A0 adımında AV1 çözmeyi kapatan koşul gibi çalışma anı koşulları okunmaz / run-time conditions such as Tiger Lake A0 turning AV1 decode off are not read. `VAConfigAttribRTFormat` VA'nın render-target biçimleridir; 4:2:2/4:4:4 kodlama girdileri de orada görünür / these are VA render-target formats, so encoder input formats (4:2:2, 4:4:4) appear there too; the platform matrix shows the 4:2:0 bit depths.
