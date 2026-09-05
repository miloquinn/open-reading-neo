# Android APK 签名与证书轮换

## 当前配置

2026-09-05 核查：

- `android/app/build.gradle.kts` 在 release 签名配置中启用 `enableV3Signing = true`，继续使用原证书；v1/v2 保持构建工具按最低系统版本选择的默认行为。
- 当前 Flutter SDK 的最低 Android API 为 24（Android 7），旧系统兼容依赖 v2，无需额外开启 v1。
- `.github/workflows/release.yml` 校验每个 release APK 的签名有效性、v3 签名存在性和证书指纹。
- 本地原证书有效期为 2026-07-11 至 2051-07-05，SHA-256 为 `52DBBE537026932720315FBFFCAB797AD4315347DA0660FF357F6CA885E4D984`。

启用 APK Signature Scheme v3 不改变证书，也不延长证书有效期。X.509 证书版本与 APK 签名方案版本不是一回事。

本次验证：arm64 release APK 构建成功；v2/v3 均为 true，签名指纹匹配上述原证书；API 24–27、28–32、33–36 的离线验证通过。发布检查完整脚本接受该 APK，并拒绝缺少 v3 的调试 APK。Dart 静态分析无问题，工作流 YAML 与 Shell 语法验证通过，指纹提取覆盖四种工具输出格式。当前无连接的 Android 设备，尚未验证真机覆盖安装；验证用 APK 已清理。

## 迁移到约 50 年的新证书（尚未执行）

重新签发证书会改变签名身份，即使复用原私钥，也不能直接替换现有证书来保持升级兼容。建议生成独立新密钥，再使用原密钥建立 signing certificate lineage。

采用 Android 13 起的 v3.1 定向轮换：

| 系统 | 轮换版本使用的证书 |
| --- | --- |
| Android 7–8（API 24–27） | 原证书，v2 |
| Android 9–12L（API 28–32） | 原证书，v3 |
| Android 13 及以上（API 33+） | 新证书，v3.1 和轮换信任链 |

这使新系统转到长期证书；旧系统仍使用到期于 2051 年的原证书，不能宣称所有设备的证书都已延长到 2076 年。官方不建议在 Android 12 及更早版本使用传统密钥轮换。

### 实施顺序

1. 取得一个实际发布的旧版 APK，核对其包名、versionCode 和证书指纹。确认分发渠道；若由 Play App Signing 管理应用签名，使用 Play Console 的密钥升级流程，不能只更换上传密钥。
2. 离线备份原 keystore；为新 keystore 选择独立文件名。原文件不得覆盖，旧系统后续发布仍需原密钥。
3. 生成约 50 年的新密钥。下面是未来实施模板；变量需设为实际路径、别名，密码由工具交互读取，不写入代码或命令历史。

   ```bash
   keytool -genkeypair \
     -keystore "$NEW_P12" -storetype PKCS12 -alias "$NEW_ALIAS" \
     -keyalg RSA -keysize 4096 -sigalg SHA256withRSA -validity 18263
   ```

   `-validity` 单位为天；生成后读取证书的 `NotAfter` 确认日期。若在 2026 年生成，约于 2076 年到期。

4. 使用原密钥和新密钥生成轮换链：

   ```bash
   apksigner rotate --out "$LINEAGE_BIN" \
     --old-signer --ks "$OLD_P12" --ks-key-alias "$OLD_ALIAS" \
     --new-signer --ks "$NEW_P12" --ks-key-alias "$NEW_ALIAS"
   ```

5. 为 APK 发布增加最终签名阶段。当前 Gradle 签名配置只有一个 signer，不能仅把环境变量换成新 keystore。准备已对齐的 APK，然后用 `apksigner` 输出独立的轮换签名产物：

   ```bash
   apksigner sign \
     --out "$ROTATED_APK" \
     --min-sdk-version 24 \
     --v2-signing-enabled true --v3-signing-enabled true \
     --lineage "$LINEAGE_BIN" --rotation-min-sdk-version 33 \
     --ks "$OLD_P12" --ks-key-alias "$OLD_ALIAS" \
     --next-signer --ks "$NEW_P12" --ks-key-alias "$NEW_ALIAS" \
     "$ALIGNED_APK"
   ```

   可调整构建流程输出未签名 APK，或对当前已签名产物重新签名到另一个文件（apksigner 默认替换原签名）。不得对签名后的 APK 再运行 zipalign 或修改其内容。

6. 同步修改 CI 校验：分别断言 API 24–27、28–32 的原证书，以及 API 33+ 的新证书、v3.1 和 lineage。当前的单一证书指纹检查应随轮换一起升级。安全保存新旧 keystore 与 lineage，后续发布持续使用此链。

### 发布前验证

- 对最终 APK 分别运行 `apksigner verify --verbose --print-certs`，指定 `--min-sdk-version 24 --max-sdk-version 27`、`--min-sdk-version 28 --max-sdk-version 32` 和 `--min-sdk-version 33`。
- 在 API 24/27、28/32、33 和当前目标系统安装实际旧版，再覆盖安装 versionCode 更高的轮换版；保留书架、阅读进度和同步配置，验证启动及后续一次更新。签名工具的离线通过不能代替安装测试。
- 排查绑定签名指纹的登录、App Links、第三方 SDK、签名权限或共享 UID；需要时登记新旧指纹。
- 第一次启用新证书后，回退发布也必须沿用有效轮换链并提高 versionCode；不要假设重新使用旧密钥单独签名即可覆盖新版本。

## 官方依据

- [APK v3 与轮换信任链](https://source.android.com/docs/security/features/apksigning/v3)
- [APK v3.1 与 Android 13 定向轮换](https://source.android.com/docs/security/features/apksigning/v3-1)
- [apksigner 命令参考](https://developer.android.com/tools/apksigner)
- [应用签名及 Play 密钥升级](https://developer.android.com/studio/publish/app-signing)
- [keytool：有效期以天为单位](https://docs.oracle.com/en/java/javase/25/docs/specs/man/keytool.html)
