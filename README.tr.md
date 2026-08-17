<h1 align="center">hadoop-forge</h1>

<p align="center">
  <strong>Apache Hadoop 3.3.6, içeriden dışarıya.</strong><br>
  Tekrarlanabilir cluster'lar, kendini açıklayan konfigürasyon ve her ayarın
  arkasındaki dağıtık sistem mantığı.
</p>

<p align="center">
  <a href="https://github.com/enesagu/hadoop-forge/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/enesagu/hadoop-forge/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="Hadoop 3.3.6" src="https://img.shields.io/badge/Hadoop-3.3.6-66CCFF">
  <img alt="Java 11" src="https://img.shields.io/badge/Java-11-orange">
  <a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-blue"></a>
  <a href="README.md"><img alt="English" src="https://img.shields.io/badge/doc-English-lightgrey"></a>
</p>

---

Çoğu Hadoop rehberi kopyalayacağınız komutlar verir. Bu repo ise **bilerek
bozabileceğiniz** bir cluster, kendini açıklayan konfigürasyon dosyaları ve
*neden* 128 MB blok, *neden* replikaların tam olarak o yerleşimle üç kopya,
*neden* job'unuzun `ACCEPTED`'da takıldığını anlatan dokümantasyon verir.

Çalışan bir cluster'a iki dakika:

```bash
git clone https://github.com/enesagu/hadoop-forge.git
cd hadoop-forge
make up      # 3 DataNode, 2 NodeManager, HDFS + YARN + JobHistory
make smoke   # checksum ile doğrulanan HDFS turu, ardından gerçek bir MapReduce job'ı
```

| Arayüz | Adres |
|---|---|
| NameNode | http://localhost:9870 |
| ResourceManager | http://localhost:8088 |
| JobHistory | http://localhost:19888 |

Bare-metal mi tercih ediyorsunuz? Ubuntu 22.04 üzerinde
`sudo ./scripts/install-pseudo-distributed.sh`.

> Dokümantasyonun tamamı ([`docs/`](docs)) İngilizcedir — Hadoop'un kendi
> terminolojisi ve hata mesajları İngilizce olduğu için çeviri arama yapmayı
> zorlaştırıyordu. Bu sayfa repoya Türkçe bir giriş kapısıdır.

## Repoda ne var

| | |
|---|---|
| **[docs/](docs)** | On doküman: mimari iç işleyiş, kurulum, konfigürasyon referansı, HA, güvenlik, tuning, izleme, sorun giderme |
| **[docker/](docker)** | Tek çok-rollü imaj; tek node ve çok node'lu Compose topolojileri |
| **[conf/](conf)** | Dört konfigürasyon seti — `pseudo`, `cluster`, `docker`, `ha` — her parametre gerekçesiyle yorumlanmış |
| **[scripts/](scripts)** | Numaralı, idempotent bare-metal kurulum script'leri + health check, smoke test, teardown |
| **[examples/](examples)** | Production tarzı yazılmış, unit test'li WordCount job'ı ve rehberli HDFS komut turu |
| **[monitoring/](monitoring)** | Hazır provision edilmiş Prometheus + Grafana, alarm kuralları dahil |
| **[tests/](tests)** | Statik konfigürasyon doğrulaması — 86 kontrol, cluster gerekmez |

## Günlük komutlar

```bash
make up / down / purge      # cluster yaşam döngüsü (purge HDFS verisini siler)
make single                 # daha küçük pseudo-distributed topoloji (~3 GB)
make shell                  # gateway container'ında client kabuğu
make report / nodes         # hdfs dfsadmin -report / yarn node -list
make health                 # tam sağlık raporu
make smoke                  # uçtan uca doğrulama
make example && make wordcount
make monitoring-up          # + Prometheus ve Grafana
make lint                   # CI'ın kontrol ettiği her şey
```

Herhangi birini tek node'lu cluster'a yönlendirmek için `TOPOLOGY=single` ekleyin.

## Nereden okumaya başlamalı

**Hadoop'a yeniyseniz** → [01 — Architecture](docs/01-architecture.md). Yazma
pipeline'ı, rack-aware yerleşim ve blok konumlarının neden hiç diske yazılmadığı.

**Hemen cluster lazımsa** → [03 — Docker quickstart](docs/03-docker-quickstart.md),
sonra [denemeye değer şeyler](docs/03-docker-quickstart.md#things-worth-trying) —
bir DataNode'u durdurup re-replikasyonu canlı izleyin.

**Bir şey bozulduysa** → [09 — Troubleshooting](docs/09-troubleshooting.md).
Belirtiden başlar, hata mesajının söylemediği sebepleri anlatır.

**Bir şey yavaşsa** → [07 — Tuning](docs/07-tuning.md). Etki sırasına göre
dizilmiş ve parametre tahmin etmek yerine counter okumakla bitiyor.

**Production planlıyorsanız** → [05 — High availability](docs/05-high-availability.md)
ve [06 — Security](docs/06-security.md), bu sırayla.

## Bu reponun ısrar ettiği üç şey

**NameNode'u formatlamak silmektir.** Blok konumları yalnızca NameNode'un
belleğinde yaşar; boş bir namespace, diskteki her bloğu erişilemez bayt yığınına
çevirir. `scripts/60-format-and-start.sh` mevcut metadata üzerine format atmayı
`FORGE_FORCE_FORMAT=1` verilmediği sürece reddeder, verilse bile ayrıca sorar.

**`simple` authentication zayıf güvenlik değil, güvenliğin yokluğudur.**
NameNode'a erişebilen herkes tek bir ortam değişkeniyle istediği kullanıcı olur.
Buradaki cluster'lar bilerek güvensiz bırakılmış öğrenme araçlarıdır; birini bir
yere bağlamadan önce [SECURITY.md](SECURITY.md).

**YARN olaylarının çoğu aritmetiktir.** Node kapasitesi → scheduler üst sınırı →
container boyutu → task heap → sort buffer. Zinciri bir yerde kırın, job'lar
`ACCEPTED`'da takılır ya da çalışırken öldürülür.
`tests/validate-configs.sh` bunu statik olarak kontrol eder — sabaha karşı teşhis
etmekten çok daha kolay olduğu için.

## İddia değil, doğrulanmış

CI iki topolojide de gerçek bir cluster ayağa kaldırıp smoke test'i koşar: 12 MB
rastgele veri HDFS'e yazılıp okunurken bayt bayt karşılaştırılır, ardından kelime
sayıları bilinen değerlere karşı doğrulanan gerçek bir MapReduce job'ı çalışır.
Bütün daemon'ları "healthy" görünen bir cluster, shuffle aux-service eksikse
tek bir job çalıştıramaz — o yüzden test gerçekten bir job koşar.

## Katkı

[CONTRIBUTING.md](CONTRIBUTING.md). Kısa hâli: *neden*'i satır içinde yorumlayın,
script'leri idempotent tutun ve öğrenme modu kısayollarının `conf/cluster`'a
sızmasına asla izin vermeyin.

## Lisans

[MIT](LICENSE) · English: **[README.md](README.md)**
