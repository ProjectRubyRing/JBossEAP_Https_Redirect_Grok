# JBoss EAP で HTTPS のアップロード失敗が HTTP へ戻される件

作成日: 2026-10-03  
対象: JBoss EAP 7.4 / 8.0 / 8.1（Web サーバは Undertow）  
現象: `RequestTooBigException` のあと、独自フィルタ `IBOWildflyUploadErrorFilter` が HTTP 302 で `/multipartException` へ戻す。ブラウザは `https://xxxxxxxx.net` で送ったのに、`Location` が `http://xxxxxxxxx.net/multipartException` になる。

この文書は、その理由と、直す手順を説明する。前半はたとえ話である。後半は、2026-10-03 に確認した Undertow と WildFly のソース、Red Hat の EAP 8.0 / 8.1 の文書に基づく。

対象のコンテナ実機と、フィルタのソースはこの作業環境には無い。サーバの中で実際にヘッダを見る手順は第16章にある。そこを実行するまでは、原因は「ソースと症状が一致する最有力の説明」である。

---

## 0. 30秒でわかる結論

案内状（`Location`）のホスト名は正しい。スキームだけが `http` になっている。

Undertow は、フィルタが相対パスで `sendRedirect` したとき、自分で絶対URLを作る。そのとき使うスキームは、ブラウザが使った HTTPS ではなく、**EAP が受けたソケットが平文 HTTP かどうか**である。ロードバランサが TLS をほどいて HTTP で渡す構成では、ソケットは平文なのでスキームは `http` になる。ホスト名は `Host` ヘッダの `xxxxxxxxx.net` をそのまま使うので、ポート 8080 は付かない。観測された `http://xxxxxxxxx.net/multipartException` は、この組み立てそのものである。

直す本命は次の二つを組にする。

1. プロキシが、ブラウザとの通信で見たスキームを `X-Forwarded-Proto: https` として**置き換えて**渡す。
2. その通信を受けている Undertow の `http-listener` で `proxy-address-forwarding=true` にする。

これで `sendRedirect` の `Location` は `https://xxxxxxxxx.net/multipartException` になる。フィルタを直せない場合でも、この設定だけで直る。ただしフィルタが文字列 `"http://"` を自分で書いている場合は、設定では直らない。ソースの確認が要る。

あわせて、このフィルタだけは `sendRedirect` に頼らず、`Location: /multipartException` のようなルート相対で返すと、プロキシヘッダが欠けてもブラウザは今来た HTTPS のまま進む。

`secure=true` と `redirect-socket=https` は、今回の `Location` のスキームを変えない。役割が別である。第12章に根拠がある。

---

## 1. 小学生向けの話

学校の受付を想像する。

子供は、中が見えない封筒（HTTPS）に手紙を入れて出す。宛先は `xxxxxxxx.net`。手紙の中身は、大きすぎるファイルである。

門の受付（ロードバランサ）は、封筒を開けて中身を調べる。この仕事を「TLS の終端」という。受付は、中の先生（JBoss EAP）へは、普通の紙（HTTP）で渡す。先生の机まで秘密の封筒を運び直すと遅いし、証明書の管理も増えるから、こうする会社が多い。

先生は正直である。渡された紙を見て、「これは普通の紙だ」と判断する。ファイルが大きすぎたので、子供に次の部屋を案内する。案内状には、自分が見た通りにこう書く。

```text
次はこちらへ: http://xxxxxxxxx.net/multipartException
```

子供は秘密の封筒で来た。案内状は普通の紙の道を指している。子供は案内状に従う。ブラウザは、アドレスバーが HTTPS だったことを覚えて補正しない。`Location` に `http://` と書いてあれば、次の通信は HTTP である。

直す方法は二つある。

- 受付が紙の端に付箋を貼る。「この子は秘密の封筒で来ました」。先生がその付箋を読むスイッチを入れる。先生の案内状は `https://` になる。
- 先生が道の種類を書かない。「この建物の `/multipartException` という部屋へ」。子供は、今来た秘密の道のままその部屋へ行く。

付箋の正式な名前が `X-Forwarded-Proto` である。先生のスイッチの名前が `proxy-address-forwarding` である。

---

## 2. いま起きていること

観測は次の形である。

| 見えたもの | 値 |
| --- | --- |
| ブラウザが送った先 | `https://xxxxxxxx.net` |
| サーバの応答 | HTTP 302 |
| 応答を作ったもの | `IBOWildflyUploadErrorFilter` |
| きっかけ | `RequestTooBigException`（ファイルが Undertow の上限を超えた） |
| `Location` | `http://xxxxxxxxx.net/multipartException` |

ここから、サーバの内部を見なくても言えることがある。

ホスト名は公開名のままである。`:8080` やコンテナの内部名は付いていない。Undertow の `getHostAndPort()` は、`Host` ヘッダがあればその文字列をそのまま返す。プロキシが `Host: xxxxxxxxxx.net` を維持している、という観測と一致する。

スキームだけが、ソケット側の `http` である。平文リスナでは、ヘッダを読む前に Undertow がスキームを `http` にする。

```java
httpServerExchange.setRequestScheme(connection.getSslSession() != null ? "https" : "http");
```

出典: Undertow 2.3.18.Final `HttpReadListener.java` 215行。SSL セッションが無い接続は `http` である。

したがって、この 302 を返したリスナは、ブラウザと直接 TLS で話していない。手前のどこかで TLS が終わっている。

---

## 3. 登場人物

| 名前 | たとえ | この件での仕事 |
| --- | --- | --- |
| ブラウザ | 子供 | `Location` の絶対URLへ、書いた通りに次の通信を出す |
| ロードバランサ / リバースプロキシ | 門の受付 | TLS をほどき、HTTP で EAP へ渡す。付箋（転送ヘッダ）を貼る担当 |
| `http-listener` | 先生の普通の郵便受け | 平文を受ける。既定ではスキーム `http` |
| `https-listener` | 秘密の封筒を自分で開ける窓口 | ここまで TLS のまま届くと、最初からスキームは `https`。今回の症状は、こちらの窓口では起きにくい |
| `ProxyPeerAddressHandler` | 付箋を読む人 | `proxy-address-forwarding=true` のときだけ呼ばれる |
| `IBOWildflyUploadErrorFilter` | 大きすぎる荷物の案内係 | 例外を捕まえ、エラーページへ 302 する |
| `sendRedirect` | 案内状を清書する人 | 相対パスを、スキーム＋ホスト＋パスの絶対URLにする |
| `X-Forwarded-Proto` | 「本当の封筒の種類」の付箋 | 値 `https` なら、清書のスキームが `https` になる |
| `secure=true` | 「この郵便受けは安全だ」という印 | `isSecure()` を true にする。案内状の `http://` は変えない |
| `redirect-socket` | 「機密ページは別の扉へ」という表 | `web.xml` の機密制約用。今回のフィルタの 302 とは別経路 |

