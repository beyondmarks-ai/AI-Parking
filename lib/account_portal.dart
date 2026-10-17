import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'account_api.dart';
import 'account_session.dart';

class AccountGate extends StatefulWidget {
  const AccountGate({super.key, required this.adminBuilder});
  final Widget Function(VoidCallback signOut) adminBuilder;
  @override
  State<AccountGate> createState() => _AccountGateState();
}

class _AccountGateState extends State<AccountGate> {
  final api = AccountApi();
  bool restoring = true;
  AccountSession? session;
  String? error;

  @override
  void initState() {
    super.initState();
    unawaited(restore());
  }

  Future<void> restore() async {
    try {
      final token = await AccountSession.storage.invokeMethod<String>('load');
      if (token != null) {
        AccountSession.current = AccountSession(token, {});
        final data = await api.request('/account');
        session = AccountSession(
          token,
          Map<String, dynamic>.from(data['user']),
        );
        AccountSession.current = session;
        unawaited(registerPush());
      }
    } on MissingPluginException {
      // Non-Android previews keep sessions in memory only.
    } on Object catch (e) {
      AccountSession.current = null;
      error = '$e';
    }
    if (mounted) setState(() => restoring = false);
  }

  Future<void> signedIn(Map<String, dynamic> data) async {
    final next = AccountSession(
      data['token'] as String,
      Map<String, dynamic>.from(data['user']),
    );
    AccountSession.current = next;
    try {
      await AccountSession.storage.invokeMethod('save', {
        'token': next.token,
        'userId': next.user['id'],
        'api': api.baseUrl,
      });
    } on MissingPluginException {
      /* Session lasts for this app run. */
    }
    if (!mounted) return;
    setState(() {
      session = next;
      error = null;
    });
    unawaited(registerPush());
  }

  Future<void> registerPush() async {
    try {
      final token = await AccountSession.storage.invokeMethod<String>(
        'pushToken',
      );
      if (token != null && AccountSession.current != null) {
        await api.request('/push/register', post: true, body: {'token': token});
      }
    } on Object {
      /* Inbox remains available; dashboard shows push availability. */
    }
  }

  Future<void> signOut() async {
    try {
      await api.request('/auth/logout', post: true);
    } on Object {
      /* Clear local access even offline. */
    }
    try {
      await AccountSession.storage.invokeMethod('clear');
    } on Object {
      /* Unsupported preview platform. */
    }
    AccountSession.current = null;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    if (mounted) setState(() => session = null);
  }

  @override
  void dispose() {
    api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (restoring) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (session == null) {
      return AccountForm(api: api, onSignedIn: signedIn, initialError: error);
    }
    if (session!.isAdmin) {
      return widget.adminBuilder(() => unawaited(signOut()));
    }
    return AccountDashboard(onSignOut: () => unawaited(signOut()));
  }
}

class AccountForm extends StatefulWidget {
  const AccountForm({
    super.key,
    required this.api,
    required this.onSignedIn,
    this.initialError,
  });
  final AccountApi api;
  final Future<void> Function(Map<String, dynamic>) onSignedIn;
  final String? initialError;
  @override
  State<AccountForm> createState() => _AccountFormState();
}

