#!/usr/bin/env bash
#
# Release:
#   V0.1 
# 
# Author:
#   Jose Guerreiro Faisca
#
# Description: 
#   Creates a Java Android project structure and builds a DEBUG APK
#   directly with Android SDK tools. No Gradle or Maven is used.
#
# Prerequisites:
#   - JDK (javac, java, keytool)
#   - Android SDK platform (android.jar)
#   - Android SDK Build-Tools (aapt2, d8, zipalign, apksigner)
#   - Android SDK Platform-Tools (adb, optional)
#
# Usage:
#   chmod +x android-native-build.sh
#   ./android-native-build.sh
#
# Optional environment variables:
#   ANDROID_HOME / ANDROID_SDK_ROOT  SDK root
#   COMPILE_SDK                    API level, default: highest installed
#   MIN_SDK                        minimum API level, default: 24
#   TARGET_SDK                     target API level, default: COMPILE_SDK
#   BUILD_TOOLS_VERSION            Build-Tools version, default: highest installed
#   APP_ID                         e.g. org.example.hello
#   APP_LABEL                      e.g. Hello Android
#   APP_VERSION_CODE               default: 1
#   APP_VERSION_NAME               default: 1.0
#
# Project layout:
#   AndroidManifest.xml
#   src/<package path>/*.java
#   res/                         optional Android resources
#   build/
#     classes/                   compiled Java classes
#     generated/                 generated R.java
#     apk/                       final APK
#
# The script does not overwrite existing source files or the manifest.
#

set -Eeuo pipefail

log()  { printf '\n[%s] %s\n' "INFO" "$*"; }
warn() { printf '\n[%s] %s\n' "WARN" "$*" >&2; }
die()  { printf '\n[%s] %s\n' "ERROR" "$*" >&2; exit 1; }

is_version() {
    [[ $1 =~ ^[0-9]+(\.[0-9]+)*$ ]]
}

