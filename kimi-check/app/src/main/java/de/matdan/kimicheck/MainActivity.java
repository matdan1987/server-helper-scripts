package de.matdan.kimicheck;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.InstallSourceInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.content.pm.SigningInfo;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.view.Gravity;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.security.MessageDigest;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

public class MainActivity extends Activity {
    private static final String TARGET = "com.moonshot.kimiclaw";
    private static final int BG = Color.rgb(12, 17, 26);
    private static final int FG = Color.rgb(236, 243, 253);
    private static final int ACCENT = Color.rgb(87, 174, 255);
    private TextView output;
    private String currentReport = "";

    @Override
    public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(18), dp(28), dp(18), dp(16));
        root.setBackgroundColor(BG);

        TextView title = new TextView(this);
        title.setText("Kimi Claw Check");
        title.setTextSize(26);
        title.setTextColor(FG);
        title.setTypeface(null, 1);
        root.addView(title);

        TextView description = new TextView(this);
        description.setText("Lokaler Paket- und Signaturbericht  |  Version 1.2");
        description.setTextColor(ACCENT);
        description.setTextSize(12);
        description.setPadding(0, dp(6), 0, dp(18));
        root.addView(description);

        LinearLayout buttons = new LinearLayout(this);
        buttons.setOrientation(LinearLayout.HORIZONTAL);
        Button refresh = addButton(buttons, "Neu prüfen");
        Button copy = addButton(buttons, "Kopieren");
        Button share = addButton(buttons, "Teilen");
        root.addView(buttons);

        ScrollView scroll = new ScrollView(this);
        output = new TextView(this);
        output.setTextColor(FG);
        output.setTextSize(14);
        output.setTextIsSelectable(true);
        output.setLineSpacing(dp(3), 1.0f);
        output.setPadding(dp(3), dp(20), dp(3), dp(20));
        scroll.addView(output);
        root.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));

        TextView footer = new TextView(this);
        footer.setText("Nur Auslesen. Kein Netzwerkzugriff. Kein Malware-Scanner.");
        footer.setGravity(Gravity.CENTER);
        footer.setTextSize(11);
        footer.setTextColor(Color.LTGRAY);
        root.addView(footer);
        setContentView(root);

        refresh.setOnClickListener(v -> scan());
        copy.setOnClickListener(v -> {
            if (currentReport.isEmpty()) return;
            ClipboardManager clipboard = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
            clipboard.setPrimaryClip(ClipData.newPlainText("Kimi Claw Check", currentReport));
            Toast.makeText(this, "Bericht kopiert", Toast.LENGTH_SHORT).show();
        });
        share.setOnClickListener(v -> {
            if (currentReport.isEmpty()) return;
            Intent intent = new Intent(Intent.ACTION_SEND);
            intent.setType("text/plain");
            intent.putExtra(Intent.EXTRA_TEXT, currentReport);
            startActivity(Intent.createChooser(intent, "Prüfbericht teilen"));
        });
        scan();
    }

    private Button addButton(LinearLayout holder, String label) {
        Button button = new Button(this);
        button.setText(label);
        button.setTextAllCaps(false);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, dp(50), 1);
        lp.setMargins(0, 0, dp(5), 0);
        holder.addView(button, lp);
        return button;
    }

    private int dp(int value) {
        return Math.round(getResources().getDisplayMetrics().density * value);
    }

    private void scan() {
        output.setText("Prüfe die installierte App …");
        new Thread(() -> {
            String result = buildReport();
            runOnUiThread(() -> {
                currentReport = result;
                output.setText(result);
            });
        }).start();
    }

    private String buildReport() {
        StringBuilder b = new StringBuilder();
        b.append("KIMI CLAW CHECK 1.2\n");
        b.append("Zeit: ").append(date(System.currentTimeMillis())).append("\n");
        b.append("Android API: ").append(Build.VERSION.SDK_INT).append("\n\n");
        b.append("Gesuchtes Paket: ").append(TARGET).append("\n\n");

        PackageManager pm = getPackageManager();
        final PackageInfo info;
        try {
            int flags = PackageManager.GET_PERMISSIONS | PackageManager.GET_SIGNING_CERTIFICATES;
            if (Build.VERSION.SDK_INT >= 33) {
                info = pm.getPackageInfo(TARGET, PackageManager.PackageInfoFlags.of(flags));
            } else {
                info = pm.getPackageInfo(TARGET, flags);
            }
        } catch (PackageManager.NameNotFoundException e) {
            b.append("STATUS: Nicht gefunden.\n");
            b.append("Das Paket ist nicht installiert, hat einen anderen Namen oder ist für diese App nicht sichtbar.\n");
            return b.toString();
        } catch (Exception e) {
            b.append("Paketabfrage fehlgeschlagen: ").append(e.getClass().getSimpleName()).append("\n");
            return b.toString();
        }

        b.append("=== APP ===\n");
        b.append("Version: ").append(info.versionName).append("\n");
        if (Build.VERSION.SDK_INT >= 28) {
            b.append("VersionCode: ").append(info.getLongVersionCode()).append("\n");
        }
        b.append("Installiert: ").append(date(info.firstInstallTime)).append("\n");
        b.append("Aktualisiert: ").append(date(info.lastUpdateTime)).append("\n");
        ApplicationInfo app = info.applicationInfo;
        if (app != null) {
            b.append("Name: ").append(pm.getApplicationLabel(app)).append("\n");
        }

        b.append("\n=== INSTALLATIONSQUELLE ===\n");
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                InstallSourceInfo source = pm.getInstallSourceInfo(TARGET);
                b.append("Installiert von: ").append(safe(source.getInstallingPackageName())).append("\n");
                b.append("Angestoßen von: ").append(safe(source.getInitiatingPackageName())).append("\n");
                b.append("Ursprung (falls bekannt): ").append(safe(source.getOriginatingPackageName())).append("\n");
            } else {
                b.append("Installiert von: ").append(safe(pm.getInstallerPackageName(TARGET))).append("\n");
            }
        } catch (Exception e) {
            b.append("Nicht abrufbar: ").append(e.getClass().getSimpleName()).append("\n");
        }
        b.append("Hinweis: Die Browser-Downloadadresse gibt Android hier nicht frei.\n");

        b.append("\n=== SIGNATURZERTIFIKAT ===\n");
        try {
            Signature[] signers = null;
            if (Build.VERSION.SDK_INT >= 28) {
                SigningInfo si = info.signingInfo;
                if (si != null) {
                    signers = si.hasMultipleSigners() ? si.getApkContentsSigners()
                            : si.getSigningCertificateHistory();
                }
            }
            if (signers == null || signers.length == 0) {
                b.append("Kein Zertifikat verfügbar.\n");
            } else {
                for (int i = 0; i < signers.length; i++) {
                    b.append("Signatur ").append(i + 1).append(" SHA-256:\n");
                    b.append(sha256(signers[i].toByteArray())).append("\n");
                }
            }
        } catch (Exception e) {
            b.append("Nicht abrufbar: ").append(e.getClass().getSimpleName()).append("\n");
        }

        b.append("\n=== BERECHTIGUNGEN ===\n");
        if (info.requestedPermissions == null || info.requestedPermissions.length == 0) {
            b.append("Keine deklarierten Berechtigungen gefunden.\n");
        } else {
            for (String permission : info.requestedPermissions) {
                boolean granted = pm.checkPermission(permission, TARGET) == PackageManager.PERMISSION_GRANTED;
                b.append(granted ? "[ERLAUBT] " : "[NICHT ERLAUBT] ").append(permission).append("\n");
            }
        }

        b.append("\n=== INSTALLIERTE BASIS-APK ===\n");
        if (app != null && app.sourceDir != null) {
            File f = new File(app.sourceDir);
            b.append("APK-Größe: ").append(f.length()).append(" Bytes\n");
            try (InputStream in = new FileInputStream(f)) {
                b.append("APK SHA-256:\n").append(sha256Stream(in)).append("\n");
            } catch (Exception e) {
                b.append("Lesen durch Android verhindert: ").append(e.getClass().getSimpleName()).append("\n");
            }
        } else {
            b.append("APK-Pfad nicht zugänglich.\n");
        }

        b.append("\n=== EINORDNUNG ===\n");
        b.append("Ein Fingerabdruck allein bestätigt nicht den offiziellen Herausgeber.\n");
        b.append("Kein Nachweis für oder gegen eine Malware-Infektion.\n");
        b.append("Keine Daten werden an einen Server übertragen.\n");
        return b.toString();
    }

    private static String safe(String value) {
        return value == null || value.isEmpty() ? "Nicht verfügbar" : value;
    }

    private static String date(long millis) {
        return new SimpleDateFormat("dd.MM.yyyy HH:mm:ss", Locale.GERMANY).format(new Date(millis));
    }

    private static String sha256(byte[] bytes) throws Exception {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        return hex(md.digest(bytes));
    }

    private static String sha256Stream(InputStream in) throws Exception {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        byte[] buf = new byte[65536];
        int count;
        while ((count = in.read(buf)) != -1) {
            md.update(buf, 0, count);
        }
        return hex(md.digest());
    }

    private static String hex(byte[] bytes) {
        char[] chars = "0123456789abcdef".toCharArray();
        StringBuilder output = new StringBuilder();
        for (byte value : bytes) {
            output.append(chars[(value >>> 4) & 15]).append(chars[value & 15]);
        }
        return output.toString();
    }
}
