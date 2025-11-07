#!/usr/bin/env python3
"""
    Robust Android Emulator setup for Ubuntu (idempotent, non-interactive).

    Features:
        - Installs all system dependencies cleanly
        - Automatically downloads and configures Android SDK command-line tools
        - Ensures PATH and environment variables are persistent
        - Installs emulator, platform-tools, and Android 33 x86_64 image
        - Creates a default AVD if missing
        - Optional proxy setup via --proxy IP[:PORT] (applied after emulator boots)
"""

import os
import sys
import shutil
import subprocess
import socket
import argparse
import time
from pathlib import Path
from urllib.request import urlretrieve


SDK_ZIP_URL = "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
SDK_ROOT = Path.home() / "Android" / "Sdk"
CMDLINE_DIR = SDK_ROOT / "cmdline-tools" / "latest"
SDKMANAGER_PATH = CMDLINE_DIR / "bin" / "sdkmanager"
AVDMANAGER_PATH = CMDLINE_DIR / "bin" / "avdmanager"
AVD_NAME = "android_emulator_36"
IMAGE_NAME = "system-images;android-36;google_apis_playstore;x86_64"

JAVA_PACKAGES = ["openjdk-17-jdk", "openjdk-17-jre"]

REQUIRED_DEPS = [
    "qemu-kvm",
    "libvirt-daemon-system",
    "libvirt-clients",
    "bridge-utils",
    "virt-manager",
    "wget",
    "unzip",
    "curl"
] + JAVA_PACKAGES


def run(cmd, check=True, env=None):
    print(f"\n[+] Running: {cmd}")
    result = subprocess.run(cmd, shell=True, text=True, env=env)
    if check and result.returncode != 0:
        sys.exit(f"[-] Command failed with exit code {result.returncode}: {cmd}")
    return result


def ensure_dependencies():
    print("\n[+] Checking and installing dependencies...")
    run("sudo apt update -y")
    installed = subprocess.run("dpkg -l", shell=True, text=True, capture_output=True).stdout
    missing = [pkg for pkg in REQUIRED_DEPS if pkg not in installed]
    if missing:
        print(f"[+] Installing missing dependencies: {' '.join(missing)}")
        run(f"sudo apt install -y {' '.join(missing)}")
    else:
        print("[+] All required packages already installed.")


def ensure_java_home():
    candidates = [
        "/usr/lib/jvm/java-17-openjdk-amd64",
        "/usr/lib/jvm/java-11-openjdk-amd64",
        "/usr/lib/jvm/default-java"
    ]
    for c in candidates:
        if Path(c).exists():
            os.environ["JAVA_HOME"] = c
            print(f"[+] JAVA_HOME set to {c}")
            return c
    sys.exit("[-] Java not found after installation.")


def ensure_cmdline_tools():
    if SDKMANAGER_PATH.exists():
        print(f"[+] Command-line tools already installed at {CMDLINE_DIR}")
        return
    print("[+] Downloading Android command-line tools...")
    SDK_ROOT.mkdir(parents=True, exist_ok=True)
    zip_path = Path("/tmp/cmdline-tools.zip")
    urlretrieve(SDK_ZIP_URL, zip_path)
    temp_extract = SDK_ROOT / "cmdline-tools-temp"
    if temp_extract.exists():
        shutil.rmtree(temp_extract)
    temp_extract.mkdir(parents=True, exist_ok=True)
    run(f"unzip -o {zip_path} -d {temp_extract}")
    inner = next(temp_extract.iterdir())
    CMDLINE_DIR.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(inner), CMDLINE_DIR)
    shutil.rmtree(temp_extract)
    zip_path.unlink(missing_ok=True)
    for tool in CMDLINE_DIR.glob("**/*"):
        if tool.is_file():
            tool.chmod(tool.stat().st_mode | 0o111)
    print(f"[+] Installed command-line tools to {CMDLINE_DIR}")


def setup_env():
    env_lines = [
        f'export ANDROID_SDK_ROOT="{SDK_ROOT}"',
        f'export PATH="$PATH:{CMDLINE_DIR}/bin:{SDK_ROOT}/platform-tools:{SDK_ROOT}/emulator"'
    ]
    bashrc = Path.home() / ".bashrc"
    with bashrc.open("a") as f:
        f.write("\n# Android SDK setup\n")
        f.write("\n".join(env_lines) + "\n")
    os.environ["ANDROID_SDK_ROOT"] = str(SDK_ROOT)
    os.environ["PATH"] += f":{CMDLINE_DIR}/bin:{SDK_ROOT}/platform-tools:{SDK_ROOT}/emulator"
    print("[+] Environment configured (added to ~/.bashrc)")


