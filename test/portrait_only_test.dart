import 'package:fede_apps_core/fede_apps_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Contador de builds y de veces que se monta: la app no se reconstruye
/// "desde cero" al rotar.
class _Probe extends StatefulWidget {
  const _Probe();
  static int inits = 0;
  static Size? lastSize;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    _Probe.inits++;
  }

  @override
  Widget build(BuildContext context) {
    _Probe.lastSize = MediaQuery.of(context).size;
    return const Text('APP');
  }
}

void main() {
  tearDown(() => PortraitOnly.debugDeviceIsLandscape = () => null);

  Future<void> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) =>
          PortraitOnly(enabled: true, child: child!),
      home: const Scaffold(body: _Probe()),
    ));
  }

  testWidgets('teléfono: apaisado tapa la app y la mantiene en vertical',
      (tester) async {
    addTearDown(tester.view.reset);
    _Probe.inits = 0;
    PortraitOnly.debugDeviceIsLandscape = () => false;
    await pump(tester, const Size(390, 844));
    expect(find.text('Rotate your phone'), findsNothing);
    expect(_Probe.lastSize, const Size(390, 844));

    PortraitOnly.debugDeviceIsLandscape = () => true;
    await pump(tester, const Size(844, 390));
    expect(find.text('Rotate your phone'), findsOneWidget);
    expect(_Probe.lastSize, const Size(390, 844)); // no se reacomoda

    PortraitOnly.debugDeviceIsLandscape = () => false;
    await pump(tester, const Size(390, 844));
    expect(find.text('Rotate your phone'), findsNothing);
    expect(_Probe.lastSize, const Size(390, 844));
    expect(_Probe.inits, 1); // nunca se desmontó
  });

  testWidgets('teclado en vertical (ventana más ancha) no dispara el aviso',
      (tester) async {
    addTearDown(tester.view.reset);
    PortraitOnly.debugDeviceIsLandscape = () => false;
    await pump(tester, const Size(390, 350));
    expect(find.text('Rotate your phone'), findsNothing);
  });

  testWidgets('sin dato del navegador usa el tamaño', (tester) async {
    addTearDown(tester.view.reset);
    PortraitOnly.debugDeviceIsLandscape = () => null;
    await pump(tester, const Size(844, 390));
    expect(find.text('Rotate your phone'), findsOneWidget);
  });

  testWidgets('tablet / compu apaisada: sin aviso', (tester) async {
    addTearDown(tester.view.reset);
    PortraitOnly.debugDeviceIsLandscape = () => true;
    await pump(tester, const Size(1280, 800));
    expect(find.text('Rotate your phone'), findsNothing);
    expect(_Probe.lastSize, const Size(1280, 800));
  });
}
