import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../protocol/conversation.dart';
import '../phase_pill.dart';
import '../theme.dart';
import '../ui_settings.dart';
import 'diff_view.dart';
import 'workflow_card.dart';

/// Tool-call cards (official ToolCallBlocks parity): per-call tile with
/// status icon, summary line and expandable input/output, the workflow
/// graph card and the turn header. Split out of chat_page.dart for size.

class ToolCallTile extends StatelessWidget {
  final Map<String, dynamic> row;

  /// Live snapshot for the workflow card's run join (status/steps overlay).
  final ConversationState? state;

  /// Actor pill tap (workflow card): opens the actor transcript session;
  /// an empty sessionId means "not started yet".
  final void Function(String sessionId, String name)? onOpenActor;

  /// Run-details entry (workflow card ⤢ / more row).
  final void Function(Map<String, dynamic> liveRun)? onOpenRunDetails;

  const ToolCallTile({
    super.key,
    required this.row,
    this.state,
    this.onOpenActor,
    this.onOpenRunDetails,
  });

  @override
  Widget build(BuildContext context) {
    final status = row['status'] as String? ?? '';
    final inputText = row['inputText'] as String? ?? '';
    final output = row['output'];
    final outputText = output is Map ? output['text'] as String? ?? '' : '';
    final error = row['error'];
    final progress = row['progress'];
    final display = row['display'];
    final diff = extractDiff(row);

    // CreateWorkflow/AmendWorkflow with the official display payload render
    // the workflow graph card instead of the generic summary tile.
    if (display is Map && display['kind'] == 'create_workflow') {
      return WorkflowCard(
        row: row,
        display: display.cast<String, dynamic>(),
        state: state,
        onOpenActor: onOpenActor,
        onOpenRunDetails: onOpenRunDetails,
      );
    }

    final (icon, color) = switch (status) {
      'running' || 'inputStreaming' || 'pendingApproval' => (
          Icons.hourglass_top,
          ZColors.sky400
        ),
      'success' => (Icons.check, ZColors.success),
      'error' => (Icons.error_outline, ZColors.danger),
      'cancelled' => (Icons.block, ZColors.warning),
      _ => (Icons.build_outlined, ZInk.faint(context)),
    };

    final images = display is Map &&
            display['kind'] == 'node_repl_images' &&
            display['images'] is List
        ? display['images'] as List
        : const [];

    // CUA screenshots ride display.media as inline base64 (max 4, web
    // toolDisplay cua schema); artifactUri variants are skipped — they
    // need an async attachmentRead this stateless tile can't do.
    final cuaShots = <Uint8List>[];
    if (display is Map &&
        display['kind'] == 'cua' &&
        display['media'] is List) {
      for (final media in display['media'] as List) {
        if (media is Map &&
            media['data'] is String &&
            '${media['mimeType'] ?? ''}'.startsWith('image/')) {
          final bytes = _decodeBase64('${media['data']}');
          if (bytes != null) cuaShots.add(bytes);
        }
      }
    }

    final summary = _toolSummary(context, row, diff);

    // Official tool row: bold-ish first line (已写入 <file> / 终端 · cmd /
    // 探索 · N 文件) with +/- counts right-aligned; second line = directory
    // path (write/edit) or the tool name.
    final title = Row(
      children: [
        Expanded(
          child: Text(
            summary.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: ZInk.solid(context),
            ),
          ),
        ),
        if (summary.additions > 0)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text(
              '+${summary.additions}',
              style: const TextStyle(fontSize: 11.5, color: ZColors.success),
            ),
          ),
        if (summary.deletions > 0)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              '-${summary.deletions}',
              style: const TextStyle(fontSize: 11.5, color: ZColors.danger),
            ),
          ),
      ],
    );
    final subtitle = summary.subtitle == null
        ? null
        : Text(
            summary.subtitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: ZInk.faint(context),
              fontFamily: 'monospace',
            ),
          );

    return Material(
      color: ZInk.tile(context),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExpansionTile(
            dense: true,
            tilePadding: const EdgeInsets.symmetric(horizontal: 12),
            leading: Icon(icon, size: 15, color: color),
            title: title,
            subtitle: subtitle,
            children: [
              if (inputText.isNotEmpty)
                _kv(context, tr(context, 'chat.tool.input'), inputText),
              if (outputText.isNotEmpty)
                _kv(context, tr(context, 'chat.tool.output'), outputText),
              if (error is Map)
                _kv(
                  context,
                  tr(context, 'chat.tool.error'),
                  '${error['code'] ?? ''} ${error['message'] ?? ''}',
                ),
            ],
          ),
          if (progress is Map) _ProgressRow(progress: progress),
          if (diff != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: DiffView(diff: diff),
            ),
          for (final image in images)
            if (image is Map && image['base64'] is String)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    base64Decode(image['base64'] as String),
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) =>
                        const SizedBox.shrink(),
                  ),
                ),
              ),
          // CUA screenshots (decoded above; invalid payloads are dropped).
          for (final shot in cuaShots)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(shot, fit: BoxFit.contain),
              ),
            ),
        ],
      ),
    );
  }

  static Uint8List? _decodeBase64(String value) {
    try {
      return base64Decode(value);
    } catch (_) {
      return null;
    }
  }

  /// Automation cards: CronCreate/CronUpdate/OffPeakCreate.
  static bool _isAutomationTool(String normalizedToolName) {
    return normalizedToolName.contains('croncreate') ||
        normalizedToolName.contains('cronupdate') ||
        normalizedToolName.contains('offpeakcreate');
  }

  /// Workflow family — web TOOL_FAMILY_BY_NAME plus the by-name split list
  /// (web workflowToolNames.ts), normalized like the official matcher.
  static bool _isWorkflowTool(String normalizedToolName) {
    final normalized = normalizedToolName.replaceAll(RegExp(r'[^a-z_]'), '');
    const known = {
      'createworkflow',
      'amendworkflow',
      'submit_result',
      'submitresult',
      'saveworkflow',
      'listsavedworkflows',
      'getworkflowrun',
      'listworkflowruns',
      'evalworkflowsnippet',
      'resumeworkflowrun',
      'resolveworkflowquestion',
      'listmodels',
    };
    return known.contains(normalized);
  }

  /// Parses the automation payload from any of the web candidate positions
  /// (output → raw.rawOutput/rawResult/result → raw) into {title, schedule}.
  static Map<String, String?>? _automationCardFields(Map<String, dynamic> row) {
    Map? payload;
    final raw = row['raw'];
    final candidates = [
      row['output'],
      if (raw is Map) ...[
        raw['rawOutput'],
        raw['rawResult'],
        raw['result'],
      ],
      raw,
    ];
    for (final candidate in candidates) {
      if (candidate is! Map) continue;
      if (candidate['automationId'] != null ||
          candidate['title'] != null ||
          candidate['cronExpr'] != null ||
          candidate['cron_expr'] != null ||
          candidate['scheduleRule'] != null) {
        payload = candidate;
        break;
      }
    }
    if (payload == null) return {'title': null, 'schedule': null};
    final title =
        payload['title'] is String ? payload['title'] as String : null;
    final cronExpr = payload['cronExpr'] ?? payload['cron_expr'];
    String? schedule =
        cronExpr is String && cronExpr.isNotEmpty ? cronExpr : null;
    if (schedule == null && payload['scheduleRule'] is Map) {
      final rule = payload['scheduleRule'] as Map;
      final interval = (rule['interval'] as num?)?.toInt() ?? 1;
      final unit = '${rule['unit'] ?? ''}';
      final hour = (rule['hour'] as num?)?.toInt();
      final minute = (rule['minute'] as num?)?.toInt();
      final buffer = StringBuffer('$interval×$unit');
      if (hour != null && minute != null) {
        buffer.write(
          ' ${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}',
        );
      }
      schedule = buffer.toString();
    }
    return {'title': title, 'schedule': schedule};
  }

  /// Official tool summary: first line (已写入 `<file>` / 终端 · cmd /
  /// 探索 · N 文件), optional second line (directory path), +/- counts.
  static ({String title, String? subtitle, int additions, int deletions})
      _toolSummary(
          BuildContext context, Map<String, dynamic> row, DiffData? diff) {
    final toolNameRaw = row['toolName'] as String? ?? 'tool';
    final toolName = toolNameRaw.toLowerCase();
    final inputText = row['inputText'] as String? ?? '';
    final display = row['display'];

    // CUA computer-use display card (web kind:"cua").
    if (display is Map && display['kind'] == 'cua') {
      final failed = display['status'] == 'failed';
      return (
        title:
            '${tr(context, 'chat.tool.cua.kind')} · ${failed ? tr(context, 'chat.tool.cua.failed') : tr(context, 'chat.tool.cua.done')}',
        subtitle: display['toolName'] is String
            ? display['toolName'] as String
            : null,
        additions: 0,
        deletions: 0,
      );
    }

    // Automation cards: CronCreate/CronUpdate/OffPeakCreate (web
    // cron-create.tsx — summary parsed from any of the output candidates).
    if (_isAutomationTool(toolName)) {
      final fields = _automationCardFields(row);
      final kindLabel = toolName.contains('update')
          ? tr(context, 'chat.tool.cron.updated')
          : toolName.contains('offpeak')
              ? tr(context, 'chat.tool.cron.offpeak')
              : tr(context, 'chat.tool.cron.kind');
      final title = fields?['title'];
      final schedule = fields?['schedule'];
      return (
        title: title != null && title.isNotEmpty
            ? '$kindLabel · $title'
            : kindLabel,
        subtitle: schedule,
        additions: 0,
        deletions: 0,
      );
    }

    // Workflow family (web tool-identity + workflowToolNames by-name split).
    if (_isWorkflowTool(toolName)) {
      final st = '${row['status'] ?? ''}';
      final running = st == 'running' || st == 'pending' || st.isEmpty;
      final word = switch (toolName) {
        'createworkflow' => running
            ? tr(context, 'chat.tool.workflow.creating')
            : st == 'error'
                ? tr(context, 'chat.tool.workflow.createFailed')
                : tr(context, 'chat.tool.workflow.created'),
        'submit_result' || 'submitresult' => running
            ? tr(context, 'chat.tool.workflow.submitting')
            : tr(context, 'chat.tool.workflow.completed'),
        'amendworkflow' => tr(context, 'chat.tool.workflow.amended'),
        _ => running
            ? tr(context, 'chat.tool.workflow.running')
            : tr(context, 'chat.tool.workflow.done'),
      };
      return (
        title: '${tr(context, 'chat.tool.workflow.kind')} · $word',
        subtitle: null,
        additions: 0,
        deletions: 0,
      );
    }

    if (toolName.contains('write') ||
        toolName.contains('edit') ||
        toolName.contains('notebook')) {
      final file = _filePath(inputText) ?? diff?.filePath ?? toolNameRaw;
      // title shows the basename; subtitle the directory (official style)
      final segs = file.split(RegExp(r'[\\/]'));
      final base = segs.last;
      final dir =
          segs.length > 1 ? segs.sublist(0, segs.length - 1).join('/') : null;
      return (
        title: trP(context, 'chat.tool.wrote', [base]),
        subtitle: dir,
        additions: diff?.additions ?? 0,
        deletions: diff?.deletions ?? 0,
      );
    }
    if (toolName.contains('taskoutput')) {
      // Web chat.toolCall.taskOutput.* states, keyed off the row status
      // machine (pending/running/completed/failed/denied/stopped).
      final st = '${row['status'] ?? ''}';
      final title = switch (st) {
        'pending' => tr(context, 'chat.tool.taskOutput.fetching'),
        'running' => tr(context, 'chat.tool.taskOutput.running'),
        'failed' => tr(context, 'chat.tool.taskOutput.failed'),
        'denied' => tr(context, 'chat.tool.taskOutput.denied'),
        'stopped' => tr(context, 'chat.tool.taskOutput.stopped'),
        _ => tr(context, 'chat.tool.taskOutput.retrieved'),
      };
      return (
        title: '${tr(context, 'chat.tool.taskOutput.kind')} · $title',
        subtitle: null,
        additions: 0,
        deletions: 0,
      );
    }
    if (toolName.contains('taskstop')) {
      final st = '${row['status'] ?? ''}';
      final title = switch (st) {
        'pending' || 'running' => tr(context, 'chat.tool.taskStop.stopping'),
        'failed' => tr(context, 'chat.tool.taskStop.failed'),
        'denied' => tr(context, 'chat.tool.taskStop.denied'),
        'stopped' => tr(context, 'chat.tool.taskStop.cancelled'),
        _ => tr(context, 'chat.tool.taskStop.stopped'),
      };
      return (
        title: '${tr(context, 'chat.tool.taskStop.kind')} · $title',
        subtitle: null,
        additions: 0,
        deletions: 0,
      );
    }
    if (toolName.contains('sendmessage')) {
      final st = '${row['status'] ?? ''}';
      final title = switch (st) {
        'pending' || 'running' => tr(context, 'chat.tool.send.sending'),
        'failed' => tr(context, 'chat.tool.send.failed'),
        'denied' => tr(context, 'chat.tool.send.denied'),
        'stopped' => tr(context, 'chat.tool.send.stopped'),
        _ => tr(context, 'chat.tool.send.sent'),
      };
      return (
        title: '${tr(context, 'chat.tool.send.kind')} · $title',
        subtitle: null,
        additions: 0,
        deletions: 0,
      );
    }
    if (toolName.contains('askuserquestion') ||
        toolName.contains('ask_user_question')) {
      // Web chat.askQuestion.* parity: asking → asked · N questions →
      // no-answer / auto-continued. Question count comes from the input
      // JSON's questions array when parseable (no guessed fields beyond
      // that); output text carries the auto-continue notice.
      final running = row['status'] == 'running' || row['status'] == 'pending';
      final outputText = row['outputText'] as String? ?? '';
      var count = 0;
      try {
        final input = jsonDecode(inputText);
        if (input is Map && input['questions'] is List) {
          count = (input['questions'] as List).length;
        }
      } catch (_) {}
      final noAnswer = outputText.isNotEmpty &&
          (outputText.contains('未提供回答') ||
              outputText.contains('No answer') ||
              outputText.contains('auto-continued') ||
              outputText.contains('自动继续'));
      return (
        title: running
            ? tr(context, 'chat.tool.askQuestion.asking')
            : noAnswer
                ? tr(context, 'chat.tool.askQuestion.autoContinued')
                : count > 0
                    ? trP(context, 'chat.tool.askQuestion.askedN', ['$count'])
                    : tr(context, 'chat.tool.askQuestion.asked'),
        subtitle: null,
        additions: 0,
        deletions: 0,
      );
    }
    if (toolName.contains('bash') ||
        toolName.contains('terminal') ||
        toolName.contains('exec') ||
        toolName.contains('command')) {
      final cmd = _firstLine(inputText);
      return (
        title: cmd.isEmpty
            ? tr(context, 'chat.tool.terminal')
            : '${tr(context, 'chat.tool.terminal')} · $cmd',
        subtitle: toolNameRaw,
        additions: 0,
        deletions: 0,
      );
    }
    if (toolName.contains('read') ||
        toolName.contains('glob') ||
        toolName.contains('grep') ||
        toolName.contains('explore') ||
        toolName.contains('search')) {
      final count = _fileCount(inputText) ?? _fileCountFromText(inputText);
      final file = _filePath(inputText);
      if (count != null) {
        return (
          title: trP(context, 'chat.tool.exploreN', ['$count']),
          subtitle: toolNameRaw,
          additions: 0,
          deletions: 0,
        );
      }
      if (file != null) {
        return (
          title: '${tr(context, 'chat.tool.explore')} · $file',
          subtitle: toolNameRaw,
          additions: 0,
          deletions: 0,
        );
      }
      return (
        title: tr(context, 'chat.tool.explore'),
        subtitle: toolNameRaw,
        additions: 0,
        deletions: 0,
      );
    }
    return (
      title: toolNameRaw,
      subtitle: null,
      additions: diff?.additions ?? 0,
      deletions: diff?.deletions ?? 0,
    );
  }

  static String? _filePath(String inputText) {
    try {
      final decoded = jsonDecode(inputText);
      if (decoded is Map) {
        for (final key in const [
          'filePath',
          'file_path',
          'path',
          'file',
          'notebookPath',
        ]) {
          final v = decoded[key];
          if (v is String && v.isNotEmpty) return v;
        }
      }
    } catch (_) {}
    final match = RegExp(
      r'"(?:file_?[Pp]ath|path|file)"\s*:\s*"([^"]+)"',
    ).firstMatch(inputText);
    return match?.group(1);
  }

  static int? _fileCount(String inputText) {
    try {
      final decoded = jsonDecode(inputText);
      if (decoded is Map) {
        for (final key in const ['paths', 'files', 'filePaths']) {
          final v = decoded[key];
          if (v is List) return v.length;
          if (v is String && v.isNotEmpty) return 1;
        }
        for (final key in const ['path', 'filePath', 'file']) {
          if (decoded[key] is String) return 1;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Fallback counter for streaming (not-yet-valid-JSON) input.
  static int? _fileCountFromText(String inputText) {
    final matches = RegExp(r'"(?:path|file)"\s*:').allMatches(inputText).length;
    return matches > 0 ? matches : null;
  }

  static String _firstLine(String inputText) {
    try {
      final decoded = jsonDecode(inputText);
      if (decoded is Map) {
        for (final key in const ['command', 'cmd', 'script']) {
          final v = decoded[key];
          if (v is String && v.isNotEmpty) {
            final line = v.split('\n').first.trim();
            return line.length > 60 ? line.substring(0, 60) : line;
          }
        }
      }
    } catch (_) {}
    if (inputText.isEmpty) return '';
    final line = inputText.split('\n').first.trim();
    return line.length > 60 ? line.substring(0, 60) : line;
  }

  Widget _kv(BuildContext context, String label, String value) {
    // Pretty-print JSON input when possible (official shows structured view)
    var display = value;
    try {
      final decoded = jsonDecode(value);
      display = const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {}
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 10.5, color: ZInk.faint(context)),
          ),
          const SizedBox(height: 2),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: ZInk.codeBlockBg(context),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              display.length > 4000
                  ? '${display.substring(0, 4000)}…'
                  : display,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: ZInk.solid(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressRow extends StatelessWidget {
  final Map progress;

  const _ProgressRow({required this.progress});

  @override
  Widget build(BuildContext context) {
    final bytes = (progress['bytes'] as num?)?.toInt() ?? 0;
    final preview = progress['previewLine'] as String? ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              [
                if (preview.isNotEmpty) preview,
                '${(bytes / 1024).toStringAsFixed(1)} KB',
              ].join(' · '),
              style: TextStyle(fontSize: 11, color: ZInk.faint(context)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Turn footer: "已工作 N 分 N 秒" + chevron (expands file changes) and the
/// phase pill on the right.
/// Turn header at the TOP of a turn (official): 「已工作 N 分 N 秒」灰字 +
/// chevron (toggles the file-changes card), status pill on the right.
class TurnHeader extends StatelessWidget {
  final Map<String, dynamic> row;
  final bool hasChanges;
  final bool expanded;
  final VoidCallback onToggle;

  const TurnHeader({
    super.key,
    required this.row,
    required this.hasChanges,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final phase = row['state'] as String? ?? '';
    final duration = _fmtDuration(context, (row['activeMs'] as num?)?.toInt());

    final phaseKey = switch (phase) {
      'running' => 'phase.running',
      'completedSuccess' => 'phase.completedSuccess',
      'completedInterrupted' => 'phase.completedInterrupted',
      'failed' || 'error' => 'phase.error',
      _ => null,
    };

    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Row(
        children: [
          if (duration.isNotEmpty)
            Text(
              trP(context, 'chat.turn.worked', [duration]),
              style: TextStyle(fontSize: 11.5, color: ZInk.faint(context)),
            ),
          if (hasChanges)
            InkWell(
              onTap: onToggle,
              child: Icon(
                expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                size: 16,
                color: ZInk.ghost(context),
              ),
            ),
          const Spacer(),
          if (phaseKey != null)
            PhasePill(label: tr(context, phaseKey), phase: phase),
        ],
      ),
    );
  }

  static String _fmtDuration(BuildContext context, int? ms) {
    if (ms == null || ms < 0) return '';
    final s = (ms / 1000).round();
    if (s < 60) return trP(context, 'chat.time.secOnly', ['$s']);
    return trP(context, 'chat.time.minSec', ['${s ~/ 60}', '${s % 60}']);
  }
}