---

## 4. 動作イメージ

### 4.1 いまの流れ

```text
ブラウザ
  POST https://xxxxxxxx.net/...   （大きなファイル）
        |
        | TLS
        v
プロキシ（TLS をここで終える）
  POST http://eap:8080/...
  Host: xxxxxxxxx.net
  X-Forwarded-Proto: https     ← 無い、または EAP が読んでいない
        |
        v
Undertow のパーサ
  SSL セッションが無いので scheme = "http"
        |
        v
上限超過 → RequestTooBigException
        |
        v
IBOWildflyUploadErrorFilter
  sendRedirect("/multipartException") など
        |
        v
HttpServletResponseImpl
  Location = "http" + "://" + "xxxxxxxxx.net" + "/multipartException"
        |
        v
ブラウザ
  次の通信は http://xxxxxxxxx.net/multipartException
```

### 4.2 設定を直したあとの流れ

```text
プロキシが X-Forwarded-Proto: https を置いて渡す
        |
        v
proxy-address-forwarding=true
  ProxyPeerAddressHandler が scheme を "https" に書き換える
        |
        v
フィルタの sendRedirect
  Location = "https://xxxxxxxxx.net/multipartException"
```

フィルタの呼び出しより前に、ハンドラがスキームを書き換える。だから、フィルタのソースを変えなくても `sendRedirect` と `getScheme()` は `https` を見る。

WildFly の `HttpListenerService` は、属性が true のときだけ `ProxyPeerAddressHandler` をリスナのハンドラ列に足す。`ListenerService` は、そのラッパをサーブレットより外側に掛ける。リクエストはパーサのあと、サーブレットフィルタより前にこのハンドラを通る。

### 4.3 フィルタを相対URLにした流れ

```text
HTTP/1.1 302 Found
Location: /multipartException
```

ブラウザは、今開いている `https://xxxxxxxxx.net` を台にして、このパスを足す。結果は `https://xxxxxxxxx.net/multipartException` である。サーバがスキームを知らなくても、子供は今来た道のまま歩ける。

これは HTTP の現在の規則で正しい。RFC 9110（2022年、インターネット標準）は、`Location` に相対参照を書いてよいと定め、解決の基準は有効なリクエストURIである。

一方、Jakarta Servlet 6.0（EAP 8.0 / 8.1 / 8.2 Beta が実装する版）の `sendRedirect` は、今も相対URLをコンテナが絶対URLにすると書いている。Undertow 2.3.18.Final の実装もそうである。相対のまま出したいときは、`sendRedirect` を呼ばず、ステータスと `Location` を自分で書く。

---

## 5. 動作原理

### 5.1 スキームはいつ決まるか

平文の `http-listener` では、ヘッダを解釈した直後に次が走る。

```text
SSLセッションがある → "https"
SSLセッションが無い → "http"
```

この時点では `X-Forwarded-Proto` はまだ見ていない。見るのは、属性を有効にしたときだけ後から挿入されるハンドラである。

`https-listener` で EAP 自身が TLS を終えると、SSL セッションがあるので最初から `https` である。今回の `Location` が `http` であることは、「ブラウザから EAP までがずっと TLS」ではない、という証拠になる。

### 5.2 sendRedirect が書く文字列

Undertow 2.3.18.Final `HttpServletResponseImpl.sendRedirect`（191行から225行）の動きは次のとおりである。

1. 応答が始まっていたら例外。まだならバッファを捨て、`Content-Length` を消し、ステータスを 302 にする。
2. 引数が `http://` や `https://` のような絶対URLなら、その文字列をそのまま `Location` に書く。コンテナはスキームを直さない。
3. 引数が `/` で始まる相対パスなら、そのパスを使う。
4. `/` で始まらない相対パスなら、今のパスからの相対として正規化してから使う。
5. 絶対URLでなかった場合だけ、次の連結をする。

```text
Location = exchange.getRequestScheme()
         + "://"
         + exchange.getHostAndPort()
         + realPath
```

`getHostAndPort()` は、`Host` ヘッダがあればその値を返す。無ければ接続先アドレスを使い、80 や 443 のような標準ポートは省く。

今回 `Host` が `xxxxxxxxx.net` なので、ポートは付かない。スキームが `http` なので、完成形は `http://xxxxxxxxx.net/multipartException` になる。

### 5.3 付箋を読む処理

`proxy-address-forwarding=true` のとき、`HttpListenerService` が `ProxyPeerAddressHandler` を足す。2026-10-03 に取得した Undertow の main の実装は、次のヘッダだけを読む。

| ヘッダ | 効果 |
| --- | --- |
| `X-Forwarded-For` | 送信元アドレスを、カンマの左端の値に変える |
| `X-Forwarded-Proto` | `setRequestScheme` する。カンマの左端だけを使う |
| `X-Forwarded-Host` | `Host` ヘッダを置き換える。ポートが書かれていれば切り離す |
| `X-Forwarded-Port` | `X-Forwarded-Host` があるときだけ、標準ポートでなければ `Host` にポートを足す |

確認できた細部は、運用で外しやすい。

- `X-Forwarded-Proto` は、`X-Forwarded-For` が無くても効く。For の if の中には入っていない。
- `X-Forwarded-Port` は、`X-Forwarded-Host` が無いと無視される。ポートだけのヘッダでは `Host` は変わらない。
- メソッド名は `mostRecent` だが、実装はカンマの**左端**を返す。右端ではない。
- RFC 7239 の `Forwarded: proto=https` は、このハンドラは読まない。別クラス `ForwardedHandler` の仕事であり、`proxy-address-forwarding` では有効にならない。プロキシは `X-Forwarded-Proto` を送る。
- システムプロパティ `io.undertow.forwarded.change-local-addr-port` の既定は false である。`getLocalPort()` はリスナの実ポートのままになりやすい。`Location` は `Host` ヘッダ側を使うので、今回の症状の修復にはこのプロパティは不要である。

