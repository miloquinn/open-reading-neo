import 'dart:convert';

import 'package:html/parser.dart' as html_parser;

class SourceScriptTextApi {
  const SourceScriptTextApi();

  Object? handle(String operation, List arguments) {
    final value = arguments.isEmpty ? '' : '${arguments.first ?? ''}';
    return switch (operation) {
      'toNumChapter' => sourceScriptToNumChapter(value),
      'utf8Bytes' => List<int>.from(utf8.encode(value)),
      'htmlFormat' => html_parser.parseFragment(value).text ?? '',
      'traditionalToSimplified' => traditionalToSimplified(value),
      'simplifiedToTraditional' => simplifiedToTraditional(value),
      _ => null,
    };
  }
}

String traditionalToSimplified(String value) =>
    _translateCharacters(value, _traditionalSimplifiedMap);

String simplifiedToTraditional(String value) =>
    _translateCharacters(value, _simplifiedTraditionalMap);

String _translateCharacters(String value, Map<int, int> mapping) {
  if (value.isEmpty) return value;
  final output = StringBuffer();
  for (final rune in value.runes) {
    output.writeCharCode(mapping[rune] ?? rune);
  }
  return output.toString();
}

// Keep the built-in conversion deliberately small and deterministic. Sources
// mainly use it for labels and category names; content parsing must not depend
// on a locale-specific system service.
const _traditionalSimplifiedPairs = <String>[
  '萬万',
  '與与',
  '專专',
  '業业',
  '東东',
  '絲丝',
  '兩两',
  '為为',
  '這这',
  '個个',
  '們们',
  '來来',
  '國国',
  '學学',
  '習习',
  '書书',
  '體体',
  '發发',
  '現现',
  '會会',
  '應应',
  '該该',
  '號号',
  '處处',
  '門门',
  '開开',
  '關关',
  '問问',
  '題题',
  '說说',
  '話话',
  '讀读',
  '寫写',
  '進进',
  '過过',
  '還还',
  '選选',
  '擇择',
  '頁页',
  '類类',
  '別别',
  '圖图',
  '標标',
  '籤签',
  '網网',
  '頁页',
  '線线',
  '經经',
  '驗验',
  '證证',
  '碼码',
  '樂乐',
  '歡欢',
  '愛爱',
  '戀恋',
  '廣广',
  '東东',
  '臺台',
  '灣湾',
  '門门',
  '漢汉',
  '語语',
  '簡简',
  '繁繁',
  '轉转',
  '換换',
  '優优',
  '劣劣',
  '機机',
  '動动',
  '靜静',
  '訊讯',
  '息息',
  '時时',
  '間间',
  '長长',
  '短短',
  '頭头',
  '聽听',
  '見见',
  '覺觉',
  '點点',
  '擊击',
  '標标',
  '題题',
  '數数',
  '據据',
  '從从',
  '無无',
  '與与',
  '將将',
  '後后',
  '裡里',
  '別别',
  '麼么',
  '們们',
  '創创',
  '建建',
  '導导',
  '覽览',
  '級级',
  '線线',
  '線线',
  '畫画',
  '報报',
  '導导',
  '權权',
  '限限',
  '錯错',
  '誤误',
  '載载',
  '入入',
  '輸输',
  '出出',
  '實实',
  '際际',
  '聯联',
  '絡络',
  '標标',
  '準准',
  '體体',
  '驗验',
  '認认',
  '識识',
  '獲获',
  '取取',
  '細细',
  '節节',
  '點点',
  '擊击',
  '後后',
  '臺台',
  '館馆',
  '專专',
  '區区',
  '頁页',
  '冊册',
  '冊册',
  '乾干',
  '兒儿',
  '畫画',
  '麗丽',
  '潔洁',
  '壓压',
  '縮缩',
  '慾欲',
  '與与',
  '將将',
  '製制',
  '作作',
  '廣广',
  '場场',
  '夢梦',
  '韓韩',
  '熱热',
  '劇剧',
  '誘诱',
  '亂乱',
  '倫伦',
  '學学',
  '姊姐',
  '師师',
  '護护',
  '醫医',
  '辦办',
  '強强',
  '獄狱',
  '勵励',
  '靈灵',
  '懸悬',
  '慾欲',
  '戲戏',
  '職职',
  '恢恢',
  '聲声',
  '雙双',
  '分分',
  '類类',
  '篩筛',
  '條条',
];

final Map<int, int> _traditionalSimplifiedMap = {
  for (final pair in _traditionalSimplifiedPairs)
    pair.runes.first: pair.runes.last,
};

final Map<int, int> _simplifiedTraditionalMap = {
  for (final entry in _traditionalSimplifiedMap.entries) entry.value: entry.key,
};

String sourceScriptToNumChapter(String input) {
  final match = RegExp(r'[零〇一二两三四五六七八九十百千万亿]+').firstMatch(input);
  if (match == null) return input;
  const digits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  const smallUnits = {'十': 10, '百': 100, '千': 1000};
  const largeUnits = {'万': 10000, '亿': 100000000};
  var total = 0;
  var section = 0;
  var number = 0;
  for (final rune in match.group(0)!.runes) {
    final char = String.fromCharCode(rune);
    if (digits.containsKey(char)) {
      number = digits[char]!;
    } else if (smallUnits.containsKey(char)) {
      section += (number == 0 ? 1 : number) * smallUnits[char]!;
      number = 0;
    } else if (largeUnits.containsKey(char)) {
      total += (section + number) * largeUnits[char]!;
      section = 0;
      number = 0;
    }
  }
  final converted = total + section + number;
  return input.replaceRange(match.start, match.end, '$converted');
}
