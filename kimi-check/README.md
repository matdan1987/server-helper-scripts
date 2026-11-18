# Kimi Claw Check 1.2

Minimalistischer Android-Inspektor fuer die installierte App `com.moonshot.kimiclaw`.

- Zeigt App-Name, Paket, Version, Installations- und Updatezeit
- Zeigt Installationsquelle, soweit sie Android freigibt
- Zeigt angeforderte und gewaehrte Berechtigungen
- Zeigt SHA-256 des Signaturzertifikats
- Versucht die SHA-256 der installierten Basis-APK zu lesen (Android kann den Zugriff verweigern)
- Exportiert den Bericht per Zwischenablage oder Teilen-Dialog
- Keine INTERNET-Berechtigung, keine Telemetrie, keine Veraenderung anderer Apps

## Einschraenkungen

Die App kann nicht die vollstaendige Browser-Download-URL oder Defender-interne Fundberichte lesen. Der SHA-256-Zertifikatsfingerabdruck beweist keine Echtheit, solange kein unabhaengig verifizierter Herstellerwert vorliegt. Diese App erkennt **keine Malware** und ersetzt keinen Virenscanner.

## APK bauen

Der GitHub-Actions-Workflow `.github/workflows/kimi-claw-check-apk.yml` kompiliert mit Android Gradle Plugin und erstellt eine debug-signierte APK als Workflow-Artefakt.

Zur Installation die APK aus dem ZIP-Artefakt entpacken.