左端を使うので、プロキシは追記してはいけない。クライアントが先に `X-Forwarded-Proto: http` を付け、プロキシがうしろへ `, https` を足すと、Undertow は左端の `http` を採用する。エッジのプロキシは、入ってきた値を捨てて、自分が見たスキームを1つだけ書き込む。

今回の症状では、公開ホストにポートが付いていない。必要なヘッダはまず `X-Forwarded-Proto: https` である。`Host` がすでに `xxxxxxxxx.net` なら、`X-Forwarded-Host` が無くてもホスト部分はそのまま残る。スキームだけが `https` に変わる。

### 5.4 secure=true が変えるもの

リスナ属性 `secure=true` は、WildFly の `ListenerAdd` が `MarkSecureHandler` を足す、という実装である。そのハンドラがする処理は1行である。

```java
exchange.putAttachment(HttpServerExchange.SECURE_REQUEST, Boolean.TRUE);
```

`isSecure()` は、この印があるか、スキームが `https` なら true を返す。`sendRedirect` は `isSecure()` を見ない。`getRequestScheme()` を見る。

したがって `secure=true` だけにすると、次のように割れる。

| メソッド | 結果 |
| --- | --- |
| `request.isSecure()` | true |
| `request.getScheme()` | `http` のまま |
| `Location` | `http://xxxxxxxxx.net/...` のまま |

Cookie の Secure 判定のように `isSecure()` を見る処理と、案内状のスキームは、別のスイッチである。ブログによっては `secure=true` を転送ヘッダの代わりとして書く。今回の 302 には届かない。

### 5.5 redirect-socket が変えるもの

WildFly の管理ガイドは、`redirect-socket` を次の用途として説明する。このリスナが非 SSL で、リクエストが SSL 必須の `security-constraint` に一致したとき、指定したソケットバインディングのポートへ Undertow が自動で転送する。

`Server.registerListener` は、セキュアではないリスナについて「このポートで受けたら、転送先ソケットのポートへ」という表を作る。これは機密制約の自動リダイレクト用である。

今回の 302 は、制約ハンドラではなく、独自フィルタが送っている。`redirect-socket=https` を足しても、`sendRedirect` の連結式は変わらない。

クラウドの内側ポートが 8443 のとき、この属性は別の害も出す。機密制約が動くページでは、ブラウザを `https://公開名:8443` へ飛ばすことがある。8443 が外に開いていなければ、その転送は失敗する。TLS 終端が前段にある構成では、アプリに「最初から https で届いた」と教える方が、扉のポートを教え直すより安全である。

### 5.6 ハンドラが走る順番

実装の追加順と、リクエストが通る順は逆になる。`ListenerService.start` は、先に足したラッパをルートのすぐ外に巻き、あとに足したラッパを一番外に巻く。一番外が最初に実行される。

有効な機能だけの概念順は、外側から次のようになる。

```text
禁止メソッド
  → secure=true の MarkSecureHandler（印を付けるだけ）
    → proxy-address-forwarding の ProxyPeerAddressHandler（スキームを書き換える）
      → サーバのルート
        → 仮想ホスト
          → サーブレット
            → IBOWildflyUploadErrorFilter
```

フィルタが動くころには、スキームの書き換えは終わっている。`getScheme()` も `sendRedirect` も、書き換え後の値を使う。

### 5.7 RequestTooBigException との関係

`RequestTooBigException`（ログでは `UT000020: Connection terminated as request was larger than N`）は、リクエスト本体が上限を超えたときに出る。上限はリスナの `max-post-size`、サーバオプションの最大エンティティサイズ、マルチパートの `max-request-size` / `max-file-size` のどこかである。

誰も捕まえないと、Undertow は接続を切ることがある。ブラウザから見ると空の応答や接続断になる。`IBOWildflyUploadErrorFilter` は、その体験を避けるために、エラーページへ 302 する独自実装だと読むのが自然である。

例外そのものはスキームを消さない。スキームは、本体を読み終えるより前、ヘッダ解析の直後に決まっている。フィルタが例外を捕まえて 302 を書けているなら、応答はまだ確定していない。直すべきは例外処理の有無ではなく、その時点のスキームである。

アップロード上限を上げても、`Location` の `http` は残る。上限の見直しは、大きなファイルを受けたいかどうかの別の判断である。

この症状がアップロード失敗のときだけ目立つ理由は、そこだけがサーバ側の `sendRedirect` だから、という可能性が高い。同じ組み立ては、次でも起きる。

- `response.sendRedirect(相対パス)` のすべて
- `request.getRequestURL()` で作った絶対リンク
- スキームを見て HTML に書いたフォームの action
- `isSecure()` が false のままだと、Secure Cookie や「HTTPS のときだけする」分岐が、外からは HTTPS なのに内側では HTTP として動く

本命の設定は、フィルタ1か所ではなく、サーバが見ている「外の姿」を直す。

---

## 6. 歴史と、この仕組みが必要になった経緯

### 6.1 道が1本だった時代

1991年、Web の通信は HTTP だけだった。秘密の封筒は無い。案内状に道の種類を書き間違える問題も無い。

1996年の HTTP/1.0（RFC 1945）は、`Location` を絶対URIにした。当時のブラウザは、相対の案内をうまく解けないことがあった。サーブレット API は 1990年代末に広まり、`sendRedirect` に相対パスを渡してもよいが、コンテナが送る前に絶対URLへ直す、という約束になった。Servlet 2.4 の文書にもその文がある。コンテナが「自分の知っているスキームとホスト」で清書する、という今日の動きは、この時代の約束の続きである。

1999年の HTTP/1.1（RFC 2616）も、`Location` は絶対URIだった。

### 6.2 秘密の封筒と、途中で開ける受付

1995年から1996年にかけて Netscape が SSL を広め、HTTPS が生まれた。1999年には TLS 1.0 が RFC になった。道が2種類になった。

2000年代になると、証明書と暗号の処理を入口の専用機に集める構成が普通になった。理由は具体的である。

