import 'dart:async';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/account/account.dart';
import '../../utils/localization_extension.dart';
import '../../widgets/account_avatar_image.dart';
import '../../widgets/floating_subpage_scaffold.dart';
import '../../widgets/qr_code_view.dart';
import '../../widgets/side_toast.dart';
import 'avatar_crop_page.dart';

part 'parts/account_auth_part.dart';
part 'parts/account_membership_part.dart';
part 'parts/account_security_part.dart';
part 'parts/account_shared_widgets_part.dart';

enum _AccountMode { email, password, register, code, reset }

class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  static const _avatarProcessor = AvatarImageProcessor();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  final _username = TextEditingController();
  final _displayName = TextEditingController();
  final _code = TextEditingController();
  final _mfaLoginCode = TextEditingController();
  _AccountMode _mode = _AccountMode.email;
  MemberEmailChallenge? _challenge;
  DeviceAuthorization? _deviceAuthorization;
  bool _polling = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_initializeAccount());
    });
  }

  Future<void> _initializeAccount() async {
    final account = context.read<MemberAccountController>();
    try {
      await account.initialize();
      if (!mounted) return;
      _syncProfile(account.user);
      if (account.isAuthenticated && account.mfaStatus == null) {
        await account.loadMfaStatus();
      }
    } catch (error) {
      _showError(error);
    }
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    _username.dispose();
    _displayName.dispose();
    _code.dispose();
    _mfaLoginCode.dispose();
    super.dispose();
  }

  void _syncProfile(MemberUser? user) {
    if (user == null) return;
    _username.text = user.username;
    _displayName.text = user.displayName ?? '';
  }

  void _showError(Object error) {
    if (!mounted) return;
    showSideToast(context, error.toString(), kind: SideToastKind.error);
  }

  void _switchMode(_AccountMode mode) {
    setState(() {
      _mode = mode;
      _challenge = null;
      _code.clear();
      _password.clear();
      _confirmPassword.clear();
    });
  }

  void _continueWithEmail() {
    if (_email.text.trim().isEmpty) {
      _showError(MemberAccountException(context.l10n.accountEmailRequired));
      return;
    }
    _switchMode(_AccountMode.password);
  }

  Future<void> _submit() async {
    final account = context.read<MemberAccountController>();
    try {
      if (_mode != _AccountMode.email && _email.text.trim().isEmpty) {
        _showError(MemberAccountException(context.l10n.accountEmailRequired));
        return;
      }
      switch (_mode) {
        case _AccountMode.email:
          _continueWithEmail();
          return;
        case _AccountMode.password:
          await account.loginPassword(_email.text, _password.text);
        case _AccountMode.code:
          final challenge = _challenge;
          if (challenge == null) {
            _challenge = await account.requestCode(
              _email.text,
              MemberEmailCodePurpose.login,
            );
            setState(() {});
            return;
          }
          await account.verifyEmailCode(
            email: _email.text,
            challengeId: challenge.id,
            code: _code.text,
          );
        case _AccountMode.register:
          final challenge = _challenge;
          if (challenge == null) {
            _challenge = await account.requestCode(
              _email.text,
              MemberEmailCodePurpose.registration,
            );
            setState(() {});
            return;
          }
          if (_password.text != _confirmPassword.text) {
            throw const MemberAccountException('两次输入的密码不一致');
          }
          await account.registerPassword(
            email: _email.text,
            challengeId: challenge.id,
            code: _code.text,
            username: _username.text,
            displayName: _displayName.text,
            password: _password.text,
          );
        case _AccountMode.reset:
          final challenge = _challenge;
          if (challenge == null) {
            _challenge = await account.requestCode(
              _email.text,
              MemberEmailCodePurpose.passwordReset,
            );
            setState(() {});
            return;
          }
          if (_password.text != _confirmPassword.text) {
            throw const MemberAccountException('两次输入的密码不一致');
          }
          await account.resetPassword(
            email: _email.text,
            challengeId: challenge.id,
            code: _code.text,
            password: _password.text,
          );
      }
      if (!mounted) return;
      _syncProfile(account.user);
      if (account.mfaRequired) return;
      await account.loadMfaStatus();
      if (!mounted) return;
      showSideToast(context, context.l10n.settingsAccountVerified);
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _externalLogin(MemberExternalAuthMethod method) async {
    final account = context.read<MemberAccountController>();
    try {
      if (method == MemberExternalAuthMethod.passkey) {
        await account.loginPasskey();
        if (!mounted) return;
        _syncProfile(account.user);
        await account.loadMfaStatus();
        if (mounted) {
          showSideToast(context, context.l10n.settingsAccountVerified);
        }
        return;
      }
      final authorization = await account.beginExternalLogin(method);
      final uri =
          authorization.verificationUriComplete ??
          authorization.verificationUri;
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw const MemberAccountException('无法打开安全登录页面');
      }
      if (!mounted) return;
      setState(() {
        _deviceAuthorization = authorization;
        _polling = true;
      });
      final deadline = DateTime.now().add(
        Duration(seconds: authorization.expiresIn),
      );
      while (mounted && _polling && DateTime.now().isBefore(deadline)) {
        await Future.any<void>([
          Future<void>.delayed(Duration(seconds: authorization.interval)),
          account.waitForAuthCallback(
            Duration(seconds: authorization.interval),
          ),
        ]);
        if (!mounted || !_polling) return;
        var complete = account.isAuthenticated || account.mfaRequired;
        if (!complete) {
          try {
            complete = await account.pollDeviceAuthorization(authorization);
          } on MemberAccountException catch (error) {
            if (error.code != 'slow_down') rethrow;
            account.clearError();
            await Future<void>.delayed(
              Duration(seconds: error.retryAfter ?? authorization.interval),
            );
            continue;
          }
        }
        if (!complete) continue;
        if (!mounted) return;
        _syncProfile(account.user);
        setState(() {
          _polling = false;
          _deviceAuthorization = null;
        });
        if (account.mfaRequired) return;
        await account.loadMfaStatus();
        if (!mounted) return;
        showSideToast(context, context.l10n.settingsAccountVerified);
        return;
      }
      if (mounted && _polling) {
        setState(() {
          _polling = false;
          _deviceAuthorization = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _polling = false;
          _deviceAuthorization = null;
        });
      }
      _showError(error);
    }
  }

  Future<void> _loginWithApple() async {
    final account = context.read<MemberAccountController>();
    try {
      await account.loginWithApple();
      if (!mounted) return;
      _syncProfile(account.user);
      if (account.mfaRequired) return;
      await account.loadMfaStatus();
      if (!mounted) return;
      showSideToast(context, context.l10n.settingsAccountVerified);
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _saveProfile() async {
    try {
      await context.read<MemberAccountController>().updateProfile(
        username: _username.text,
        displayName: _displayName.text,
      );
      if (mounted) showSideToast(context, context.l10n.accountSaveProfile);
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _verifyMfaLogin() async {
    try {
      final account = context.read<MemberAccountController>();
      await account.verifyMfa(_mfaLoginCode.text);
      if (!mounted) return;
      _syncProfile(account.user);
      await account.loadMfaStatus();
      if (mounted) {
        showSideToast(context, context.l10n.settingsAccountVerified);
      }
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _changeAvatar() async {
    final account = context.read<MemberAccountController>();
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    final bytes = result?.files.single.bytes;
    if (bytes == null) return;
    try {
      final imageInfo = await _avatarProcessor.inspect(bytes);
      if (!mounted) return;
      final cropRect = await Navigator.of(context).push<ui.Rect>(
        MaterialPageRoute(
          builder: (_) => AvatarCropPage(bytes: bytes, imageInfo: imageInfo),
        ),
      );
      if (cropRect == null) return;
      final upload = await _avatarProcessor.cropAndCompress(
        bytes,
        sourceRect: cropRect,
      );
      await account.uploadAvatar(upload);
    } catch (error) {
      _showError(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<MemberAccountController>();
    final user = account.user;
    return FloatingSubpageScaffold(
      title: context.l10n.accountPageTitle,
      body: account.initialized
          ? ListView(
              padding: floatingSubpagePadding(context, bottom: 40),
              children: account.mfaRequired
                  ? _buildMfaChallenge(account)
                  : user == null
                  ? _buildSignedOut(account)
                  : _buildSignedIn(account, user),
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }

  List<Widget> _buildSignedOut(MemberAccountController account) => [
    _AccountIntroCard(),
    const SizedBox(height: 16),
    _formCard(account),
  ];

  List<Widget> _buildMfaChallenge(MemberAccountController account) => [
    _AccountIntroCard(),
    const SizedBox(height: 16),
    _SectionCard(
      title: context.l10n.accountMfaChallengeTitle,
      icon: Icons.phonelink_lock_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(context.l10n.accountMfaChallengeHint),
          const SizedBox(height: 12),
          _accountTextField(
            _mfaLoginCode,
            context.l10n.accountMfaCode,
            Icons.password_rounded,
          ),
          const SizedBox(height: 14),
          FilledButton(
            key: const ValueKey('account-mfa-verify'),
            onPressed: account.loading ? null : _verifyMfaLogin,
            child: Text(context.l10n.accountMfaVerify),
          ),
          TextButton(
            onPressed: account.loading ? null : account.logout,
            child: Text(context.l10n.accountSignOut),
          ),
        ],
      ),
    ),
  ];

  List<Widget> _buildSignedIn(
    MemberAccountController account,
    MemberUser user,
  ) => [
    _SignedInHeader(user: user, supporter: account.membership?.premium == true),
    const SizedBox(height: 16),
    _AccountActionsCard(
      user: user,
      onEditProfile: () => _openProfileEditor(),
      onOpenSecurity: _openAccountSecurity,
      onOpenReferral: _openReferral,
      onOpenSupport: _openSupport,
    ),
    const SizedBox(height: 20),
    TextButton.icon(
      onPressed: account.loading
          ? null
          : () async {
              await account.logout();
              if (mounted) setState(() {});
            },
      icon: const Icon(Icons.logout_rounded),
      label: Text(context.l10n.accountSignOut),
    ),
  ];

  Future<void> _openProfileEditor() async {
    _syncProfile(context.read<MemberAccountController>().user);
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => Consumer<MemberAccountController>(
          builder: (context, account, child) {
            final user = account.user;
            return FloatingSubpageScaffold(
              title: context.l10n.accountEditProfile,
              body: user == null
                  ? const SizedBox.shrink()
                  : ListView(
                      padding: floatingSubpagePadding(context, bottom: 40),
                      children: [_profileCard(account, user)],
                    ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _openAccountSecurity() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const _AccountSecurityPage()),
    );
  }

  Future<void> _openReferral() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const _AccountReferralPage()),
    );
  }

  Future<void> _openSupport() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const _AccountSupportPage()),
    );
  }

  Widget _formCard(MemberAccountController account) {
    final l10n = context.l10n;
    return _SectionCard(
      key: const ValueKey('account-sign-in-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_mode == _AccountMode.email) ...[
            Text(
              l10n.accountLoginTab,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 5),
            Text(
              l10n.accountEmailFirstHint,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            _accountTextField(
              _email,
              l10n.accountEmail,
              Icons.mail_outline_rounded,
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 18),
            FilledButton(
              key: const ValueKey('account-email-continue'),
              onPressed: account.loading ? null : _continueWithEmail,
              child: Text(l10n.accountContinue),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  key: const ValueKey('account-open-register'),
                  onPressed: account.loading
                      ? null
                      : () => _switchMode(_AccountMode.register),
                  child: Text(l10n.accountNoAccount),
                ),
                TextButton(
                  key: const ValueKey('account-open-reset'),
                  onPressed: account.loading
                      ? null
                      : () => _switchMode(_AccountMode.reset),
                  child: Text(l10n.accountForgotPassword),
                ),
              ],
            ),
          ] else if (_email.text.trim().isEmpty) ...[
            Text(
              _modeTitle(),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 5),
            Text(
              _modeHint(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            _accountTextField(
              _email,
              l10n.accountEmail,
              Icons.mail_outline_rounded,
              keyboardType: TextInputType.emailAddress,
            ),
          ] else ...[
            InkWell(
              key: const ValueKey('account-change-email'),
              borderRadius: BorderRadius.circular(14),
              onTap: account.loading
                  ? null
                  : () => _switchMode(_AccountMode.email),
              child: Ink(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.52),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.mail_outline_rounded,
                      size: 19,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _email.text.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      l10n.accountChangeEmail,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              _modeTitle(),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 5),
            Text(
              _modeHint(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (_mode == _AccountMode.register && _challenge != null) ...[
            const SizedBox(height: 18),
            _accountTextField(
              _username,
              l10n.accountUsername,
              Icons.alternate_email_rounded,
              helper: l10n.accountUsernameHint,
            ),
            const SizedBox(height: 12),
            _accountTextField(
              _displayName,
              l10n.accountDisplayName,
              Icons.person_outline_rounded,
            ),
          ],
          if (_challenge != null) ...[
            const SizedBox(height: 12),
            _accountTextField(
              _code,
              l10n.accountVerificationCode,
              Icons.password_rounded,
              keyboardType: TextInputType.number,
            ),
          ],
          if (_mode == _AccountMode.password ||
              (_challenge != null &&
                  (_mode == _AccountMode.register ||
                      _mode == _AccountMode.reset))) ...[
            const SizedBox(height: 12),
            _accountTextField(
              _password,
              l10n.accountPassword,
              Icons.lock_outline_rounded,
              obscure: _obscurePassword,
              helper: _mode == _AccountMode.password
                  ? null
                  : l10n.accountPasswordLengthHint,
              suffix: IconButton(
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
          ],
          if (_challenge != null &&
              (_mode == _AccountMode.register ||
                  _mode == _AccountMode.reset)) ...[
            const SizedBox(height: 12),
            _accountTextField(
              _confirmPassword,
              l10n.accountConfirmPassword,
              Icons.lock_reset_rounded,
              obscure: _obscurePassword,
            ),
          ],
          if (_mode != _AccountMode.email) ...[
            const SizedBox(height: 18),
            FilledButton(
              onPressed: account.loading ? null : _submit,
              child: account.loading
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(_submitLabel()),
            ),
            if (_mode == _AccountMode.password) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const ValueKey('account-use-email-code'),
                onPressed: account.loading
                    ? null
                    : () => _switchMode(_AccountMode.code),
                icon: const Icon(Icons.mark_email_read_outlined, size: 19),
                label: Text(l10n.accountUseEmailCode),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: account.loading
                        ? null
                        : () => _switchMode(_AccountMode.register),
                    child: Text(l10n.accountNoAccount),
                  ),
                  TextButton(
                    onPressed: account.loading
                        ? null
                        : () => _switchMode(_AccountMode.reset),
                    child: Text(l10n.accountForgotPassword),
                  ),
                ],
              ),
            ] else
              TextButton(
                onPressed: account.loading
                    ? null
                    : () => _switchMode(_AccountMode.password),
                child: Text(
                  _mode == _AccountMode.register
                      ? l10n.accountHaveAccount
                      : l10n.accountBackToPassword,
                ),
              ),
          ],
          const SizedBox(height: 20),
          Divider(
            height: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          const SizedBox(height: 20),
          _ExternalLoginMethods(
            account: account,
            polling: _polling,
            authorization: _deviceAuthorization,
            onLogin: _externalLogin,
            onLoginApple: _loginWithApple,
            onCancel: () => setState(() => _polling = false),
          ),
        ],
      ),
    );
  }

  String _modeTitle() => switch (_mode) {
    _AccountMode.email => context.l10n.accountLoginTab,
    _AccountMode.password => context.l10n.accountPasswordLoginTitle,
    _AccountMode.register => context.l10n.accountRegisterTab,
    _AccountMode.code => context.l10n.accountCodeTab,
    _AccountMode.reset => context.l10n.accountResetTab,
  };

  String _modeHint() => switch (_mode) {
    _AccountMode.email => context.l10n.accountEmailFirstHint,
    _AccountMode.password => context.l10n.accountPasswordLoginHint,
    _AccountMode.register => context.l10n.accountRegisterHint,
    _AccountMode.code => context.l10n.accountCodeLoginHint,
    _AccountMode.reset => context.l10n.accountResetHint,
  };

  String _submitLabel() {
    final l10n = context.l10n;
    if (_challenge == null &&
        _mode != _AccountMode.email &&
        _mode != _AccountMode.password) {
      return l10n.accountSendCode;
    }
    return switch (_mode) {
      _AccountMode.email => l10n.accountContinue,
      _AccountMode.password => l10n.accountSignIn,
      _AccountMode.register => l10n.accountCreate,
      _AccountMode.code => l10n.accountSignIn,
      _AccountMode.reset => l10n.accountResetPassword,
    };
  }

  Widget _profileCard(MemberAccountController account, MemberUser user) =>
      _SectionCard(
        title: context.l10n.accountProfileTitle,
        icon: Icons.person_outline_rounded,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _MemberAvatar(user: user, size: 58),
                const SizedBox(width: 12),
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: account.loading ? null : _changeAvatar,
                        icon: const Icon(Icons.photo_camera_outlined, size: 18),
                        label: Text(context.l10n.accountChangeAvatar),
                      ),
                      if (user.avatarUrl != null)
                        TextButton(
                          onPressed: account.loading
                              ? null
                              : account.deleteAvatar,
                          child: Text(context.l10n.accountRemoveAvatar),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _accountTextField(
              _username,
              context.l10n.accountUsername,
              Icons.alternate_email_rounded,
              helper: context.l10n.accountUsernameHint,
            ),
            const SizedBox(height: 12),
            _accountTextField(
              _displayName,
              context.l10n.accountDisplayName,
              Icons.badge_outlined,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: account.loading ? null : _saveProfile,
              child: Text(context.l10n.accountSaveProfile),
            ),
          ],
        ),
      );
}