class _AccountFormState extends State<AccountForm> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController();
  final email = TextEditingController();
  final password = TextEditingController();
  final plate = TextEditingController();
  bool signup = false, busy = false, showPassword = false;
  String? error;
  @override
  void initState() {
    super.initState();
    error = widget.initialError;
  }

  @override
  void dispose() {
    for (final c in [name, email, password, plate]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> submit() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = await widget.api.request(
        signup ? '/auth/signup' : '/auth/login',
        post: true,
        body: {
          'email': email.text.trim(),
          'password': password.text,
          if (signup) 'name': name.text.trim(),
          if (signup) 'plate': plate.text.trim(),
        },
      );
      await widget.onSignedIn(Map<String, dynamic>.from(data));
    } on Object catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Form(
              key: form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(
                    Icons.local_parking_rounded,
                    size: 64,
                    color: Color(0xFF2155D9),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    signup
                        ? 'Create your ParkGuard account'
                        : 'Welcome to ParkGuard',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    signup
                        ? 'Register your vehicle to receive parking alerts, view evidence and manage penalties.'
                        : 'Sign in to view your vehicles and parking notices.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  if (signup) ...[
                    TextFormField(
                      controller: name,
                      decoration: const InputDecoration(
                        labelText: 'Full name',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      validator: (v) => (v?.trim().length ?? 0) < 2
                          ? 'Enter your name'
                          : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: plate,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'Vehicle registration number',
                        hintText: 'KA01AB1234',
                        prefixIcon: Icon(Icons.directions_car_outlined),
                      ),
                      validator: (v) => (v?.trim().isEmpty ?? true)
                          ? 'Enter your vehicle number'
                          : null,
                    ),
                    const SizedBox(height: 16),
                  ],
                  TextFormField(
                    controller: email,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.email_outlined),
                    ),
                    validator: (v) =>
                        !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                            .hasMatch(v?.trim() ?? '')
                        ? 'Enter a valid email'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: password,
                    obscureText: !showPassword,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        onPressed: () =>
                            setState(() => showPassword = !showPassword),
                        icon: Icon(
                          showPassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                      ),
                    ),
                    validator: (v) => (v?.length ?? 0) < 8
                        ? 'Use at least 8 characters'
                        : null,
                    onFieldSubmitted: (_) {
                      if (!busy) unawaited(submit());
                    },
                  ),
                  const SizedBox(height: 24),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  FilledButton(
                    onPressed: busy ? null : submit,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(signup ? 'Create account' : 'Sign in'),
                    ),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            signup = !signup;
                            error = null;
                          }),
                    child: Text(
                      signup
                          ? 'Already registered? Sign in'
                          : 'New here? Create an account',
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Payments in this version are demonstrations. No money is charged.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class AccountDashboard extends StatefulWidget {
  const AccountDashboard({super.key, this.admin = false, this.onSignOut});
  final bool admin;
  final VoidCallback? onSignOut;
  @override
  State<AccountDashboard> createState() => _AccountDashboardState();
}

class _AccountDashboardState extends State<AccountDashboard> {
  final api = AccountApi();
  List<Map<String, dynamic>> penalties = [], users = [];
  List<String> vehicles = [];
  Map<String, dynamic> summary = {};
  String? error;
  bool loading = true, refreshing = false;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    unawaited(refresh());
    timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(refresh());
      }
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    api.close();
    super.dispose();
  }

  Future<void> refresh() async {
    if (refreshing) return;
    refreshing = true;
    try {
      final data = await api.request(
        widget.admin ? '/admin/penalties' : '/penalties',
      );
      final account = await api.request(
        widget.admin ? '/admin/users' : '/account',
      );
      if (!mounted) return;
      setState(() {
        penalties = List<Map<String, dynamic>>.from(
          widget.admin ? data['penalties'] : data,
        );
        if (widget.admin) {
          summary = Map<String, dynamic>.from(data['summary']);
          users = List<Map<String, dynamic>>.from(account);
        } else {
          vehicles = List<String>.from(account['vehicles']);
        }
        error = null;
      });
      if (!widget.admin) {
        try {
          final id = await AccountSession.storage.invokeMethod<String>(
            'notification',
          );
          final matches = penalties.where((p) => p['id'] == id);
          if (mounted && matches.isNotEmpty) {
            unawaited(openPenalty(matches.first));
          }
        } on MissingPluginException {
          /* Browser preview. */
        }
      }
    } on Object catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      refreshing = false;
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> addVehicle() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a vehicle'),
        content: TextField(
          controller: controller,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(labelText: 'Vehicle number'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Register'),
          ),
        ],
      ),
    );
    // The dialog route can still animate while its text field is mounted.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    if (value == null) return;
    try {
      await api.request(
        '/account/vehicles',
        post: true,
        body: {'plate': value},
      );
      await refresh();
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> openPenalty(Map<String, dynamic> penalty) async {
    if (!widget.admin) {
      try {
        await api.request('/penalties/${penalty['id']}/seen', post: true);
      } on Object {
        /* Retry on next open. */
      }
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PenaltyDetails(penalty: penalty, admin: widget.admin),
      ),
    );
    await refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.admin ? 'Admin dashboard' : 'My parking account'),
      actions: [
        IconButton(
          tooltip: 'Refresh',
          onPressed: refresh,
          icon: const Icon(Icons.refresh),
        ),
        if (widget.onSignOut != null)
          IconButton(
            tooltip: 'Sign out',
            onPressed: widget.onSignOut,
            icon: const Icon(Icons.logout),
          ),
      ],
    ),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: refresh,
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  'Hello, ${AccountSession.current?.name ?? ''}',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  widget.admin ? 'Vehicle owners, evidence and payment status' : 'Notices are matched to your registered vehicle numbers.',
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                const SizedBox(height: 16),
                if (widget.admin) ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Chip(label: Text('${summary['total'] ?? 0} penalties')),
                      Chip(label: Text('${summary['unpaid'] ?? 0} unpaid')),
                      Chip(
                        label: Text(
                          'Rs ${summary['outstanding'] ?? 0} outstanding',
                        ),
                      ),
                      Chip(
                        label: Text('${summary['demo_paid'] ?? 0} demo paid'),
                      ),
                    ],
                  ),
                  ExpansionTile(
                    title: Text('Registered accounts (${users.length})'),
                    children: [
                      for (final user in users)
                        ListTile(
                          title: Text(user['name']),
                          subtitle: Text(
                            '${user['email']}\n${(user['vehicles'] as List).join(', ')}',
                          ),
                        ),
                    ],
                  ),
                ] else ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final plate in vehicles)
                        Chip(
                          avatar: const Icon(Icons.directions_car, size: 18),
                          label: Text(plate),
                        ),
                    ],
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: addVehicle,
                      icon: const Icon(Icons.add),
                      label: const Text('Add vehicle'),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Text(
                  widget.admin
                      ? 'All penalties'
                      : 'My notifications & penalties',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                if (penalties.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(28),
                      child: Text('No parking penalties yet.'),
                    ),
                  ),
                for (final p in penalties)
                  Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(14),
                      leading: Icon(
                        p['payment_status'] == 'demo_paid'
                            ? Icons.check_circle_outline
                            : Icons.warning_amber_rounded,
                        color: p['payment_status'] == 'demo_paid'
                            ? Colors.green
                            : Colors.orange,
                      ),
                      title: Text(
                        '${p['plate']} · Rs ${p['amount']}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        '${widget.admin ? '${p['owner_name'] ?? 'Unregistered vehicle'}\n' : ''}${_date(p['occurred_at'])}\n${p['payment_status'] == 'demo_paid' ? 'Demo paid — no money collected' : 'No-parking bay violation · Unpaid'}',
                      ),
                      trailing: !widget.admin && p['seen_at'] == null
                          ? const Badge(label: Text('New'))
                          : const Icon(Icons.chevron_right),
                      onTap: () => openPenalty(p),
                    ),
                  ),
              ],
            ),
          ),
  );
}

