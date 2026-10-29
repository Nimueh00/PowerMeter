# PowerMeter

Apple Silicon Mac'ler için küçük bir menü çubuğu uygulaması. Menü çubuğunda adaptörden giren gücü ve sistemin anlık tüketimini gösterir (`42 ▸ 15 W`). Tıklayınca açılan panelde şunlar var:

- **Güç:** giriş / tüketim / pil akışı, 10 dakikalık grafik, 1 dk / 10 dk / oturum ortalamaları, harcanan Wh
- **Sıcaklık:** CPU, GPU, SSD ve pil (SMC), termal durum
- **İşlemci:** toplam, performans ve verimlilik çekirdekleri, çekirdek başına yük
- **GPU:** kullanım oranı
- **Bellek:** uygulamalar / sistem / sıkıştırılmış / önbellek, swap, bellek baskısı, CPU–GPU paylaşımı

Sudo gerekmez; veriler IOKit (AppleSmartBattery, AppleSMC, IOAccelerator) ve Mach API'lerinden okunur. Panel kapalıyken yalnızca güç okunur, o da birkaç saniyede bir.

**Gereksinimler:** Apple Silicon (M1 ve sonrası) Mac, macOS 14 veya üstü. Intel Mac'lerde çalışmaz.

## Kurulum

1. [Releases](../../releases/latest) sayfasından `PowerMeter.zip` dosyasını indir ve aç.
2. `PowerMeter.app`'i **Uygulamalar** klasörüne sürükle.
3. Uygulamayı aç. Uygulama Apple'a kayıtlı bir geliştirici hesabıyla imzalanmadığı için macOS ilk açılışta *"doğrulanamadı"* uyarısı verip açmayacak. Bu normal:
   - **Sistem Ayarları → Gizlilik ve Güvenlik** bölümüne gir, en alta kaydır.
   - *"PowerMeter engellendi"* satırının yanındaki **Yine de Aç** düğmesine bas, parolanı gir.
   - Bu sadece bir kez gerekir.

   Terminal'i tercih edersen aynı işi tek satırla yapabilirsin:

   ```bash
   xattr -dr com.apple.quarantine /Applications/PowerMeter.app
   ```

Uygulama menü çubuğunda görünür (Dock'ta simgesi yoktur). Sol tık paneli açar, sağ tık menüyü açar. Uygulamalar klasöründen ilk açılışta kendini oturum açılışında başlayacak şekilde ayarlar; bunu sağ tık menüsünden kapatabilirsin.

## Kaynaktan derleme

Xcode Command Line Tools yeterli (`xcode-select --install`).

```bash
./build.sh            # sadece derle
./build.sh --install  # derle, /Applications'a kur ve başlat
./build.sh --zip      # derle ve dağıtım için PowerMeter.zip oluştur
```

Arayüz olmadan sensör okumalarını görmek için:

```bash
./PowerMeter.app/Contents/MacOS/PowerMeter --dump
```

Sıcaklık sensörü anahtarları M4 için ayarlı; başka çiplerde SMC taranarak bulunur.

## Lisans

[MIT](LICENSE)