def install_sdk_components():
    sdkmanager = str(SDKMANAGER_PATH)
    if not Path(sdkmanager).exists():
        sys.exit("[-] sdkmanager not found.")
    print("[+] Accepting licenses...")
    run(f"yes | {sdkmanager} --licenses")
    print("[+] Updating sdkmanager...")
    run(f"{sdkmanager} --update")
    print("[+] Installing Android SDK components...")
    run(f"{sdkmanager} 'platform-tools' 'emulator' 'platforms;android-36' '{IMAGE_NAME}'")


def create_avd():
    avd_dir = Path.home() / ".android" / "avd" / f"{AVD_NAME}.avd"
    if avd_dir.exists():
        print(f"[+] AVD '{AVD_NAME}' already exists.")
        return
    print(f"[+] Creating AVD '{AVD_NAME}'...")
    cmd = (
        f"echo no | {AVDMANAGER_PATH} create avd "
        f"--name {AVD_NAME} --package '{IMAGE_NAME}' --device 'pixel'"
    )
    run(cmd)


def test_kvm():
    print("\n[+] Checking for hardware virtualization (KVM)...")
    result = subprocess.run("egrep -c '(vmx|svm)' /proc/cpuinfo", shell=True, capture_output=True, text=True)
    if result.returncode == 0 and int(result.stdout.strip()) > 0:
        print("[+] KVM virtualization supported.")
    else:
        print("[-] KVM not detected. Emulator performance may be degraded.")


def launch_emulator_background():
    emulator = SDK_ROOT / "emulator" / "emulator"
    if not emulator.exists():
        sys.exit("[-] Emulator binary not found. Check installation.")
    print(f"[+] Launching emulator '{AVD_NAME}' in background...")
    cmd = f"{emulator} -avd {AVD_NAME} -no-snapshot -no-boot-anim -gpu off &"
    subprocess.Popen(cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("[+] Emulator started in background. Waiting for it to boot...")
    run("adb wait-for-device", check=False)
    for _ in range(30):
        boot_status = subprocess.run("adb shell getprop sys.boot_completed", shell=True, capture_output=True, text=True)
        if boot_status.stdout.strip() == "1":
            print("[+] Emulator fully booted.")
            return
        time.sleep(5)
    print("[!] Warning: Emulator may not have finished booting yet.")


def is_port_open(host, port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(1)
        try:
            s.connect((host, port))
            return True
        except (socket.timeout, ConnectionRefusedError, OSError):
            return False


def configure_proxy(proxy=None):
    if not proxy:
        print("[i] No proxy specified; skipping proxy configuration.")
        return
    if ":" in proxy:
        host, port_str = proxy.split(":", 1)
        port = int(port_str)
    else:
        host, port = proxy, 8080
    if not is_port_open(host, port):
        print(f"[-] Warning: Nothing appears to be listening on {host}:{port}. Proxy may not work.")
    else:
        print(f"[+] Detected open port {port} on {host} — continuing proxy setup.")
    print(f"[+] Setting Android emulator proxy to {host}:{port}...")
    run("adb root", check=False)
    run(f"adb shell settings put global http_proxy {host}:{port}", check=False)
    run(f"adb shell settings put global https_proxy {host}:{port}", check=False)
    print("[+] Proxy settings applied. Verifying...")
    run("adb shell settings get global http_proxy", check=False)


def parse_args():
    parser = argparse.ArgumentParser(description="Android Emulator Setup (with optional proxy)")
    parser.add_argument("--proxy", type=str, help="Proxy in format IP[:PORT] (e.g., 192.168.1.10:8080)")
    return parser.parse_args()


def main():
    args = parse_args()
    ensure_dependencies()
    ensure_java_home()
    ensure_cmdline_tools()
    setup_env()
    install_sdk_components()
    test_kvm()
    create_avd()
    launch_emulator_background()
    configure_proxy(args.proxy)


if __name__ == "__main__":
    main()
