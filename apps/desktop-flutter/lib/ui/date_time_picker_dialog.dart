// SPDX-License-Identifier: AGPL-3.0-or-later
//
// One dialog for picking a date AND a time (issue #705).
//
// Every "jump to" / range control used to chain Flutter's stock date picker
// into its stock time picker. The time only appeared after pressing OK on the
// date, and nothing said so, so operators reasonably concluded the time could
// not be set at all. This dialog shows both fields side by side, both
// typeable, Enter confirms from either. The calendar button still opens the
// stock calendar for browsing, and writes its pick back into the date field.
//
// Fields use the app's own YYYY-MM-DD and 24-hour HH:MM:SS formats (what the
// export dialog and timelines print). Typing is forgiving: M/D/YYYY dates,
// times without seconds, and 12-hour times with am/pm are all accepted.

import 'package:flutter/material.dart';

String _two(int n) => n.toString().padLeft(2, '0');

/// [d] as YYYY-MM-DD.
@visibleForTesting
String fmtPickerDate(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

/// [d] as 24-hour HH:MM:SS.
@visibleForTesting
String fmtPickerTime(DateTime d) =>
    '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';

/// Parse a typed date: YYYY-MM-DD (also with / or .) or M/D/YYYY. Returns
/// local midnight of that day, or null when it is not a real date.
@visibleForTesting
DateTime? parsePickerDate(String text) {
  final t = text.trim();
  int y, m, d;
  var match = RegExp(r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})$').firstMatch(t);
  if (match != null) {
    y = int.parse(match[1]!);
    m = int.parse(match[2]!);
    d = int.parse(match[3]!);
  } else {
    match = RegExp(r'^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})$').firstMatch(t);
    if (match == null) return null;
    m = int.parse(match[1]!);
    d = int.parse(match[2]!);
    y = int.parse(match[3]!);
  }
  final out = DateTime(y, m, d);
  // DateTime rolls 2026-02-31 over into March; reject instead.
  if (out.year != y || out.month != m || out.day != d) return null;
  return out;
}

/// Parse a typed time: H:MM or H:MM:SS, 24-hour, or 12-hour with am/pm
/// ("2:30 pm", "2:30pm", "2pm"). Returns (hour, minute, second) or null.
@visibleForTesting
(int, int, int)? parsePickerTime(String text) {
  final t = text.trim().toLowerCase();
  final match = RegExp(r'^(\d{1,2})(?::(\d{2}))?(?::(\d{2}))?\s*([ap])\.?m?\.?$')
          .firstMatch(t) ??
      RegExp(r'^(\d{1,2}):(\d{2})(?::(\d{2}))?()$').firstMatch(t);
  if (match == null) return null;
  var h = int.parse(match[1]!);
  final min = int.parse(match[2] ?? '0');
  final s = int.parse(match[3] ?? '0');
  final ampm = match[4] ?? '';
  if (ampm.isNotEmpty) {
    if (h < 1 || h > 12) return null;
    if (ampm == 'a' && h == 12) h = 0;
    if (ampm == 'p' && h != 12) h += 12;
  }
  if (h > 23 || min > 59 || s > 59) return null;
  return (h, min, s);
}

/// Ask for a local date and time in one dialog, seeded from [initial] (shown
/// in local time). The date must fall between [firstDate] and [lastDate]
/// (whole days). Returns the chosen LOCAL [DateTime], or null on cancel.
Future<DateTime?> showDateTimePickerDialog(
  BuildContext context, {
  required DateTime initial,
  required DateTime firstDate,
  required DateTime lastDate,
  String title = 'Go to date and time',
  String confirmLabel = 'OK',
}) {
  return showDialog<DateTime>(
    context: context,
    builder: (_) => _DateTimePickerDialog(
      initial: initial.toLocal(),
      firstDate: firstDate,
      lastDate: lastDate,
      title: title,
      confirmLabel: confirmLabel,
    ),
  );
}

class _DateTimePickerDialog extends StatefulWidget {
  const _DateTimePickerDialog({
    required this.initial,
    required this.firstDate,
    required this.lastDate,
    required this.title,
    required this.confirmLabel,
  });

  final DateTime initial;
  final DateTime firstDate;
  final DateTime lastDate;
  final String title;
  final String confirmLabel;

  @override
  State<_DateTimePickerDialog> createState() => _DateTimePickerDialogState();
}

class _DateTimePickerDialogState extends State<_DateTimePickerDialog> {
  late final _dateCtrl = TextEditingController(text: fmtPickerDate(widget.initial));
  late final _timeCtrl = TextEditingController(text: fmtPickerTime(widget.initial));
  String? _dateError;
  String? _timeError;

  DateTime get _firstDay =>
      DateTime(widget.firstDate.year, widget.firstDate.month, widget.firstDate.day);
  DateTime get _lastDay =>
      DateTime(widget.lastDate.year, widget.lastDate.month, widget.lastDate.day);

  @override
  void dispose() {
    _dateCtrl.dispose();
    _timeCtrl.dispose();
    super.dispose();
  }

  Future<void> _openCalendar() async {
    var seed = parsePickerDate(_dateCtrl.text) ?? widget.initial;
    if (seed.isBefore(_firstDay)) seed = _firstDay;
    if (seed.isAfter(_lastDay)) seed = _lastDay;
    final picked = await showDatePicker(
      context: context,
      initialDate: seed,
      firstDate: _firstDay,
      lastDate: _lastDay,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _dateCtrl.text = fmtPickerDate(picked);
      _dateError = null;
    });
  }

  void _submit() {
    final date = parsePickerDate(_dateCtrl.text);
    final time = parsePickerTime(_timeCtrl.text);
    String? dateError;
    if (date == null) {
      dateError = 'Use YYYY-MM-DD, like ${fmtPickerDate(widget.initial)}';
    } else if (date.isBefore(_firstDay)) {
      dateError = 'The earliest date is ${fmtPickerDate(_firstDay)}';
    } else if (date.isAfter(_lastDay)) {
      dateError = 'The latest date is ${fmtPickerDate(_lastDay)}';
    }
    setState(() {
      _dateError = dateError;
      _timeError = time == null ? 'Use 24-hour HH:MM:SS, or 2:30 pm' : null;
    });
    if (dateError != null || time == null) return;
    final (h, m, s) = time;
    Navigator.of(context).pop(DateTime(date!.year, date.month, date.day, h, m, s));
  }

  @override
  Widget build(BuildContext context) {
    // Enter in either field confirms (onSubmitted); no extra key binding, so a
    // single Enter can never pop twice.
    return AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: 380,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 5,
                child: TextField(
                  key: const Key('dtp-date'),
                  controller: _dateCtrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Date',
                    hintText: 'YYYY-MM-DD',
                    errorText: _dateError,
                    errorMaxLines: 2,
                    suffixIcon: IconButton(
                      tooltip: 'Pick from a calendar',
                      icon: const Icon(Icons.calendar_today, size: 18),
                      onPressed: _openCalendar,
                    ),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 4,
                child: TextField(
                  key: const Key('dtp-time'),
                  controller: _timeCtrl,
                  decoration: InputDecoration(
                    labelText: 'Time',
                    hintText: 'HH:MM:SS',
                    errorText: _timeError,
                    errorMaxLines: 2,
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
        ],
    );
  }
}
