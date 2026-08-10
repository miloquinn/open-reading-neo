/// Rewrites source-script JS so that a script's own `try { ... } catch { ... }`
/// cannot silently swallow the internal signal ORSP throws when a synchronous
/// host call (`java.ajax`, `java.get`, `startBrowserAwait`, ...) needs a real
/// async network/interaction round trip.
///
/// The script evaluator (see `source_script_engine.dart`) emulates blocking
/// I/O by throwing an `Error` whose message starts with
/// `__OPEN_READING_NETWORK__` or `__OPEN_READING_INTERACTION__`, catching it
/// outside the whole script, performing the real request, and re-running the
/// script with the answer cached. That only works if the marker error
/// propagates all the way out of the script uncaught — but many real-world
/// Legado sources wrap their own network calls in a defensive
/// `try { ... } catch (e) { ... }`, which intercepts the marker just like any
/// other error and never lets Dart see it. The request then silently never
/// happens.
///
/// This rewrites every `catch` clause in the script (recursively, including
/// inside template-literal `${...}` interpolations) to re-throw the marker
/// before running the source's own catch body, so the retry loop still gets
/// a chance to see it. Any other exception is left untouched — from the
/// source script's point of view, this is invisible.
///
/// This is a lightweight tokenizer, not a full JS parser: it understands
/// string/template literals and comments well enough not to be fooled by the
/// word "catch" appearing inside them, but it does not disambiguate regex
/// literals from division, matching real-world JS tooling limitations for a
/// single-pass scan. A `catch` clause with a destructuring binding (e.g.
/// `catch ({message}) {}`) is left untouched rather than risk generating
/// invalid JS.
String guardNetworkCatchBlocks(String script) {
  if (!script.contains('catch')) return script;
  return _CatchGuardTransform(script).run();
}

const String _networkMarker = '__OPEN_READING_NETWORK__';
const String _interactionMarker = '__OPEN_READING_INTERACTION__';
const String _syntheticCatchVar = '__orNetErr';

String _guardStatement(String catchVar) =>
    'if($catchVar&&typeof $catchVar.message===\'string\'&&'
    '($catchVar.message.indexOf(\'$_networkMarker\')===0||'
    '$catchVar.message.indexOf(\'$_interactionMarker\')===0)){throw $catchVar;}';

class _CatchGuardTransform {
  _CatchGuardTransform(this.source);

  final String source;
  final StringBuffer _out = StringBuffer();
  int _pos = 0;

  int get _length => source.length;

  String run() {
    while (_pos < _length) {
      if (_trySkipStringOrComment()) continue;
      if (_trySkipTemplateLiteral()) continue;
      if (_tryTransformCatch()) continue;
      _out.write(source[_pos]);
      _pos++;
    }
    return _out.toString();
  }

  bool _trySkipStringOrComment() {
    final ch = source[_pos];
    if (ch == '"' || ch == "'") {
      final end = _quotedStringEnd(_pos, ch);
      _out.write(source.substring(_pos, end));
      _pos = end;
      return true;
    }
    if (ch == '/' && _pos + 1 < _length && source[_pos + 1] == '/') {
      var end = source.indexOf('\n', _pos);
      end = end < 0 ? _length : end;
      _out.write(source.substring(_pos, end));
      _pos = end;
      return true;
    }
    if (ch == '/' && _pos + 1 < _length && source[_pos + 1] == '*') {
      final close = source.indexOf('*/', _pos + 2);
      final end = close < 0 ? _length : close + 2;
      _out.write(source.substring(_pos, end));
      _pos = end;
      return true;
    }
    return false;
  }

  /// Handles a backtick template literal, recursing into `${...}`
  /// interpolations so `catch` blocks inside them still get guarded.
  bool _trySkipTemplateLiteral() {
    if (source[_pos] != '`') return false;
    _out.write('`');
    _pos++;
    while (_pos < _length) {
      final ch = source[_pos];
      if (ch == r'\' && _pos + 1 < _length) {
        _out.write(source.substring(_pos, _pos + 2));
        _pos += 2;
        continue;
      }
      if (ch == '`') {
        _out.write('`');
        _pos++;
        return true;
      }
      if (ch == r'$' && _pos + 1 < _length && source[_pos + 1] == '{') {
        _out.write(r'${');
        _pos += 2;
        _consumeBalancedCode(stopAtDepthZeroBrace: true);
        continue;
      }
      _out.write(ch);
      _pos++;
    }
    return true;
  }

