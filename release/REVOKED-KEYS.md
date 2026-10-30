# 发布信任根:已作废的根与当前的根

这个文件是发布验签的唯一权威清单。`mk-release.py --trusted-key` 只接受
`trusted-keys.sha256` 里列出的根;不在其中的一律拒绝(报
`is not in release/trusted-keys.sha256`),这样"签名能验过"就不会被当成"这个公钥还有效"。

## 当前生效的根(root-C)

    Ed25519, 生成于 2026-10-30 PDT, openssl 3.5.5 (genpkey -algorithm ed25519)
    公钥文件        release/trusted-release-key.pem
    公钥 sha256     ead6fe7751cec2b7b995dfa5be288d681581c4c899cd925b5bc65c5fbf5678f8
    公钥 DER sha256 27b18bcb65a9222e05eda3385f3b78f22eb897f1ee5e285ee978a8589e1dfd61
    公钥原始字节    98:de:4f:17:7e:95:5c:07:e3:65:de:4b:a8:24:21:…
    私钥            不入库。bench ~/.danos-release-key/private.pem (600)、
                    watchtower /root/.danos-release-key/private.pem (600),两份 sha256
                    `5d10b570844fad7f0e1bb2b4a64eb80410dc46830482c48118bd1fcf22fb2055`

验签:

    openssl pkeyutl -verify -pubin -inkey release/trusted-release-key.pem -rawin \
      -in <doc> -sigfile <doc>.sig

## 已作废的根

### root-A(forge,2026-10-27 — 2026-10-29)

- 位于已被平台重置的 `10.254.252.234: ~/.danos-release-key/`。
- **私钥与公钥一起丢失**:工作站全盘检索(排除 CA 与 node_modules)没有任何副本,
  因此连指纹都无法记录,更不可能签发一份密码学上有效的吊销证书
  (Ed25519 的吊销必须由原私钥签名)。
- 处置:**自 2026-10-29 起视为已作废**。它签发过的东西——
  `handoff/verify/evidence/{a02-p05-danos10-20261028, p2p4-danos10-20261028,
  r4-20261027, vps-release-20261028T1255}/*.sig`——**无法再被任何人验签**,
  只能作为历史记录,不得作为"可复现的验收证明"。
- 实测(2026-10-30):这四个 `.sig` 用 root-C 公钥验签全部失败(符合预期,它们本来就不是 root-C 签的)。

### root-B(bench,2026-10-29 04:15 — 2026-10-30 15:29)

- 上一轮轮换在 bench 生成的 Ed25519 根,公钥 sha256 `291d3d7ced179e6ebdb04083f64b340e2318ff93c4f1008722b1fc6d018744dd`。
- **从未签过任何东西**:上面四个 `.sig` 用 root-B 公钥验签全部失败(实测),仓库里也不存在
  root-B 的签名产物。因此作废它不使任何既有证据失效。
- 处置:2026-10-30 由 root-C 取代。私钥已 `shred -u`(bench 与 watchtower 两份都销毁),
  只保留公钥存档 `handoff/verify/keys/retired/root-B-20261029/public.pem`
  (私钥不进 handoff 仓库——那是要推到 GitHub 的)。

## 轮换规矩

1. 新根必须在**同一台机器**生成(`openssl genpkey -algorithm ed25519`),不许用自定义脚本;
   目录 700、私钥 600、公钥 644。
2. 立刻做一次"异地配对实证":bench 签名 → watchtower 用**本地那份公钥**验签,必须
   `Signature Verified Successfully`。只比对文件 sha256 不算,那证明不了两份配对。
3. 同一个 commit 里同时改:`trusted-release-key.pem`、`trusted-keys.sha256`、本文件。
4. **Ed25519 不能用 `openssl dgst -sha256 -sign`**(会报 `Explicit digest not allowed with
   EdDSA operations`),只能用 `pkeyutl -sign -rawin` / `-verify -rawin`。
5. 旧根作废时:私钥 `shred`,公钥存档进 `handoff/verify/keys/retired/`,
   并在本文件写清"它签过什么、谁还能验、从哪天起无效"。
