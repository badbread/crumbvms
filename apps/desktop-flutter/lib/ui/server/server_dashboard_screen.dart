// Native Server dashboard: connection info, per-camera recording stats,
// storage/disk health, per-policy usage + forecast, and a retention policy
// editor (global default + per-camera override).
//
// Ported from apps/desktop/src/app.js's Server section (srvEnter,
// srvSelectSection, srvRenderConnection, srvLoadStats, srvRenderPaths,
// srvLoadHealth, srvLoadPolicyUsage, srvVerifyPolicySizes, srvLoadPolicyList,
// srvHandleSave) — the pieces that don't just duplicate the embedded /admin
// console. Section switcher → four tabs instead of app.js's sidebar list.

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/api/server_dashboard_api.dart';
import 'package:crumb_desktop/api/server_dashboard_models.dart';

/// Entry point: `ServerDashboardScreen(api: api, session: session)`.
class ServerDashboardScreen extends StatefulWidget {
  const ServerDashboardScreen({super.key, required this.api, required this.session});

  final CrumbApi api;
  final Session session;

  @override
  State<ServerDashboardScreen> createState() => _ServerDashboardScreenState();
}

class _ServerDashboardScreenState extends State<ServerDashboardScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Server'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Connection'),
            Tab(text: 'Cameras'),
            Tab(text: 'Storage'),
            Tab(text: 'Retention'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _ConnectionSection(api: widget.api, session: widget.session),
          _CameraStatsSection(api: widget.api, session: widget.session),
          _StorageSection(api: widget.api, session: widget.session),
          _RetentionSection(api: widget.api, session: widget.session),
        ],
      ),
    );
  }
}

// ─── shared formatting helpers (mirrors app.js srvFmt*) ───────────────────────

String fmtBytes(num? bytes) {
  final b = (bytes ?? 0).toDouble();
  if (b <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var v = b;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}';
}

String fmtMem(double? mb) {
  if (mb == null) return '—';
  if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
  return '${mb.round()} MB';
}

String fmtRetentionHours(double? hours) {
  if (hours == null || hours <= 0) return '—';
  if (hours < 48) return '${hours.round()} h';
  return '${(hours / 24).toStringAsFixed(1)} d';
}

String fmtPct(double? pct) => pct == null ? '—' : '${pct.round()}%';

String fmtAgo(DateTime? t) {
  if (t == null) return '—';
  final d = DateTime.now().toUtc().difference(t.toUtc());
  if (d.inSeconds < 60) return '${d.inSeconds}s ago';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

/// Generic "loading / error / content" wrapper matching this file's sections'
/// common shape — avoids repeating the same three states in every section.
class _AsyncSection<T> extends StatefulWidget {
  const _AsyncSection({
    required this.loader,
    required this.builder,
    this.onRetryLabel = 'Retry',
  });

  final Future<T> Function() loader;
  final Widget Function(BuildContext, T, VoidCallback reload) builder;
  final String onRetryLabel;

  @override
  State<_AsyncSection<T>> createState() => _AsyncSectionState<T>();
}

class _AsyncSectionState<T> extends State<_AsyncSection<T>> {
  late Future<T> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.loader();
  }

  void _reload() => setState(() => _future = widget.loader());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${snap.error}'),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _reload,
                  child: Text(widget.onRetryLabel),
                ),
              ],
            ),
          );
        }
        return widget.builder(context, snap.data as T, _reload);
      },
    );
  }
}

// ─── Connection section (srvRenderConnection, app.js:11093) ──────────────────

class _ConnectionSection extends StatelessWidget {
  const _ConnectionSection({required this.api, required this.session});

  final CrumbApi api;
  final Session session;

