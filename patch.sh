#!/bin/bash
#
# APK Network Security Config Patcher
#
# This script patches an Android APK to trust user-installed CA certificates,
# enabling HTTPS traffic interception with tools like mitmproxy.
#
# Usage: ./patch-apk-nsc.sh <package-name>
# Example: ./patch-apk-nsc.sh co.hinge.app
#
# Requirements:
# - adb (Android Debug Bridge)
# - java (for xml2axml and uber-apk-signer)
# - zip/unzip
# - wget or curl
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Tool URLs
XML2AXML_URL="https://github.com/codyi96/xml2axml/releases/download/2.0.1/xml2axml-2.0.1.jar"
UBER_SIGNER_URL="https://github.com/patrickfav/uber-apk-signer/releases/download/v1.3.0/uber-apk-signer-1.3.0.jar"

# Tool filenames
XML2AXML_JAR="xml2axml-2.0.1.jar"
UBER_SIGNER_JAR="uber-apk-signer-1.3.0.jar"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Check for required commands
check_requirements() {
    log_info "Checking requirements..."

    for cmd in adb java zip unzip; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "$cmd is required but not installed."
        fi
    done

    # Check for wget or curl
    if ! command -v wget &> /dev/null && ! command -v curl &> /dev/null; then
        log_error "wget or curl is required but neither is installed."
    fi

    # Check adb connection
    if ! adb devices | grep -q "device$"; then
        log_error "No Android device connected. Please connect a device with USB debugging enabled."
    fi

    log_success "All requirements met."
}

# Download a file using wget or curl
download_file() {
    local url="$1"
    local output="$2"

    if [ -f "$output" ]; then
        log_info "$output already exists, skipping download."
        return 0
    fi

    log_info "Downloading $output..."

    if command -v wget &> /dev/null; then
        wget -q --show-progress -O "$output" "$url"
    else
        curl -L -o "$output" "$url"
    fi
}

# Download required tools
download_tools() {
    log_info "Downloading required tools..."

    download_file "$XML2AXML_URL" "$XML2AXML_JAR"
    download_file "$UBER_SIGNER_URL" "$UBER_SIGNER_JAR"

    log_success "Tools downloaded."
}

