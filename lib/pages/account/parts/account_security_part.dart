// 文件说明：账号安全、邮箱与密码变更、MFA 设置流程。
// 技术要点：同一账号功能库内的私有实现拆分，不扩大公开 API。

part of '../account_page.dart';

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
