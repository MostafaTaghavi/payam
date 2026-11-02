"""تنظیمات اندروید لازم برای نوتیفیکیشن و سرویس پس‌زمینه را روی پروژه ساخته‌شده اعمال می‌کند."""
import re
import sys
import pathlib

root = pathlib.Path(sys.argv[1])

# ---------- AndroidManifest ----------
man = root / "android/app/src/main/AndroidManifest.xml"
t = man.read_text(encoding="utf-8")

if "xmlns:tools" not in t:
    t = t.replace("<manifest ", '<manifest xmlns:tools="http://schemas.android.com/tools" ', 1)

perms = [
    "INTERNET",
    "POST_NOTIFICATIONS",
    "FOREGROUND_SERVICE",
    "FOREGROUND_SERVICE_DATA_SYNC",
    "WAKE_LOCK",
]
add = "".join(
    f'    <uses-permission android:name="android.permission.{p}"/>\n' for p in perms
    if f"android.permission.{p}" not in t
)
assert "<application" in t, "application tag not found"
t = t.replace("<application", add + "    <application", 1)
t = t.replace("<application", '<application android:usesCleartextTraffic="true"', 1)
t = t.replace('android:label="payam"', 'android:label="پیام"')

service = (
    '        <service\n'
    '            android:name="id.flutter.flutter_background_service.BackgroundService"\n'
    '            android:foregroundServiceType="dataSync"\n'
    '            tools:replace="android:foregroundServiceType" />\n'
)
assert "</application>" in t, "closing application tag not found"
t = t.replace("</application>", service + "    </application>", 1)
man.write_text(t, encoding="utf-8")
print("manifest patched")

# ---------- Gradle: desugaring (لازم برای flutter_local_notifications) ----------
done = False
kts = root / "android/app/build.gradle.kts"
groovy = root / "android/app/build.gradle"
if kts.exists():
    s = kts.read_text(encoding="utf-8")
    if "isCoreLibraryDesugaringEnabled" not in s:
        s, n = re.subn(r"compileOptions\s*\{", "compileOptions {\n        isCoreLibraryDesugaringEnabled = true", s, count=1)
        assert n == 1, "compileOptions not found in build.gradle.kts"
        s += '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n}\n'
        kts.write_text(s, encoding="utf-8")
    done = True
elif groovy.exists():
    s = groovy.read_text(encoding="utf-8")
    if "coreLibraryDesugaringEnabled" not in s:
        s, n = re.subn(r"compileOptions\s*\{", "compileOptions {\n        coreLibraryDesugaringEnabled true", s, count=1)
        assert n == 1, "compileOptions not found in build.gradle"
        s += "\ndependencies {\n    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'\n}\n"
        groovy.write_text(s, encoding="utf-8")
    done = True
assert done, "no app gradle file found"
print("gradle patched")
