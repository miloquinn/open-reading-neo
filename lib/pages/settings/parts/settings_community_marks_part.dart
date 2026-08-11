part of '../settings_page.dart';

class _GithubMark extends StatelessWidget {
  const _GithubMark();

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: const _GithubMarkPainter());
}

class _GithubMarkPainter extends CustomPainter {
  const _GithubMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white;
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final mark = Path()
      ..moveTo(6.1, 7.2)
      ..lineTo(5.1, 3.1)
      ..quadraticBezierTo(8.2, 3.2, 10.1, 4.8)
      ..quadraticBezierTo(12, 4.35, 13.9, 4.8)
      ..quadraticBezierTo(15.8, 3.2, 18.9, 3.1)
      ..lineTo(17.9, 7.2)
      ..quadraticBezierTo(19.6, 9, 19.6, 11.8)
      ..quadraticBezierTo(19.6, 16.7, 15.8, 18.2)
      ..quadraticBezierTo(14.9, 18.55, 14.9, 20)
      ..lineTo(14.9, 22)
      ..lineTo(9.1, 22)
      ..lineTo(9.1, 20.3)
      ..quadraticBezierTo(7.5, 20.65, 6.7, 19.5)
      ..quadraticBezierTo(6, 18.45, 5, 17.75)
      ..quadraticBezierTo(4.4, 17.3, 4.7, 16.9)
      ..quadraticBezierTo(5, 16.55, 5.7, 17)
      ..quadraticBezierTo(6.9, 17.75, 7.4, 18.35)
      ..quadraticBezierTo(8, 19, 9.1, 18.7)
      ..quadraticBezierTo(9.15, 18, 9.55, 17.55)
      ..quadraticBezierTo(4.4, 16.95, 4.4, 11.8)
      ..quadraticBezierTo(4.4, 9, 6.1, 7.2)
      ..close();
    canvas.drawPath(mark, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _QqMark extends StatelessWidget {
  const _QqMark();

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: const _QqMarkPainter());
}

class _QqMarkPainter extends CustomPainter {
  const _QqMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final white = Paint()..color = Colors.white;
    final blue = Paint()..color = const Color(0xFF1677FF);
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    canvas.drawOval(const Rect.fromLTWH(6.6, 2.2, 10.8, 17.8), white);
    canvas.drawOval(const Rect.fromLTWH(4.2, 9, 4.6, 8.3), white);
    canvas.drawOval(const Rect.fromLTWH(15.2, 9, 4.6, 8.3), white);
    canvas.drawOval(const Rect.fromLTWH(5, 18, 6.8, 3.2), white);
    canvas.drawOval(const Rect.fromLTWH(12.2, 18, 6.8, 3.2), white);
    canvas.drawOval(const Rect.fromLTWH(8.8, 6.2, 2.1, 2.8), blue);
    canvas.drawOval(const Rect.fromLTWH(13.1, 6.2, 2.1, 2.8), blue);
    canvas.drawOval(const Rect.fromLTWH(10.3, 9.1, 3.4, 2), blue);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(6, 13.1, 12, 2.25),
        const Radius.circular(1.1),
      ),
      blue,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
