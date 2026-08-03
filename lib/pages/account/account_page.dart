import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/account/account.dart';
import '../../utils/localization_extension.dart';
import '../../widgets/side_toast.dart';

enum _AccountMode { login, register, code, reset }

class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  final _username = TextEditingController();
  final _displayName = TextEditingController();
  final _code = TextEditingController();
  final _mfaLoginCode = TextEditingController();
  final _newEmail = TextEditingController();
  final _currentEmailCode = TextEditingController();
  final _newEmailCode = TextEditingController();
  final _securityPassword = TextEditingController();
  final _securityConfirmPassword = TextEditingController();
  final _securityPasswordCode = TextEditingController();
  final _mfaCode = TextEditingController();
  _AccountMode _mode = _AccountMode.login;
  MemberEmailChallenge? _challenge;
  DeviceAuthorization? _deviceAuthorization;
  bool _polling = false;
  bool _obscurePassword = true;
  MemberEmailChangeChallenge? _emailChangeChallenge;
  MemberEmailChallenge? _passwordChangeChallenge;
  MemberEmailChallenge? _mfaSetupChallenge;
  MemberMfaSetup? _mfaSetup;
  List<String>? _recoveryCodes;

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
    _newEmail.dispose();
    _currentEmailCode.dispose();
    _newEmailCode.dispose();
    _securityPassword.dispose();
    _securityConfirmPassword.dispose();
    _securityPasswordCode.dispose();
    _mfaCode.dispose();
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

  Future<void> _submit() async {
    final account = context.read<MemberAccountController>();
    try {
      switch (_mode) {
        case _AccountMode.login:
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
        await Future<void>.delayed(Duration(seconds: authorization.interval));
        if (!mounted || !_polling) return;
        bool complete;
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

  Future<void> _changeEmail() async {
    final account = context.read<MemberAccountController>();
    try {
      final challenge = _emailChangeChallenge;
      if (challenge == null) {
        final value = await account.requestEmailChangeCode(_newEmail.text);
        if (mounted) setState(() => _emailChangeChallenge = value);
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
      setState(() {
        _emailChangeChallenge = null;
        _newEmail.clear();
        _currentEmailCode.clear();
        _newEmailCode.clear();
      });
      showSideToast(context, context.l10n.accountEmailChanged);
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _changePassword() async {
    final account = context.read<MemberAccountController>();
    try {
      final challenge = _passwordChangeChallenge;
      if (challenge == null) {
        final value = await account.requestPasswordChangeCode();
        if (mounted) setState(() => _passwordChangeChallenge = value);
        return;
      }
      if (_securityPassword.text != _securityConfirmPassword.text) {
        throw MemberAccountException(context.l10n.accountPasswordsMismatch);
      }
      await account.changePassword(
        challengeId: challenge.id,
        code: _securityPasswordCode.text,
        password: _securityPassword.text,
      );
      if (!mounted) return;
      setState(() {
        _passwordChangeChallenge = null;
        _securityPassword.clear();
        _securityConfirmPassword.clear();
        _securityPasswordCode.clear();
      });
      showSideToast(context, context.l10n.accountPasswordChanged);
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _setupMfa() async {
    final account = context.read<MemberAccountController>();
    try {
      final challenge = _mfaSetupChallenge;
      if (challenge == null) {
        final value = await account.requestMfaSetupCode();
        if (mounted) setState(() => _mfaSetupChallenge = value);
        return;
      }
      final setup = await account.setupMfa(
        challengeId: challenge.id,
        code: _mfaCode.text,
      );
      if (mounted) {
        setState(() {
          _mfaSetup = setup;
          _mfaCode.clear();
        });
      }
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _confirmMfa() async {
    try {
      final confirmation = await context
          .read<MemberAccountController>()
          .confirmMfa(_mfaCode.text);
      if (!mounted) return;
      setState(() {
        _mfaSetup = null;
        _mfaSetupChallenge = null;
        _mfaCode.clear();
        _recoveryCodes = confirmation.recoveryCodes;
      });
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _disableMfa() async {
    try {
      await context.read<MemberAccountController>().disableMfa(_mfaCode.text);
      if (!mounted) return;
      setState(() {
        _mfaCode.clear();
        _recoveryCodes = null;
      });
      showSideToast(context, context.l10n.accountMfaDisabled);
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _changeAvatar() async {
    final account = context.read<MemberAccountController>();
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    final path = result?.files.single.path;
    if (path == null) return;
    try {
      await account.uploadAvatar(path);
    } catch (error) {
      _showError(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<MemberAccountController>();
    final user = account.user;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.accountPageTitle)),
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Theme.of(context).colorScheme.primary.withValues(alpha: 0.055),
              Theme.of(context).colorScheme.surface,
            ],
          ),
        ),
        child: SafeArea(
          top: false,
          child: account.initialized
              ? ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
                  children: account.mfaRequired
                      ? _buildMfaChallenge(account)
                      : user == null
                      ? _buildSignedOut(account)
                      : _buildSignedIn(account, user),
                )
              : const Center(child: CircularProgressIndicator()),
        ),
      ),
    );
  }

  List<Widget> _buildSignedOut(MemberAccountController account) => [
    _AccountIntroCard(),
    const SizedBox(height: 16),
    _ExternalLoginCard(
      account: account,
      polling: _polling,
      authorization: _deviceAuthorization,
      onLogin: _externalLogin,
      onCancel: () => setState(() => _polling = false),
    ),
    const SizedBox(height: 16),
    _formCard(account),
    const SizedBox(height: 16),
    _SupportCard(account: account),
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
    _profileCard(account, user),
    const SizedBox(height: 16),
    _LoginMethodsCard(user: user),
    const SizedBox(height: 16),
    _securityCard(account, user),
    const SizedBox(height: 16),
    _SupportCard(account: account),
    const SizedBox(height: 18),
    OutlinedButton.icon(
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

  Widget _formCard(MemberAccountController account) {
    final l10n = context.l10n;
    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<_AccountMode>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: _AccountMode.login,
                label: Text(l10n.accountLoginTab),
              ),
              ButtonSegment(
                value: _AccountMode.register,
                label: Text(l10n.accountRegisterTab),
              ),
              ButtonSegment(
                value: _AccountMode.code,
                label: Text(l10n.accountCodeTab),
              ),
              ButtonSegment(
                value: _AccountMode.reset,
                label: Text(l10n.accountResetTab),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: account.loading
                ? null
                : (value) => setState(() {
                    _mode = value.first;
                    _challenge = null;
                    _code.clear();
                  }),
          ),
          const SizedBox(height: 18),
          _field(
            _email,
            l10n.accountEmail,
            Icons.mail_outline_rounded,
            keyboardType: TextInputType.emailAddress,
          ),
          if (_mode == _AccountMode.register) ...[
            const SizedBox(height: 12),
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
          if (_mode != _AccountMode.code) ...[
            const SizedBox(height: 12),
            _field(
              _password,
              l10n.accountPassword,
              Icons.lock_outline_rounded,
              obscure: _obscurePassword,
              helper: _mode == _AccountMode.login
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
          if (_mode == _AccountMode.register ||
              _mode == _AccountMode.reset) ...[
            const SizedBox(height: 12),
            _field(
              _confirmPassword,
              l10n.accountConfirmPassword,
              Icons.lock_reset_rounded,
              obscure: _obscurePassword,
            ),
          ],
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
        ],
      ),
    );
  }

  String _submitLabel() {
    final l10n = context.l10n;
    if (_challenge == null && _mode != _AccountMode.login) {
      return l10n.accountSendCode;
    }
    return switch (_mode) {
      _AccountMode.login => l10n.accountSignIn,
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

  Widget _securityCard(MemberAccountController account, MemberUser user) =>
      _SectionCard(
        title: context.l10n.accountSecurityTitle,
        icon: Icons.security_rounded,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.l10n.accountChangeEmailTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 10),
            Text('${context.l10n.accountCurrentEmail}: ${user.email}'),
            const SizedBox(height: 10),
            _field(
              _newEmail,
              context.l10n.accountNewEmail,
              Icons.mark_email_unread_outlined,
              keyboardType: TextInputType.emailAddress,
            ),
            if (_emailChangeChallenge != null) ...[
              const SizedBox(height: 10),
              _field(
                _currentEmailCode,
                context.l10n.accountCurrentEmailCode,
                Icons.password_rounded,
              ),
              const SizedBox(height: 10),
              _field(
                _newEmailCode,
                context.l10n.accountNewEmailCode,
                Icons.password_rounded,
              ),
            ],
            const SizedBox(height: 10),
            OutlinedButton(
              key: const ValueKey('account-change-email'),
              onPressed: account.loading ? null : _changeEmail,
              child: Text(
                _emailChangeChallenge == null
                    ? context.l10n.accountSendBothCodes
                    : context.l10n.accountChangeEmailAction,
              ),
            ),
            const Divider(height: 32),
            Text(
              context.l10n.accountChangePasswordTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (_passwordChangeChallenge != null) ...[
              const SizedBox(height: 10),
              _field(
                _securityPasswordCode,
                context.l10n.accountVerificationCode,
                Icons.password_rounded,
              ),
              const SizedBox(height: 10),
              _field(
                _securityPassword,
                context.l10n.accountNewPassword,
                Icons.lock_outline_rounded,
                obscure: true,
                helper: context.l10n.accountPasswordLengthHint,
              ),
              const SizedBox(height: 10),
              _field(
                _securityConfirmPassword,
                context.l10n.accountConfirmPassword,
                Icons.lock_reset_rounded,
                obscure: true,
              ),
            ],
            const SizedBox(height: 10),
            OutlinedButton(
              key: const ValueKey('account-change-password'),
              onPressed: account.loading ? null : _changePassword,
              child: Text(
                _passwordChangeChallenge == null
                    ? context.l10n.accountSendCode
                    : context.l10n.accountChangePasswordAction,
              ),
            ),
            const Divider(height: 32),
            _mfaControls(account),
          ],
        ),
      );

  Widget _mfaControls(MemberAccountController account) {
    final status = account.mfaStatus;
    if (status == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final recoveryCodes = _recoveryCodes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.l10n.accountMfaTitle,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 6),
        Text(
          status.enabled
              ? context.l10n.accountMfaEnabled
              : context.l10n.accountMfaDisabledByDefault,
        ),
        if (recoveryCodes != null) ...[
          const SizedBox(height: 12),
          Text(
            context.l10n.accountRecoveryCodesWarning,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 8),
          SelectableText(recoveryCodes.join('\n')),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: recoveryCodes.join('\n')),
              );
              if (mounted) {
                showSideToast(context, context.l10n.accountRecoveryCodesCopied);
              }
            },
            icon: const Icon(Icons.copy_rounded),
            label: Text(context.l10n.accountCopyRecoveryCodes),
          ),
          TextButton(
            onPressed: () => setState(() => _recoveryCodes = null),
            child: Text(context.l10n.accountRecoveryCodesSaved),
          ),
        ] else if (status.enabled) ...[
          const SizedBox(height: 10),
          _field(
            _mfaCode,
            context.l10n.accountMfaOrRecoveryCode,
            Icons.password_rounded,
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            key: const ValueKey('account-mfa-disable'),
            onPressed: account.loading ? null : _disableMfa,
            child: Text(context.l10n.accountMfaDisable),
          ),
        ] else if (_mfaSetup != null) ...[
          const SizedBox(height: 10),
          Text(context.l10n.accountMfaSecretWarning),
          const SizedBox(height: 6),
          SelectableText(_mfaSetup!.secret),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => launchUrl(
              _mfaSetup!.otpauthUri,
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.open_in_new_rounded),
            label: Text(context.l10n.accountMfaOpenAuthenticator),
          ),
          const SizedBox(height: 10),
          _field(_mfaCode, context.l10n.accountMfaCode, Icons.password_rounded),
          const SizedBox(height: 10),
          FilledButton(
            key: const ValueKey('account-mfa-confirm'),
            onPressed: account.loading ? null : _confirmMfa,
            child: Text(context.l10n.accountMfaConfirm),
          ),
        ] else ...[
          if (_mfaSetupChallenge != null) ...[
            const SizedBox(height: 10),
            _field(
              _mfaCode,
              context.l10n.accountVerificationCode,
              Icons.password_rounded,
            ),
          ],
          const SizedBox(height: 10),
          OutlinedButton(
            key: const ValueKey('account-mfa-setup'),
            onPressed: account.loading ? null : _setupMfa,
            child: Text(
              _mfaSetupChallenge == null
                  ? context.l10n.accountMfaSendSetupCode
                  : context.l10n.accountMfaContinueSetup,
            ),
          ),
        ],
      ],
    );
  }

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
                context.l10n.accountPageTitle,
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

class _ExternalLoginCard extends StatelessWidget {
  const _ExternalLoginCard({
    required this.account,
    required this.polling,
    required this.authorization,
    required this.onLogin,
    required this.onCancel,
  });

  final MemberAccountController account;
  final bool polling;
  final DeviceAuthorization? authorization;
  final ValueChanged<MemberExternalAuthMethod> onLogin;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => _SectionCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (polling) ...[
          Row(
            children: [
              const SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(context.l10n.accountExternalHint)),
              TextButton(
                onPressed: onCancel,
                child: Text(
                  MaterialLocalizations.of(context).cancelButtonLabel,
                ),
              ),
            ],
          ),
          if ((authorization?.userCode ?? '').isNotEmpty) ...[
            const SizedBox(height: 10),
            SelectableText(
              authorization!.userCode,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
              ),
            ),
          ],
        ] else ...[
          _providerButton(
            context,
            icon: Icons.code_rounded,
            label: context.l10n.accountUseGithub,
            enabled: account.providers.github,
            method: MemberExternalAuthMethod.github,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _providerButton(
                  context,
                  icon: Icons.key_rounded,
                  label: context.l10n.accountUsePasskey,
                  enabled: account.providers.passkey,
                  method: MemberExternalAuthMethod.passkey,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _providerButton(
                  context,
                  icon: Icons.g_mobiledata_rounded,
                  label: context.l10n.accountUseGoogle,
                  enabled: account.providers.google,
                  method: MemberExternalAuthMethod.google,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            context.l10n.accountExternalHint,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    ),
  );

  Widget _providerButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool enabled,
    required MemberExternalAuthMethod method,
  }) => OutlinedButton.icon(
    onPressed: enabled && !account.loading ? () => onLogin(method) : null,
    icon: Icon(icon, size: 19),
    label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
  );
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

class _LoginMethodsCard extends StatelessWidget {
  const _LoginMethodsCard({required this.user});

  final MemberUser user;

  @override
  Widget build(BuildContext context) => _SectionCard(
    title: context.l10n.accountUsePasskey,
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

class _SupportCard extends StatelessWidget {
  const _SupportCard({required this.account});

  final MemberAccountController account;

  @override
  Widget build(BuildContext context) {
    final purchaseUrl = account.membershipConfig?.purchaseUrl;
    return _SectionCard(
      title: context.l10n.accountSupportTitle,
      icon: Icons.volunteer_activism_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.l10n.accountSupportFreeTitle,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 5),
          Text(
            context.l10n.accountSupportFreeSubtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          if (purchaseUrl != null) ...[
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.28),
      child: user.avatarUrl == null
          ? fallback
          : Image.network(
              user.avatarUrl!,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({this.title, this.icon, required this.child});

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