- 証明書をサーバ台数ぶん配らなくてよい
- 暗号の計算を入口に集められる
- 入口で検査や振り分けができる
- 中のアプリケーションサーバは平文のままでも、拠点の中だけなら当時は足りるとされた

入口が封筒を開け、中へは普通の紙で渡す。先生は「普通の紙で届いた」としか言えない。案内状が `http` になる、というバグの形は、この分業から生まれる。

Squid などのプロキシは、もともとクライアントの IP を残すために `X-Forwarded-For` を付けていた。これは長いあいだ、標準ではなく現場の習慣だった。スキームを残す `X-Forwarded-Proto` も、同じ習慣として広まった。

### 6.3 標準が習慣に追いついた年

2014年6月、二つの RFC が出た。

- RFC 7239 が `Forwarded` ヘッダを標準にした。`proto`、`host`、`for` を1つのヘッダに書く。
- RFC 7231 が、`Location` に相対参照を許した。ブラウザがもともと相対を解けていたので、仕様が実装に合わせた。

Undertow の `ProxyPeerAddressHandler` の著作権表示は 2014年である。WildFly 8.1 の時点で、`http-listener` に `proxy-address-forwarding` があった（2014年の JBoss 開発者フォーラム）。これは RFC の `Forwarded` ではなく、すでに広かった `X-Forwarded-*` を読む実装である。標準の `Forwarded` 用には別ハンドラがある。属性1つでは、標準ヘッダの方は有効にならない。2026年のソースでも、この分担は変わっていない。

### 6.4 JBoss が Undertow に替わったとき

EAP 6 の Web 層は JBoss Web（Tomcat 系）だった。HTTPS 終端の裏側では、次のような設定が使われていた。

- コネクタ属性 `scheme="https"` と `proxy-port`
- `RemoteIpValve` が `X-Forwarded-Proto` を読んでスキームと Secure を直す

EAP 7.0（2016年、WildFly 10 系）から Web 層は Undertow である。EAP 6 のバルブは、移行で自動的に `proxy-address-forwarding=true` へはならない。Undertow の既定値は false である。false の意味は「付箋を無視し、自分が見たソケットを信じる」である。

この既定は、インターネットに直接出るサーバでは正しい。クライアントが自分で `X-Forwarded-Proto: https` と書けるからである。プロキシの裏側では、既定のままだと今回の症状になる。EAP 6 から 7 以降へ移したシステムで、アップロードエラーのときだけ HTTP に落ちる、という形で残っていることがある。

2016年には別の不具合もあった。UNDERTOW-756 / JBEAP-5669 は、`Host` ヘッダがあると `X-Forwarded-Host` と `X-Forwarded-Port` が無視され、スキームだけは `https` になる、というものだった。EAP 7.1 で修正されている。今回の症状は逆である。ホストは正しく、スキームが `http` である。古い UNDERTOW-756 が再発した、という説明にはならない。

`https-listener` に同じ属性が付いたのは WildFly 11 の WFLY-6538 である。EAP 7.1 以降なら、平文リスナにも TLS リスナにも付けられる。プロキシと EAP の間も TLS で、さらに外側のスキームを伝えたいときに使う。今回のように内側が平文なら、設定する場所は `http-listener` である。

### 6.5 AJP が退いたあと

長いあいだ、Apache HTTP Server と JBoss の間は AJP で結ぶことが多かった。AJP はスキームなどの接続情報を専用の形で運べる。

2020年、AJP の Ghostcat（CVE-2020-1938）が公表された。属性を読めてしまう欠陥である。AJP をインターネット側へ出せないこと、使わないならリスナを止めることが、運用の前提になった。代わりに増えたのが、HTTP でプロキシし、`X-Forwarded-*` で外側の情報を渡す形である。Undertow 側でそのヘッダを読むスイッチが、今回の設定である。

### 6.6 いまの仕様

2022年の RFC 9110 は RFC 7231 を置き換え、インターネット標準になった。`Location` は URI 参照であり、相対でもよい。解決は有効なリクエストURIに対して行う。

Jakarta Servlet 6.0 は、EAP 8.0、8.1、8.2 Beta のサーブレット仕様である（Red Hat の対応標準一覧、2026-09-23 更新）。この版の `sendRedirect` は、相対を絶対にするとした従来の文を引き継いでいる。Servlet 6.1 では、相対のまま出す選択が議論され、Tomcat は新しいメソッドを実装し始めている。EAP 8 系は Servlet 6.0 のままなので、Undertow は今も絶対URLへ清書する。相対のまま出すには、アプリケーションがヘッダを自分で書く。

EAP 8.0 では、管理属性を環境変数で上書きできる（WFCORE-5489）。OpenShift の EAP 8.0 ランタイムイメージでは、この機能は最初から有効である。それ以外のコンテナでは `WILDFLY_OVERRIDING_ENV_VARS` を何かの値にする。公式文書の例が、まさにこの `proxy-address-forwarding` である。

---

## 7. 原因の切り分け

症状と一致する説明は、次の3つである。上から先に確認する。

| 番号 | フィルタの書き方 | Undertow の設定だけで直るか |
| --- | --- | --- |
| H1 | `sendRedirect("/multipartException")` のように相対パス | 直る。清書が `getRequestScheme()` を使う |
| H2 | `getScheme()` や `getRequestURL()` で絶対URLを組み立ててから `sendRedirect` | 直る。ハンドラはフィルタより前にスキームを変える |
| H3 | ソースに `"http://"` と書いて連結している | 直らない。絶対URLはそのまま `Location` に入る |

H1 と H2 は、第5章のソースと、観測された「ホストは正しく、スキームだけ http、ポート無し」が同時に説明できる。H3 も同じ `Location` を作れる。フィルタのソースで、リダイレクトを作っている行を見る。

プロキシが `X-Forwarded-Proto: https` をすでに送っているかどうかも分ける。

| プロキシのヘッダ | EAP の属性 | 結果 |
| --- | --- | --- |
| 送っている | false（既定） | 今回の症状。付箋を無視する |
| 送っていない | true にしただけ | 直らない。読むスイッチだけがあっても、付箋が無い |
| 送っている | true | `Location` のスキームは `https` |
| `Forwarded: proto=https` だけ | true | 直らない。この属性は RFC 7239 を読まない |

---

## 8. 対応の比較