  /// Consumes code up to (and including) the `}` that matches the `{`
  /// already consumed by the caller, writing it through `run`'s normal
  /// per-character/per-token handling (so nested catches are still
  /// transformed), then returns with `_pos` just past that `}`.
  void _consumeBalancedCode({required bool stopAtDepthZeroBrace}) {
    var depth = 0;
    while (_pos < _length) {
      if (_trySkipStringOrComment()) continue;
      if (_trySkipTemplateLiteral()) continue;
      if (_tryTransformCatch()) continue;
      final ch = source[_pos];
      if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        if (depth == 0 && stopAtDepthZeroBrace) {
          _out.write('}');
          _pos++;
          return;
        }
        depth--;
      }
      _out.write(ch);
      _pos++;
    }
  }

  bool _tryTransformCatch() {
    if (!source.startsWith('catch', _pos)) return false;
    if (_pos > 0 && _isIdentifierPart(source[_pos - 1])) return false;
    final afterKeyword = _pos + 5;
    if (afterKeyword < _length && _isIdentifierPart(source[afterKeyword])) {
      return false;
    }
    if (_precededByDot()) return false;

    var p = _skipInsignificant(afterKeyword);
    String? catchVar;
    int headerEnd;
    if (p < _length && source[p] == '(') {
      final close = _findMatchingParen(p);
      if (close == null) return false;
      final inner = source.substring(p + 1, close).trim();
      if (!_simpleIdentifier.hasMatch(inner)) {
        // Destructuring or other complex binding: leave this catch alone
        // rather than risk emitting invalid JS.
        return false;
      }
      catchVar = inner;
      headerEnd = close + 1;
    } else {
      headerEnd = afterKeyword;
    }
    final braceAt = _skipInsignificant(headerEnd);
    if (braceAt >= _length || source[braceAt] != '{') return false;

    if (catchVar == null) {
      // `catch { ... }` (no binding) — Legado sources commonly write this.
      _out.write('catch ($_syntheticCatchVar) {');
      catchVar = _syntheticCatchVar;
    } else {
      _out.write(source.substring(_pos, braceAt + 1));
    }
    _out.write(_guardStatement(catchVar));
    _pos = braceAt + 1;
    return true;
  }

  bool _precededByDot() {
    final text = _out.toString();
    var i = text.length - 1;
    while (i >= 0 && (text[i] == ' ' || text[i] == '\t' || text[i] == '\n')) {
      i--;
    }
    return i >= 0 && text[i] == '.';
  }

  int _skipInsignificant(int start) {
    var i = start;
    while (i < _length) {
      final ch = source[i];
      if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
        i++;
        continue;
      }
      if (ch == '/' && i + 1 < _length && source[i + 1] == '/') {
        final end = source.indexOf('\n', i);
        i = end < 0 ? _length : end;
        continue;
      }
      if (ch == '/' && i + 1 < _length && source[i + 1] == '*') {
        final close = source.indexOf('*/', i + 2);
        i = close < 0 ? _length : close + 2;
        continue;
      }
      break;
    }
    return i;
  }

  int? _findMatchingParen(int openParenPos) {
    var depth = 0;
    var i = openParenPos;
    while (i < _length) {
      final ch = source[i];
      if (ch == '"' || ch == "'") {
        i = _quotedStringEnd(i, ch);
        continue;
      }
      if (ch == '/' && i + 1 < _length && source[i + 1] == '/') {
        final end = source.indexOf('\n', i);
        i = end < 0 ? _length : end;
        continue;
      }
      if (ch == '/' && i + 1 < _length && source[i + 1] == '*') {
        final close = source.indexOf('*/', i + 2);
        i = close < 0 ? _length : close + 2;
        continue;
      }
      if (ch == '(') depth++;
      if (ch == ')') {
        depth--;
        if (depth == 0) return i;
      }
      i++;
    }
    return null;
  }

  int _quotedStringEnd(int start, String quote) {
    var i = start + 1;
    while (i < _length) {
      final ch = source[i];
      if (ch == r'\' && i + 1 < _length) {
        i += 2;
        continue;
      }
      if (ch == quote) return i + 1;
      i++;
    }
    return _length;
  }
}

bool _isIdentifierPart(String ch) =>
    RegExp(r'[A-Za-z0-9_$]').hasMatch(ch);

final RegExp _simpleIdentifier = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');
