**Virtual Desktop のβ版（1.34.19 以降）は USB 接続を正式サポートしました。**  
**条件を満たせる場合は、そちらを使うことをおすすめします。(2026/08/06)**

----
# Quest VD Wired Watchdog

[Quest VD Wired](https://github.com/kkoemets/quest-vd-wired) を使用するとQuestとVirtualDesktopをUSBで有線接続できますが  
Quest VD Wired 単体では、**HMD の電源を切って入れ直すと接続が戻りません。**  
毎回タスクトレイを開いて **Diagnose and fix** を押す必要があります。  

このスクリプトはその手間をなくします。  
リンクが切れたことを検知し、自動で復旧させます。  
**これにより、PC に一切さわらずに HMD 側から接続できるようになります。**

HMD を起動した後は Quest VD Wired を再起動する時間が必要です。
Virtual Desktop を起動して繋がらない場合は、少し待ってから Virtual Desktop を起動し直してください。

> **非公式のスクリプトです。** Meta、Virtual Desktop、Genymobile、Quest VD Wired プロジェクトの
> いずれとも関係ありません。

🔸AIに頼んだらできたので、デバッグを頑張って問題ないレベルまで仕上げました。

---

## できること

| 状況 | 動作 |
|---|---|
| HMD の電源 OFF → ON | 自動で再接続 |
| HMD のスリープ → 復帰 | 自動で再接続 |
| ケーブルの抜き差し・接触不良 | 復帰を検知して自動で再接続 |
| ケーブルが抜けている間 | 何もせず待機 |

タスクトレイのアイコンで、常駐していることと接続状態がひと目で分かります。

| アイコン | 状態 |
|---|---|
| 🟢 緑 | 接続中 |
| ⚪ 灰 | 未接続（Quest が USB で見えていない） |
| 🔴 赤 | 切断を検知・復旧作業中 |

右クリックで **ログを開く** / **設定ファイルを開く** / **今すぐ再接続** / **終了** が使えます。

---

## 必要なもの

- Windows 10 / 11
- [Quest VD Wired](https://github.com/kkoemets/quest-vd-wired) — 先に導入・設定してください
- Meta Quest 3（開発者モード・USB デバッグ有効）
- USB 3 のデータケーブル

Windows 標準の PowerShell 5.1 で動作します。追加のインストールは不要です。

---

## 導入

1. Quest VD Wired をセットアップし、**手動で一度は接続できることを確認**してください
2. [Releases](../../releases) から ZIP をダウンロード
3. **ZIP を右クリック → プロパティ →「ブロックの解除」にチェック → OK**
   展開する **前** に行ってください。ダウンロードしたファイルは Windows にブロックされ、
   そのまま実行すると警告が出ます
4. **Quest VD Wired のフォルダの中に、`quest-vd-wired-watchdog` フォルダごと展開**します

   ```
   quest-vd-wired-v4.1.4-windows-x64\      ← Quest VD Wired のフォルダ
   ├─ quest-vd-wired.exe
   └─ quest-vd-wired-watchdog\             ← ここに展開する
      ├─ install.cmd
      ├─ uninstall.cmd
      ├─ run_debug.cmd
      ├─ watchdog.ps1
      ├─ README.txt
      └─ LICENSE.txt
   ```

5. `quest-vd-wired-watchdog` フォルダを開き、**`install.cmd`** をダブルクリック

これだけです。必要なパスを自動検出し、Windows のスタートアップに登録し、その場で常駐を開始します。
タスクトレイに丸いアイコンが表示されれば成功です。

| ファイル | 用途 |
|---|---|
| `install.cmd` | 常駐開始 ＋ 自動起動の登録 — **導入時に一度だけ実行します** |
| `uninstall.cmd` | 常駐停止 ＋ 自動起動の登録解除 |
| `run_debug.cmd` | 前景で実行してログを見る。自動起動の登録は **しません**。不具合調査用 |

Quest VD Wired を別の場所にインストールしている場合は自動検出に失敗します。
その場合は `watchdog.config.json` の `questVdWiredPath` に実際のパスを記入してください。

---

## 仕組み

`adb` で Quest 側に `tun` インターフェースが存在するかを確認しています。
存在すれば VPN が確立している ＝ 接続が生きている、という判定です。

```
10 秒ごとに繰り返す:

    Quest は "adb devices" に見えている？
        いいえ -> ケーブルか電源の問題。何もせず待機
        はい   v

    tun インターフェースはある？
        はい   -> 健全。何もしない          <- 普段はここ
        いいえ v

    3 回連続で失敗（約 30 秒）
        -> quest-vd-wired.exe を再起動
        -> 5 秒ごとに確認し、復帰したら緑に戻る
```

**接続が健全な間は一切何もしません。**3 回連続という条件は、接触の甘い USB で一瞬途切れた
ときに VR セッションを中断させないための緩衝です。

---

## 設定

初回実行時に `watchdog.config.json` がスクリプトの隣に生成されます。

| キー | 既定値 | 説明 |
|---|---|---|
| `adbPath` | 自動検出 | `adb.exe` のパス |
| `questVdWiredPath` | 自動検出 | `quest-vd-wired.exe` のパス |
| `logPath` | `%LOCALAPPDATA%\GnirehtetVD\watchdog.log` | ログの出力先 |
| `intervalSec` | `10` | 監視間隔（秒） |
| `failThreshold` | `3` | 連続何回異常を見たら再起動するか |
| `settleSec` | `60` | 再起動後、復帰を待つ上限（秒） |
| `settlePollSec` | `5` | 復帰待ち中の確認間隔（秒） |
| `cmdTimeoutSec` | `10` | adb コマンドの打ち切り時間（秒） |
| `maxRestarts` | `3` | 連続何回まで再起動を試みるか |
| `giveUpWaitSec` | `600` | 上限に達したあとの待機時間（秒） |

> **`failThreshold` を下げないでください。**
> USB の接触が不安定な環境では、接続が数十秒おきに一瞬途切れることがあります。
> `3` は、そうした一過性のフラつきで再起動が走らないようにするための値です。
> `1` にすると、正常な使用中に何度もアプリが再起動され、かえって使えなくなります。

手で書いたパスが自動検出で上書きされることはありません。
変更を反映するには、トレイアイコンを右クリック →「終了」してから `install.cmd` を実行し直してください。

---

## うまく動かないとき

**トレイアイコンが出ない**
`run_debug.cmd` を実行してエラーを確認してください。`adb.exe` または `quest-vd-wired.exe` の
パスが自動検出できていない場合は、`watchdog.config.json` に直接記入してください。

**何度も再接続を繰り返す**
Quest VD Wired 側が復旧できない状態です。3 回失敗すると 10 分間待機に入ります。
アイコンが赤のままなら、Quest VD Wired 本体のトレイメニューから「Diagnose and fix」を実行してください。

**動いているか分からない**
トレイアイコンを右クリック →「ログを開く」。状態が変わったときだけ記録されるため、
接続が安定している間は行が増えません。

---

## 開発者向けメモ

Quest VD Wired v4.1.4 で実測して確認した内容です。同種のツールを作る場合、以下は **やってはいけません**。

- **`quest-vd-wired.exe` をサブコマンド付きで実行しない**
  常駐中に `status` / `repair` / `start` / `stop` を叩くと、動作中のセッションを巻き込んで
  停止します。死活監視に `status` を使うことはできません。
- **`adb kill-server` を実行しない**
  `adb reverse` のマッピングは adb サーバー内に保持されているため、サーバーを再起動すると
  リンクが壊れます。
- **`ping` で疎通確認をしない**
  gnirehtet は ICMP を中継しないため、**正常に接続されていても ping は 100% ロスします。**
  死活判定には使えません。`tun` インターフェースの有無を見てください。

---

## ライセンス

MIT — [LICENSE.txt](LICENSE.txt)

このスクリプトは Quest VD Wired を外部から起動しているだけで、その配布物やソースコードを
**一切含みません。**

| プロジェクト | ライセンス |
|---|---|
| [Quest VD Wired](https://github.com/kkoemets/quest-vd-wired) | Apache License 2.0 |
| [gnirehtet](https://github.com/Genymobile/gnirehtet) | Apache License 2.0, © 2017 Genymobile |

"Meta Quest"、"Virtual Desktop"、"gnirehtet"、"Quest VD Wired" は、本スクリプトが連携する製品を
識別する目的でのみ使用しています。各商標は、それぞれの所有者に帰属します。