| 対応 | Location のスキーム | アプリ全体の getScheme() | いつ選ぶか |
| --- | --- | --- | --- |
| A. `proxy-address-forwarding=true` かつ `X-Forwarded-Proto: https` | 直る | 直る | 本命。プロキシの裏側であるとき |
| B. フィルタがルート相対の `Location` を自分で書く | この 302 は直る | 他の画面は元のまま | A と一緒にやる。A が遅れてもこの画面は守れる |
| C. 公開ベースURLを設定で持たせ、絶対URLを自分で書く | この 302 は直る | その設定を使った箇所だけ | パスを入口で書き換える Ingress で、相対パスがブラウザのパスとずれるとき |
| D. プロキシが応答の `Location` の `http://` を `https://` に書き換える | ブラウザが見るこのヘッダは直る | 直らない | EAP を今すぐ変更できない応急 |
| E. `secure=true` | 直らない | `getScheme()` は直らない。`isSecure()` は true | 今回の目的には使わない |
| F. `redirect-socket=https` | 直らない | 直らない | 機密制約の別機能。今回の目的には使わない |
| G. アップロード上限を上げる | 直らない | 直らない | 大きなファイルを受けたい場合の別要件 |
| H. フィルタに `https://` を直書きする | この 302 は https になる | 直らない | ローカルの HTTP 試験が壊れる。選ばない |

推奨は A を本命にし、B をこのフィルタの防御として足すことである。D は、A を入れるまでの応急にとどめる。

---

## 9. フィルタの修正案

本命の Undertow 設定が効けば、既存の `sendRedirect(相対パス)` も `https` になる。それでもこのフィルタは、案内状の清書に頼らない形へ変えると、ヘッダ漏れに強くなる。

次は提案用の形である。パッケージ名と、エラーパスは現行フィルタに合わせる。現行が `sendRedirect` にクエリを付けているなら、そのクエリは `location` のうしろに残す。

```java
final class MultipartErrorRedirects {

    private MultipartErrorRedirects() {
    }

    static void redirect(HttpServletRequest request, HttpServletResponse response)
            throws IOException {
        if (response.isCommitted()) {
            return;
        }
        response.resetBuffer();

        String contextPath = request.getContextPath();
        if (contextPath == null) {
            contextPath = "";
        }
        String location = contextPath + "/multipartException";

        response.setStatus(HttpServletResponse.SC_SEE_OTHER);
        response.setHeader("Location", location);
        response.setContentLength(0);
        response.flushBuffer();
    }
}
```

要点は次のとおりである。

- `sendRedirect` を呼ばない。呼ぶと Undertow が絶対URLにする。
- パスは `/` で始める。今のディレクトリからの相対にしない。コンテキストパスが `/ibo` なら、`Location` は `/ibo/multipartException` になる。観測がルートの `/multipartException` なら、コンテキストパスは空である。
- ステータスは 303 を推奨する。もとのリクエストはファイルの POST である。303 は「次は GET でその場所を見てください」という意味で、RFC 9110 に沿う。302 のままでもブラウザの多くは GET に変えるが、巨大な本体をもう一度 POST するクライアントが歴史的にはある。現行が 302 固定なら、変更の影響を見てから 303 にしてよい。スキームの修復自体は、302 のままでも A または相対 `Location` で足りる。
- `https://` は書かない。ローカルの HTTP と、本番の HTTPS の両方で、ブラウザが今使っている道を保つ。

入口のパスと、EAP のコンテキストパスが違う（例: 外は `/app`、中は `/`）場合、ルート相対は外のパスとずれる。そのときだけ、設定値の公開ベースURLで絶対URLを作る。

```java
String base = System.getProperty("ibo.public.base.url");
String location = (base == null || base.isEmpty())
        ? contextPath + "/multipartException"
        : base.replaceAll("/$", "") + "/multipartException";
```

`ibo.public.base.url` の例は `https://xxxxxxxxx.net` である。末尾のスラッシュは捨てる。この値をリクエストヘッダから直接は取らない。

---

## 10. Undertow に入れる設定

### 10.1 入れる値

トラフィックを受けている平文リスナに、次を入れる。名前が既定のままなら、XML ではこの1属性である。

```xml
<http-listener name="default"
               socket-binding="http"
               proxy-address-forwarding="true"
               enable-http2="true"/>
```

`redirect-socket` は今回の修復に不要なので、既存値を消す必要は無い。新しく `https` を足すこともしない。既に付いているなら、機密制約の挙動が変わるので、この作業では触らない。

`secure=true` は付けない。`isSecure()` と `getScheme()` が再び別々になる。

### 10.2 前提

このリスナへ到達できるのは、信頼できるプロキシだけにする。セキュリティグループ、NetworkPolicy、バインドアドレスで、ブラウザが 8080 へ直接届かないようにする。直接届くと、ブラウザが自分で `X-Forwarded-Proto: https` と書ける。

プロキシは、クライアントが付けた `X-Forwarded-Proto`、`X-Forwarded-Host`、`X-Forwarded-Port`、`X-Forwarded-For` を、自分の値で置き換える。

### 10.3 リスナ名の確認

既定名は `default-server` の `http-listener=default` である。現場の名前が違うことがある。変更の前に名前を読む。第13章のコマンドがそれである。

### 10.4 反映

この属性はリスナサービスの再起動が要る。稼働中のサーバでは `reload` を使う。処理中のリクエストは切れる。複数台なら1台ずつ行う。

### 10.5 EAP 8 の環境変数

XML を焼かずに、コンテナの環境変数で同じ属性を上書きできる。EAP 8.0 以降である。OpenShift の EAP 8 ランタイムイメージでは上書き機能は既定で有効である。それ以外では、次も入れる。

```text
WILDFLY_OVERRIDING_ENV_VARS=1
SUBSYSTEM_UNDERTOW_SERVER_DEFAULT_SERVER_HTTP_LISTENER_DEFAULT__PROXY_ADDRESS_FORWARDING=true
```

名前の作り方は、Red Hat の EAP 8.0 / 8.1 の OpenShift 文書どおりである。

1. リソースアドレスの先頭の `/` を取る。
2. うしろに `__` と属性名を足す。
3. 英数字以外を `_` にし、全体を大文字にする。

