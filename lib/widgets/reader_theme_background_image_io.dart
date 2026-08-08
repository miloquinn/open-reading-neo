import 'dart:io';

import 'package:flutter/material.dart';

Widget buildReaderThemeBackgroundImage(String imagePath) {
  return Image.file(
    File(imagePath),
    fit: BoxFit.cover,
    filterQuality: FilterQuality.medium,
    gaplessPlayback: true,
    errorBuilder: (_, _, _) => const SizedBox.shrink(),
  );
}
