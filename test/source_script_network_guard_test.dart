import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/source_script_network_guard.dart';

void main() {
  group('guardNetworkCatchBlocks', () {
    test('injects a marker re-throw guard right after catch (e) {', () {
      final result = guardNetworkCatchBlocks(
        'try { java.ajax(url); } catch (e) { requestFailed = true; }',
      );
      expect(result, contains("catch (e) {if(e&&typeof e.message==='string'"));
      expect(result, contains('requestFailed = true;'));
    });

    test('synthesizes a binding for a bare catch {}', () {
      final result = guardNetworkCatchBlocks(
        'try { x(); } catch { y = 1; }',
      );
      expect(result, contains('catch (__orNetErr) {'));
      expect(result, contains('__orNetErr.message'));
      expect(result, contains('y = 1;'));
    });

    test('does not touch a Promise-style .catch( method call', () {
      const script = 'p.then(x).catch(function(e){ log(e); });';
      expect(guardNetworkCatchBlocks(script), script);
    });

    test('does not touch identifiers merely containing "catch"', () {
      const script = 'function catchAll() { return catchAllValue; }';
      expect(guardNetworkCatchBlocks(script), script);
    });

    test('does not touch the word catch inside a string or comment', () {
      const script = '''
        // catch this comment
        let msg = "please catch me";
        let tmpl = 'catch \\'quoted\\'';
      ''';
      expect(guardNetworkCatchBlocks(script), script);
    });

    test('recurses into nested try/catch inside a catch body', () {
      final result = guardNetworkCatchBlocks(
        'try { a(); } catch (outer) { try { b(); } catch (inner) { c(); } }',
      );
      expect(result, contains("catch (outer) {if(outer&&"));
      expect(result, contains("catch (inner) {if(inner&&"));
    });

    test('guards a catch inside a template literal interpolation', () {
      final result = guardNetworkCatchBlocks(
        r'const s = `x${(function(){ try { f(); } catch (e) { return 1; } })()}y`;',
      );
      expect(result, contains("catch (e) {if(e&&"));
      // The literal template text around the interpolation is preserved.
      expect(result, startsWith('const s = `x\${'));
      expect(result, endsWith('}y`;'));
    });

    test('leaves a destructuring catch binding untouched', () {
      const script = 'try { a(); } catch ({message}) { log(message); }';
      expect(guardNetworkCatchBlocks(script), script);
    });

    test('handles whitespace and comments in the catch header', () {
      final result = guardNetworkCatchBlocks(
        'try { a(); } catch /* err */ (e)\n{ log(e); }',
      );
      expect(result, contains("{if(e&&typeof e.message"));
    });

    test('leaves scripts without any catch untouched', () {
      const script = 'function f(){ return 1; }';
      expect(guardNetworkCatchBlocks(script), same(script));
    });
  });
}
