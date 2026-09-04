# LPW4EXUpdater

L&P W4EX のファームウェアをmacOSから更新する、非公式のGUI／CLIツールである。Mac標準のIOKit USB APIからCT7601系のISP制御転送を行う。

## 重要事項

このツールはメーカー公式のMac版ではない。FW更新には機器が起動しなくなる危険がある。公式FWを使用し、更新中はUSBを抜かず、Macをスリープさせないこと。FWファイルは本リポジトリに含まれない。

2026-09-05にW4EX実機1台で `W4_V1.0.2.4_AS.bin` の消去、書込み、全域照合、再接続後の本体更新と通常起動を確認した。ただし、USB descriptorだけではW4とW4EXを区別できず、1台での成功は他の個体・FWの安全性を保証しない。

## ビルド

macOS 12 以降で、Apple Silicon / Intel の universal binary を作成する。

```sh
cd /path/to/LPW4EXUpdater
./build.sh
```

生成物はCLIの `lpw4ex-updater-universal` とGUIの `LPW4EXUpdater.app` である。どちらもApple Silicon／Intel対応のUniversal Binaryである。未署名のため、Gatekeeperの警告が出る場合がある。

## GUI

`LPW4EXUpdater.app` を開き、次の順で操作する。

1. `接続確認` で `VID 2FC6 / PID F82D` を確認する。
2. 公式の `.bin` ファイルを選択する。
3. W4EX用FWであることを確認してチェックを入れる。
4. `FW UPDATE` を押し、最終警告を確認する。
5. `Verifying Success` の後だけUSBを抜き差しし、本体の `Updating` が終わるまで待つ。

GUIは同梱CLIを呼び出す薄いフロントエンドであり、更新時は `caffeinate` によりMacのスリープを抑止する。

## 読み取り専用の確認

接続状態を確認する。

```sh
./lpw4ex-updater-universal scan
```

JEDEC ID と既知領域を読む。

```sh
./lpw4ex-updater-universal probe-normal
```

ファイルサイズ・SHA-256 を確認する。

```sh
./lpw4ex-updater-universal inspect /path/to/W4_V1.0.x.x_AS.bin
```

指定ファイルと実機のフラッシュを比較する。これは書き込みを行わない。

```sh
./lpw4ex-updater-universal diff-normal /path/to/W4_V1.0.x.x_AS.bin
```

## 更新コマンド

更新は意図的な書き込みであり、`--yes` が必須である。

```sh
./lpw4ex-updater-universal update /path/to/W4_V1.0.x.x_AS.bin --model W4EX --accept-unverified-w4ex-firmware --yes
```

`--model W4EX` はUSBだけでは判定できない機種の明示であり、`--accept-unverified-w4ex-firmware` はツール自身ではFWの適合性を証明できないことを受諾するためのガードである。

現在の実装は、通常の `F82D` デバイスを閉じて `PID=6000` を待つ方式ではない。Windows ツールの静的解析と公開デモに合わせ、同じ USB ハンドルで ISP 移行シーケンスを送り、そのまま消去・ページ書き込み・読み戻し検証を行う。W4EX に物理ボタンを押す作業はない。

消去後は SPI status の WIP bit を確認し、対象範囲が `0xFF` であることを確認してから書き込む。各ページ後にもフラッシュの完了を待ち、全データを 64 バイト単位で読み戻して完全一致を要求する。`Verifying Success` が出ない場合は成功と扱わない。

公式のW4系手順では、検証成功後にロゴ画面でUSBを抜き、再接続して `Updating` が表示された場合は約10秒待つとされる。`Verifying Success` より前に抜き差ししてはならない。

## ファームウェアと公式資料

- [L&P 公式ダウンロードページ](https://www.luxuryprecision.net/xiazai/)
- [L&P W4 EX 製品ページ](https://www.luxuryprecision.net/shangpin/bofangqi/2023-05-23/42.html)
- [W4 系更新手順のミラー PDF](https://device.report/m/e6fc89821f1055dc98f8898f788fdbef8faf01e482fff964ae285cfd96830de.pdf)

公式ページに掲載された `V1.0.2.4 AS` は「W4シリーズ」と記載されている。W4EX への適用可否が確認できるまで、別モデルの `.bin` を試してはならない。公式手順は電源・USB接続を中断しないことも要求している。

## 検証状況（2026-09-05）

- `swift build -c release` / universal binary: 成功
- 実機の識別: `VID_2FC6&PID_F82D`、製品記述 `LuxuryPrecision UAC Device`
- JEDEC ID: `85 60 15`
- OUT 転送: IOKit は `result=0`、ページデータで `done=256` を返した
- IN 転送: `result=0`、64 バイト要求で `done=64` を返した
- `W4_V1.0.2.4_AS.bin`: 451,190 bytes、SHA-256 `3a87074689ef89eff2ae5423c3a1f5391480c5a94b6c53f55d637b93a2be93d2`
- 修正前の試行: WIP待機不足などにより不一致 29,356 bytes / 6,021範囲
- 最終試行: `Blanking Success`、書込み100%、全域照合100%、`Verifying Success`
- 再接続後: 本体の `Updating` 完了、通常画面への復帰、FW更新を画面上で確認
- GUI／CLI: arm64・x86_64のrelease build成功

通信の根拠、確定事項、推測、未確認事項は [PROTOCOL.md](PROTOCOL.md) に分けて記載している。