version_leq() {
    local -a a b
    local IFS=.
    read -ra a <<< "$1"
    read -ra b <<< "$2"

    local i n=${#a[@]}
    (( ${#b[@]} > n )) && n=${#b[@]}

    local x y
    for ((i = 0; i < n; i++)); do
        x=${a[i]:-0}
        y=${b[i]:-0}
        (( 10#$x < 10#$y )) && return 0
        (( 10#$x > 10#$y )) && return 1
    done
    return 0
}

command -v javac >/dev/null 2>&1 || die "javac not found. Install a JDK and put it on PATH."
command -v java  >/dev/null 2>&1 || die "java not found. Install a JDK and put it on PATH."
command -v keytool >/dev/null 2>&1 || die "keytool not found. Install a JDK."
command -v jar >/dev/null 2>&1 || die "jar not found. Install a JDK."

SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$SDK_ROOT" ]]; then
    die "Set ANDROID_HOME or ANDROID_SDK_ROOT to your Android SDK directory."
fi
SDK_ROOT="$(cd "$SDK_ROOT" && pwd)"

# Locate installed platform directories and choose the requested or highest API.
if [[ -n "${COMPILE_SDK:-}" ]]; then
    PLATFORM_DIR=""
    for candidate in "$SDK_ROOT"/platforms/android-"${COMPILE_SDK}"*; do
        [[ -f "$candidate/android.jar" ]] && PLATFORM_DIR="$candidate" && break
    done
    [[ -n "$PLATFORM_DIR" ]] || die "Android platform API ${COMPILE_SDK} (android.jar) is not installed."
else
    PLATFORM_DIR="$(
        find "$SDK_ROOT/platforms" -mindepth 2 -maxdepth 2 -type f -name android.jar 2>/dev/null |
        sed 's#/android.jar$##' |
        sort -V |
        tail -n 1
    )"
    [[ -n "$PLATFORM_DIR" ]] || die "No installed Android SDK platform containing android.jar was found."
fi

ANDROID_JAR="$PLATFORM_DIR/android.jar"
PLATFORM_NAME="${PLATFORM_DIR##*/}"
DETECTED_API="${PLATFORM_NAME#android-}"
COMPILE_API="${COMPILE_SDK:-$DETECTED_API}"
MIN_API="${MIN_SDK:-24}"
TARGET_API="${TARGET_SDK:-$COMPILE_API}"

is_version "$MIN_API" || die "MIN_SDK must be a dotted numeric version."
is_version "$TARGET_API" || die "TARGET_SDK must be a dotted numeric version."
version_leq "$MIN_API" "$TARGET_API" ||
    die "MIN_SDK ($MIN_API) cannot exceed TARGET_SDK ($TARGET_API)."

# Choose a Build-Tools version. Explicit BUILD_TOOLS_VERSION takes precedence.
if [[ -n "${BUILD_TOOLS_VERSION:-}" ]]; then
    BT_DIR="$SDK_ROOT/build-tools/$BUILD_TOOLS_VERSION"
    [[ -d "$BT_DIR" ]] || die "Build-Tools $BUILD_TOOLS_VERSION is not installed."
else
    BT_DIR="$(
        find "$SDK_ROOT/build-tools" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
        sort -V |
        tail -n 1
    )"
    [[ -n "$BT_DIR" ]] || die "No Android SDK Build-Tools installation was found."
fi

AAPT2="$BT_DIR/aapt2"
D8="$BT_DIR/d8"
ZIPALIGN="$BT_DIR/zipalign"
APKSIGNER="$BT_DIR/apksigner"

for tool in "$AAPT2" "$D8" "$ZIPALIGN" "$APKSIGNER"; do
    [[ -x "$tool" ]] || die "Required SDK tool is missing or not executable: $tool"
done

PROJECT_DIR="$(pwd)"
# Reuse the layout from the supplied Gradle project if it already exists;
# otherwise use a compact Gradle-free layout at the project root.
if [[ -f "$PROJECT_DIR/AndroidManifest.xml" ]]; then
    MANIFEST="$PROJECT_DIR/AndroidManifest.xml"
elif [[ -f "$PROJECT_DIR/app/src/main/AndroidManifest.xml" ]]; then
    MANIFEST="$PROJECT_DIR/app/src/main/AndroidManifest.xml"
else
    MANIFEST="$PROJECT_DIR/AndroidManifest.xml"
fi

if [[ -d "$PROJECT_DIR/app/src/main/java" ]]; then
    SRC_DIR="$PROJECT_DIR/app/src/main/java"
else
    SRC_DIR="$PROJECT_DIR/src"
fi
if [[ -d "$PROJECT_DIR/app/src/main/res" ]]; then
    RES_DIR="$PROJECT_DIR/app/src/main/res"
else
    RES_DIR="$PROJECT_DIR/res"
fi
BUILD_DIR="$PROJECT_DIR/build"
GEN_DIR="$BUILD_DIR/generated"
CLASSES_DIR="$BUILD_DIR/classes"
DEX_DIR="$BUILD_DIR/dex"
APK_DIR="$BUILD_DIR/apk"
APK_UNSIGNED="$APK_DIR/app-unsigned.apk"
APK_ALIGNED="$APK_DIR/app-aligned.apk"
APK_FINAL="$APK_DIR/app-debug.apk"

APP_ID="${APP_ID:-}"
APP_LABEL="${APP_LABEL:-}"

if [[ -z "$APP_ID" ]]; then
    read -rp "Application ID (e.g. org.example.hello): " APP_ID
fi
if [[ ! "$APP_ID" =~ ^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$ ]]; then
    die "Invalid application ID: $APP_ID"
fi

if [[ -z "$APP_LABEL" ]]; then
    read -rp "Application display name [Hello Android]: " APP_LABEL
    APP_LABEL="${APP_LABEL:-Hello Android}"
fi

VERSION_CODE="${APP_VERSION_CODE:-1}"
VERSION_NAME="${APP_VERSION_NAME:-1.0}"
PACKAGE_PATH="${APP_ID//./\/}"
JAVA_PACKAGE_DIR="$SRC_DIR/$PACKAGE_PATH"

mkdir -p "$JAVA_PACKAGE_DIR" "$RES_DIR" "$BUILD_DIR" "$GEN_DIR" "$CLASSES_DIR" "$DEX_DIR" "$APK_DIR"

if [[ ! -f "$MANIFEST" ]]; then
    cat > "$MANIFEST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="$APP_ID">
    <uses-sdk
        android:minSdkVersion="$MIN_API"
        android:targetSdkVersion="$TARGET_API" />
    <application
        android:label="$APP_LABEL"
        android:theme="@android:style/Theme.Material.Light.NoActionBar">
        <activity
            android:name=".MainActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
EOF
    log "Created $MANIFEST"
else
    log "Using existing $MANIFEST (not overwritten)"
fi

MAIN_JAVA="$JAVA_PACKAGE_DIR/MainActivity.java"
if [[ ! -f "$MAIN_JAVA" ]]; then
    cat > "$MAIN_JAVA" <<EOF
package $APP_ID;

import android.app.Activity;
import android.os.Bundle;
import android.widget.TextView;

public class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        TextView message = new TextView(this);
        message.setText("Hello from a Gradle-free Android APK!");
        message.setTextSize(22);
        message.setPadding(32, 32, 32, 32);
        setContentView(message);
    }
}
EOF
    log "Created $MAIN_JAVA"
else
    log "Using existing $MAIN_JAVA (not overwritten)"
fi

log "SDK:          $SDK_ROOT"
log "Platform:     $PLATFORM_NAME ($ANDROID_JAR)"
log "Build-Tools:  ${BT_DIR##*/}"
log "Application:  $APP_ID"
log "Min/Target:   $MIN_API / $TARGET_API"

# Compile Android resources, if any exist. This also supports an empty res/ directory.
RESOURCE_ARGS=()
COMPILED_RES="$BUILD_DIR/resources"
rm -rf "$COMPILED_RES"
mkdir -p "$COMPILED_RES"

if find "$RES_DIR" -type f | grep -q .; then
    log "Compiling resources with aapt2"
    "$AAPT2" compile --dir "$RES_DIR" -o "$BUILD_DIR/resources.zip"
    RESOURCE_ARGS=(-R "$BUILD_DIR/resources.zip")
else
    log "No resource files found; linking manifest only"
    RESOURCE_ARGS=()
fi

log "Linking manifest and Android resources"
rm -rf "$GEN_DIR"
mkdir -p "$GEN_DIR"
"$AAPT2" link \
    -o "$APK_UNSIGNED" \
    -I "$ANDROID_JAR" \
    --manifest "$MANIFEST" \
    --rename-manifest-package "$APP_ID" \
    --java "$GEN_DIR" \
    --min-sdk-version "$MIN_API" \
    --target-sdk-version "$TARGET_API" \
    --version-code "$VERSION_CODE" \
    --version-name "$VERSION_NAME" \
    "${RESOURCE_ARGS[@]}"

# Compile all project Java sources plus generated R.java (when resources exist).
mapfile -d '' JAVA_FILES < <(find "$SRC_DIR" "$GEN_DIR" -type f -name '*.java' -print0)
((${#JAVA_FILES[@]} > 0)) || die "No Java source files found under $SRC_DIR."

log "Compiling ${#JAVA_FILES[@]} Java source file(s)"
rm -rf "$CLASSES_DIR"
mkdir -p "$CLASSES_DIR"
javac \
    -encoding UTF-8 \
    -source 8 -target 8 \
    -bootclasspath "$ANDROID_JAR" \
    -d "$CLASSES_DIR" \
    "${JAVA_FILES[@]}"

log "Converting Java bytecode to DEX"
rm -rf "$DEX_DIR"
mkdir -p "$DEX_DIR"
mapfile -d '' CLASS_FILES < <(find "$CLASSES_DIR" -type f -name '*.class' -print0)
((${#CLASS_FILES[@]} > 0)) || die "javac did not produce any .class files."

"$D8" \
    --lib "$ANDROID_JAR" \
    --min-api "$MIN_API" \
    --output "$DEX_DIR" \
    "${CLASS_FILES[@]}"

[[ -f "$DEX_DIR/classes.dex" ]] || die "D8 did not produce classes.dex."

log "Adding DEX bytecode to APK"
shopt -s nullglob
DEX_FILES=("$DEX_DIR"/classes*.dex)
((${#DEX_FILES[@]} > 0)) || die "No DEX files were produced."
for dex_file in "${DEX_FILES[@]}"; do
    jar uf "$APK_UNSIGNED" -C "$DEX_DIR" "${dex_file##*/}"
done
shopt -u nullglob

log "Aligning APK"
"$ZIPALIGN" -f -v 4 "$APK_UNSIGNED" "$APK_ALIGNED"

KEYSTORE="$BUILD_DIR/debug.keystore"
if [[ ! -f "$KEYSTORE" ]]; then
    log "Generating local debug keystore"
    keytool -genkeypair \
        -keystore "$KEYSTORE" \
        -storepass android \
        -keypass android \
        -alias androiddebugkey \
        -dname "CN=Android Debug,O=Android,C=US" \
        -keyalg RSA \
        -keysize 2048 \
        -validity 10000 \
        >/dev/null 2>&1
fi

log "Signing APK"
"$APKSIGNER" sign \
    --ks "$KEYSTORE" \
    --ks-pass pass:android \
    --key-pass pass:android \
    --ks-key-alias androiddebugkey \
    --out "$APK_FINAL" \
    "$APK_ALIGNED"

"$APKSIGNER" verify --verbose "$APK_FINAL" >/dev/null

log "Verifying manifest SDK metadata"
BADGING="$("$BT_DIR/aapt" dump badging "$APK_FINAL")"
printf '%s\n' "$BADGING" | grep -E "^(sdkVersion|targetSdkVersion):" || true
if ! printf '%s\n' "$BADGING" | grep -q "targetSdkVersion:'$TARGET_API'"; then
    die "Final APK does not contain targetSdkVersion $TARGET_API. Inspect the manifest and aapt2 link step."
fi

printf '\nBuild successful.\n'
printf 'APK: %s\n' "$APK_FINAL"
printf 'Install with: adb install -r "%s"\n' "$APK_FINAL"
