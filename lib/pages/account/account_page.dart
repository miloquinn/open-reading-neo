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
          _field(
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
      onOpenSecurity: () => _openAccountSecurity(),
      onOpenReferral: () => _openReferral(),
      onOpenSupport: () => _openSupport(),
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
            _field(
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
            _field(
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
            _field(
              _username,
              l10n.accountUsername,
              Icons.alternate_email_rounded,
              helper: l10n.accountUsernameHint,
            ),
            const SizedBox(height: 12),
            _field(
              _displayName,
              l10n.accountDisplayName,
              Icons.person_outline_rounded,
            ),
          ],
          if (_challenge != null) ...[
            const SizedBox(height: 12),
            _field(
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
            _field(
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
            _field(
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
            _field(
              _username,
              context.l10n.accountUsername,
              Icons.alternate_email_rounded,
              helper: context.l10n.accountUsernameHint,
            ),
            const SizedBox(height: 12),
            _field(
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

  Widget _field(
    TextEditingController controller,
    String label,
    IconData icon, {
    bool obscure = false,
    String? helper,
    TextInputType? keyboardType,
    Widget? suffix,
  }) => TextField(
    controller: controller,
    obscureText: obscure,
    keyboardType: keyboardType,
    autocorrect: false,
    enableSuggestions: !obscure,
    decoration: InputDecoration(
      labelText: label,
      helperText: helper,
      prefixIcon: Icon(icon),
      suffixIcon: suffix,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}

class _AccountIntroCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) => _SectionCard(
    child: Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(15),
          ),
          child: Icon(
            Icons.account_circle_outlined,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.accountIntroTitle,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 3),
              Text(
                context.l10n.accountPageSubtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ExternalLoginMethods extends StatefulWidget {
  const _ExternalLoginMethods({
    required this.account,
    required this.polling,
    required this.authorization,
    required this.onLogin,
    required this.onLoginApple,
    required this.onCancel,
  });

  final MemberAccountController account;
  final bool polling;
  final DeviceAuthorization? authorization;
  final ValueChanged<MemberExternalAuthMethod> onLogin;
  final VoidCallback onLoginApple;
  final VoidCallback onCancel;

  @override
  State<_ExternalLoginMethods> createState() => _ExternalLoginMethodsState();
}

class _ExternalLoginMethodsState extends State<_ExternalLoginMethods> {
  bool _showMore = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.login_rounded, size: 20, color: colorScheme.primary),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                context.l10n.accountSignInMethodsTitle,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        const SizedBox(height: 15),
        if (polling)
          _AuthorizationProgress(
            authorization: widget.authorization,
            onCancel: widget.onCancel,
          )
        else ...[
          if (_isApplePlatform && widget.account.providers.apple) ...[
            _ProviderLoginButton(
              key: const ValueKey('account-provider-apple'),
              label: context.l10n.accountUseApple,
              brand: _ProviderBrand.apple,
              enabled: !widget.account.loading,
              onTap: defaultTargetPlatform == TargetPlatform.macOS
                  ? () => widget.onLogin(MemberExternalAuthMethod.apple)
                  : widget.onLoginApple,
            ),
            const SizedBox(height: 8),
          ],
          _ProviderLoginButton(
            key: const ValueKey('account-provider-github'),
            label: context.l10n.accountUseGithub,
            brand: _ProviderBrand.github,
            enabled: widget.account.providers.github && !widget.account.loading,
            onTap: () => widget.onLogin(MemberExternalAuthMethod.github),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            key: const ValueKey('account-more-providers'),
            onPressed: widget.account.loading
                ? null
                : () => setState(() => _showMore = !_showMore),
            icon: Icon(
              _showMore
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: 20,
            ),
            label: Text(context.l10n.accountMoreSignInMethods),
          ),
          if (_showMore) ...[
            const SizedBox(height: 4),
            _ProviderLoginButton(
              key: const ValueKey('account-provider-passkey'),
              label: context.l10n.accountUsePasskey,
              brand: _ProviderBrand.passkey,
              enabled:
                  widget.account.providers.passkey && !widget.account.loading,
              onTap: () => widget.onLogin(MemberExternalAuthMethod.passkey),
            ),
            const SizedBox(height: 8),
            _ProviderLoginButton(
              key: const ValueKey('account-provider-google'),
              label: context.l10n.accountUseGoogle,
              brand: _ProviderBrand.google,
              enabled:
                  widget.account.providers.google && !widget.account.loading,
              onTap: () => widget.onLogin(MemberExternalAuthMethod.google),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            context.l10n.accountExternalHint,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
        ],
      ],
    );
    return content;
  }

  bool get polling => widget.polling;

  bool get _isApplePlatform =>
      !kIsWeb &&
      {
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      }.contains(defaultTargetPlatform);
}

class _AuthorizationProgress extends StatelessWidget {
  const _AuthorizationProgress({
    required this.authorization,
    required this.onCancel,
  });

  final DeviceAuthorization? authorization;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final userCode = authorization?.userCode ?? '';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.36),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  context.l10n.accountExternalHint,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              TextButton(
                onPressed: onCancel,
                child: Text(
                  MaterialLocalizations.of(context).cancelButtonLabel,
                ),
              ),
            ],
          ),
          if (userCode.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.75),
                ),
              ),
              child: SelectableText(
                userCode,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2.4,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

enum _ProviderBrand { github, google, apple, passkey }

class _ProviderLoginButton extends StatelessWidget {
  const _ProviderLoginButton({
    super.key,
    required this.label,
    required this.brand,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final _ProviderBrand brand;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark =
        brand == _ProviderBrand.github || brand == _ProviderBrand.apple;
    final isPasskey = brand == _ProviderBrand.passkey;
    final foreground = isDark ? Colors.white : colorScheme.onSurface;
    final background = isDark
        ? const Color(0xFF24292F)
        : isPasskey
        ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.52)
        : colorScheme.surface;

    return Opacity(
      opacity: enabled ? 1 : 0.48,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            height: isPasskey ? 46 : 54,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isDark
                    ? const Color(0xFF24292F)
                    : colorScheme.outlineVariant.withValues(alpha: 0.86),
              ),
            ),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: isPasskey ? 21 : 24,
                  child: switch (brand) {
                    _ProviderBrand.passkey => Icon(
                      Icons.key_rounded,
                      size: 20,
                      color: colorScheme.primary,
                    ),
                    _ProviderBrand.apple => const Icon(
                      Icons.apple_rounded,
                      size: 24,
                      color: Colors.white,
                    ),
                    _ProviderBrand.github ||
                    _ProviderBrand.google => _ProviderBrandMark(brand: brand),
                  },
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: isPasskey
                          ? colorScheme.onSurfaceVariant
                          : foreground,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Icon(
                  Icons.arrow_forward_rounded,
                  size: 18,
                  color: (isPasskey ? colorScheme.onSurfaceVariant : foreground)
                      .withValues(alpha: 0.68),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProviderBrandMark extends StatelessWidget {
  const _ProviderBrandMark({required this.brand});

  final _ProviderBrand brand;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: switch (brand) {
      _ProviderBrand.github => const _GithubMarkPainter(),
      _ProviderBrand.google => const _GoogleMarkPainter(),
      _ProviderBrand.apple || _ProviderBrand.passkey => null,
    },
  );
}

class _GithubMarkPainter extends CustomPainter {
  const _GithubMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white;
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final mark = Path()
      ..moveTo(6.1, 7.2)
      ..lineTo(5.1, 3.1)
      ..quadraticBezierTo(8.2, 3.2, 10.1, 4.8)
      ..quadraticBezierTo(12, 4.35, 13.9, 4.8)
      ..quadraticBezierTo(15.8, 3.2, 18.9, 3.1)
      ..lineTo(17.9, 7.2)
      ..quadraticBezierTo(19.6, 9, 19.6, 11.8)
      ..quadraticBezierTo(19.6, 16.7, 15.8, 18.2)
      ..quadraticBezierTo(14.9, 18.55, 14.9, 20)
      ..lineTo(14.9, 22)
      ..lineTo(9.1, 22)
      ..lineTo(9.1, 20.3)
      ..quadraticBezierTo(7.5, 20.65, 6.7, 19.5)
      ..quadraticBezierTo(6, 18.45, 5, 17.75)
      ..quadraticBezierTo(4.4, 17.3, 4.7, 16.9)
      ..quadraticBezierTo(5, 16.55, 5.7, 17)
      ..quadraticBezierTo(6.9, 17.75, 7.4, 18.35)
      ..quadraticBezierTo(8, 19, 9.1, 18.7)
      ..quadraticBezierTo(9.15, 18, 9.55, 17.55)
      ..quadraticBezierTo(4.4, 16.95, 4.4, 11.8)
      ..quadraticBezierTo(4.4, 9, 6.1, 7.2)
      ..close();
    canvas.drawPath(mark, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _GoogleMarkPainter extends CustomPainter {
  const _GoogleMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final strokeWidth = size.shortestSide * 0.18;
    final rect = Rect.fromLTWH(
      strokeWidth / 2,
      strokeWidth / 2,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    Paint segment(Color color) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.butt;

    canvas.drawArc(rect, -0.18, 1.3, false, segment(const Color(0xFF4285F4)));
    canvas.drawArc(rect, 1.12, 1.16, false, segment(const Color(0xFF34A853)));
    canvas.drawArc(rect, 2.28, 0.92, false, segment(const Color(0xFFFBBC05)));
    canvas.drawArc(rect, 3.2, 1.55, false, segment(const Color(0xFFEA4335)));
    canvas.drawArc(rect, 4.75, 0.78, false, segment(const Color(0xFF4285F4)));

    final blue = Paint()
      ..color = const Color(0xFF4285F4)
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.square;
    canvas.drawLine(
      Offset(size.width * 0.52, size.height * 0.5),
      Offset(size.width * 0.93, size.height * 0.5),
      blue,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _SignedInHeader extends StatelessWidget {
  const _SignedInHeader({required this.user, required this.supporter});

  final MemberUser user;
  final bool supporter;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF123456), Color(0xFF1768B4)],
      ),
      borderRadius: BorderRadius.circular(22),
    ),
    child: Row(
      children: [
        _MemberAvatar(user: user, size: 62),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      user.effectiveName,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (supporter) ...[
                    const SizedBox(width: 8),
                    _Badge(label: context.l10n.accountSupporterBadge),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '@${user.username} · ${user.email}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.72),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _AccountSecurityPage extends StatelessWidget {
  const _AccountSecurityPage();

  @override
  Widget build(BuildContext context) => Consumer<MemberAccountController>(
    builder: (context, account, child) {
      final user = account.user;
      final status = account.mfaStatus;
      return FloatingSubpageScaffold(
        title: context.l10n.accountSecurityTitle,
        body: user == null
            ? const SizedBox.shrink()
            : ListView(
                padding: floatingSubpagePadding(context, bottom: 40),
                children: [
                  _LoginMethodsCard(user: user),
                  const SizedBox(height: 16),
                  _SectionCard(
                    child: Column(
                      children: [
                        _AccountActionTile(
                          key: const ValueKey('account-change-email'),
                          icon: Icons.mark_email_unread_outlined,
                          title: context.l10n.accountChangeEmailTitle,
                          subtitle: user.email,
                          onTap: () => Navigator.of(context).push<void>(
                            MaterialPageRoute(
                              builder: (_) => const _ChangeEmailPage(),
                            ),
                          ),
                        ),
                        const Divider(height: 1),
                        _AccountActionTile(
                          key: const ValueKey('account-change-password'),
                          icon: Icons.password_rounded,
                          title: context.l10n.accountChangePasswordTitle,
                          subtitle: context.l10n.accountPasswordLengthHint,
                          onTap: () => Navigator.of(context).push<void>(
                            MaterialPageRoute(
                              builder: (_) => const _ChangePasswordPage(),
                            ),
                          ),
                        ),
                        const Divider(height: 1),
                        _AccountActionTile(
                          key: const ValueKey('account-mfa-setup'),
                          icon: Icons.phonelink_lock_rounded,
                          title: context.l10n.accountMfaTitle,
                          subtitle: status == null
                              ? context.l10n.accountSecurityLoading
                              : status.enabled
                              ? context.l10n.accountMfaEnabled
                              : context.l10n.accountMfaDisabledByDefault,
                          onTap: status == null
                              ? null
                              : () => Navigator.of(context).push<void>(
                                  MaterialPageRoute(
                                    builder: (_) => const _MfaOverviewPage(),
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      );
    },
  );
}

class _ChangeEmailPage extends StatefulWidget {
  const _ChangeEmailPage();

  @override
  State<_ChangeEmailPage> createState() => _ChangeEmailPageState();
}

class _ChangeEmailPageState extends State<_ChangeEmailPage> {
  final _newEmail = TextEditingController();
  final _currentEmailCode = TextEditingController();
  final _newEmailCode = TextEditingController();
  MemberEmailChangeChallenge? _challenge;

  @override
  void dispose() {
    _newEmail.dispose();
    _currentEmailCode.dispose();
    _newEmailCode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final account = context.read<MemberAccountController>();
    try {
      final challenge = _challenge;
      if (challenge == null) {
        final value = await account.requestEmailChangeCode(_newEmail.text);
        if (mounted) setState(() => _challenge = value);
        return;
      }
      await account.changeEmail(
        newEmail: _newEmail.text,
        currentChallengeId: challenge.currentChallengeId,
        currentCode: _currentEmailCode.text,
        newChallengeId: challenge.newChallengeId,
        newCode: _newEmailCode.text,
      );
      if (!mounted) return;
      showSideToast(context, context.l10n.accountEmailChanged);
      Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        showSideToast(context, error.toString(), kind: SideToastKind.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<MemberAccountController>();
    final user = account.user;
    return FloatingSubpageScaffold(
      title: '',
      showHeader: false,
      body: user == null
          ? const SizedBox.shrink()
          : ListView(
              padding: floatingSubpagePadding(
                context,
                left: 20,
                top: 0,
                right: 20,
                bottom: 40,
              ),
              children: [
                _FlowIntro(
                  icon: _challenge == null
                      ? Icons.alternate_email_rounded
                      : Icons.mark_email_read_outlined,
                  title: _challenge == null
                      ? context.l10n.accountChangeEmailEnterTitle
                      : context.l10n.accountChangeEmailVerifyTitle,
                  body: _challenge == null
                      ? context.l10n.accountChangeEmailEnterHint
                      : context.l10n.accountChangeEmailVerifyHint,
                ),
                const SizedBox(height: 16),
                _SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '${context.l10n.accountCurrentEmail}: ${user.email}',
                      ),
                      const SizedBox(height: 14),
                      if (_challenge == null)
                        _accountTextField(
                          _newEmail,
                          context.l10n.accountNewEmail,
                          Icons.mark_email_unread_outlined,
                          keyboardType: TextInputType.emailAddress,
                        )
                      else ...[
                        _accountTextField(
                          _currentEmailCode,
                          context.l10n.accountCurrentEmailCode,
                          Icons.password_rounded,
                          keyboardType: TextInputType.number,
                        ),
                        const SizedBox(height: 12),
                        _accountTextField(
                          _newEmailCode,
                          context.l10n.accountNewEmailCode,
                          Icons.password_rounded,
                          keyboardType: TextInputType.number,
                        ),
                      ],
                      const SizedBox(height: 16),
                      FilledButton(
                        key: const ValueKey('account-change-email-submit'),
                        onPressed: account.loading ? null : _submit,
                        child: Text(
                          _challenge == null
                              ? context.l10n.accountSendBothCodes
                              : context.l10n.accountChangeEmailAction,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _ChangePasswordPage extends StatefulWidget {
  const _ChangePasswordPage();

  @override
  State<_ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<_ChangePasswordPage> {
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  MemberEmailChallenge? _challenge;

  @override
  void dispose() {
    _code.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final account = context.read<MemberAccountController>();
    try {
      final challenge = _challenge;
      if (challenge == null) {
        final value = await account.requestPasswordChangeCode();
        if (mounted) setState(() => _challenge = value);
        return;
      }
      if (_password.text != _confirmPassword.text) {
        throw MemberAccountException(context.l10n.accountPasswordsMismatch);
      }
      await account.changePassword(
        challengeId: challenge.id,
        code: _code.text,
        password: _password.text,
      );
      if (!mounted) return;
      showSideToast(context, context.l10n.accountPasswordChanged);
      Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        showSideToast(context, error.toString(), kind: SideToastKind.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<MemberAccountController>();
    return FloatingSubpageScaffold(
      title: '',
      showHeader: false,
      body: ListView(
        padding: floatingSubpagePadding(
          context,
          left: 20,
          top: 0,
          right: 20,
          bottom: 40,
        ),
        children: [
          _FlowIntro(
            icon: _challenge == null
                ? Icons.outgoing_mail
                : Icons.password_rounded,
            title: _challenge == null
                ? context.l10n.accountPasswordEmailTitle
                : context.l10n.accountPasswordNewTitle,
            body: _challenge == null
                ? context.l10n.accountPasswordEmailHint
                : context.l10n.accountPasswordNewHint,
          ),
          const SizedBox(height: 16),
          _SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_challenge != null) ...[
                  _accountTextField(
                    _code,
                    context.l10n.accountVerificationCode,
                    Icons.password_rounded,
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 12),
                  _accountTextField(
                    _password,
                    context.l10n.accountNewPassword,
                    Icons.lock_outline_rounded,
                    obscure: true,
                    helper: context.l10n.accountPasswordLengthHint,
                  ),
                  const SizedBox(height: 12),
                  _accountTextField(
                    _confirmPassword,
                    context.l10n.accountConfirmPassword,
                    Icons.lock_reset_rounded,
                    obscure: true,
                  ),
                  const SizedBox(height: 16),
                ],
                FilledButton(
                  key: const ValueKey('account-change-password-submit'),
                  onPressed: account.loading ? null : _submit,
                  child: Text(
                    _challenge == null
                        ? context.l10n.accountSendCode
                        : context.l10n.accountChangePasswordAction,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MfaOverviewPage extends StatefulWidget {
  const _MfaOverviewPage();

  @override
  State<_MfaOverviewPage> createState() => _MfaOverviewPageState();
}

class _MfaOverviewPageState extends State<_MfaOverviewPage> {
  final _disableCode = TextEditingController();

  @override
  void dispose() {
    _disableCode.dispose();
    super.dispose();
  }

  Future<void> _disable() async {
    try {
      await context.read<MemberAccountController>().disableMfa(
        _disableCode.text,
      );
      if (!mounted) return;
      _disableCode.clear();
      showSideToast(context, context.l10n.accountMfaDisabled);
    } catch (error) {
      if (mounted) {
        showSideToast(context, error.toString(), kind: SideToastKind.error);
      }
    }
  }

  Future<void> _sendCode() async {
    try {
      final challenge = await context
          .read<MemberAccountController>()
          .requestMfaSetupCode();
      if (!mounted) return;
      await Navigator.of(context).pushReplacement<void, void>(
        MaterialPageRoute(
          builder: (_) => _MfaEmailCodePage(challenge: challenge),
        ),
      );
    } catch (error) {
      if (mounted) {
        showSideToast(context, error.toString(), kind: SideToastKind.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<MemberAccountController>();
    final status = account.mfaStatus;
    final email = account.user?.email ?? '';
    return FloatingSubpageScaffold(
      title: '',
      showHeader: false,
      body: status == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: floatingSubpagePadding(
                context,
                left: 20,
                top: 0,
                right: 20,
                bottom: 40,
              ),
              children: [
                _FlowIntro(
                  icon: status.enabled
                      ? Icons.verified_user_rounded
                      : Icons.outgoing_mail,
                  title: status.enabled
                      ? context.l10n.accountMfaOnTitle
                      : context.l10n.accountMfaEmailTitle,
                  body: status.enabled
                      ? context.l10n.accountMfaEnabled
                      : context.l10n.accountMfaEmailHint(email),
                ),
                const SizedBox(height: 24),
                if (status.enabled)
                  _SectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _accountTextField(
                          _disableCode,
                          context.l10n.accountMfaOrRecoveryCode,
                          Icons.password_rounded,
                        ),
                        const SizedBox(height: 16),
                        OutlinedButton(
                          key: const ValueKey('account-mfa-disable'),
                          onPressed: account.loading ? null : _disable,
                          child: Text(context.l10n.accountMfaDisable),
                        ),
                      ],
                    ),
                  )
                else
                  SizedBox(
                    height: 52,
                    child: FilledButton.icon(
                      key: const ValueKey('account-mfa-send-email-submit'),
                      onPressed: account.loading ? null : _sendCode,
                      icon: const Icon(Icons.mail_outline_rounded),
                      label: Text(context.l10n.accountMfaSendSetupCode),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _MfaEmailCodePage extends StatefulWidget {
  const _MfaEmailCodePage({required this.challenge});

  final MemberEmailChallenge challenge;

  @override
  State<_MfaEmailCodePage> createState() => _MfaEmailCodePageState();
}

class _MfaEmailCodePageState extends State<_MfaEmailCodePage> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    try {
      final setup = await context.read<MemberAccountController>().setupMfa(
        challengeId: widget.challenge.id,
        code: _code.text,
      );
      if (!mounted) return;
      await Navigator.of(context).pushReplacement<void, void>(
        MaterialPageRoute(builder: (_) => _MfaAuthenticatorPage(setup: setup)),
      );
    } catch (error) {
      if (mounted) {
        showSideToast(context, error.toString(), kind: SideToastKind.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<MemberAccountController>();
    return FloatingSubpageScaffold(
      title: '',
      showHeader: false,
      body: ListView(
        padding: floatingSubpagePadding(
          context,
          left: 20,
          top: 0,
          right: 20,
          bottom: 40,
        ),
        children: [
          _FlowIntro(
            icon: Icons.mark_email_read_outlined,
            title: context.l10n.accountMfaEmailCodeTitle,
            body: context.l10n.accountMfaEmailCodeHint,
          ),
          const SizedBox(height: 16),
          _SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _accountTextField(
                  _code,
                  context.l10n.accountVerificationCode,
                  Icons.password_rounded,
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  key: const ValueKey('account-mfa-email-code-submit'),
                  onPressed: account.loading ? null : _continue,
                  child: Text(context.l10n.accountMfaContinueSetup),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MfaAuthenticatorPage extends StatefulWidget {
  const _MfaAuthenticatorPage({required this.setup});

  final MemberMfaSetup setup;

  @override
  State<_MfaAuthenticatorPage> createState() => _MfaAuthenticatorPageState();
}

class _MfaAuthenticatorPageState extends State<_MfaAuthenticatorPage> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    try {
      final confirmation = await context
          .read<MemberAccountController>()
          .confirmMfa(_code.text);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement<void, void>(
        MaterialPageRoute(
          builder: (_) =>
              _MfaRecoveryCodesPage(recoveryCodes: confirmation.recoveryCodes),
        ),
      );
    } catch (error) {
      if (mounted) {
        showSideToast(context, error.toString(), kind: SideToastKind.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<MemberAccountController>();
    return FloatingSubpageScaffold(
      title: '',
      showHeader: false,
      body: ListView(
        padding: floatingSubpagePadding(
          context,
          left: 20,
          top: 0,
          right: 20,
          bottom: 40,
        ),
        children: [
          _FlowIntro(
            icon: Icons.qr_code_2_rounded,
            title: context.l10n.accountMfaAuthenticatorTitle,
            body: context.l10n.accountMfaAuthenticatorHint,
          ),
          const SizedBox(height: 16),
          _SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  child: QrCodeView(
                    key: const ValueKey('account-mfa-qr-code'),
                    data: widget.setup.otpauthUri.toString(),
                    size: 224,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  context.l10n.accountMfaSecretLabel,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 6),
                _SecretValue(value: widget.setup.secret),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () => launchUrl(
                    widget.setup.otpauthUri,
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: Text(context.l10n.accountMfaOpenAuthenticator),
                ),
                const SizedBox(height: 16),
                _accountTextField(
                  _code,
                  context.l10n.accountMfaCode,
                  Icons.password_rounded,
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  key: const ValueKey('account-mfa-confirm'),
                  onPressed: account.loading ? null : _confirm,
                  child: Text(context.l10n.accountMfaConfirm),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MfaRecoveryCodesPage extends StatelessWidget {
  const _MfaRecoveryCodesPage({required this.recoveryCodes});

  final List<String> recoveryCodes;

  @override
  Widget build(BuildContext context) => FloatingSubpageScaffold(
    title: '',
    showHeader: false,
    canPop: false,
    body: ListView(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 40),
      children: [
        _FlowIntro(
          icon: Icons.key_rounded,
          title: context.l10n.accountMfaRecoveryTitle,
          body: context.l10n.accountRecoveryCodesWarning,
        ),
        const SizedBox(height: 16),
        _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableText(
                recoveryCodes.join('\n'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.65,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: recoveryCodes.join('\n')),
                  );
                  if (context.mounted) {
                    showSideToast(
                      context,
                      context.l10n.accountRecoveryCodesCopied,
                    );
                  }
                },
                icon: const Icon(Icons.copy_rounded),
                label: Text(context.l10n.accountCopyRecoveryCodes),
              ),
              const SizedBox(height: 8),
              FilledButton(
                key: const ValueKey('account-mfa-recovery-saved'),
                onPressed: () => Navigator.of(context).pop(),
                child: Text(context.l10n.accountRecoveryCodesSaved),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _FlowIntro extends StatelessWidget {
  const _FlowIntro({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: colorScheme.primary),
        ),
        const SizedBox(height: 18),
        Text(
          title,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w900,
            letterSpacing: -0.7,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          body,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

class _SecretValue extends StatelessWidget {
  const _SecretValue({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      children: [
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ),
        IconButton(
          tooltip: MaterialLocalizations.of(context).copyButtonLabel,
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: value));
            if (context.mounted) {
              showSideToast(context, context.l10n.accountMfaSecretCopied);
            }
          },
          icon: const Icon(Icons.copy_rounded),
        ),
      ],
    ),
  );
}

Widget _accountTextField(
  TextEditingController controller,
  String label,
  IconData icon, {
  bool obscure = false,
  String? helper,
  TextInputType? keyboardType,
}) => TextField(
  controller: controller,
  obscureText: obscure,
  keyboardType: keyboardType,
  autocorrect: false,
  enableSuggestions: !obscure,
  decoration: InputDecoration(
    labelText: label,
    helperText: helper,
    prefixIcon: Icon(icon),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
  ),
);

class _LoginMethodsCard extends StatelessWidget {
  const _LoginMethodsCard({required this.user});

  final MemberUser user;

  @override
  Widget build(BuildContext context) => _SectionCard(
    title: context.l10n.accountSignInMethodsTitle,
    icon: Icons.shield_outlined,
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: user.authMethods
          .map(
            (method) => Chip(
              avatar: const Icon(Icons.check_circle_rounded, size: 17),
              label: Text(_methodLabel(context, method)),
            ),
          )
          .toList(growable: false),
    ),
  );

  String _methodLabel(BuildContext context, String method) => switch (method) {
    'github' => 'GitHub',
    'google' => 'Google',
    'passkey' => 'Passkey',
    'password' => context.l10n.accountPassword,
    'email_code' => context.l10n.accountEmail,
    _ => method,
  };
}

class _AccountActionsCard extends StatelessWidget {
  const _AccountActionsCard({
    required this.user,
    required this.onEditProfile,
    required this.onOpenSecurity,
    required this.onOpenReferral,
    required this.onOpenSupport,
  });

  final MemberUser user;
  final VoidCallback onEditProfile;
  final VoidCallback onOpenSecurity;
  final VoidCallback onOpenReferral;
  final VoidCallback onOpenSupport;

  @override
  Widget build(BuildContext context) => _SectionCard(
    child: Column(
      children: [
        _AccountActionTile(
          key: const ValueKey('account-edit-profile'),
          icon: Icons.person_outline_rounded,
          title: context.l10n.accountEditProfile,
          subtitle: '@${user.username}',
          onTap: onEditProfile,
        ),
        const Divider(height: 1),
        _AccountActionTile(
          key: const ValueKey('account-security'),
          icon: Icons.shield_outlined,
          title: context.l10n.accountSecurityTitle,
          subtitle: user.email,
          onTap: onOpenSecurity,
        ),
        const Divider(height: 1),
        _AccountActionTile(
          key: const ValueKey('account-referral'),
          icon: Icons.group_add_rounded,
          title: context.l10n.accountInviteTitle,
          subtitle: context.l10n.accountInviteSubtitle,
          onTap: onOpenReferral,
        ),
        const Divider(height: 1),
        _AccountActionTile(
          key: const ValueKey('account-support'),
          icon: Icons.volunteer_activism_rounded,
          title: context.l10n.accountSupportTitle,
          subtitle: context.l10n.accountSupportFreeSubtitle,
          onTap: onOpenSupport,
        ),
      ],
    ),
  );
}

class _AccountReferralPage extends StatelessWidget {
  const _AccountReferralPage();

  @override
  Widget build(BuildContext context) => Consumer<MemberAccountController>(
    builder: (context, account, child) => FloatingSubpageScaffold(
      title: context.l10n.accountInviteTitle,
      body: ListView(
        padding: floatingSubpagePadding(context, bottom: 40),
        children: [
          if (account.referral != null)
            _ReferralCard(account: account)
          else
            _SectionCard(child: Text(context.l10n.accountInviteSubtitle)),
        ],
      ),
    ),
  );
}

class _AccountSupportPage extends StatelessWidget {
  const _AccountSupportPage();

  @override
  Widget build(BuildContext context) => Consumer<MemberAccountController>(
    builder: (context, account, child) => FloatingSubpageScaffold(
      title: context.l10n.accountSupportTitle,
      body: ListView(
        padding: floatingSubpagePadding(context, bottom: 40),
        children: [_SupportCard(account: account)],
      ),
    ),
  );
}

class _AccountActionTile extends StatelessWidget {
  const _AccountActionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
      leading: Container(
        width: 42,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: 21,
          color: Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    ),
  );
}

class _SupportCard extends StatefulWidget {
  const _SupportCard({required this.account});

  final MemberAccountController account;

  @override
  State<_SupportCard> createState() => _SupportCardState();
}

class _SupportCardState extends State<_SupportCard> {
  final _redemptionCode = TextEditingController();

  @override
  void dispose() {
    _redemptionCode.dispose();
    super.dispose();
  }

  Future<void> _redeem() async {
    try {
      final wasWaitingForInviteReward =
          widget.account.referral?.inviter?.status == 'pending';
      await widget.account.redeemMembership(_redemptionCode.text);
      _redemptionCode.clear();
      if (mounted) {
        showSideToast(
          context,
          wasWaitingForInviteReward
              ? context.l10n.accountPremiumUnlockedReferral
              : context.l10n.accountPremiumUnlocked,
        );
      }
    } catch (error) {
      if (mounted) {
        showSideToast(context, error.toString(), kind: SideToastKind.error);
      }
    }
  }

  Future<void> _purchaseWithApple() async {
    try {
      await widget.account.purchaseApplePremium();
      if (mounted) {
        showSideToast(context, context.l10n.accountApplePurchaseSubmitted);
      }
    } catch (error) {
      if (mounted) {
        showSideToast(context, error.toString(), kind: SideToastKind.error);
      }
    }
  }

  Future<void> _restoreApplePurchase() async {
    try {
      await widget.account.restoreApplePremium();
      if (mounted) {
        showSideToast(context, context.l10n.accountAppleRestoreSubmitted);
      }
    } catch (error) {
      if (mounted) {
        showSideToast(context, error.toString(), kind: SideToastKind.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.account;
    final purchaseUrl = account.membershipConfig?.purchaseUrl;
    final applePlatform =
        !kIsWeb &&
        {
          TargetPlatform.iOS,
          TargetPlatform.macOS,
        }.contains(defaultTargetPlatform);
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: colors.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.primary,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.volunteer_activism_rounded,
                  size: 21,
                  color: colors.onPrimary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  context.l10n.accountSupportTitle,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: colors.onPrimaryContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            account.membership?.premium == true
                ? context.l10n.accountPremiumLifetime
                : context.l10n.accountSupportFreeTitle,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 5),
          Text(
            account.membership?.premium == true
                ? context.l10n.accountPremiumLifetimeSubtitle
                : context.l10n.accountSupportFreeSubtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          if (account.membership?.premium != true) ...[
            const SizedBox(height: 12),
            Container(
              key: const ValueKey('account-premium-purchase-notice'),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colors.tertiaryContainer.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colors.tertiary.withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.tips_and_updates_rounded,
                      size: 15,
                      color: colors.onTertiaryContainer,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      context.l10n.accountSupportPurchaseNotice,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onTertiaryContainer,
                        height: 1.55,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (account.isAuthenticated &&
              account.membership?.premium != true &&
              !applePlatform) ...[
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('account-redemption-code'),
              controller: _redemptionCode,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: context.l10n.accountRedemptionCode,
                prefixIcon: const Icon(Icons.key_rounded),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const ValueKey('account-redeem-premium'),
              onPressed: account.loading ? null : _redeem,
              icon: const Icon(Icons.lock_open_rounded),
              label: Text(context.l10n.accountRedeemPremium),
            ),
          ],
          if (account.isAuthenticated &&
              account.membership?.premium != true &&
              applePlatform) ...[
            const SizedBox(height: 14),
            Text(
              context.l10n.accountApplePurchaseHint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            _AppleStorePurchaseButton(
              key: const ValueKey('account-apple-purchase'),
              purchase: account.applePurchase,
              onPurchase: _purchaseWithApple,
            ),
            const SizedBox(height: 4),
            Center(
              child: CupertinoButton(
                key: const ValueKey('account-apple-restore'),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                minimumSize: Size.zero,
                onPressed: account.applePurchase.loading
                    ? null
                    : _restoreApplePurchase,
                child: Text(
                  context.l10n.accountAppleRestore,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: account.applePurchase.loading
                        ? CupertinoColors.inactiveGray
                        : CupertinoColors.activeBlue.resolveFrom(context),
                  ),
                ),
              ),
            ),
            if (account.applePurchase.error != null &&
                account.applePurchase.product != null) ...[
              const SizedBox(height: 4),
              Text(
                account.applePurchase.error!,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.error),
              ),
            ],
          ],
          if (purchaseUrl != null && !applePlatform) ...[
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: () => launchUrl(
                Uri.parse(purchaseUrl),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.favorite_outline_rounded),
              label: Text(context.l10n.accountSupportAction),
            ),
          ],
        ],
      ),
    );
  }
}

/// Mirrors the iOS "Get"/pill purchase button so App Store purchase reads as
/// a native control rather than a generic Material button. Product loading,
/// purchase-in-flight, and failed-to-load states share one pill so the
/// button never sits blank while StoreKit is still answering.
class _AppleStorePurchaseButton extends StatelessWidget {
  const _AppleStorePurchaseButton({
    super.key,
    required this.purchase,
    required this.onPurchase,
  });

  final ApplePremiumPurchaseService purchase;
  final VoidCallback onPurchase;

  @override
  Widget build(BuildContext context) {
    final product = purchase.product;
    final loading = purchase.loading;
    if (product == null) {
      return CupertinoButton(
        padding: const EdgeInsets.symmetric(vertical: 13),
        borderRadius: BorderRadius.circular(14),
        color: CupertinoColors.systemFill.resolveFrom(context),
        onPressed: loading ? null : purchase.initialize,
        child: loading
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CupertinoActivityIndicator(),
              )
            : Text(
                purchase.error != null
                    ? context.l10n.accountAppleProductRetry
                    : context.l10n.accountAppleProductLoading,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
      );
    }
    return CupertinoButton.filled(
      padding: const EdgeInsets.symmetric(vertical: 13),
      borderRadius: BorderRadius.circular(14),
      onPressed: loading ? null : onPurchase,
      child: loading
          ? const SizedBox(
              height: 20,
              width: 20,
              child: CupertinoActivityIndicator(color: CupertinoColors.white),
            )
          : Text(
              '${context.l10n.accountApplePurchase} · ${product.price}',
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.white,
              ),
            ),
    );
  }
}

class _ReferralCard extends StatefulWidget {
  const _ReferralCard({required this.account});

  final MemberAccountController account;

  @override
  State<_ReferralCard> createState() => _ReferralCardState();
}

class _ReferralCardState extends State<_ReferralCard> {
  final _inviteCode = TextEditingController();

  @override
  void dispose() {
    _inviteCode.dispose();
    super.dispose();
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) showSideToast(context, context.l10n.accountInviteCopied);
  }

  Future<void> _bind() async {
    try {
      await widget.account.bindReferral(_inviteCode.text);
      _inviteCode.clear();
      if (mounted) showSideToast(context, context.l10n.accountInviteBound);
    } catch (error) {
      if (mounted) {
        showSideToast(context, error.toString(), kind: SideToastKind.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final referral = widget.account.referral;
    if (referral == null) return const SizedBox.shrink();
    final inviter = referral.inviter;
    final colors = Theme.of(context).colorScheme;
    return _SectionCard(
      title: context.l10n.accountInviteTitle,
      icon: Icons.group_add_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.l10n.accountInviteSubtitle,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            key: const ValueKey('account-invite-ticket'),
            padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
            decoration: BoxDecoration(
              color: colors.tertiaryContainer.withValues(alpha: 0.52),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: colors.tertiary.withValues(alpha: 0.2)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.accountInviteMyCode,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: colors.onTertiaryContainer.withValues(
                                alpha: 0.7,
                              ),
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        referral.inviteCode,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              color: colors.onTertiaryContainer,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w900,
                              letterSpacing: 2,
                            ),
                      ),
                    ],
                  ),
                ),
                IconButton.filledTonal(
                  key: const ValueKey('account-copy-invite-code'),
                  tooltip: context.l10n.accountInviteCopyCode,
                  onPressed: () => _copy(referral.inviteCode),
                  icon: const Icon(Icons.copy_rounded),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('account-share-invite'),
            onPressed: () => _copy(referral.inviteUrl.toString()),
            icon: const Icon(Icons.ios_share_rounded),
            label: Text(context.l10n.accountInviteShareAction),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _InviteStat(
                  value: referral.invitedCount,
                  label: context.l10n.accountInviteStatsInvited,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _InviteStat(
                  value: referral.rewardedCount,
                  label: context.l10n.accountInviteStatsRewarded,
                  highlighted: referral.rewardedCount > 0,
                ),
              ),
            ],
          ),
          if (referral.recentInvites.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(
              '最近邀请',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            ...referral.recentInvites
                .take(5)
                .map(
                  (item) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: CircleAvatar(
                      radius: 16,
                      child: Text(item.name.characters.first.toUpperCase()),
                    ),
                    title: Text(item.name),
                    subtitle: Text(
                      '绑定于 ${MaterialLocalizations.of(context).formatCompactDate(item.boundAt)}',
                    ),
                    trailing: Text(
                      item.status == 'rewarded' ? '已解锁奖励' : '等待兑换',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: item.status == 'rewarded'
                            ? Colors.green.shade700
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
          ],
          const SizedBox(height: 20),
          Text(
            context.l10n.accountInviteHowItWorks,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          _InviteStep(
            number: 1,
            title: context.l10n.accountInviteStepShareTitle,
            body: context.l10n.accountInviteStepShareBody,
          ),
          _InviteStep(
            number: 2,
            title: context.l10n.accountInviteStepBindTitle,
            body: context.l10n.accountInviteStepBindBody,
          ),
          _InviteStep(
            number: 3,
            title: context.l10n.accountInviteStepRedeemTitle,
            body: context.l10n.accountInviteStepRedeemBody,
            last: true,
          ),
          const Divider(height: 30),
          Text(
            context.l10n.accountInviteMyBinding,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          if (inviter != null)
            Container(
              key: const ValueKey('account-inviter-bound'),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: 0.58),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Icon(
                    inviter.status == 'rewarded'
                        ? Icons.verified_rounded
                        : Icons.hourglass_top_rounded,
                    color: inviter.status == 'rewarded'
                        ? colors.primary
                        : colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.l10n.accountInviterBound(inviter.name),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${inviter.code} · ${inviter.status == 'rewarded' ? context.l10n.accountInviteRewarded : context.l10n.accountInviteWaiting}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            )
          else if (widget.account.membership?.premium != true) ...[
            Text(
              context.l10n.accountInviteBindIntro,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('account-invite-code'),
              controller: _inviteCode,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: context.l10n.accountInviteBindLabel,
                helperText: context.l10n.accountInviteBindHint,
                prefixIcon: const Icon(Icons.person_add_alt_1_rounded),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              key: const ValueKey('account-bind-invite'),
              onPressed: widget.account.loading ? null : _bind,
              child: Text(context.l10n.accountInviteBindAction),
            ),
          ] else
            Text(
              context.l10n.accountInviteBindingNotNeeded,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

class _InviteStat extends StatelessWidget {
  const _InviteStat({
    required this.value,
    required this.label,
    this.highlighted = false,
  });

  final int value;
  final String label;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: highlighted
            ? colors.primaryContainer.withValues(alpha: 0.62)
            : colors.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$value',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: highlighted ? colors.primary : colors.onSurface,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _InviteStep extends StatelessWidget {
  const _InviteStep({
    required this.number,
    required this.title,
    required this.body,
    this.last = false,
  });

  final int number;
  final String title;
  final String body;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 34,
            child: Column(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '$number',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: colors.onPrimaryContainer,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                if (!last)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: colors.outlineVariant.withValues(alpha: 0.72),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    body,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MemberAvatar extends StatelessWidget {
  const _MemberAvatar({required this.user, required this.size});

  final MemberUser user;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Text(
        (user.effectiveName.trim().isEmpty ? user.username : user.effectiveName)
            .characters
            .first
            .toUpperCase(),
        style: TextStyle(fontSize: size * 0.34, fontWeight: FontWeight.w800),
      ),
    );
    return ClipOval(
      child: user.avatarUrl == null
          ? fallback
          : AccountAvatarImage(
              url: Uri.parse(user.avatarUrl!),
              fallback: fallback,
              width: size,
              height: size,
              fit: BoxFit.cover,
            ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({super.key, this.title, this.icon, required this.child});

  final String? title;
  final IconData? icon;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(17),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(
        color: Theme.of(
          context,
        ).colorScheme.outlineVariant.withValues(alpha: 0.72),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null) ...[
          Row(
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 9),
              ],
              Text(
                title!,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 15),
        ],
        child,
      ],
    ),
  );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}