リスナ名が `default` でない場合は、`HTTP_LISTENER_DEFAULT` の `DEFAULT` をその名前の大文字に変える。EAP 7.4 にはこの上書き機能は無い。7.4 では CLI で属性を `true` にする。

---

## 11. プロキシ側

EAP だけを true にしても、ヘッダが無ければスキームは `http` のままである。

エッジでは「置き換え」を使う。Apache なら `RequestHeader set`、nginx なら `proxy_set_header`、HAProxy なら `http-request set-header` である。`add` や追記は使わない。

### 11.1 nginx

```nginx
proxy_set_header Host              $host;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Port  $server_port;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
```

TLS を終えるサーバブロックでは `$scheme` は `https` になる。`X-Forwarded-For` の追記は IP の慣習だが、左端はクライアントが偽装できる。アクセス制御に使う IP は、信頼できるプロキシが付けた段を自分で決める。今回の `Location` の修復に、For は必須ではない。

### 11.2 Apache HTTP Server

```apache
ProxyPreserveHost On
RequestHeader set X-Forwarded-Proto "https"
RequestHeader set X-Forwarded-Port  "443"
```

同じ仮想ホストが HTTP と HTTPS の両方を受けるなら、固定の `https` ではなく、リクエストのスキームを入れる。HTTPS 専用の仮想ホストなら、固定の `https` でよい。`ProxyPreserveHost On` は、今回すでにホスト名が正しいので、入っている可能性が高い。

### 11.3 HAProxy

```text
http-request set-header X-Forwarded-Proto https if { ssl_fc }
http-request set-header X-Forwarded-Proto http  if !{ ssl_fc }
```

### 11.4 AWS ALB と OpenShift の edge route

ALB は `X-Forwarded-Proto` を、クライアントとのプロトコルで入れる。OpenShift の edge termination も、ルートの HAProxy が同じヘッダを入れる。その場合、足す作業は EAP の `proxy-address-forwarding=true` が中心になる。ヘッダが本当に届いているかは、第16章のログで見る。

### 11.5 応急の Location 書き換え

EAP を変えるまでのあいだだけ、入口で書き換える例である。

```nginx
proxy_redirect http://xxxxxxxxx.net/ https://xxxxxxxxx.net/;
```

ブラウザが見る `Location` はこの応答については直る。HTML の中の絶対リンク、`getScheme()`、Cookie の判断は `http` のままである。本命のあとでは、二重に書き換えないよう、この `proxy_redirect` は外す。

---

## 12. やってはいけないこと

- インターネットに開いたリスナで `proxy-address-forwarding=true` にする。
- `X-Forwarded-Proto` を `add` で追記する。
- `secure=true` を、この 302 の修正だとみなす。
- `redirect-socket=https` を足して、修復できたことにする。
- 修復確認の前に、アップロード上限だけを上げる。
- 稼働中の `standalone.xml` を手で編集する。モデル検証を通る CLI か、EAP 8 の環境変数上書きを使う。
- 管理ポートを新しく外へ開ける。コンテナの中から、ループバックの 9990 へ CLI でつなぐ。

---

## 13. コンテナの中で jboss-cli を実行する実装

同じ内容のファイルが次にある。

- `docs/cli/enable-proxy-address-forwarding-online.cli`
- `docs/cli/enable-proxy-address-forwarding-offline.cli`
- `docs/cli/apply-in-container.sh`

コンテナは Linux なので、シェルは bash である。改行は LF にしてある。

### 13.1 どのモードを使うか

| 状況 | 使うもの |
| --- | --- |
| サーバが起動していて、管理ポート 9990 がコンテナ内の 127.0.0.1 で開いている | online。`--connect` |
| イメージを作るとき、または `standalone.sh` の前 | offline。`embed-server` |
| EAP 8 で、イメージを書き換えずデプロイ設定だけ変えたい | 環境変数。CLI は不要 |
| 稼働中のプロセスに対して `embed-server` | 使わない。設定ファイルの扱いが稼働中のサーバと競合する |

online の CLI は、サーバを起動した OS ユーザで実行する。公式イメージなら `jboss` である。

```bash
docker exec -u jboss -it <コンテナ名> bash
```

Kubernetes なら `kubectl exec -it <pod> -- bash` のあと、必要なら `su` やセキュリティコンテキストのユーザで合わせる。

### 13.2 名前を確認する

```bash
${JBOSS_HOME}/bin/jboss-cli.sh --connect \
  --controller=remote+http://127.0.0.1:9990 \
  --commands="/subsystem=undertow/server=default-server:read-children-names(child-type=http-listener),/subsystem=undertow/server=default-server:read-children-names(child-type=https-listener),/core-service=server-environment:read-attribute(name=product-version)"
```

`JBOSS_HOME` が空なら、公式イメージでは `/opt/eap` や `/opt/jboss/eap` が多い。スクリプトは、実行ファイルの位置から探す。

### 13.3 稼働中に入れるコマンド

リスナ名が `default`、サーバ名が `default-server` のとき、online 用ファイルの中身は次である。

```text
/subsystem=undertow/server=default-server/http-listener=default:read-attribute(name=proxy-address-forwarding)
/subsystem=undertow/server=default-server/http-listener=default:write-attribute(name=proxy-address-forwarding,value=true)
```

実行は次である。`reload` は、書き込み結果を見てから別コマンドにする。

```bash
${JBOSS_HOME}/bin/jboss-cli.sh --connect \
  --controller=remote+http://127.0.0.1:9990 \
  --file=/path/enable-proxy-address-forwarding-online.cli

${JBOSS_HOME}/bin/jboss-cli.sh --connect \
  --controller=remote+http://127.0.0.1:9990 \
  --commands="reload"
```

`reload` のあと CLI の接続が切れることがある。プロセスが落ちたという意味ではない。数秒待って、同じ read-attribute を再実行し、結果が `true` であることを見る。

すでに `true` のリスナへ同じ write をしても、値は `true` のままである。

### 13.4 起動前に XML へ書くコマンド

offline 用ファイルは、サーバが止まっているときに使う。

```text
embed-server --std-out=echo --server-config=standalone.xml
/subsystem=undertow/server=default-server/http-listener=default:write-attribute(name=proxy-address-forwarding,value=true)
stop-embedded-server
```

```bash
${JBOSS_HOME}/bin/jboss-cli.sh --file=/path/enable-proxy-address-forwarding-offline.cli
```

