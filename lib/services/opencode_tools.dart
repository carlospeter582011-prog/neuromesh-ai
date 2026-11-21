import 'dart:convert';
import 'dart:io';

import 'agent_tools.dart';

/// The first on-device agent profile can inspect the workspace.
const openCodeReadTools = {'read'};

class OpenCodeTools {
  OpenCodeTools(Object? offered, {this.workspace}) {
    if (offered is! List) return;
    for (final item in offered.whereType<Map>()) {
      final function = item['function'];
      if (item['type'] == 'function' &&
          function is Map &&
          openCodeReadTools.contains(function['name']) &&
          function['parameters'] is Map) {
        _functions[function['name'] as String] = function;
      }
    }
  }

  final _functions = <String, Map>{};
  final Directory? workspace;
  bool get isEmpty => _functions.isEmpty;

  String get instructions => '''
To inspect a workspace file, output a single tool call and stop. Example:
<tool_call>{"name":"read","arguments":{"filePath":"/workspace/example.txt"}}</tool_call>
Replace the example path with the requested file path. Optional read arguments
are offset and limit (numbers). Wait for the workspace tool result before
describing file contents. When no tool is needed, respond in plain text.
''';

  static String textForMessage(Map message) {
    final role = message['role'];
    final content = message['content'];
    final calls = message['tool_calls'];
    if (role == 'tool') return 'Workspace tool result: ${jsonEncode(content)}';
    if (role == 'assistant' && calls is List) {
      return '${content is String ? content : ''}\nRequested workspace tool: ${jsonEncode(calls)}';
    }
    return content is String ? content : '';
  }

  Map<String, dynamic>? parse(String reply, String id) {
    final text = reply.trim();
    if (isEmpty ||
        !text.startsWith('<tool_call>') ||
        !text.endsWith('</tool_call>')) return null;
    final call = parseToolCall(reply);
    if (call == null) return null;
    final schema = _functions[call.name]?['parameters'];
    if (schema is! Map) return null;
    final properties = schema['properties'];
    if (properties is! Map ||
        call.arguments.keys.any((key) => !properties.containsKey(key))) {
      return null;
    }
    final required = schema['required'];
    if (required is List &&
        required.any((key) => !call.arguments.containsKey(key))) return null;
    if (!_isInWorkspace(call.arguments)) return null;
    return {
      'id': 'call_$id',
      'type': 'function',
      'function': {'name': call.name, 'arguments': jsonEncode(call.arguments)},
    };
  }

  bool _isInWorkspace(Map<String, dynamic> arguments) {
    final root = workspace;
    if (root == null) return true;
    final location = arguments['filePath'] ?? arguments['path'] ?? '.';
    if (location is! String || location.contains('\u0000')) return false;
    if (location.startsWith('/') &&
        location != '/workspace' &&
        !location.startsWith('/workspace/')) {
      return false;
    }
    final relative = location == '/workspace'
        ? '.'
        : location.startsWith('/workspace/')
            ? location.substring(11)
            : location;
    if (relative.split('/').contains('..')) return false;
    try {
      final base = root.resolveSymbolicLinksSync();
      final target = File('$base/$relative').resolveSymbolicLinksSync();
      return target == base || target.startsWith('$base/');
    } on FileSystemException {
      return false;
    }
  }
}