# Main patching function
patch_apk() {
    local PACKAGE_NAME="$1"
    local WORK_DIR="patch_${PACKAGE_NAME}_$(date +%Y%m%d_%H%M%S)"

    log_info "Creating working directory: $WORK_DIR"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    # Copy tools to working directory
    cp "../$XML2AXML_JAR" . 2>/dev/null || download_file "$XML2AXML_URL" "$XML2AXML_JAR"
    cp "../$UBER_SIGNER_JAR" . 2>/dev/null || download_file "$UBER_SIGNER_URL" "$UBER_SIGNER_JAR"

    # Step 1: Verify package exists
    log_info "Checking if package '$PACKAGE_NAME' is installed..."
    if ! adb shell pm list packages | grep -q "^package:${PACKAGE_NAME}$"; then
        log_error "Package '$PACKAGE_NAME' not found on device."
    fi
    log_success "Package found."

    # Step 2: Get APK paths
    log_info "Getting APK paths..."
    APK_PATHS=$(adb shell pm path "$PACKAGE_NAME" | sed 's/package://' | tr -d '\r')

    if [ -z "$APK_PATHS" ]; then
        log_error "Could not get APK paths for $PACKAGE_NAME"
    fi

    # Step 3: Pull all APKs
    log_info "Pulling APKs from device..."
    declare -a PULLED_APKS

    while IFS= read -r apk_path; do
        apk_name=$(basename "$apk_path")
        log_info "  Pulling $apk_name..."
        adb pull "$apk_path" "$apk_name" > /dev/null
        PULLED_APKS+=("$apk_name")
    done <<< "$APK_PATHS"

    log_success "Pulled ${#PULLED_APKS[@]} APK(s)."

    # Identify base.apk and split APKs
    BASE_APK=""
    declare -a SPLIT_APKS

    for apk in "${PULLED_APKS[@]}"; do
        if [[ "$apk" == "base.apk" ]]; then
            BASE_APK="$apk"
        else
            SPLIT_APKS+=("$apk")
        fi
    done

    if [ -z "$BASE_APK" ]; then
        log_error "Could not find base.apk"
    fi

    log_info "Base APK: $BASE_APK"
    log_info "Split APKs: ${SPLIT_APKS[*]:-none}"

    # Step 4: Create patched network security config
    log_info "Creating patched network_security_config.xml..."

    cat > nsc_patched.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <base-config cleartextTrafficPermitted="true">
        <trust-anchors>
            <certificates src="system" />
            <certificates src="user" />
        </trust-anchors>
    </base-config>
</network-security-config>
EOF

    # Step 5: Convert to Android binary XML
    log_info "Converting to Android binary XML format..."
    java -jar "$XML2AXML_JAR" e nsc_patched.xml nsc_binary.xml

    if [ ! -f "nsc_binary.xml" ]; then
        log_error "Failed to create binary XML"
    fi

    # Step 6: Patch the base APK
    log_info "Patching base APK..."
    cp "$BASE_APK" "base-patched.apk"

    # Create directory structure for the config
    mkdir -p res/xml
    cp nsc_binary.xml res/xml/network_security_config.xml

    # Remove old signature and inject new config
    zip -d "base-patched.apk" "META-INF/*" 2>/dev/null || true
    zip -u "base-patched.apk" res/xml/network_security_config.xml

    log_success "Base APK patched."

    # Step 7: Prepare install directory
    log_info "Preparing APKs for signing..."
    mkdir -p install

    # Copy patched base
    cp "base-patched.apk" install/

    # Copy and strip signatures from split APKs
    for split_apk in "${SPLIT_APKS[@]}"; do
        cp "$split_apk" install/
        zip -d "install/$split_apk" "META-INF/*" 2>/dev/null || true
    done

    # Step 8: Sign all APKs
    log_info "Signing all APKs..."
    java -jar "$UBER_SIGNER_JAR" --apks install/ --overwrite

    log_success "APKs signed."

    # Step 9: Prepare install command
    log_info "Preparing installation..."

    # Find all signed APKs in install directory
    # uber-apk-signer with --overwrite keeps original names
    log_info "Finding signed APKs..."

    # Debug: show what's in the install directory
    log_info "Contents of install directory:"
    ls -la install/

    # Collect all APKs for installation
    declare -a INSTALL_APKS

    # Find base APK (patched)
    if [ -f "install/base-patched.apk" ]; then
        INSTALL_APKS+=("install/base-patched.apk")
    elif [ -f "install/base-patched-aligned-debugSigned.apk" ]; then
        INSTALL_APKS+=("install/base-patched-aligned-debugSigned.apk")
    else
        # Try to find any base-patched APK
        BASE_SIGNED=$(find install -maxdepth 1 -name "base-patched*.apk" -type f | head -1)
        if [ -n "$BASE_SIGNED" ]; then
            INSTALL_APKS+=("$BASE_SIGNED")
        else
            log_error "Could not find signed base APK"
        fi
    fi

    # Find split APKs
    for split_apk in "${SPLIT_APKS[@]}"; do
        split_name="${split_apk%.apk}"
        if [ -f "install/$split_apk" ]; then
            INSTALL_APKS+=("install/$split_apk")
        elif [ -f "install/${split_name}-aligned-debugSigned.apk" ]; then
            INSTALL_APKS+=("install/${split_name}-aligned-debugSigned.apk")
        else
            # Try to find any matching APK
            SPLIT_SIGNED=$(find install -maxdepth 1 -name "${split_name}*.apk" -type f | head -1)
            if [ -n "$SPLIT_SIGNED" ]; then
                INSTALL_APKS+=("$SPLIT_SIGNED")
            else
                log_warn "Could not find signed split APK for $split_apk"
            fi
        fi
    done

    log_info "APKs to install: ${INSTALL_APKS[*]}"

    # Validate APK files exist and have content
    for apk in "${INSTALL_APKS[@]}"; do
        if [ ! -f "$apk" ]; then
            log_error "APK file not found: $apk"
        fi
        apk_size=$(stat -f%z "$apk" 2>/dev/null || stat -c%s "$apk" 2>/dev/null)
        if [ "$apk_size" -eq 0 ] 2>/dev/null; then
            log_error "APK file has zero size: $apk"
        fi
        log_info "  $apk ($(numfmt --to=iec-i --suffix=B $apk_size 2>/dev/null || echo "${apk_size} bytes"))"
    done

    # Step 10: Uninstall and install
    log_info "Uninstalling existing app..."
    adb uninstall "$PACKAGE_NAME" 2>/dev/null || true

    log_info "Installing patched APKs..."
    if [ ${#INSTALL_APKS[@]} -eq 1 ]; then
        # Single APK install
        adb install "${INSTALL_APKS[0]}"
    else
        # Multiple APK install
        adb install-multiple "${INSTALL_APKS[@]}"
    fi

    log_success "Installation complete!"

    # Summary
    echo ""
    echo "=============================================="
    echo -e "${GREEN}APK PATCHING COMPLETE${NC}"
    echo "=============================================="
    echo "Package: $PACKAGE_NAME"
    echo "Working directory: $WORK_DIR"
    echo ""
    echo "The app now trusts user-installed CA certificates."
    echo ""
    echo "Next steps:"
    echo "1. Install your mitmproxy CA certificate on the device"
    echo "2. Configure the device's WiFi proxy to point to mitmproxy"
    echo "3. Launch the app and intercept traffic"
    echo "=============================================="
}

# Print usage
usage() {
    echo "Usage: $0 <package-name>"
    echo ""
    echo "Example:"
    echo "  $0 co.hinge.app"
    echo "  $0 com.instagram.android"
    echo ""
    echo "To find package names:"
    echo "  adb shell pm list packages | grep <app-name>"
    exit 1
}

# Main
main() {
    echo "=============================================="
    echo "APK Network Security Config Patcher"
    echo "=============================================="
    echo ""

    if [ $# -ne 1 ]; then
        usage
    fi

    PACKAGE_NAME="$1"

    check_requirements
    download_tools
    patch_apk "$PACKAGE_NAME"
}

main "$@"