`embed-server` は既定で admin-only である。HTTP の 8080 は開かない。設定ファイルだけを更新して止まる。使う設定が `standalone-full.xml` や `standalone-ha.xml` なら、`--server-config` をそれに変える。起動スクリプトがどの XML を渡しているかを先に見る。

イメージビルドの例である。

```dockerfile
COPY docs/cli/enable-proxy-address-forwarding-offline.cli /opt/eap/config/
RUN /opt/eap/bin/jboss-cli.sh --file=/opt/eap/config/enable-proxy-address-forwarding-offline.cli
```

`JBOSS_HOME` はベースイメージに合わせる。

### 13.5 ラッパースクリプト

`docs/cli/apply-in-container.sh` は次をする。

- `--check` で、http リスナ一覧と、指定リスナの現在値を表示する。変更しない。
- `--apply` で、現在値が `true` でなければ write し、`reload` し、再接続して `true` を確認する。
- `--offline` は、`embed-server` のコマンドをその場で作って実行する。稼働中には使わない。設定ファイル名は `SERVER_CONFIG`（既定 `standalone.xml`）である。
- リスナ名は環境変数 `UNDERTOW_HTTP_LISTENER`、サーバ名は `UNDERTOW_SERVER` で変える。既定は `default` と `default-server` である。同梱の `.cli` は、その既定名をそのまま書く版である。

```bash
chmod +x /path/apply-in-container.sh
/path/apply-in-container.sh --check
/path/apply-in-container.sh --apply
```

スクリプトは `set -euo pipefail` で動く。write の出力に `"outcome" => "failed"` があれば、その時点で失敗にする。`reload` 後の確認読み取りが `true` でなければ失敗にする。

### 13.6 戻し方

```bash
${JBOSS_HOME}/bin/jboss-cli.sh --connect \
  --controller=remote+http://127.0.0.1:9990 \
  --commands="/subsystem=undertow/server=default-server/http-listener=default:write-attribute(name=proxy-address-forwarding,value=false),reload"
```

戻すと、`Location` は再び `http` になる。プロキシがヘッダを消したことの確認以外では、戻さない。

---

## 14. セキュリティ

`proxy-address-forwarding=true` は、そのリスナに届いた `X-Forwarded-*` を信じる、という宣言である。Undertow の文書も、信頼できるプロキシの後ろだけで使え、そうでなければ遠隔の利用者が IP を偽装できる、と書いている。

`ProxyPeerAddressHandler` は左端を採用する。エッジが置き換えではなく追記をすると、クライアントが書いた左端が勝つ。スキームなら `http` のままになり、今回の不具合が残る。IP なら、アクセス制御の判定が偽のアドレスになる。

この設定のあとで直るものは、`Location` だけではない。`getScheme()`、`isSecure()`、`getRequestURL()` が、外側の HTTPS に揃う。それは目的どおりの変化である。あわせて、次を見る。

- セッション Cookie が、HTTPS のリクエストで Secure になるか
- CSRF や戻り先 URL が、急に `https` の絶対URLになるか
- アプリが `getRemoteAddr()` で ACL をしていないか。左端の IP は偽装され得る

RFC 7239 の `Forwarded` だけを送るプロキシは、この属性では不足である。`X-Forwarded-Proto` を追加する。

---

## 15. 他に同じ症状が出る場所

本命を入れると、次もまとめて外側のスキームを見るようになる。

- ログイン後の 302
- タイムアウト時の 302
- JSP や API が `getRequestURL()` で返すリンク
- パスワードリセットメールに入れる URL を、リクエストから組み立てている処理

メールの URL だけは、リクエストのスキームではなく、設定された公開ベースURLを使う方がよい。プロキシヘッダは「今の通信」の情報であり、メールに書く恒久的な原点とは分けた方が安全である。

HSTS（`Strict-Transport-Security`）は、ブラウザが HTTP を HTTPS へ上げることがある。それはブラウザの補正であって、サーバが正しい `Location` を出したことにはならない。HSTS が無いクライアント、API クライアント、HTTP ポートが外に閉じていて接続できない場合は、今回の 302 のまま失敗する。

---

## 16. 確認手順

変更の前とあとで、同じ比較をする。

### 16.1 EAP へ直接、ヘッダの有無を比べる

大きいファイルを毎回使わなくてよい。フィルタが同じ `sendRedirect` を通るなら、小さな再現で `Location` を見てよい。アップロード上限の再現をするなら、上限より大きい本体を POST する。

```bash
curl -s -D - -o /dev/null \
  -H "Host: xxxxxxxxx.net" \
  -H "Content-Type: multipart/form-data; boundary=----b" \
  --data-binary @too-big.bin \
  "http://127.0.0.1:8080/<アップロードのパス>"
```

変更前の期待: `Location: http://xxxxxxxxx.net/multipartException`

```bash
curl -s -D - -o /dev/null \
  -H "Host: xxxxxxxxx.net" \
  -H "X-Forwarded-Proto: https" \
  -H "Content-Type: multipart/form-data; boundary=----b" \
  --data-binary @too-big.bin \
  "http://127.0.0.1:8080/<アップロードのパス>"
```

`proxy-address-forwarding=true` のあとの期待: `Location: https://xxxxxxxxx.net/multipartException`

ヘッダ無しの1本目が、true のあとでも `http` のままなのは正しい。付箋が無い通信は、ソケットどおり `http` である。本番のプロキシが付箋を付けることを、別の確認で見る。

### 16.2 プロキシ越し

```bash
curl -sI -k "https://xxxxxxxx.net/<エラーにするための手順>"
```

期待する行は次である。

```text
HTTP/1.1 302
Location: https://xxxxxxxxx.net/multipartException
```

`Location` に `http://` が残っていたら、プロキシがヘッダを付けていないか、別のリスナが受けているか、フィルタが H3（`http://` の直書き）である。

### 16.3 アクセスログ

確認のあいだだけ、Undertow のアクセスログに次を足すと、届いたヘッダが見える。

```text
%{i,X-Forwarded-Proto} %{i,Host}
```

本番のログ形式を恒久的に増やすかどうかは、個人情報と量を見て決める。確認が終わったら、足した項目を戻してよい。

### 16.4 成功の判定

