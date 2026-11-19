# kashejo API仕様

http://kashejo.f5.si/api/v1/

ここがAPIの場所

ここから、エンドポイントにリクエストしたりする

## 認証

kashejoの設定→APIキーで事前にAPIキーを取得。

APIキーをヘッダーに必ず付けなければいけない。

```Authorization: Bearer キー```

例:curl -H "Authorization: Bearer キー" https://kashejo.f5.si/api/v1/me

## Endpoints

ヘッダー

GET

```Accept: 受信形式 - 受信形式の指定(省略可)```

POST

ヘッダー

```Content-Type: 送信形式 - 送信形式の指定```

### タイムライン

現在のタイムラインを取得する。

エンドポイント: /timeline

メソッド: GET

ヘッダー

```特になし```

|パラメータ|

レスポンス
```
    {"posts": [{
        "id": 444,
        "url": "/posts/444",
        "author": {
            "id": 107,
            "handle": "keitakawase",
            "name": "かわせけいた"
        },
        "body": "おはいお",
        "kind": "post",
        "created_at": 1795125894,
        "reply_to": null,
        "quote_id": null,
        "likes": 0,
        "reposts": 0,
        "replies": 0,
        "images": []
    },

```json