  @override
  Widget build(BuildContext context) {
    final server = session.base.replaceFirst(RegExp(r'^https?://'), '');
    final adminUrl = '${session.base.replaceFirst(RegExp(r'/$'), '')}/admin';
    return _AsyncSection<ServerStatus>(
      loader: () => api.getStatus(session),
      builder: (context, status, reload) {
        final hb = status.recorderHeartbeat;
        final recorderLive =
            hb != null && DateTime.now().toUtc().difference(hb.toUtc()).inSeconds < 30;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Connection', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    _kv('Server', server),
                    _kv('Admin console', adminUrl),
                    _kv('Config version', status.configVersion.isEmpty ? '—' : status.configVersion),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Recorder', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Icon(
                          recorderLive ? Icons.check_circle : Icons.error,
                          color: recorderLive ? Colors.green : Colors.red,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Text(recorderLive ? 'Live' : 'No recent heartbeat'),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _kv('Last heartbeat', hb == null ? '—' : fmtAgo(hb)),
                    _kv('PID', status.recorderPid?.toString() ?? '—'),
                    _kv(
                      'Active cameras',
                      status.recorderActiveCameras?.toString() ?? '—',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Cameras', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    for (final c in status.cameras)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            Icon(
                              c.recording ? Icons.fiber_manual_record : Icons.circle_outlined,
                              size: 12,
                              color: !c.enabled
                                  ? Colors.grey
                                  : (c.recording ? Colors.redAccent : Colors.grey),
                            ),
                            const SizedBox(width: 8),
                            Expanded(child: Text(c.name)),
                            if (c.recentMotion)
                              const Padding(
                                padding: EdgeInsets.only(right: 8),
                                child: Icon(Icons.directions_run, size: 14, color: Colors.amber),
                              ),
                            Text(
                              c.enabled
                                  ? (c.recording ? 'recording' : 'idle')
                                  : 'disabled',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    if (status.cameras.isEmpty) const Text('No cameras.'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: reload,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        SizedBox(width: 140, child: Text(k, style: const TextStyle(color: Colors.grey))),
        Expanded(child: SelectableText(v)),
      ],
    ),
  );
}

// ─── Per-camera stats (srvLoadStats/srvRenderStats, app.js:11126) ────────────

enum _StatsCol { name, cpu, mem, gpu, disk, rate, clips, retention }

class _CameraStatsSection extends StatefulWidget {
  const _CameraStatsSection({required this.api, required this.session});

  final CrumbApi api;
  final Session session;

  @override
  State<_CameraStatsSection> createState() => _CameraStatsSectionState();
}

class _CameraStatsSectionState extends State<_CameraStatsSection> {
  _StatsCol _sortCol = _StatsCol.disk;
  bool _sortAsc = false;

  @override
  Widget build(BuildContext context) {
    return _AsyncSection<List<CameraStat>>(
      loader: () => widget.api.getCameraStats(widget.session),
      builder: (context, cams, reload) {
        if (cams.isEmpty) {
          return const Center(child: Text('No cameras.'));
        }
        final sorted = [...cams]..sort((a, b) {
          final cmp = _compare(a, b, _sortCol);
          return _sortAsc ? cmp : -cmp;
        });
        final totalBytes = cams.fold<int>(0, (s, c) => s + c.totalBytes);
        final totalRate = cams.fold<double>(0, (s, c) => s + c.gbPerHour);

        void toggleSort(_StatsCol col) {
          setState(() {
            if (_sortCol == col) {
              _sortAsc = !_sortAsc;
            } else {
              _sortCol = col;
              _sortAsc = col == _StatsCol.name;
            }
          });
        }

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Text(
                    '${fmtBytes(totalBytes)} · ${totalRate.toStringAsFixed(1)} GB/h total',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const Spacer(),
                  IconButton(icon: const Icon(Icons.refresh), onPressed: reload),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  sortColumnIndex: _StatsCol.values.indexOf(_sortCol),
                  sortAscending: _sortAsc,
                  columns: [
                    DataColumn(
                      label: const Text('Camera'),
                      onSort: (colIdx, asc) => toggleSort(_StatsCol.name),
                    ),
                    DataColumn(
                      label: const Text('CPU'),
                      numeric: true,
                      onSort: (colIdx, asc) => toggleSort(_StatsCol.cpu),
                    ),
                    DataColumn(
                      label: const Text('Mem'),
                      numeric: true,
                      onSort: (colIdx, asc) => toggleSort(_StatsCol.mem),
                    ),
                    DataColumn(
                      label: const Text('GPU'),
                      numeric: true,
                      onSort: (colIdx, asc) => toggleSort(_StatsCol.gpu),
                    ),
                    DataColumn(
                      label: const Text('Disk'),
                      numeric: true,
                      onSort: (colIdx, asc) => toggleSort(_StatsCol.disk),
                    ),
                    DataColumn(
                      label: const Text('GB/h'),
                      numeric: true,
                      onSort: (colIdx, asc) => toggleSort(_StatsCol.rate),
                    ),
                    DataColumn(
                      label: const Text('Clips'),
                      numeric: true,
                      onSort: (colIdx, asc) => toggleSort(_StatsCol.clips),
                    ),
                    DataColumn(
                      label: const Text('Retention'),
                      numeric: true,
                      onSort: (colIdx, asc) => toggleSort(_StatsCol.retention),
                    ),
                  ],
                  rows: [
                    for (final c in sorted)
                      DataRow(
                        cells: [
                          DataCell(Text(c.name)),
                          DataCell(Text(fmtPct(c.cpuPct))),
                          DataCell(Text(fmtMem(c.memMb))),
                          DataCell(Text(c.gpuPct == null ? '—' : fmtPct(c.gpuPct))),
                          DataCell(Text(fmtBytes(c.totalBytes))),
                          DataCell(Text(c.gbPerHour > 0 ? c.gbPerHour.toStringAsFixed(2) : '—')),
                          DataCell(Text(c.segmentCount.toString())),
                          DataCell(Text(fmtRetentionHours(c.retentionHours))),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  int _compare(CameraStat a, CameraStat b, _StatsCol col) {
    switch (col) {
      case _StatsCol.name:
        return a.name.compareTo(b.name);
      case _StatsCol.cpu:
        return a.cpuPct.compareTo(b.cpuPct);
      case _StatsCol.mem:
        return a.memMb.compareTo(b.memMb);
      case _StatsCol.gpu:
        return (a.gpuPct ?? -1).compareTo(b.gpuPct ?? -1);
      case _StatsCol.disk:
        return a.totalBytes.compareTo(b.totalBytes);
      case _StatsCol.rate:
        return a.gbPerHour.compareTo(b.gbPerHour);
      case _StatsCol.clips:
        return a.segmentCount.compareTo(b.segmentCount);
      case _StatsCol.retention:
        return a.retentionHours.compareTo(b.retentionHours);
    }
  }
}

// ─── Storage / disk health (srvRenderPaths/srvRenderDiskLine, app.js:11221+) ──

IconData _storageIcon(String kind) {
  switch (kind) {
    case 'ssd':
      return Icons.memory;
    case 'hdd':
      return Icons.storage;
    default:
      return Icons.sd_storage;
  }
}

class _StorageSection extends StatelessWidget {
  const _StorageSection({required this.api, required this.session});

  final CrumbApi api;
  final Session session;

  @override
  Widget build(BuildContext context) {
    return _AsyncSection<ServerStatus>(
      loader: () => api.getStatus(session),
      builder: (context, status, reload) {
        if (status.storages.isEmpty) {
          return const Center(
            child: Text('No storage volumes reported (or non-admin account).'),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: status.storages.length,
          itemBuilder: (context, i) {
            final s = status.storages[i];
            final cap = s.capacityBytes;
            final frac = (cap != null && cap > 0) ? (s.usedBytes / cap).clamp(0.0, 1.0) : null;
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(_storageIcon(s.icon)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            s.name,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        Text(s.path, style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (frac != null) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: frac,
                          minHeight: 8,
                          color: frac > 0.9 ? Colors.red : null,
                        ),
                      ),
                      const SizedBox(height: 6),
                    ],
                    Text(
                      '${fmtBytes(s.usedBytes)} used'
                      '${s.freeBytes != null ? ' · ${fmtBytes(s.freeBytes)} free' : ''}'
                      '${cap != null ? ' of ${fmtBytes(cap)}' : ''}'
                      '${s.totalBytes == null ? ' (filesystem size)' : ' (configured cap)'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ─── Retention: policy usage/forecast + editor ────────────────────────────────
// (srvLoadPolicyUsage/srvVerifyPolicySizes app.js:11734+; srvLoadPolicyList /
// srvHandleSave app.js:11947-12233 — the editor over GET|PUT
// /config/policy/default and PUT /config/cameras/{id}/policy.)

class _RetentionSection extends StatefulWidget {
  const _RetentionSection({required this.api, required this.session});

  final CrumbApi api;
  final Session session;

  @override
  State<_RetentionSection> createState() => _RetentionSectionState();
}

class _RetentionSectionState extends State<_RetentionSection> {
  Future<List<PolicyStat>>? _usageFuture;
  Map<String, PolicyVerify>? _verify; // policyId -> verify row
  bool _verifying = false;
  String? _verifyError;

  @override
  void initState() {
    super.initState();
    _usageFuture = widget.api.getPolicyStats(widget.session);
  }

  Future<void> _runVerify() async {
    setState(() {
      _verifying = true;
      _verifyError = null;
    });
    try {
      final rows = await widget.api.verifyPolicySizes(widget.session);
      if (!mounted) return;
      setState(() => _verify = {for (final r in rows) r.policyId: r});
    } catch (e) {
      if (mounted) setState(() => _verifyError = '$e');
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(tabs: [Tab(text: 'Usage & forecast'), Tab(text: 'Edit policies')]),
          Expanded(
            child: TabBarView(
              children: [
                _usageTab(context),
                _PolicyEditorTab(api: widget.api, session: widget.session),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _usageTab(BuildContext context) {
    return FutureBuilder<List<PolicyStat>>(
      future: _usageFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text('${snap.error}'));
        }
        final policies = snap.data ?? const [];
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Storage usage is what eviction actually enforces per '
                    'effective policy (own → group → default).',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: _verifying ? null : _runVerify,
                  icon: _verifying
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.fact_check, size: 18),
                  label: const Text('Verify on disk'),
                ),
              ],
            ),
            if (_verifyError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_verifyError!, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 12),
            if (policies.isEmpty) const Text('No policies with usage or camera assignments.'),
            for (final p in policies) _policyCard(context, p),
          ],
        );
      },
    );
  }

  Widget _policyCard(BuildContext context, PolicyStat p) {
    final capFrac = (p.liveMaxBytes != null && p.liveMaxBytes! > 0)
        ? (p.liveUsedBytes / p.liveMaxBytes!).clamp(0.0, 1.0)
        : null;
    final verify = _verify?[p.policyId];
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    p.label,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (p.isDefault)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: Chip(label: Text('Default'), visualDensity: VisualDensity.compact),
                  ),
                Chip(label: Text(p.mode), visualDensity: VisualDensity.compact),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              p.cameraNames.isEmpty ? 'No cameras' : p.cameraNames.join(', '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            if (capFrac != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: capFrac, minHeight: 8),
              ),
              const SizedBox(height: 6),
            ],
            Text(
              'Live: ${fmtBytes(p.liveUsedBytes)}'
              '${p.liveMaxBytes != null ? ' / ${fmtBytes(p.liveMaxBytes)} cap' : ' (no size cap)'}'
              ' · ${p.gbPerHour.toStringAsFixed(2)} GB/h'
              ' · on disk now ${fmtRetentionHours(p.liveRetentionHoursNow)}'
              ' · configured ${p.liveRetentionHoursCap}h',
            ),
            if (p.archiveUsedBytes > 0 || p.archiveMaxBytes != null)
              Text(
                'Archive: ${fmtBytes(p.archiveUsedBytes)}'
                '${p.archiveMaxBytes != null ? ' / ${fmtBytes(p.archiveMaxBytes)} cap' : ''}',
              ),
            const SizedBox(height: 4),
            Text(_forecastText(p), style: Theme.of(context).textTheme.bodySmall),
            if (verify != null) ...[
              const Divider(height: 20),
              Text(
                'On disk: ${fmtBytes(verify.diskBytes)} vs DB ${fmtBytes(verify.dbBytes)}'
                ' (Δ ${verify.deltaPct.toStringAsFixed(1)}%)',
                style: TextStyle(
                  color: verify.deltaPct.abs() > 5 ? Colors.orange : null,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _forecastText(PolicyStat p) {
    switch (p.bindingLimit) {
      case 'size':
        final ttf = p.liveTimeToFullHours;
        return ttf == null
            ? 'Size cap binds; not enough recent footage to project.'
            : 'Size cap binds — full in ~${fmtRetentionHours(ttf)} at current rate.';
      case 'time':
        return 'Time retention binds (${p.liveRetentionHoursCap}h) — eviction holds the store flat.';
      default:
        return 'Not enough recent footage to project.';
    }
  }
}

// ─── Retention policy editor (default + per-camera) ────────────────────────────

class _PolicyEditorTab extends StatefulWidget {
  const _PolicyEditorTab({required this.api, required this.session});

  final CrumbApi api;
  final Session session;

  @override
  State<_PolicyEditorTab> createState() => _PolicyEditorTabState();
}

class _PolicyEditorTabState extends State<_PolicyEditorTab> {
  Future<_EditorData>? _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_EditorData> _load() async {
    final results = await Future.wait([
      widget.api.getDefaultPolicy(widget.session),
      widget.api.listConfigCameras(widget.session),
    ]);
    return _EditorData(
      defaultPolicy: results[0] as RecordingPolicy,
      cameras: results[1] as List<CameraConfigSummary>,
    );
  }

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_EditorData>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text('${snap.error}'));
        }
        final data = snap.data!;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Default policy', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Applies to every camera that does not have its own override '
              'or a group profile.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            _PolicyEditorCard(
              policy: data.defaultPolicy,
              onSave: (patch) async {
                await widget.api.updateDefaultPolicy(widget.session, patch);
                _reload();
              },
            ),
            const SizedBox(height: 24),
            Text('Per-camera overrides', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final cam in data.cameras)
              _CameraPolicyTile(
                api: widget.api,
                session: widget.session,
                camera: cam,
                onSaved: _reload,
              ),
          ],
        );
      },
    );
  }
}

class _EditorData {
  _EditorData({required this.defaultPolicy, required this.cameras});
  final RecordingPolicy defaultPolicy;
  final List<CameraConfigSummary> cameras;
}

class _CameraPolicyTile extends StatelessWidget {
  const _CameraPolicyTile({
    required this.api,
    required this.session,
    required this.camera,
    required this.onSaved,
  });

  final CrumbApi api;
  final Session session;
  final CameraConfigSummary camera;
  final VoidCallback onSaved;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        title: Text(camera.name),
        subtitle: Text(
          camera.hasOwnPolicy
              ? 'Custom policy'
              : (camera.groupId != null
                    ? 'Inherits from group'
                    : 'Inherits from default'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: _PolicyEditorCard(
              policy: camera.policy,
              onSave: (patch) async {
                await api.updateCameraPolicy(session, camera.id, patch);
                onSaved();
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The actual field editor for one [RecordingPolicy] — mode, retention hours,
/// size caps, motion tuning. Builds a [PolicyPatch] of only the fields the
/// user actually changed and calls `onSave`.
class _PolicyEditorCard extends StatefulWidget {
  const _PolicyEditorCard({required this.policy, required this.onSave});

  final RecordingPolicy policy;
  final Future<void> Function(PolicyPatch patch) onSave;

  @override
  State<_PolicyEditorCard> createState() => _PolicyEditorCardState();
}

class _PolicyEditorCardState extends State<_PolicyEditorCard> {
  late String _mode = widget.policy.mode;
  late final TextEditingController _liveRetentionHours =
      TextEditingController(text: widget.policy.liveRetentionHours.toString());
  late final TextEditingController _liveMaxGb = TextEditingController(
    text: widget.policy.liveMaxBytes != null
        ? (widget.policy.liveMaxBytes! / 1e9).toStringAsFixed(1)
        : '',
  );
  late final TextEditingController _motionPre =
      TextEditingController(text: widget.policy.motionPreSeconds.toString());
  late final TextEditingController _motionPost =
      TextEditingController(text: widget.policy.motionPostSeconds.toString());
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _liveRetentionHours.dispose();
    _liveMaxGb.dispose();
    _motionPre.dispose();
    _motionPost.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final patch = PolicyPatch();
    if (_mode != widget.policy.mode) patch.mode(_mode);

    final hours = int.tryParse(_liveRetentionHours.text.trim());
    if (hours != null && hours != widget.policy.liveRetentionHours) {
      patch.liveRetentionHours(hours);
    }

    final gbText = _liveMaxGb.text.trim();
    if (gbText.isEmpty) {
      if (widget.policy.liveMaxBytes != null) patch.liveMaxBytes(null);
    } else {
      final gb = double.tryParse(gbText);
      if (gb != null) {
        final bytes = (gb * 1e9).round();
        if (bytes != widget.policy.liveMaxBytes) patch.liveMaxBytes(bytes);
      }
    }

    if (_mode == 'motion') {
      final pre = int.tryParse(_motionPre.text.trim());
      if (pre != null && pre != widget.policy.motionPreSeconds) {
        patch.motionPreSeconds(pre);
      }
      final post = int.tryParse(_motionPost.text.trim());
      if (post != null && post != widget.policy.motionPostSeconds) {
        patch.motionPostSeconds(post);
      }
    }

    if (patch.isEmpty) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(patch);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'continuous', label: Text('Continuous')),
            ButtonSegment(value: 'motion', label: Text('Motion')),
          ],
          selected: {_mode},
          onSelectionChanged: (s) => setState(() => _mode = s.first),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _liveRetentionHours,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Live retention (hours)',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _liveMaxGb,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Live size cap (GB, blank = none)',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        if (_mode == 'motion') ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _motionPre,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Pre-roll (s)',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _motionPost,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Post-roll (s)',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
        ],
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ),
      ],
    );
  }
}