- ブラウザの開発者ツールで、302 の `Location` が `https://xxxxxxxxx.net/multipartException` である。
- 次のリクエストが HTTPS のままである。
- 通常の小さい画面の POST やログインの 302 が、`http://` に落ちていない。
- 公開の 8080 へ、ブラウザから直接は届かない。

この作業環境では JBoss は起動していない。上の curl は、対象コンテナで実行する手順である。第18章のロジック検証は、ソースと同じ規則をローカルで再現したものである。

---

## 17. 用語

| 用語 | 意味 |
| --- | --- |
| スキーム | URL の `https` や `http`。道の種類 |
| TLS 終端 | 入口が秘密の封筒を開け、中へは平文で渡すこと |
| `Location` | 302 や 303 の「次にここへ」というヘッダ |
| 絶対URL | `https://ホスト/パス` のように、道の種類から書いてある URL |
| ルート相対 | `/multipartException` のように、オリジンは書かずパスだけのもの |
| `sendRedirect` | サーブレットが相対パスを渡すと、コンテナが絶対URLの 302 にするメソッド |
| `X-Forwarded-Proto` | プロキシが「外側のスキームはこれだった」と書くヘッダ |
| `proxy-address-forwarding` | Undertow がそのヘッダを読むリスナ属性。既定は false |
| `RequestTooBigException` | 本体が上限を超えたときの Undertow の例外 |
| 302 | Found。一時的に別の場所へ。歴史的に POST の再送が曖昧 |
| 303 | See Other。次は GET でその場所を見ること |
| reload | EAP の設定を読み直し、リスナを再起動する管理操作。コンテナ自体は消えない |

---

## 18. ロジック検証

次の規則を、Undertow の該当ソースに合わせてローカルで実行した。JBoss プロセスの試験ではない。

規則:

- 平文リスナの初期スキームは `http`。SSL セッションがあれば `https`。
- `X-Forwarded-Proto` があれば、カンマの左端でスキームを置き換える。`X-Forwarded-For` は不要。
- `Host` ヘッダがあれば、`Location` のホスト部分はその文字列。
- `X-Forwarded-Host` が無いとき、`X-Forwarded-Port` は `Host` を変えない。
- 相対パスの `sendRedirect` は `スキーム://ホスト部分 + パス`。
- 引数がすでに絶対URLなら、連結しない。

実行結果は Excel の「18_ロジック検証」シートにある。期待と一致した項目は次のとおりである。

| 条件 | Location |
| --- | --- |
| 平文、Host=`xxxxxxxxx.net`、転送ヘッダ無し、相対パス | `http://xxxxxxxxx.net/multipartException` |
| 平文、`X-Forwarded-Proto: https`、属性は有効、Host は同じ | `https://xxxxxxxxx.net/multipartException` |
| `X-Forwarded-Proto: http, https`（左端が http） | `http://xxxxxxxxx.net/multipartException` |
| `X-Forwarded-Proto: https`、For は無し | `https://xxxxxxxxx.net/multipartException` |
| 属性が無効で、Proto ヘッダだけある | `http://xxxxxxxxx.net/multipartException` |
| フィルタが `http://xxxxxxxxx.net/multipartException` を絶対URLで渡した | そのまま `http://...`。属性では変わらない |
| 相対 `Location: /multipartException` を自分で書いた | ヘッダはそのまま。ブラウザが `https://xxxxxxxxx.net` に対して解決する |

1行目が、今回観測された文字列である。

---

## 19. 出典

確認日は 2026-10-03 である。

- Undertow 2.3.18.Final `core/.../HttpReadListener.java` 215行。スキームを SSL セッションの有無で決める。
- Undertow 2.3.18.Final `servlet/.../HttpServletResponseImpl.java` 191行から225行。`sendRedirect` の連結。
- Undertow `HttpServerExchange.getHostAndPort()`。`Host` ヘッダがあればそれを返す。
- Undertow `HttpServerExchange.isSecure()`。`SECURE_REQUEST` か、スキームが `https`。
- Undertow main `ProxyPeerAddressHandler.java` 全文。`X-Forwarded-*` と、左端の採用。RFC 7239 は読まない。
- Undertow main `MarkSecureHandler.java`。印を付けるだけで、スキームは書かない。
- WildFly main `ListenerAdd.java`。`secure=true` で `MarkSecureHandler` を足す。
- WildFly main `HttpListenerService.java`。`proxy-address-forwarding` で `ProxyPeerAddressHandler` を足す。`isSecure()` は false。
- WildFly main `Server.java` の `registerListener`。`redirect-socket` は非セキュアリスナのポート対応表。
- WildFly 管理ガイド。`redirect-socket`、`proxy-address-forwarding`、`secure` の説明。
- Red Hat EAP 8.0 / 8.1「Using JBoss EAP on OpenShift」の環境変数の章。上書きの名前の例がこの属性である。OpenShift ランタイムイメージでは既定で有効。
- Red Hat「JBoss Enterprise Application Platform Supported Standards」（2026-09-23 更新）。EAP 8.0 / 8.1 / 8.2 Beta の Jakarta Servlet は 6.0。
- RFC 1945（1996）、RFC 2616（1999）、RFC 7231（2014）、RFC 7239（2014）、RFC 9110（2022）。
- UNDERTOW-756 / JBEAP-5669（2016）。今回の症状とは逆の、Host ヘッダがあるときに転送先ホストが無視される不具合。
- WFLY-6538。`https-listener` へ `proxy-address-forwarding` を追加。WildFly 11。
- CVE-2020-1938 Ghostcat。AJP から HTTP プロキシと転送ヘッダへ移った背景。

---

## 20. 残っている確認

この環境には、対象の EAP、プロキシ設定、`IBOWildflyUploadErrorFilter` のソースが無い。次の3点は、対象環境で見る。

1. フィルタが H1 / H2 / H3 のどれか。
2. プロキシが `X-Forwarded-Proto` を置き換えで送っているか。`Forwarded` だけではないか。
3. 受けているリスナの名前と、`proxy-address-forwarding` の現在値。

1が H1 か H2 で、2のヘッダをプロキシが送り、3を true にすれば、`Location` は `https://xxxxxxxxx.net/multipartException` になる。これは第5章のソースと、第18章の規則の実行結果からの結論である。対象コンテナでの curl は、まだ実行していない。
