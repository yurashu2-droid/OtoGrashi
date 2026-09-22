import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:otogurashi/design/tokens.dart';

class OtogurashiApp extends StatelessWidget {
  const OtogurashiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'オトグラシ',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ja'),
      supportedLocales: const [Locale('ja')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: buildOtogurashiTheme(),
      home: const _OnboardingEntrance(),
    );
  }
}

class _OnboardingEntrance extends StatelessWidget {
  const _OnboardingEntrance();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppTokens.pagePadding),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppTokens.contentWidth,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'オトグラシ',
                    textAlign: TextAlign.center,
                    style: textTheme.displaySmall,
                  ),
                  const SizedBox(height: AppTokens.smallGap),
                  Text(
                    '暮らしの音から、あなただけのリズムを。',
                    textAlign: TextAlign.center,
                    style: textTheme.bodyLarge,
                  ),
                  const SizedBox(height: AppTokens.sectionGap),
                  const FilledButton(onPressed: null, child: Text('聴いてみる')),
                  const SizedBox(height: AppTokens.controlGap),
                  const OutlinedButton(
                    onPressed: null,
                    child: Text('自分の音でつくる'),
                  ),
                  const SizedBox(height: AppTokens.smallGap),
                  Text(
                    'サンプル再生と録音は、これから利用できるようになります。',
                    textAlign: TextAlign.center,
                    style: textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
