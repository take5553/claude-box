# claude-box

[English](README.md) · **日本語**

隔離された、egress(外向き通信)を既定拒否したコンテナの中で
[Claude Code](https://claude.com/claude-code) を **YOLO(`--dangerously-skip-permissions`)**
で**安全に**動かすための箱。マウントするのは、今いるプロジェクトのディレクトリだけ。

逐一の権限確認なしで自律的に作業させても、被害がホストと外部ネットワークへ波及しない
よう、**ファイル分離**と**デフォルト拒否のネットワーク**の二重の壁で囲うのが狙い。

## 何を守り、何を意図的に開けていないか

**守るもの**

- コンテナは**非 root**(`node`)・`--cap-drop=ALL` で起動し、firewall に必要な
  capability だけを足す。
- マウントは**対象プロジェクト 1 つだけ**(ホストと同じ絶対パス)。`$HOME` や `/`
  からの起動は拒否する。
- **egress は既定拒否・ホスト名で判定**。80/443 は透過リダイレクトでローカルプロキシへ
  強制的に通し、TLS の SNI / HTTP の Host のホワイトリストだけを許可する。TLS は復号しない。
- 認証情報と履歴は専用ボリュームに永続化し、ホスト側とは分離する。一方でホスト
  `~/.claude` の**一部**(設定・`skills/`・`agents/`・`commands/`・`plugins/`・
  グローバル `CLAUDE.md`)は持ち込んで普段の Claude と同じ挙動にする。既定は
  **読み取り専用**で、ホストに残すべき変更があるときは箱の中の Claude が
  「どの環境変数を付けるか」を提案する
  ([design 11](docs/design/11-read-only-by-default-and-telling-claude.md))。

**意図的に開けていないもの**(見落としではなく、これが要点)

- **AWS API は開けない** — terraform は `validate` まで、`apply` は手元で。
  この箱は IaC の検証まで、適用はしない。
- **外へ出られるのは 80/443 だけ** — SSH(22)は通さない。git は HTTPS を使う。
- **DinD もホスト docker socket も採用しない**。コンテナ内コンテナは rootless
  Podman で、**既定 off**。
- **TLS は検査しない**ので、箱が制御するのは「どのホストへ到達できるか」であって
  「許可先へ何を送るか」ではない。保証範囲は [SECURITY.md](SECURITY.md) 参照。

各判断の理由は [`docs/design/`](docs/design/) に:
[分離モデル](docs/design/01-isolation-model.md) ·
[egress](docs/design/02-default-deny-egress.md) ·
[永続化](docs/design/03-persistent-auth-state.md) ·
[YOLO 既定](docs/design/04-yolo-by-default.md) ·
[ネストしたコンテナ](docs/design/05-nested-containers-rootless-podman.md) ·
[焼き込み](docs/design/06-bake-tools-at-build-time.md)。

## 前提

- ホストに docker 互換 CLI。**動作確認は Docker(Docker Desktop)でのみ実施**。
  エンジンは `CLAUDE_BOX_ENGINE`(既定 `docker`)で差し替えられるが、Podman ホストでの
  動作は**未確認**(`--security-opt systempaths=unconfined` など Docker 固有オプションの
  扱いが要検討)。
- macOS または Linux。
- コンテナは Linux の user namespace / iptables を使うため、Linux ホストや
  Docker Desktop の Linux VM 上で動く。
- Linux ホストで AppArmor が有効な場合、ネストしたコンテナには追加で
  `--security-opt apparmor=unconfined` が要る(→ トラブルシューティング)。

## セットアップ

```sh
# 1. イメージをビルド
git clone <this-repo> claude-box && cd claude-box
docker build -t claude-box:latest .

# 2. 起動スクリプトを PATH に通す(例)
ln -s "$PWD/claude-box" /usr/local/bin/claude-box
```

### ビルド引数

焼き込むツールはビルド引数で選べる。既定は「全部入り」。

| 引数 | 既定 | 効果 |
|---|---|---|
| `WITH_PODMAN` | `1` | rootless Podman(ネストしたコンテナ実行)一式。`0` で除外 |
| `WITH_GO` | `1` | Go toolchain(pre-commit の golang フック用)。`0` で除外 |
| `WITH_PLAYWRIGHT` | `1` | Playwright の Chromium。`0` で除外 |
| `GH_VERSION` | 最新 | 焼き込む gh の版を固定 |
| `PRE_COMMIT_VERSION` | 最新 | 焼き込む pre-commit の版を固定 |
| `GITLEAKS_VERSION` | 最新 | 焼き込む gitleaks の版を固定(pre-commit からは `language: system` のフックとして使う) |
| `GO_VERSION` | 最新安定版 | 焼き込む Go の版を固定 |
| `PLAYWRIGHT_VERSION` | 最新 | 焼き込む Chromium の版を固定 |

`WITH_*=0` にした分だけイメージが小さく・ビルドが速くなる。焼き込む/焼き込まないを
**選べる**ようにしただけで、[design 06](docs/design/06-bake-tools-at-build-time.md) の
「実行時に取りに行かせず、ビルド時に焼き込む」方針は変えていない
(`WITH_PLAYWRIGHT=0` にしても実行時に CDN からは取りに行かない)。

- `WITH_PODMAN=0`: 箱の中で `docker`(= podman)が使えなくなる。実行時に
  `CLAUDE_BOX_NESTED_CONTAINERS=1` を付けても意味はなく、egress の nested グループ
  (container registry / OS ミラー)も不要になる。
- `WITH_GO=0`: pre-commit の golang フックは実行時に Go を取りに行くが、`go.dev` /
  `dl.google.com` は許可していないため失敗する(その種のフックを使うなら焼き込む)。

```sh
# 例: ネスト実行もブラウザ確認もしない最小構成
docker build -t claude-box:latest \
  --build-arg WITH_PODMAN=0 \
  --build-arg WITH_GO=0 \
  --build-arg WITH_PLAYWRIGHT=0 .
```

## 使い方

```sh
cd /path/to/your-project
claude-box            # サンドボックス内の shell に入る
claude-box claude     # 直接 claude を起動する場合
```

コンテナ内では `claude` と打つと YOLO で起動する(`login` / `update` / `mcp` などの
管理系サブコマンドはフラグなしで素通し)。

### ホストの `~/.claude` は箱に入る — 既定は読み取り専用

普段の Claude と同じ挙動にするため、ホストの `~/.claude`(`CLAUDE_CONFIG_DIR` を
設定しているならそちら)の次の項目を持ち込む。**中身は全部ある**。既定では、箱から
ホスト側へ書き戻せないだけ:

| 項目 | 変数 | 既定 | |
|---|---|---|---|
| `settings.json`・`settings.local.json` | `CLAUDE_BOX_SETTINGS` | `ro` | 箱側のコピーへマージ |
| `skills/` | `CLAUDE_BOX_SKILLS` | `ro` | |
| `agents/` | `CLAUDE_BOX_AGENTS` | `ro` | |
| `commands/` | `CLAUDE_BOX_COMMANDS` | `ro` | |
| `CLAUDE.md` | `CLAUDE_BOX_GLOBAL_MD_MODE` | `ro` | 毎起動で箱側を置換 |
| `plugins/`(インストール済みプラグインとマーケットプレイス) | `CLAUDE_BOX_PLUGINS` | **`rw`** | 例外(下記) |

各変数は `ro`(持ち込むが箱からは書けない)・`rw`(共有＝箱の書き込みがホストに届く)・
`off`(持ち込まない)。`CLAUDE_BOX_HOST_CONFIG` は全項目を一括指定するので、
`CLAUDE_BOX_HOST_CONFIG=rw` で全部共有、`=off` で素の箱になる。

> [!NOTE]
> **Linux** ホストでは、`rw` の書き込みはホストのユーザーが **uid 1000** のときだけ
> 動く。箱は `node`(uid 1000)で動き、bind mount はファイルの持ち主をそのまま見せる
> ため。別の uid だと rw の取り込み(既定 rw の `plugins/` も含む)は読めるが、書き込みは
> `Permission denied` で失敗する。起動時に警告が出る。macOS(Docker Desktop)は影響
> なし。[design 10](docs/design/10-host-config-import-modes.md) 参照。

**解禁はその場の判断でできるようにしてある**。箱は起動時のモードを箱の中の Claude に
伝えるので、コンテナより長生きさせるべき変更が出てきたときに、黙って失うのではなく
「どの環境変数を付けて入り直すか」を提案する。モードは起動時に決まるので、入り直す:

```sh
CLAUDE_BOX_SKILLS=rw claude-box       # 箱で書いたスキルを残す
CLAUDE_BOX_HOST_CONFIG=rw claude-box  # 全部共有する
```

> [!IMPORTANT]
> **`plugins/` だけは既定で読み書き共有**にしている。ホストで有効にしたプラグイン
> (たとえば公開されているセキュリティプラグイン)が箱の中で黙って効かない方が、
> リスクより問題だと判断したため。加えて Claude Code はこのディレクトリに通常運転で
> 書き込む。つまりここが、YOLO で動く箱が**ホストの** Claude Code に後で読ませる
> ものを置ける唯一の経路になる。避けたいなら `CLAUDE_BOX_PLUGINS=ro` か `off`。
> いずれにせよ `~/.claude` をバージョン管理下に置いておくと何が返ってきたか見える。

マウントするのはホスト側に**既に在るパスだけ**で、ホストには何も作らない。
**認証情報・履歴・セッション状態は共有しない**(箱専用ボリュームに留まる)。理由は
[design 11](docs/design/11-read-only-by-default-and-telling-claude.md)。

### 環境変数

| 変数 | 効果 |
|---|---|
| `GH_TOKEN` | GitHub 操作(push/PR/issue)を許可。スコープを絞った短命トークンを**実行時だけ**渡す(保存しない) |
| `CLAUDE_SKILLS_DIR` | ホストの `~/.claude/skills` の**代わりに**マウントするスキル置き場。存在しないパスはエラー |
| `CLAUDE_BOX_GLOBAL_MD` | ホストの `~/.claude/CLAUDE.md` の**代わりに**使う指示ファイル |
| `CLAUDE_BOX_ENGINE` | コンテナエンジン(docker 互換 CLI)。既定 `docker`。動作確認は docker のみ |
| `CLAUDE_BOX_IMAGE` | 使用するイメージ。既定 `claude-box:latest` |
| `CLAUDE_BOX_NESTED_CONTAINERS=1` | コンテナ内 rootless Podman を有効化(緩和を付与)。**既定 off**(→ セキュリティモデル節) |
| `CLAUDE_BOX_NO_GITCONFIG=1` | `~/.gitconfig` のマウントを無効化(壊れやすい設定の回避) |
| `CLAUDE_BOX_HOST_CONFIG` | ホスト `~/.claude` の持ち込み方を**一括**指定: `ro` / `rw` / `off`([上の節](#ホストの-claude-は箱に入る--既定は読み取り専用))。項目別変数が優先 |
| `CLAUDE_BOX_SETTINGS` | `settings.json` / `settings.local.json` のモード。既定 `ro`(箱側のコピーへマージ)。`rw` ならホストのファイルを共有 |
| `CLAUDE_BOX_SKILLS` / `CLAUDE_BOX_AGENTS` / `CLAUDE_BOX_COMMANDS` | `~/.claude/skills` / `agents` / `commands` のモード。既定 `ro` |
| `CLAUDE_BOX_PLUGINS` | `~/.claude/plugins` のモード。既定 **`rw`**(ホストで有効にしたプラグインを箱でも動かすため) |
| `CLAUDE_BOX_GLOBAL_MD_MODE` | グローバル `CLAUDE.md` のモード。既定 `ro`(ホストのファイルで箱側を毎起動置換)。`rw` なら共有 |
| `CLAUDE_BOX_REQUEST_DIR` | env-request の outbox にするホストフォルダ。**既定 on**(`~/.claude-box/requests`)。置き場を変えたいとき指定 |
| `CLAUDE_BOX_REPLY_DIR` | 要望への返答をメンテナが書くホストフォルダ(既定 `~/.claude-box/replies`、**読み取り専用**でマウント)。outbox と重ねてはいけない |
| `CLAUDE_BOX_SESSIONS` | `rw` で**このプロジェクトの**セッションログと auto-memory(`~/.claude/projects/<key>/`)をホストと共有し、orca や `claude --resume` などホスト側のツールから見えるようにする。既定 `off`。`CLAUDE_BOX_HOST_CONFIG` の対象外で、箱が書いた内容はホストの Claude に読み込まれる([design 13](docs/design/13-share-project-sessions.md)) |
| `CLAUDE_BOX_NO_REQUEST_DIR=1` | env-request の outbox と返答フォルダを無効化(既定 on) |
| `EXTRA_ALLOW_DOMAINS` | egress 許可先を**追加**する(コアは常に含む。スペース区切り) |
| `ALLOW_DOMAINS` | egress 許可リストを丸ごと上書き(スペース区切り。**コアは常に残る**) |
| `CLAUDE_BOX_VERBOSE=1` | ファイアウォールの起動ログを端末に表示する。既定では箱の中の `/tmp/claude-box/firewall.log` に書き出す(orca などのアプリが会話名にしてしまうのを避けるため)。失敗時の全ログと WARN 行は常に表示 |
| `SKIP_FIREWALL=1` | ファイアウォールを無効化(**egress 無制限**。警告表示あり) |

#### `.zshrc` での設定例

いずれも起動時に読まれるので、単発なら `VAR=value claude-box`、常用の既定は
シェルの設定ファイルで `export` する。`.zshrc` の雛形:

```sh
# ---- claude-box -----------------------------------------------------------
# 変数はシェルに export せず、すべてラッパーの中に置く。`command` は PATH 上の
# 本体を呼ぶので同名の関数でも再帰しない。`local -x` なので関数を抜ければ消える。
claude-box() {
  local -x CLAUDE_BOX_IMAGE="${CLAUDE_BOX_IMAGE:-claude-box:latest}"

  # 箱の中で docker / compose を使うときだけ(サンドボックスの緩和が付く)
  # local -x CLAUDE_BOX_NESTED_CONTAINERS="${CLAUDE_BOX_NESTED_CONTAINERS:-1}"

  # ~/.claude は既定で読み取り専用。箱の書き込みをホストに反映させたいなら外す
  # (上の「ホストの ~/.claude は箱に入る」節を参照)
  # local -x CLAUDE_BOX_HOST_CONFIG="${CLAUDE_BOX_HOST_CONFIG:-rw}"

  # スキルを ~/.claude/skills ではなく専用リポジトリで持っている場合
  # local -x CLAUDE_SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/dev/my-skills}"

  # 常に開けておきたい egress 先(コアの許可リストは常に維持される)
  # local -x EXTRA_ALLOW_DOMAINS="${EXTRA_ALLOW_DOMAINS:-pypi.org files.pythonhosted.org}"

  # `claude-box --gh …` のときだけ Keychain の GitHub トークンを*その実行に*渡す。
  # 素の `claude-box` は決して持たない(Linux なら `secret-tool lookup …` 等)
  if [ "${1:-}" = --gh ]; then
    shift
    local -x GH_TOKEN="$(security find-generic-password -s claude-box-gh -w)"
  fi

  command claude-box "$@"
}
# ---------------------------------------------------------------------------
```

各変数を `${VAR:-既定値}` で書いてあるので、単発の `CLAUDE_BOX_HOST_CONFIG=ro
claude-box` はラッパーの値より優先される。とくに `GH_TOKEN` はここに置くのが重要で、
`export` するとすべての箱(とシェル上の他のすべて)にトークンが渡ってしまう。

### コンテナへ持ち込まれるもの(マウント)

箱に入るホスト資源は次だけ。**ホーム全体はマウントしない**。

| 持ち込むもの | マウント先 | 条件 / 備考 |
|---|---|---|
| カレントプロジェクト | **ホストと同じ絶対パス**(例 `/home/you/project`) | 常時・読み書き。Claude Code はカレントパスをキーに履歴を保存するため、固定 `/workspace` だと全プロジェクトの履歴が混ざる。**同じパスに見えるのはこのためで、ホームがマウントされているわけではない** |
| 認証・設定ボリューム | `/home/node/.claude` | 常時。ホストの `~/.claude` とは**別**の専用ボリューム |
| `~/.gitconfig` | `/home/node/.gitconfig`(ro) | ファイルが在るときだけ。`CLAUDE_BOX_NO_GITCONFIG=1` で無効化 |
| `~/.claude/settings.json`・`settings.local.json` | `/etc/claude-box/host-settings*.json`(ro)→ `/home/node/.claude/` へマージ | 在るファイルだけ**既定 on**。箱側のコピーは書き換えられるがホストには届かない([design 08](docs/design/08-host-global-settings-import.md))。`CLAUDE_BOX_SETTINGS=rw` ならホストのファイルを直接マウント |
| `~/.claude/skills`・`agents`・`commands` | `/home/node/.claude` 配下の同名パス(ro) | 在るディレクトリだけ**既定 on**。箱の中で書こうとすると失敗するので、必要なら `CLAUDE_BOX_SKILLS=rw` 等で入り直す。`CLAUDE_SKILLS_DIR` で skills の場所を差し替え |
| `~/.claude/plugins` | `/home/node/.claude/plugins`(**rw** 共有) | 在れば**既定 on**。ホストで有効にしたプラグインを動かすため rw = 箱がホストへ書ける唯一の経路([design 11](docs/design/11-read-only-by-default-and-telling-claude.md)) |
| グローバル `CLAUDE.md` | `/etc/claude-box/global-CLAUDE.md`(ro)→ `/home/node/.claude/CLAUDE.md` を**置換** | ファイルが在れば**既定 on**。毎起動で置換するので箱の中での編集は残らない(`CLAUDE_BOX_GLOBAL_MD_MODE=rw` なら共有)。`CLAUDE_BOX_GLOBAL_MD` で元ファイルを差し替え |
| 持ち込みモードと箱からの注意書き | `CLAUDE_BOX_MODES` → `claude` のシステムプロンプトへ追記 | 常時。箱の中の Claude が「この変更はホストに届かない/どの変数を付ければ届く」を知るための経路([design 11](docs/design/11-read-only-by-default-and-telling-claude.md)) |
| `~/.claude/projects/<key>/`(このプロジェクトのみ) | `/home/node/.claude/projects/<key>/`(**rw** 共有) | `CLAUDE_BOX_SESSIONS=rw` のときだけ(ホストに無ければ作成)。セッションログと auto-memory。指定しなければボリューム内に留まる([design 13](docs/design/13-share-project-sessions.md)) |
| コンテナ用ボリューム | `/home/node/.local/share/containers` | `CLAUDE_BOX_NESTED_CONTAINERS=1` のときだけ |
| 要望の outbox | `/home/node/.claude-box/requests` | **既定 on**(ホスト `~/.claude-box/requests`・読み書き)。`CLAUDE_BOX_NO_REQUEST_DIR=1` で無効化 |
| 要望への返答 | `/home/node/.claude-box/replies` | outbox と一緒に有効(ホスト `~/.claude-box/replies`・**読み取り専用**)。メンテナからの返答([design 12](docs/design/12-env-request-replies.md)) |

`$HOME` や `/` からの起動は拒否する(誤って広くマウントしないため)。

### オプション機能

cmux は opt-in、env-request は既定 on:

- **cmux 通知**(opt-in) — 箱の中の Claude の待機/完了通知を
  [cmux](https://github.com/manaflow-ai/cmux) のペインへ中継する。
  [`contrib/cmux/`](contrib/cmux/) 参照。
- **環境への要望(`env-request`)** — **既定 on**: 箱の中の Claude が「この箱の環境を
  変えたい」という要望を**ファイル**として outbox(`~/.claude-box/requests`)に落とし、
  ホスト側の環境保守担当が確認する(GitHub もネットワークも使わない)。保守担当は
  読み取り専用の返答フォルダに返事を書くので、箱の中の Claude には「要望が対応され
  ました。返答を確認してください」と伝えるだけでよい。置き場は
  `CLAUDE_BOX_REQUEST_DIR` で変更、`CLAUDE_BOX_NO_REQUEST_DIR=1` で無効化。
  [`docs/env-request-operations.md`](docs/env-request-operations.md) 参照。

## カスタマイズ

大半のカスタマイズはコードを触らずに済む。まずここを見る(クローンのまま `git pull` で
upstream を追い続けられる):

- **egress**: `EXTRA_ALLOW_DOMAINS` で実行時に宛先を追加。
- **焼き込みツール**: `WITH_PODMAN` / `WITH_GO` / `WITH_PLAYWRIGHT` と版指定の `--build-arg`。
- **スキル / 指示 / エンジン / マウント / ネスト実行**: 上記の環境変数。

knob で足りないもの(新しい焼き込みツール、イメージへの常設 egress、構造的な変更)を
入れたいときだけコードを編集する。その場合は**フォーク**して自分の差分をコミットし、
upstream の更新はマージで取り込む。任意機能の **env-request** はまさにこのための導線で、
箱の中の Claude が要望を fork の outbox に落とし、あなたがブランチで確認・反映する
([`docs/env-request-operations.md`](docs/env-request-operations.md) 参照)。

## トラブルシューティング

**`Executable doesn't exist at .../chromium-XXXX/`** — 焼き込んだ Playwright の
Chromium が、プロジェクト側の `@playwright/test` と噛み合っていない。版を固定して
再ビルドする: `docker build --build-arg PLAYWRIGHT_VERSION=<ver> ...`。実行時に取りに
行かせない代わりの制約([design 06](docs/design/06-bake-tools-at-build-time.md))。

**何かが繋がらない** — egress プロキシのログで**どのホスト名が拒否されたか**を見る
(`upstream=""` / `allowed=0` が拒否):

```sh
grep 'upstream=""' /var/log/egress-proxy/tls.log    # TLS(443)
grep 'allowed=0'   /var/log/egress-proxy/http.log   # 平文 HTTP(80)
```

許可するには `EXTRA_ALLOW_DOMAINS`(実行時)か `init-firewall.sh` の `DOMAINS`
(イメージ側)に足す。

**ネストした `docker` / `compose` が動かない** — ネストしたコンテナは既定 off。
`CLAUDE_BOX_NESTED_CONTAINERS=1` で有効化する(かつ `WITH_PODMAN` が焼き込まれて
いること)。`docker pull` は通るのに `docker run` が `Invalid argument` で失敗する
場合は containers ボリュームが無い([design 05](docs/design/05-nested-containers-rootless-podman.md))。
Linux ホストで AppArmor が有効なら `--security-opt apparmor=unconfined` も足す。

**古いスキルやプラグインが復活する / 箱で入れた設定が消える** — ホストの `~/.claude`
は毎起動でボリューム側に被さるので、`skills`・`agents`・`commands`・`plugins` は
ホスト側が見える(ボリュームの中身は消えておらず、隠れているだけ)。
`CLAUDE_BOX_GLOBAL_MD_MODE=ro` にしている場合は `CLAUDE.md` も毎起動で置換される。
全部要らないときは `CLAUDE_BOX_HOST_CONFIG=off`
([design 10](docs/design/10-host-config-import-modes.md))。

**`known_marketplaces.json` が毎回書き換わる** — マーケットプレイスの install 先を
絶対パスで持っているが、同じディレクトリがホストでは `/Users/you/.claude/plugins/…`、
箱では `/home/node/.claude/plugins/…` になる。Claude Code は「自分の plugins
ディレクトリの外を指している」と検出してエントリを書き直すので、双方が起動時に
直す形になる(プラグイン自体は動く)。気になるなら `CLAUDE_BOX_PLUGINS=off`。

**箱の中で hook / `statusLine` が失敗する** — 持ち込んだ設定が、ホストにしか無い
コマンドやパス(`hooks`・`statusLine`・`apiKeyHelper` 等)を参照している可能性が
ある。`CLAUDE_BOX_SETTINGS=off` で切るか、ホスト固有の項目をグローバルの
`settings.json` から外す。`CLAUDE_BOX_SETTINGS=ro` なら箱側のコピーは書き換え可能で
ホストには波及しないので、箱の中で直して使う手もある。

**箱で変えた設定やスキルがホストに無い** — それが既定の挙動。持ち込みは読み取り専用で、
`~/.claude/skills`・`agents`・`commands` は書き込みが失敗し、`settings.json` と
`CLAUDE.md` は箱側のコピーなのでコンテナと一緒に消える。残したいときは対応する変数
(`CLAUDE_BOX_SETTINGS=rw`・`CLAUDE_BOX_SKILLS=rw`・`CLAUDE_BOX_HOST_CONFIG=rw`)を
付けて入り直す。箱の中の Claude はこれを提案するよう指示されている
([design 11](docs/design/11-read-only-by-default-and-telling-claude.md))。

**`CLAUDE_BOX_SETTINGS=rw` にすると箱の中で設定変更が保存できない** — ホストの
`settings.json` を*ファイル*として bind mount するため、`claude` は rename ではなく
インプレース書き込みのフォールバック経路で保存する。将来そのフォールバックが無くなった
場合は `CLAUDE_BOX_SETTINGS=ro`(箱が自分のコピーを持つ)に戻す
([design 10](docs/design/10-host-config-import-modes.md))。

**箱の中で git が失敗する** — マウントした `~/.gitconfig` が、コンテナ内で解決できない
設定(`includeIf`・署名鍵のパス・`credential.helper=osxkeychain` 等)を参照している
可能性がある。`CLAUDE_BOX_NO_GITCONFIG=1` でマウントを切るか、必要な値だけを個別に
渡す(箱の中で `user.name` / `user.email` を `git config` する 等)。

## セキュリティモデルの要点

「YOLO を安全に回す」ために、次を**不変条件**として維持している:

- 非 root・`--cap-drop=ALL`(必要な cap だけ追加)を崩さない。
- egress はデフォルト拒否のまま。宛先追加は許可リストへの明示追記で行う。
- コンテナ内コンテナは rootless Podman のみ。DinD(`--privileged`)や
  ホスト docker socket マウントは採用しない。
- 意図的な非許可: AWS API は開けない(terraform は `validate` まで)。

これらを緩めると YOLO 既定([design 04](docs/design/04-yolo-by-default.md))の前提が
崩れる。崩す変更には設計文書が要る。**ネストしたコンテナ**は既定 off で、有効時のみ
`seccomp`/`systempaths=unconfined` とデバイスを付与する — **追加 capability は無し・
非 root のまま・`--privileged` ではない**(詳細:
[design 05](docs/design/05-nested-containers-rootless-podman.md))。

**保証しないこと**と脆弱性の**報告窓口**は [SECURITY.md](SECURITY.md) にまとめてある。

## ファイル構成

| パス | 役割 |
|---|---|
| `Dockerfile` | イメージ定義(ツール類・rootless Podman・非 root 化) |
| `claude-box` | ホスト側の起動スクリプト(マウント・capability・通知ブリッジ) |
| `entrypoint.sh` | firewall 初期化・グローバル `CLAUDE.md` の任意マージ・フック/plugin 注入 |
| `init-firewall.sh` | デフォルト拒否 egress(iptables 透過リダイレクト + ホスト名判定) |
| `egress-proxy.conf` | 許可判定を行うプロキシ(SNI / Host ヘッダ)の nginx 設定 |
| `bashrc-claude` | `claude` を YOLO 起動にするラッパ |
| `contrib/cmux/` | cmux 通知ブリッジ(オプトイン。既定 off) |
| `claude-box-request` / `plugins/box-core/` | 任意の env-request スキル + CLI |
| `docs/design/` | 設計文書 |

## ライセンス

MIT — [LICENSE](LICENSE) 参照。Copyright (c) 2026 Takeshi Yamazaki。

## コントリビュート

変更の検証方法・セキュリティ不変条件・コミット / egress 追加の規約は
[CONTRIBUTING.md](CONTRIBUTING.md) にまとめてある。
