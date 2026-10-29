# Panel

Apple Silicon Mac'ler için küçük bir menü çubuğu uygulaması. Menü çubuğunda adaptörden giren gücü ve sistemin anlık tüketimini gösterir (`42 ▸ 15 W`). Tıklayınca açılan panelde şunlar var:

- **Güç:** giriş / tüketim / pil akışı, 10 dakikalık grafik, 1 dk / 10 dk / oturum ortalamaları, harcanan Wh
- **Sıcaklık:** CPU, GPU, SSD ve pil (SMC), termal durum
- **İşlemci:** toplam, performans ve verimlilik çekirdekleri, çekirdek başına yük
- **GPU:** kullanım oranı
- **Bellek:** uygulamalar / sistem / sıkıştırılmış / önbellek, swap, bellek baskısı, CPU–GPU paylaşımı

Sudo gerekmez; veriler IOKit (AppleSmartBattery, AppleSMC, IOAccelerator) ve Mach API'lerinden okunur. Panel kapalıyken yalnızca güç okunur, o da birkaç saniyede bir.

## Derleme

Xcode Command Line Tools yeterli (macOS 14+, Apple Silicon).

```bash
./build.sh            # sadece derle
./build.sh --install  # derle, /Applications'a kur ve başlat
```

Arayüz olmadan sensör okumalarını görmek için:

```bash
./Panel.app/Contents/MacOS/Panel --dump
```

Sıcaklık sensörü anahtarları M4 için ayarlı; başka çiplerde SMC taranarak bulunur.