String _date(dynamic value) {
  final date = DateTime.tryParse('$value')?.toLocal();
  if (date == null) return '';
  return '${date.day}/${date.month}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}

class PenaltyDetails extends StatefulWidget {
  const PenaltyDetails({super.key, required this.penalty, required this.admin});
  final Map<String, dynamic> penalty;
  final bool admin;
  @override
  State<PenaltyDetails> createState() => _PenaltyDetailsState();
}

class _PenaltyDetailsState extends State<PenaltyDetails> {
  final api = AccountApi();
  late Map<String, dynamic> penalty = Map.of(widget.penalty);
  bool paying = false;
  String? error;
  @override
  void dispose() {
    api.close();
    super.dispose();
  }

  Future<void> pay() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Demo payment'),
        content: Text(
          'Simulate payment of Rs ${penalty['amount']}? No money will be charged and no bank details are needed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm demo payment'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => paying = true);
    try {
      final receipt = await api.request(
        '/penalties/${penalty['id']}/demo-pay',
        post: true,
      );
      if (mounted) {
        setState(() => penalty.addAll(Map<String, dynamic>.from(receipt)));
      }
    } on Object catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => paying = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Penalty & evidence')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.network(
            '${api.baseUrl}${penalty['evidence_path']}',
            headers: AccountSession.headers,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const SizedBox(
              height: 180,
              child: Center(child: Text('Image unavailable. Reopen to retry.')),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          penalty['plate'],
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        if (widget.admin)
          Text('Owner: ${penalty['owner_name'] ?? 'Unregistered vehicle'}'),
        Text('Detected ${_date(penalty['occurred_at'])}'),
        const Text('Vehicle detected inside the selected no-parking bay.'),
        const SizedBox(height: 20),
        Text(
          'Rs ${penalty['amount']}',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 10),
        if (penalty['payment_status'] == 'demo_paid') ...[
          const Text(
            'Demo payment complete',
            style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
          ),
          Text('Receipt: ${penalty['receipt_id']}'),
          Text('Completed ${_date(penalty['paid_at'])}'),
        ] else if (!widget.admin)
          FilledButton.icon(
            onPressed: paying ? null : pay,
            icon: const Icon(Icons.payments_outlined),
            label: Text(
              paying ? 'Processing…' : 'Pay Rs ${penalty['amount']} — demo',
            ),
          ),
        const SizedBox(height: 12),
        const Text('Demonstration only. No money is collected.'),
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
      ],
    ),
  );
}
